import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:basic_utils/basic_utils.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gestor_ufu/platform/remote/remote_access_server.dart';

class RemoteAccessPage extends StatefulWidget {
  const RemoteAccessPage({super.key});

  @override
  State<RemoteAccessPage> createState() => _RemoteAccessPageState();
}

class _RemoteAccessPageState extends State<RemoteAccessPage> {
  final _port = TextEditingController(
    text: '${RemoteAccessServer.portDefault}',
  );
  final _cidrs = TextEditingController();
  final _token = TextEditingController();
  String? _certificate;
  String? _privateKey;
  String? _message;
  String? _fingerprint;
  List<String> _addresses = const [];
  bool _busy = true;
  bool _revealToken = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await _loadSettings();
    } catch (error) {
      _message = 'Falha ao carregar a configuração remota: $error';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    _addresses = [
      for (final networkInterface in interfaces)
        for (final address in networkInterface.addresses)
          '${networkInterface.name}: ${address.address}',
    ];
    _certificate = prefs.getString(RemoteAccessServer.certificateKey);
    const vault = FlutterSecureStorage();
    try {
      _privateKey = await vault.read(
        key: RemoteAccessServer.privateKeyMaterialKey,
      );
      if (_privateKey == null) {
        final legacyPath = prefs.getString(RemoteAccessServer.privateKeyKey);
        if (legacyPath != null && await File(legacyPath).exists()) {
          _privateKey = await File(legacyPath).readAsString();
          await vault.write(
            key: RemoteAccessServer.privateKeyMaterialKey,
            value: _privateKey!,
          );
          await prefs.remove(RemoteAccessServer.privateKeyKey);
        }
      }
    } catch (error) {
      _message =
          'Falha ao acessar o armazenamento protegido da chave TLS: $error';
    }
    _cidrs.text =
        (prefs.getStringList(RemoteAccessServer.allowedCidrsKey) ?? const [])
            .join(', ');
    if (_certificate != null) {
      try {
        await _calculateFingerprint(_certificate!);
      } catch (error) {
        _message = 'Certificado PEM inválido: $error';
      }
    }
    _port.text =
        '${prefs.getInt(RemoteAccessServer.portKey) ?? RemoteAccessServer.portDefault}';
    try {
      _token.text = await RemoteAccessServer.instance.token;
    } catch (error) {
      _message = 'Falha ao acessar o armazenamento protegido do token: $error';
    }
  }

  Future<void> _chooseCertificate() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pem', 'crt'],
    );
    final path = result?.files.single.path;
    if (path != null) {
      setState(() => _certificate = path);
      await _calculateFingerprint(path);
    }
  }

  Future<void> _generateCertificate() async {
    setState(() {
      _busy = true;
      _message = 'Gerando certificado local…';
    });
    try {
      await RemoteAccessServer.instance.stop();
      final pair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
      final privateKey = pair.privateKey as RSAPrivateKey;
      final publicKey = pair.publicKey as RSAPublicKey;
      const sans = ['localhost', 'gestor-ufu.local'];
      final csr = X509Utils.generateRsaCsrPem(
        {'CN': 'gestor-ufu.local', 'O': 'Gestor UFU'},
        privateKey,
        publicKey,
        san: sans,
      );
      final certificate = X509Utils.generateSelfSignedCertificate(
        privateKey,
        csr,
        1825,
        sans: sans,
        extKeyUsage: [ExtendedKeyUsage.SERVER_AUTH],
      );
      final directory = Directory(
        p.join(
          Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path,
          'GestorUFU',
          'RemoteFiles',
          'tls',
        ),
      );
      await directory.create(recursive: true);
      final certificateFile = File(
        p.join(directory.path, 'server-certificate.pem'),
      );
      await certificateFile.writeAsString(certificate, flush: true);
      final keyPem = CryptoUtils.encodeRSAPrivateKeyToPem(privateKey);
      const vault = FlutterSecureStorage();
      await vault.write(
        key: RemoteAccessServer.privateKeyMaterialKey,
        value: keyPem,
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        RemoteAccessServer.certificateKey,
        certificateFile.path,
      );
      await prefs.remove(RemoteAccessServer.privateKeyKey);
      _certificate = certificateFile.path;
      _privateKey = keyPem;
      await _calculateFingerprint(certificateFile.path);
      if (mounted)
        setState(() {
          _busy = false;
          _message =
              'Certificado autoassinado criado. Copie o fingerprint ao configurar o Android.';
        });
    } catch (error) {
      if (mounted)
        setState(() {
          _busy = false;
          _message = 'Falha ao gerar certificado: $error';
        });
    }
  }

  Future<void> _calculateFingerprint(String path) async {
    final pem = await File(path).readAsString();
    final match = RegExp(
      r'-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----',
      dotAll: true,
    ).firstMatch(pem);
    if (match == null)
      throw const FormatException('Certificado PEM não encontrado.');
    final hash = sha256
        .convert(base64Decode(match.group(1)!.replaceAll(RegExp(r'\s'), '')))
        .toString();
    if (mounted) setState(() => _fingerprint = hash);
  }

  Future<void> _chooseKey() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['pem', 'key'],
      );
      final path = result?.files.single.path;
      if (path != null) {
        final keyPem = await File(path).readAsString();
        const vault = FlutterSecureStorage();
        await vault.write(
          key: RemoteAccessServer.privateKeyMaterialKey,
          value: keyPem,
        );
        if (mounted) setState(() => _privateKey = keyPem);
      }
    } catch (error) {
      if (mounted)
        setState(() => _message = 'Falha ao carregar chave TLS: $error');
    }
  }

  Future<void> _start() async {
    try {
      await _activateRemoteAccess();
    } catch (error) {
      if (mounted)
        setState(() {
          _busy = false;
          _message = 'Falha ao ativar o acesso remoto: $error';
        });
    }
  }

  Future<void> _activateRemoteAccess() async {
    final port = int.tryParse(_port.text.trim());
    if (port == null || port < 1024 || port > 65535) {
      setState(() => _message = 'Informe uma porta TCP entre 1024 e 65535.');
      return;
    }
    final cidrs = _cidrs.text
        .split(',')
        .map((x) => x.trim())
        .where((x) => x.isNotEmpty)
        .toList();
    if (cidrs.isEmpty) {
      setState(
        () =>
            _message = 'Informe a faixa CIDR da VPN antes de ativar o serviço.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    await RemoteAccessServer.instance.stop();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(RemoteAccessServer.portKey, port);
    await prefs.setStringList(RemoteAccessServer.allowedCidrsKey, cidrs);
    if (_certificate != null)
      await prefs.setString(RemoteAccessServer.certificateKey, _certificate!);
    if (_privateKey != null) {
      const vault = FlutterSecureStorage();
      await vault.write(
        key: RemoteAccessServer.privateKeyMaterialKey,
        value: _privateKey!,
      );
      await prefs.remove(RemoteAccessServer.privateKeyKey);
    }
    await prefs.setBool(RemoteAccessServer.enabledKey, true);
    final error = await RemoteAccessServer.instance.startIfConfigured();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message =
          error ??
          'Serviço HTTPS ativo na porta ${RemoteAccessServer.instance.port}.';
    });
  }

  Future<void> _stop() async {
    await RemoteAccessServer.instance.stop();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(RemoteAccessServer.enabledKey, false);
    if (mounted) setState(() => _message = 'Acesso remoto desativado.');
  }

  Future<void> _rotateToken() async {
    _token.text = await RemoteAccessServer.instance.rotateToken();
    if (mounted)
      setState(
        () => _message = 'Token substituído. Atualize o cadastro no Android.',
      );
  }

  Future<void> _firewall(bool remove) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    final error = await RemoteAccessServer.instance.configureWindowsFirewall(
      remove: remove,
    );
    if (mounted)
      setState(() {
        _busy = false;
        _message =
            error ??
            (remove
                ? 'Regra removida do Firewall do Windows.'
                : 'Regra criada para uma única porta e as faixas CIDR informadas.');
      });
  }

  @override
  void dispose() {
    _port.dispose();
    _cidrs.dispose();
    _token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Acesso remoto pelo Android')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'O celular envia solicitações ao Gestor UFU neste computador. O processamento continua no Windows.',
              style: TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 18),
            TextField(
              controller: _port,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Porta TCP',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _cidrs,
              decoration: const InputDecoration(
                labelText: 'CIDR de origem permitido (obrigatório)',
                hintText: 'Ex.: 10.20.0.0/16, 172.25.40.0/24',
                helperText:
                    'Use somente a faixa confirmada do FortiClient; não use 0.0.0.0/0.',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            ListTile(
              title: Text(
                _certificate ?? 'Selecionar certificado TLS (.pem/.crt)',
              ),
              leading: const Icon(Icons.verified_user_outlined),
              onTap: _chooseCertificate,
            ),
            ListTile(
              title: Text(
                _privateKey == null
                    ? 'Selecionar chave privada TLS (.pem/.key)'
                    : 'Chave privada TLS carregada no armazenamento protegido',
              ),
              leading: const Icon(Icons.key_outlined),
              onTap: _chooseKey,
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _generateCertificate,
              icon: const Icon(Icons.security),
              label: const Text('Gerar certificado TLS local automaticamente'),
            ),
            if (_addresses.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text(
                'Endereços locais do computador (use o que for alcançável pelo FortiClient do celular):',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              for (final address in _addresses) SelectableText(address),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _token,
              readOnly: true,
              obscureText: !_revealToken,
              maxLines: _revealToken ? 2 : 1,
              decoration:
                  const InputDecoration(
                    labelText:
                        'Token deste computador (guardar no cofre do Android)',
                    border: OutlineInputBorder(),
                  ).copyWith(
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: _revealToken
                              ? 'Ocultar token'
                              : 'Mostrar token',
                          onPressed: () =>
                              setState(() => _revealToken = !_revealToken),
                          icon: Icon(
                            _revealToken
                                ? Icons.visibility_off
                                : Icons.visibility,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Copiar token',
                          onPressed: () => Clipboard.setData(
                            ClipboardData(text: _token.text),
                          ),
                          icon: const Icon(Icons.copy),
                        ),
                      ],
                    ),
                  ),
            ),
            if (_fingerprint != null)
              SelectableText(
                'Fingerprint SHA-256 do certificado:\n$_fingerprint',
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _rotateToken,
                icon: const Icon(Icons.refresh),
                label: const Text('Revogar e gerar novo token'),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _busy ? null : _start,
              icon: const Icon(Icons.wifi_tethering),
              label: const Text('Ativar acesso remoto HTTPS'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _stop,
              icon: const Icon(Icons.wifi_off),
              label: const Text('Desativar acesso remoto'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _firewall(false),
              icon: const Icon(Icons.admin_panel_settings),
              label: const Text(
                'Criar regra restrita no Firewall (pedirá administrador)',
              ),
            ),
            TextButton.icon(
              onPressed: _busy ? null : () => _firewall(true),
              icon: const Icon(Icons.delete_outline),
              label: const Text('Remover regra do Gestor UFU'),
            ),
            if (RemoteAccessServer.instance.running)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  'Ativo: https://<endereço interno deste computador>:${RemoteAccessServer.instance.port}',
                ),
              ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_message!),
              ),
            const SizedBox(height: 16),
            const Text(
              'O certificado precisa ser confiado ou fixado pelo app Android. Libere somente esta porta no Firewall do Windows e limite a origem à faixa VPN confirmada. RDP e SoundWire não comprovam que esta porta esteja liberada na rede da UFU.',
              style: TextStyle(color: Colors.deepOrange),
            ),
          ],
        ),
      ),
    ),
  );
}
