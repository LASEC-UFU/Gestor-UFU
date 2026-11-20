import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gestor_ufu/data/services/ai_agent/agent_data_host.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/module/module_registry.dart';
import 'package:gestor_ufu/platform/remote/remote_agent_service.dart';

/// API autenticada do Gestor UFU para o cliente Android.
/// TLS é obrigatório: o servidor não inicia sem um certificado configurado.
class RemoteAccessServer {
  RemoteAccessServer._();
  static final instance = RemoteAccessServer._();

  // Starts with the shared-database metadata prefix so machine-specific
  // listener settings are never synchronized to another computer.
  static const _localPrefix = '__gestor_ufu_cloud_sync_remote_access.';
  static const portKey = '${_localPrefix}port';
  static const certificateKey = '${_localPrefix}certificate';
  static const privateKeyMaterialKey = '${_localPrefix}private_key_material';
  // Legacy preference containing a filesystem path; retained for migration.
  static const privateKeyKey = '${_localPrefix}private_key';
  static const enabledKey = '${_localPrefix}enabled';
  static const allowedCidrsKey = '${_localPrefix}allowed_cidrs';
  static const tokenKey = 'remote_access.server_token';
  static const portDefault = 48761;
  static const _uploadInputFields = <String, Set<String>>{
    'moodle.importarPlanilha': {'path'},
    'diario.importarPlanilha': {'path'},
    'diario.carregarJson': {'path'},
    'ajustaHorarios.importarPlanilha': {'path'},
    'planosEnsino.importarWord': {'path'},
    'planosEnsino.importarBackup': {'path'},
    'planosTrabalho.importarPlanilha': {'path'},
    'planosTrabalho.preencherPlanilha': {'modelopath'},
    'planosTrabalho.salvarCadastro': {'pdfpath'},
    'planosTrabalho.inserirNoSei': {'pdfpath'},
    'equivalencia.importarCurriculo': {'path'},
    'equivalencia.importarAnalise': {'path'},
    'progressao.anexarComprovante': {'path'},
    'progressao.lancar': {'comprovante'},
  };

  HttpServer? _server;
  Future<void> Function()? onDataChanged;
  final _tasks = <String, _RemoteTask>{};
  final _idempotency = <String, String>{};
  final _activeModules = <String, String>{};
  final _sockets = <WebSocket>{};
  final _uploadedFiles = <String, File>{};
  final _uploadUseCounts = <String, int>{};
  final _outputFiles = <String, File>{};
  Future<void> _taskWrite = Future<void>.value();
  Future<void> _artifactWrite = Future<void>.value();
  final FlutterSecureStorage _vault = const FlutterSecureStorage();
  final RemoteAgentService agent = RemoteAgentService();
  int get port => _server?.port ?? 0;
  bool get running => _server != null;

  Future<String?> startIfConfigured({
    Future<void> Function()? onDataChanged,
  }) async {
    if (onDataChanged != null) this.onDataChanged = onDataChanged;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(enabledKey) != true) return null;
    final cidrs = prefs.getStringList(allowedCidrsKey) ?? const <String>[];
    if (cidrs.isEmpty || cidrs.any((cidr) => !_validCidr(cidr))) {
      return 'Informe a faixa CIDR atribuída ao FortiClient antes de ativar o serviço.';
    }
    final certificate = prefs.getString(certificateKey);
    String? privateKey;
    try {
      privateKey = await _vault.read(key: privateKeyMaterialKey);
      if (privateKey == null) {
        final legacyPath = prefs.getString(privateKeyKey);
        if (legacyPath != null && await File(legacyPath).exists()) {
          privateKey = await File(legacyPath).readAsString();
          await _vault.write(key: privateKeyMaterialKey, value: privateKey);
          await prefs.remove(privateKeyKey);
        }
      }
    } catch (error) {
      return 'NÃ£o foi possÃ­vel acessar o armazenamento protegido da chave TLS: $error';
    }
    if (certificate == null || privateKey == null) {
      return 'Acesso remoto ativado, mas falta selecionar certificado TLS e chave privada.';
    }
    try {
      await _restoreTasks();
      await _restoreArtifacts();
      await _cleanupOldUploads();
      final context = SecurityContext()
        ..useCertificateChain(certificate)
        ..usePrivateKeyBytes(utf8.encode(privateKey));
      final configuredPort = prefs.getInt(portKey) ?? portDefault;
      _server = await HttpServer.bindSecure(
        InternetAddress.anyIPv4,
        configuredPort,
        context,
      );
      agent
        ..onEvent = _broadcast
        ..executeCommand = _runAgentCommand;
      _server!.listen((request) => unawaited(_handle(request)));
      await _ensureToken();
      return null;
    } catch (error) {
      await _server?.close(force: true);
      _server = null;
      return 'Não foi possível iniciar o serviço remoto: $error';
    }
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    for (final socket in _sockets.toList()) {
      await socket.close(WebSocketStatus.goingAway, 'Serviço encerrado');
    }
    _sockets.clear();
    await server?.close(force: true);
    agent.onEvent = null;
    agent.executeCommand = null;
    await agent.dispose();
  }

  Future<String?> configureWindowsFirewall({required bool remove}) async {
    if (!Platform.isWindows)
      return 'A regra de Firewall está disponível apenas no Windows.';
    final prefs = await SharedPreferences.getInstance();
    final port = prefs.getInt(portKey) ?? portDefault;
    final cidrs = prefs.getStringList(allowedCidrsKey) ?? const <String>[];
    if (!remove && (cidrs.isEmpty || cidrs.any((cidr) => !_validCidr(cidr)))) {
      return 'Configure uma faixa CIDR válida antes de criar a regra.';
    }
    final remote = cidrs
        .map((cidr) => "'${cidr.replaceAll("'", '')}'")
        .join(',');
    final command = remove
        ? "Remove-NetFirewallRule -DisplayName 'Gestor UFU Remote Access' -ErrorAction SilentlyContinue"
        : "Remove-NetFirewallRule -DisplayName 'Gestor UFU Remote Access' -ErrorAction SilentlyContinue; New-NetFirewallRule -DisplayName 'Gestor UFU Remote Access' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port -RemoteAddress @($remote) -Profile Domain,Private -Enabled True | Out-Null";
    final encodedInner = base64Encode(_utf16Le(command));
    final outer =
        "\$p = Start-Process -FilePath powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList @('-NoProfile','-EncodedCommand','$encodedInner'); exit \$p.ExitCode";
    try {
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-EncodedCommand',
        base64Encode(_utf16Le(outer)),
      ]);
      return result.exitCode == 0
          ? null
          : 'O Windows não aplicou a regra (código ${result.exitCode}).';
    } catch (error) {
      return 'Não foi possível solicitar a regra elevada do Firewall: $error';
    }
  }

  List<int> _utf16Le(String value) {
    final bytes = BytesBuilder(copy: false);
    for (final unit in value.codeUnits) {
      bytes.addByte(unit & 0xff);
      bytes.addByte(unit >> 8);
    }
    return bytes.takeBytes();
  }

  Future<String> get token async {
    final current = await _vault.read(key: tokenKey);
    if (current != null && current.length >= 40) return current;
    final bytes = List<int>.generate(48, (_) => Random.secure().nextInt(256));
    final created = base64UrlEncode(bytes);
    await _vault.write(key: tokenKey, value: created);
    return created;
  }

  Future<String> rotateToken() async {
    await _vault.delete(key: tokenKey);
    final replacement = await token;
    for (final socket in _sockets.toList()) {
      try {
        await socket.close(WebSocketStatus.policyViolation, 'Token revogado');
      } catch (_) {}
    }
    _sockets.clear();
    return replacement;
  }

  Future<void> _ensureToken() async {
    final current = await _vault.read(key: tokenKey);
    if (current != null && current.length >= 40) return;
    await token;
  }

  Future<void> _handle(HttpRequest request) async {
    request.response.headers
      ..set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8')
      ..set('Cache-Control', 'no-store')
      ..set('X-Content-Type-Options', 'nosniff');
    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }
    if (!await _sourceAllowed(request)) {
      await _json(request.response, HttpStatus.forbidden, {
        'error': 'Origem fora da faixa de rede autorizada.',
      });
      return;
    }
    if (request.uri.path == '/health') {
      await _json(request.response, HttpStatus.ok, {
        'ok': true,
        'service': 'Gestor UFU',
      });
      return;
    }
    if (!await _authorized(request)) {
      await _json(request.response, HttpStatus.unauthorized, {
        'error': 'Não autorizado.',
      });
      return;
    }
    try {
      final path = request.uri.path;
      if (request.method == 'GET' && path == '/api/v1/modules') {
        await _json(request.response, HttpStatus.ok, {
          'modules': [
            for (final module in ModuleRegistry.instance.modules)
              {
                'id': module.id,
                'title': module.title,
                'description': module.description,
                'enabled': module.enabled,
                'commands': [
                  for (final command in module.commands)
                    if (command.remoteEnabled)
                      {
                        'id': command.id,
                        'title': command.title,
                        'description': command.description,
                        'schema':
                            command.remoteInputSchema ?? command.inputSchema,
                        'requiresConfirmation':
                            command.approval == CommandApproval.required,
                        'mutates': command.mutates,
                      },
                ],
              },
          ],
        });
        return;
      }
      if (request.method == 'POST' && path == '/api/v1/tasks') {
        final body = await _readJson(request);
        await _startTask(request, body);
        return;
      }
      if (request.method == 'POST' && path == '/api/v1/files') {
        await _uploadFile(request);
        return;
      }
      final downloadMatch = RegExp(
        r'^/api/v1/files/([a-zA-Z0-9_-]+)$',
      ).firstMatch(path);
      if (downloadMatch != null && request.method == 'GET') {
        await _downloadFile(request, downloadMatch.group(1)!);
        return;
      }
      if (request.method == 'POST' && path == '/api/v1/agent/message') {
        final body = await _readJson(request);
        final message = body['text'];
        if (message is! String ||
            message.trim().isEmpty ||
            message.length > 12000) {
          await _json(request.response, HttpStatus.badRequest, {
            'error': 'Texto vazio ou acima do limite de 12.000 caracteres.',
          });
          return;
        }
        await _json(request.response, HttpStatus.accepted, {'accepted': true});
        unawaited(_runAgentMessage(message));
        return;
      }
      if (request.method == 'POST' && path == '/api/v1/agent/cancel') {
        if (!await agent.cancel()) {
          await _json(request.response, HttpStatus.conflict, {
            'error': 'O agente não está processando uma solicitação.',
          });
          return;
        }
        await _json(request.response, HttpStatus.accepted, {
          'cancelRequested': true,
          'note':
              'A geração e confirmações pendentes foram interrompidas. Uma operação do módulo que já começou pode continuar.',
        });
        return;
      }
      if (request.method == 'GET' && path == '/api/v1/agent/approvals') {
        await _json(request.response, HttpStatus.ok, {
          'approvals': agent.pendingApprovals,
        });
        return;
      }
      if (request.method == 'GET' && path == '/api/v1/agent/history') {
        await _json(request.response, HttpStatus.ok, {
          'messages': agent.history,
        });
        return;
      }
      if (request.method == 'GET' && path == '/api/v1/agent/status') {
        await _json(request.response, HttpStatus.ok, {
          'busy': agent.busy,
          'lastError': agent.lastError,
          'pendingApprovals': agent.pendingApprovals,
        });
        return;
      }
      final approvalMatch = RegExp(
        r'^/api/v1/agent/approvals/([0-9]+)$',
      ).firstMatch(path);
      if (approvalMatch != null && request.method == 'POST') {
        final body = await _readJson(request);
        final approved = body['approved'];
        if (approved is! bool ||
            !agent.answer(approvalMatch.group(1)!, approved)) {
          await _json(request.response, HttpStatus.notFound, {
            'error': 'Confirmação inexistente ou expirada.',
          });
        } else {
          await _json(request.response, HttpStatus.ok, {'ok': true});
        }
        return;
      }
      final taskMatch = RegExp(
        r'^/api/v1/tasks/([a-zA-Z0-9-]+)$',
      ).firstMatch(path);
      if (taskMatch != null && request.method == 'GET') {
        final task = _tasks[taskMatch.group(1)];
        if (task == null) {
          await _json(request.response, HttpStatus.notFound, {
            'error': 'Tarefa não encontrada.',
          });
        } else {
          await _json(request.response, HttpStatus.ok, task.toJson());
        }
        return;
      }
      if (taskMatch != null && request.method == 'DELETE') {
        final task = _tasks[taskMatch.group(1)];
        if (task == null) {
          await _json(request.response, HttpStatus.notFound, {
            'error': 'Tarefa não encontrada.',
          });
        } else {
          final command = ModuleRegistry.instance.commandById(task.commandId);
          if (command?.runRemote == null ||
              {
                'succeeded',
                'failed',
                'cancelled',
                'interrupted',
              }.contains(task.status)) {
            await _json(request.response, HttpStatus.notImplemented, {
              'error':
                  'Este comando não oferece cancelamento seguro no momento.',
              'cancelSupported': false,
            });
          } else {
            task.cancelRequested = true;
            task.status = 'cancel_requested';
            task.updatedAt = DateTime.now().toUtc();
            await _persistTasks();
            await _broadcast({'type': 'task', 'task': task.toJson()});
            await _json(request.response, HttpStatus.accepted, {
              'ok': true,
              'cancelRequested': true,
            });
          }
        }
        return;
      }
      if (request.method == 'GET' && path == '/api/v1/events') {
        if (!WebSocketTransformer.isUpgradeRequest(request)) {
          await _json(request.response, HttpStatus.badRequest, {
            'error': 'WebSocket obrigatório.',
          });
          return;
        }
        final socket = await WebSocketTransformer.upgrade(request);
        _sockets.add(socket);
        socket.listen(
          (message) {
            if (message == 'snapshot') {
              socket.add(
                jsonEncode({
                  'type': 'snapshot',
                  'tasks': _tasks.values.map((t) => t.toJson()).toList(),
                }),
              );
            }
          },
          onDone: () => _sockets.remove(socket),
          onError: (_) => _sockets.remove(socket),
        );
        return;
      }
      await _json(request.response, HttpStatus.notFound, {
        'error': 'Rota não encontrada.',
      });
    } on FormatException catch (error) {
      await _json(request.response, HttpStatus.badRequest, {
        'error': error.message,
      });
    } on Object catch (error) {
      await _json(request.response, HttpStatus.internalServerError, {
        'error': '$error',
      });
    }
  }

  Future<void> _runAgentMessage(String text) async {
    try {
      await _broadcast({'type': 'agent_status', 'status': 'processing'});
      final completed = await agent.send(text);
      await _broadcast({
        'type': 'agent_status',
        'status': completed ? 'complete' : 'cancelled',
      });
    } catch (error) {
      await _broadcast({'type': 'agent_error', 'message': '$error'});
      await _broadcast({'type': 'agent_status', 'status': 'failed'});
    }
  }

  Future<bool> _authorized(HttpRequest request) async {
    final expected = await _vault.read(key: tokenKey);
    final supplied = request.headers.value(HttpHeaders.authorizationHeader);
    if (expected == null || supplied == null || !supplied.startsWith('Bearer '))
      return false;
    final a = sha256.convert(utf8.encode(supplied.substring(7))).bytes;
    final b = sha256.convert(utf8.encode(expected)).bytes;
    var difference = a.length ^ b.length;
    for (var i = 0; i < min(a.length, b.length); i++) {
      difference |= a[i] ^ b[i];
    }
    return difference == 0;
  }

  Future<bool> _sourceAllowed(HttpRequest request) async {
    final prefs = await SharedPreferences.getInstance();
    final cidrs = prefs.getStringList(allowedCidrsKey) ?? const <String>[];
    final address = request.connectionInfo?.remoteAddress;
    if (address == null) return false;
    return cidrs.any((cidr) => _contains(cidr, address));
  }

  bool _validCidr(String cidr) {
    final parts = cidr.split('/');
    if (parts.length != 2) return false;
    try {
      final address = InternetAddress(parts[0].trim());
      final prefix = int.parse(parts[1]);
      final bits = address.type == InternetAddressType.IPv4 ? 32 : 128;
      final minimum = address.type == InternetAddressType.IPv4 ? 8 : 32;
      return prefix >= minimum && prefix <= bits;
    } catch (_) {
      return false;
    }
  }

  bool _contains(String cidr, InternetAddress candidate) {
    if (!_validCidr(cidr)) return false;
    final pieces = cidr.split('/');
    final network = InternetAddress(pieces[0].trim());
    final prefix = int.parse(pieces[1]);
    var networkBytes = network.rawAddress;
    var candidateBytes = candidate.rawAddress;
    if (networkBytes.length != candidateBytes.length) {
      final mappedV4 =
          candidateBytes.length == 16 &&
          candidateBytes.take(10).every((b) => b == 0) &&
          candidateBytes[10] == 255 &&
          candidateBytes[11] == 255;
      if (mappedV4 && networkBytes.length == 4) {
        candidateBytes = candidateBytes.sublist(12);
      } else {
        return false;
      }
    }
    final whole = prefix ~/ 8;
    final remainder = prefix % 8;
    for (var i = 0; i < whole; i++) {
      if (networkBytes[i] != candidateBytes[i]) return false;
    }
    if (remainder == 0) return true;
    final mask = (0xff << (8 - remainder)) & 0xff;
    return (networkBytes[whole] & mask) == (candidateBytes[whole] & mask);
  }

  Future<void> _startTask(
    HttpRequest request,
    Map<String, dynamic> body,
  ) async {
    final commandId = body['commandId'];
    if (commandId is! String || commandId.trim().isEmpty) {
      await _json(request.response, HttpStatus.badRequest, {
        'error': 'commandId é obrigatório.',
      });
      return;
    }
    final command = ModuleRegistry.instance.commandById(commandId);
    if (command == null) {
      await _json(request.response, HttpStatus.notFound, {
        'error': 'Comando inexistente.',
      });
      return;
    }
    if (!command.remoteEnabled) {
      await _json(request.response, HttpStatus.forbidden, {
        'error':
            'Esta aÃ§Ã£o apenas abre uma tela no computador e nÃ£o estÃ¡ disponÃ­vel como operaÃ§Ã£o remota.',
      });
      return;
    }
    final key = request.headers.value('Idempotency-Key');
    if (key != null &&
        (key.length > 160 || !RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(key))) {
      await _json(request.response, HttpStatus.badRequest, {
        'error': 'Idempotency-Key invÃ¡lida.',
      });
      return;
    }
    if (key != null && _idempotency.containsKey(key)) {
      final existing = _tasks[_idempotency[key]];
      if (existing != null) {
        if (existing.commandId != command.id) {
          await _json(request.response, HttpStatus.conflict, {
            'error': 'A chave de idempotÃªncia jÃ¡ foi usada por outra aÃ§Ã£o.',
          });
          return;
        }
        await _json(request.response, HttpStatus.accepted, existing.toJson());
        return;
      }
    }
    final runningTasks = _tasks.values
        .where(
          (task) =>
              {'queued', 'running', 'cancel_requested'}.contains(task.status),
        )
        .length;
    if (runningTasks >= 4) {
      await _json(request.response, HttpStatus.tooManyRequests, {
        'error': 'O computador já está executando quatro tarefas remotas.',
      });
      return;
    }
    String? moduleId;
    for (final module in ModuleRegistry.instance.modules) {
      if (module.commands.any((item) => item.id == command.id)) {
        moduleId = module.id;
        break;
      }
    }
    if (command.mutates &&
        moduleId != null &&
        _activeModules.containsKey(moduleId)) {
      await _json(request.response, HttpStatus.conflict, {
        'error':
            'Este módulo já tem uma operação remota que altera dados em andamento.',
      });
      return;
    }
    final input = body['input'] is Map
        ? Map<String, dynamic>.from(body['input'] as Map)
        : <String, dynamic>{};
    if (_hasClientPath(input, command.id)) {
      await _json(request.response, HttpStatus.badRequest, {
        'error':
            'Caminhos locais não podem ser enviados pelo celular. Envie o arquivo pelo seletor do app e use a referência upload:// gerada.',
      });
      return;
    }
    if (command.id == 'progressao.criar' &&
        (input['pastaComprovantes'] == null ||
            '${input['pastaComprovantes']}'.trim().isEmpty)) {
      input['pastaComprovantes'] = p.join(
        _localRoot.path,
        'progressao',
        'processo-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32).toRadixString(16)}',
      );
    }
    if (command.approval == CommandApproval.required &&
        body['confirmed'] != true) {
      await _json(request.response, HttpStatus.preconditionRequired, {
        'error': 'Confirme esta ação no celular.',
        'requiresConfirmation': true,
      });
      return;
    }
    final id =
        '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32).toRadixString(16)}';
    final task = _RemoteTask(
      id: id,
      commandId: command.id,
      title: command.title,
      clientAddress: request.connectionInfo?.remoteAddress.address ?? 'unknown',
      moduleId: moduleId,
    );
    task.idempotencyKey = key;
    task.cancelSupported = command.runRemote != null;
    _tasks[id] = task;
    if (command.mutates && moduleId != null) _activeModules[moduleId] = id;
    if (key != null) _idempotency[key] = id;
    try {
      await _persistTasks();
    } catch (_) {
      _tasks.remove(id);
      if (key != null) _idempotency.remove(key);
      if (moduleId != null && _activeModules[moduleId] == id) {
        _activeModules.remove(moduleId);
      }
      await _json(request.response, HttpStatus.insufficientStorage, {
        'error':
            'Não foi possível registrar a operação no computador. Confira o espaço e as permissões da pasta local do Gestor UFU.',
      });
      return;
    }
    _trackUploadedReferences(input, 1);
    await _broadcast({'type': 'task', 'task': task.toJson()});
    unawaited(_execute(task, command, input));
    await _json(request.response, HttpStatus.accepted, task.toJson());
  }

  Future<void> _execute(
    _RemoteTask task,
    ModuleCommand command,
    CommandInput input, {
    CommandOrigin origin = CommandOrigin.ui,
  }) async {
    try {
      task.status = 'running';
      task.updatedAt = DateTime.now().toUtc();
      await _persistTasks();
      await _broadcast({'type': 'task', 'task': task.toJson()});
      final preparedInput = _resolveUploadedPaths(input, command.id);
      if (command.id == 'planosTrabalho.salvarCadastro') {
        final uploadedPath = preparedInput['pdfPath'];
        if (uploadedPath is String &&
            _uploadedFiles.values.any((file) => file.path == uploadedPath)) {
          final source = File(uploadedPath);
          final directory = Directory(
            p.join(_localRoot.path, 'retained', 'planos_trabalho'),
          );
          await directory.create(recursive: true);
          final originalName = p.basename(uploadedPath);
          final shortName = originalName.length > 100
              ? originalName.substring(originalName.length - 100)
              : originalName;
          final storedName =
              '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32).toRadixString(16)}-$shortName';
          final retained = await source.copy(
            p.join(directory.path, storedName),
          );
          preparedInput['pdfPath'] = retained.path;
        }
      }
      final context = CommandExecutionContext(
        isCancellationRequested: () => task.cancelRequested,
        reportProgress: (stage, {fraction}) {
          task.stage = stage;
          task.progress = fraction?.clamp(0.0, 1.0);
          task.updatedAt = DateTime.now().toUtc();
          unawaited(_persistTasks().catchError((_) {}));
          unawaited(_broadcast({'type': 'task', 'task': task.toJson()}));
        },
      );
      context.checkCancellation();
      final result = command.runRemote == null
          ? await command.run(preparedInput, origin)
          : await command.runRemote!(preparedInput, origin, context);
      task.status = result.ok ? 'succeeded' : 'failed';
      task.result = await _sanitizeResult(result.toJson());
      if (command.mutates && result.ok) {
        if (origin == CommandOrigin.agent) {
          await AgentDataHost.instance.notifyDataChanged();
        } else {
          await onDataChanged?.call();
        }
      }
    } on CommandException catch (error) {
      task.status = error.code == 'cancelled' ? 'cancelled' : 'failed';
      task.result = {'ok': false, 'code': error.code, 'message': error.message};
    } catch (error) {
      task.status = 'failed';
      task.result = {'ok': false, 'message': '$error'};
    } finally {
      task.updatedAt = DateTime.now().toUtc();
      if (task.moduleId != null && _activeModules[task.moduleId] == task.id) {
        _activeModules.remove(task.moduleId);
      }
      try {
        await _persistTasks();
      } catch (_) {
        // The live terminal state is still sent to connected clients even if
        // local disk persistence has failed.
      }
      await _broadcast({'type': 'task', 'task': task.toJson()});
      await _releaseUploadedReferences(input);
      if (!task.completion.isCompleted) task.completion.complete();
    }
  }

  Future<String> _runAgentCommand(String commandId, CommandInput input) async {
    String error(String message) => jsonEncode({'ok': false, 'error': message});

    if (!running) return error('O serviço remoto foi desativado.');
    final command = ModuleRegistry.instance.commandById(commandId);
    if (command == null) return error('Comando inexistente: $commandId.');
    if (!command.remoteEnabled) {
      return error('Esta ação não está disponível para execução remota.');
    }
    final active = _tasks.values
        .where(
          (task) =>
              {'queued', 'running', 'cancel_requested'}.contains(task.status),
        )
        .length;
    if (active >= 4) {
      return error('O computador já está executando quatro tarefas remotas.');
    }
    String? moduleId;
    for (final module in ModuleRegistry.instance.modules) {
      if (module.commands.any((item) => item.id == command.id)) {
        moduleId = module.id;
        break;
      }
    }
    if (command.mutates &&
        moduleId != null &&
        _activeModules.containsKey(moduleId)) {
      return error(
        'Este módulo já tem uma operação remota que altera dados em andamento.',
      );
    }
    final task = _RemoteTask(
      id: '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32).toRadixString(16)}',
      commandId: command.id,
      title: command.title,
      clientAddress: 'mobile-agent',
      moduleId: moduleId,
    )..cancelSupported = command.runRemote != null;
    _tasks[task.id] = task;
    if (command.mutates && moduleId != null) _activeModules[moduleId] = task.id;
    try {
      await _persistTasks();
    } catch (_) {
      _tasks.remove(task.id);
      if (moduleId != null && _activeModules[moduleId] == task.id) {
        _activeModules.remove(moduleId);
      }
      return error(
        'Não foi possível registrar a operação no computador. Confira o espaço e as permissões da pasta local do Gestor UFU.',
      );
    }
    _trackUploadedReferences(input, 1);
    await _broadcast({'type': 'task', 'task': task.toJson()});
    unawaited(_execute(task, command, input, origin: CommandOrigin.agent));
    await task.completion.future;
    return jsonEncode({
      'ok': task.status == 'succeeded',
      'taskId': task.id,
      'status': task.status,
      if (task.result != null) 'result': task.result,
    });
  }

  void _trackUploadedReferences(Object? value, int delta) {
    for (final id in _uploadedReferenceIds(value)) {
      final next = (_uploadUseCounts[id] ?? 0) + delta;
      if (next > 0) {
        _uploadUseCounts[id] = next;
      } else {
        _uploadUseCounts.remove(id);
      }
    }
  }

  Future<void> _releaseUploadedReferences(Object? value) async {
    for (final id in _uploadedReferenceIds(value)) {
      final next = (_uploadUseCounts[id] ?? 1) - 1;
      if (next > 0) {
        _uploadUseCounts[id] = next;
        continue;
      }
      _uploadUseCounts.remove(id);
      final file = _uploadedFiles.remove(id);
      try {
        if (file != null && await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  Set<String> _uploadedReferenceIds(Object? value) {
    final ids = <String>{};
    void visit(Object? item) {
      if (item is String && item.startsWith('upload://')) {
        ids.add(item.substring('upload://'.length));
      } else if (item is Map) {
        for (final child in item.values) {
          visit(child);
        }
      } else if (item is List) {
        for (final child in item) {
          visit(child);
        }
      }
    }

    visit(value);
    return ids;
  }

  bool _hasClientPath(Object? value, String commandId) {
    if (value is Map) {
      for (final entry in value.entries) {
        final key = '${entry.key}'.toLowerCase();
        final fileField =
            key.contains('path') ||
            key.contains('file') ||
            key.contains('arquivo') ||
            key.contains('folder') ||
            key.contains('pasta') ||
            key == 'comprovante';
        final permitted = _uploadInputFields[commandId]?.contains(key) == true;
        if (fileField &&
            entry.value is String &&
            (!permitted || !(entry.value as String).startsWith('upload://'))) {
          return true;
        }
        if (_hasClientPath(entry.value, commandId)) return true;
      }
    } else if (value is List) {
      return value.any((item) => _hasClientPath(item, commandId));
    }
    return false;
  }

  CommandInput _resolveUploadedPaths(CommandInput input, String commandId) {
    Object? resolve(Object? value, {String? key}) {
      if (value is String && value.startsWith('upload://')) {
        if (key == null ||
            !(_uploadInputFields[commandId]?.contains(key) ?? false)) {
          throw const CommandException(
            'arquivo_nao_permitido',
            'Este comando nÃ£o aceita arquivo enviado nesse campo.',
          );
        }
        final id = value.substring('upload://'.length);
        final file = _uploadedFiles[id];
        if (file == null || !file.existsSync())
          throw const CommandException(
            'arquivo_remoto_expirado',
            'O arquivo enviado não está mais disponível. Envie-o novamente.',
          );
        return file.path;
      }
      if (value is Map)
        return {
          for (final entry in value.entries)
            '${entry.key}': resolve(
              entry.value,
              key: '${entry.key}'.toLowerCase(),
            ),
        };
      if (value is List)
        return value.map((item) => resolve(item, key: key)).toList();
      return value;
    }

    return Map<String, dynamic>.from(resolve(input) as Map);
  }

  Future<void> _uploadFile(HttpRequest request) async {
    const maxBytes = 100 * 1024 * 1024;
    final declared = request.contentLength;
    if (declared > maxBytes) {
      await _json(request.response, HttpStatus.requestEntityTooLarge, {
        'error': 'O limite por arquivo é 100 MB.',
      });
      return;
    }
    final requestedName = Uri.decodeComponent(
      request.headers.value('X-File-Name') ?? 'arquivo',
    );
    final name = p
        .basename(requestedName)
        .replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_');
    final extension = p.extension(name).toLowerCase();
    const allowed = {
      '.pdf',
      '.docx',
      '.doc',
      '.xlsx',
      '.xlsm',
      '.xls',
      '.csv',
      '.json',
      '.txt',
      '.png',
      '.jpg',
      '.jpeg',
      '.zip',
    };
    if (extension.isEmpty || !allowed.contains(extension)) {
      await _json(request.response, HttpStatus.unsupportedMediaType, {
        'error': 'Formato de arquivo não permitido: $extension',
      });
      return;
    }
    final random = Random.secure();
    final id = base64UrlEncode(
      List<int>.generate(18, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
    final root = Directory(
      p.join(
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path,
        'GestorUFU',
        'RemoteFiles',
        'uploads',
      ),
    );
    await root.create(recursive: true);
    final target = File(p.join(root.path, '$id-$name'));
    final sink = target.openWrite();
    var count = 0;
    try {
      await for (final chunk in request) {
        count += chunk.length;
        if (count > maxBytes) throw const _UploadTooLarge();
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
    } catch (error) {
      await sink.close();
      if (await target.exists()) await target.delete();
      if (error is _UploadTooLarge) {
        await _json(request.response, HttpStatus.requestEntityTooLarge, {
          'error': 'O limite por arquivo é 100 MB.',
        });
      } else {
        rethrow;
      }
      return;
    }
    _uploadedFiles[id] = target;
    await _json(request.response, HttpStatus.created, {
      'id': id,
      'name': name,
      'size': count,
      'reference': 'upload://$id',
    });
  }

  Future<void> _downloadFile(HttpRequest request, String id) async {
    final file = _outputFiles[id];
    if (file == null || !await file.exists()) {
      await _json(request.response, HttpStatus.notFound, {
        'error': 'Arquivo de resultado não encontrado.',
      });
      return;
    }
    request.response.headers
      ..contentType = ContentType.binary
      ..set(
        'content-disposition',
        'attachment; filename="${Uri.encodeComponent(p.basename(file.path))}"',
      )
      ..set(HttpHeaders.cacheControlHeader, 'no-store');
    await file.openRead().pipe(request.response);
  }

  Future<Map<String, Object?>> _sanitizeResult(
    Map<String, Object?> result,
  ) async {
    final artifacts = <Map<String, Object?>>[];
    Future<void> walk(Map<String, Object?> map) async {
      final path = map['path'];
      if (path is String && path.isNotEmpty) {
        final file = File(path);
        if (await file.exists()) {
          final id = base64UrlEncode(
            List<int>.generate(18, (_) => Random.secure().nextInt(256)),
          ).replaceAll('=', '');
          _outputFiles[id] = file;
          artifacts.add({
            'id': id,
            'name': p.basename(path),
            'size': await file.length(),
          });
          await _persistArtifacts();
        }
        map.remove('path');
      }
      for (final value in map.values) {
        if (value is Map<String, Object?>) {
          await walk(value);
        } else if (value is List) {
          for (final child in value) {
            if (child is Map<String, Object?>) await walk(child);
          }
        }
      }
    }

    final clean = Map<String, Object?>.from(result);
    await walk(clean);
    if (artifacts.isNotEmpty) clean['artifacts'] = artifacts;
    return clean;
  }

  Future<void> _restoreTasks() async {
    final file = File(p.join(_localRoot.path, 'tasks.json'));
    if (!await file.exists()) return;
    final rows = jsonDecode(await file.readAsString()) as List? ?? const [];
    for (final row in rows) {
      try {
        final task = _RemoteTask.fromJson(
          Map<String, dynamic>.from(row as Map),
        );
        if (task.status == 'running' || task.status == 'queued')
          task.status = 'interrupted';
        _tasks[task.id] = task;
        if (task.idempotencyKey != null)
          _idempotency[task.idempotencyKey!] = task.id;
      } catch (_) {}
    }
    await _persistTasks();
  }

  Future<void> _persistTasks() async {
    final ordered = _tasks.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final cutoff = DateTime.now().toUtc().subtract(const Duration(days: 30));
    for (final old in ordered.where(
      (task) => task.updatedAt.isBefore(cutoff),
    )) {
      _tasks.remove(old.id);
    }
    for (final old
        in ordered.where((task) => _tasks.containsKey(task.id)).skip(100)) {
      _tasks.remove(old.id);
    }
    _idempotency.removeWhere((_, taskId) => !_tasks.containsKey(taskId));
    final snapshot = _tasks.values.map((t) => t.toJson()).toList();
    _taskWrite = _taskWrite.then(
      (_) => _writeLocalJson('tasks.json', snapshot),
    );
    await _taskWrite;
  }

  Directory get _localRoot => Directory(
    p.join(
      Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path,
      'GestorUFU',
      'RemoteFiles',
    ),
  );

  Future<void> _restoreArtifacts() async {
    final index = File(p.join(_localRoot.path, 'artifacts.json'));
    if (!await index.exists()) return;
    try {
      final rows = Map<String, dynamic>.from(
        jsonDecode(await index.readAsString()) as Map,
      );
      for (final entry in rows.entries) {
        final path = entry.value;
        if (path is String && await File(path).exists())
          _outputFiles[entry.key] = File(path);
      }
    } catch (_) {}
  }

  Future<void> _persistArtifacts() async {
    final snapshot = {
      for (final entry in _outputFiles.entries) entry.key: entry.value.path,
    };
    _artifactWrite = _artifactWrite.then(
      (_) => _writeLocalJson('artifacts.json', snapshot),
    );
    await _artifactWrite;
  }

  Future<void> _writeLocalJson(String name, Object data) async {
    await _localRoot.create(recursive: true);
    final target = File(p.join(_localRoot.path, name));
    final temporary = File(
      '${target.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await temporary.writeAsString(jsonEncode(data), flush: true);
    if (await target.exists()) await target.delete();
    await temporary.rename(target.path);
  }

  Future<void> _cleanupOldUploads() async {
    final root = Directory(p.join(_localRoot.path, 'uploads'));
    if (!await root.exists()) return;
    final cutoff = DateTime.now().subtract(const Duration(hours: 48));
    await for (final item in root.list()) {
      if (item is! File) continue;
      try {
        if ((await item.lastModified()).isBefore(cutoff)) await item.delete();
      } catch (_) {}
    }
  }

  Future<Map<String, dynamic>> _readJson(HttpRequest request) async {
    const maxBytes = 1024 * 1024;
    final bytes = BytesBuilder(copy: false);
    var size = 0;
    await for (final chunk in request) {
      size += chunk.length;
      if (size > maxBytes) {
        throw const FormatException('Corpo excede o limite de 1 MB.');
      }
      bytes.add(chunk);
    }
    final text = utf8.decode(bytes.takeBytes());
    final data = jsonDecode(text);
    if (data is! Map)
      throw const FormatException('Corpo JSON deve ser um objeto.');
    return Map<String, dynamic>.from(data);
  }

  Future<void> _json(HttpResponse response, int status, Object value) async {
    response.statusCode = status;
    response.write(jsonEncode(value));
    await response.close();
  }

  Future<void> _broadcast(Map<String, Object?> event) async {
    final message = jsonEncode(event);
    for (final socket in _sockets.toList()) {
      try {
        socket.add(message);
      } catch (_) {
        _sockets.remove(socket);
      }
    }
  }
}

class _RemoteTask {
  _RemoteTask({
    required this.id,
    required this.commandId,
    required this.title,
    required this.clientAddress,
    this.moduleId,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().toUtc();
  final String id;
  final String commandId;
  final String title;
  final String clientAddress;
  final String? moduleId;
  final DateTime createdAt;
  String status = 'queued';
  String? idempotencyKey;
  bool cancelRequested = false;
  bool cancelSupported = false;
  String? stage;
  double? progress;
  Map<String, Object?>? result;
  final Completer<void> completion = Completer<void>();
  DateTime updatedAt = DateTime.now().toUtc();
  Map<String, Object?> toJson() => {
    'id': id,
    'commandId': commandId,
    'title': title,
    'clientAddress': clientAddress,
    if (moduleId != null) 'moduleId': moduleId,
    'createdAt': createdAt.toIso8601String(),
    'status': status,
    if (idempotencyKey != null) 'idempotencyKey': idempotencyKey,
    'cancelSupported': cancelSupported,
    if (stage != null) 'stage': stage,
    if (progress != null) 'progress': progress,
    'updatedAt': updatedAt.toIso8601String(),
    if (result != null) 'result': result,
  };

  factory _RemoteTask.fromJson(Map<String, dynamic> json) =>
      _RemoteTask(
          id: '${json['id']}',
          commandId: '${json['commandId']}',
          title: '${json['title']}',
          clientAddress: '${json['clientAddress'] ?? 'unknown'}',
          moduleId: json['moduleId'] as String?,
          createdAt: DateTime.tryParse('${json['createdAt']}')?.toUtc(),
        )
        ..status = '${json['status'] ?? 'interrupted'}'
        ..idempotencyKey = json['idempotencyKey'] as String?
        ..cancelSupported = json['cancelSupported'] as bool? ?? false
        ..stage = json['stage'] as String?
        ..progress = (json['progress'] as num?)?.toDouble()
        ..result = json['result'] is Map
            ? Map<String, Object?>.from(json['result'] as Map)
            : null
        ..updatedAt =
            DateTime.tryParse('${json['updatedAt']}')?.toUtc() ??
            DateTime.now().toUtc();
}

class _UploadTooLarge implements Exception {
  const _UploadTooLarge();
}
