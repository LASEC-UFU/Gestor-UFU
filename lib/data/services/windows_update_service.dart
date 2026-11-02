import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;

class WindowsUpdateRelease {
  const WindowsUpdateRelease({
    required this.tag,
    required this.version,
    required this.assetName,
    required this.downloadUri,
    this.notes = '',
    this.sha256,
  });

  final String tag;
  final String version;
  final String assetName;
  final Uri downloadUri;
  final String notes;
  final String? sha256;
}

class WindowsUpdateService {
  static final _releaseUri = Uri.https(
    'api.github.com',
    '/repos/LASEC-UFU/Gestor-UFU/releases/latest',
  );
  static const _client = 'GestorUFU-Windows-Updater';
  static final _sha256 = Sha256();

  bool get isInstalledWindowsApp {
    if (!Platform.isWindows) return false;
    final executable = p
        .normalize(p.absolute(Platform.resolvedExecutable))
        .toLowerCase();
    final roots = <String?>[
      Platform.environment['ProgramFiles'],
      Platform.environment['ProgramFiles(x86)'],
    ].whereType<String>().where((root) => root.trim().isNotEmpty);
    return roots.any((root) {
      final installFolder = p.join(root, 'Gestor UFU').toLowerCase();
      return executable.startsWith('$installFolder${p.separator}');
    });
  }

  Future<WindowsUpdateRelease?> findUpdate() async {
    if (!isInstalledWindowsApp) return null;
    try {
      final info = await PackageInfo.fromPlatform();
      final response = await http
          .get(
            _releaseUri,
            headers: const {
              'Accept': 'application/vnd.github+json',
              'User-Agent': _client,
              'X-GitHub-Api-Version': '2022-11-28',
            },
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != HttpStatus.ok) return null;

      final release = jsonDecode(response.body);
      if (release is! Map<String, dynamic> ||
          release['draft'] == true ||
          release['prerelease'] == true) {
        return null;
      }
      final tag = release['tag_name']?.toString() ?? '';
      final latestVersion = _normalizedVersion(tag);
      if (latestVersion == null ||
          _compareVersions(latestVersion, info.version) <= 0) {
        return null;
      }

      final assets = release['assets'];
      if (assets is! List) return null;
      Map<String, dynamic>? installer;
      for (final asset in assets) {
        if (asset is! Map<String, dynamic>) continue;
        final name = asset['name']?.toString() ?? '';
        final downloadUrl = Uri.tryParse(
          asset['browser_download_url']?.toString() ?? '',
        );
        if (name.toLowerCase().endsWith('.msi') &&
            downloadUrl?.scheme == 'https' &&
            downloadUrl?.host == 'github.com') {
          installer = asset;
          break;
        }
      }
      if (installer == null) return null;

      final downloadUri = Uri.parse(
        installer['browser_download_url'].toString(),
      );
      final digest = installer['digest']?.toString();
      return WindowsUpdateRelease(
        tag: tag,
        version: latestVersion,
        assetName: installer['name'].toString(),
        downloadUri: downloadUri,
        notes: _releaseNotes(release['body']?.toString() ?? ''),
        sha256: digest != null && digest.startsWith('sha256:')
            ? digest.substring('sha256:'.length).toLowerCase()
            : null,
      );
    } on Object {
      // A falta de internet ou uma indisponibilidade do GitHub não bloqueia
      // a inicialização do aplicativo.
      return null;
    }
  }

  Future<String> downloadInstaller(
    WindowsUpdateRelease release, {
    required void Function(int received, int total) onProgress,
  }) async {
    final client = http.Client();
    final fileName =
        'GestorUFU_${release.tag.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}.msi';
    final updatesDirectory = Directory(
      p.join(
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path,
        'Gestor UFU',
        'Updates',
      ),
    );
    await updatesDirectory.create(recursive: true);
    final installer = File(p.join(updatesDirectory.path, fileName));
    try {
      final request = http.Request('GET', release.downloadUri);
      request.headers['User-Agent'] = _client;
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'O GitHub respondeu com o status ${response.statusCode}.',
          uri: release.downloadUri,
        );
      }
      final total = response.contentLength ?? 0;
      if (total > 600 * 1024 * 1024) {
        throw const FormatException('O instalador excede o tamanho esperado.');
      }

      final sink = installer.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.stream.timeout(
          const Duration(seconds: 60),
        )) {
          sink.add(chunk);
          received += chunk.length;
          onProgress(received, total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      if (received == 0 || (total > 0 && received != total)) {
        throw const HttpException('O download do instalador ficou incompleto.');
      }
      if (release.sha256 != null) {
        final digest = await _sha256.hash(await installer.readAsBytes());
        final actual = digest.bytes
            .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
            .join();
        if (actual != release.sha256) {
          throw const FormatException(
            'A verificação do instalador falhou. O arquivo foi descartado.',
          );
        }
      }
      return installer.path;
    } catch (_) {
      if (await installer.exists()) await installer.delete();
      rethrow;
    } finally {
      client.close();
    }
  }

  Future<void> installAfterApplicationCloses(
    String installerPath, {
    required String expectedVersion,
  }) async {
    if (!isInstalledWindowsApp) {
      throw const FileSystemException(
        'A atualização automática está disponível na instalação do Windows.',
      );
    }
    final windows = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final powershell = p.join(
      windows,
      r'System32\WindowsPowerShell\v1.0\powershell.exe',
    );
    final helper = File(
      p.join(
        Directory.systemTemp.path,
        'gestor_ufu_updater_${pid}_${DateTime.now().microsecondsSinceEpoch}.ps1',
      ),
    );
    final logDirectory = Directory(
      p.join(
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path,
        'Gestor UFU',
      ),
    );
    await logDirectory.create(recursive: true);
    final logPath = p.join(logDirectory.path, 'atualizacao.log');
    final installer = File(installerPath);
    if (!await installer.exists() || await installer.length() == 0) {
      throw const FileSystemException(
        'O instalador da atualização não existe ou está vazio.',
      );
    }
    await helper.writeAsBytes(
      [0xef, 0xbb, 0xbf, ...utf8.encode(_installerHelper)],
      flush: true,
    );
    try {
      await Process.start(powershell, [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        helper.path,
        '-ParentPid',
        pid.toString(),
        '-MsiPath',
        installerPath,
        '-AppPath',
        Platform.resolvedExecutable,
        '-ExpectedVersion',
        expectedVersion,
        '-LogPath',
        logPath,
      ], mode: ProcessStartMode.detached);
    } on Object {
      if (await helper.exists()) await helper.delete();
      rethrow;
    }
  }

  static String? _normalizedVersion(String value) {
    final parts = RegExp(r'\d+')
        .allMatches(value)
        .take(3)
        .map((match) => int.tryParse(match.group(0) ?? ''))
        .toList();
    if (parts.length != 3 || parts.any((part) => part == null)) return null;
    return parts.map((part) => part.toString()).join('.');
  }

  static int _compareVersions(String latest, String current) {
    final a = _normalizedVersion(latest)!.split('.').map(int.parse).toList();
    final b = _normalizedVersion(current) ?? '0.0.0';
    final currentParts = b.split('.').map(int.parse).toList();
    for (var i = 0; i < 3; i++) {
      final comparison = a[i].compareTo(currentParts[i]);
      if (comparison != 0) return comparison;
    }
    return 0;
  }

  static String _releaseNotes(String notes) {
    final trimmed = notes.trim();
    if (trimmed.isEmpty) return 'Correções e melhorias do Gestor UFU.';
    return trimmed.length <= 2400 ? trimmed : '${trimmed.substring(0, 2400)}…';
  }

  static const _installerHelper = r'''
param(
  [int]$ParentPid,
  [string]$MsiPath,
  [string]$AppPath,
  [string]$ExpectedVersion,
  [string]$LogPath
)
$ErrorActionPreference = 'Stop'
$installSucceeded = $false
function Write-UpdateLog([string]$Message) {
  $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"
  Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}
function Show-UpdateError([string]$Message) {
  try {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
      "$Message`r`n`r`nLog: $LogPath",
      'Atualização do Gestor UFU',
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
  } catch { }
}
try {
  Write-UpdateLog "Atualização para $ExpectedVersion iniciada. Instalador: $MsiPath"
  if (-not (Test-Path -LiteralPath $MsiPath)) {
    throw "O instalador baixado não foi encontrado: $MsiPath"
  }
  while (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue) {
    Start-Sleep -Milliseconds 400
  }
  Write-UpdateLog 'Aplicativo encerrado; iniciando Windows Installer.'
  $msiLog = [System.IO.Path]::ChangeExtension($LogPath, 'msi.log')
  $arguments = '/i "' + $MsiPath + '" /passive /norestart /L*V "' + $msiLog + '"'
  $result = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -Verb RunAs -Wait -PassThru
  Write-UpdateLog "Windows Installer terminou com código $($result.ExitCode). Log MSI: $msiLog"
  if ($result.ExitCode -ne 0 -and $result.ExitCode -ne 3010) {
    throw "A instalação MSI falhou com o código $($result.ExitCode)."
  }
  if (-not (Test-Path -LiteralPath $AppPath)) {
    throw "A instalação terminou, mas o executável não foi encontrado: $AppPath"
  }
  $installedVersion = (Get-Item -LiteralPath $AppPath).VersionInfo.ProductVersion
  $installedVersionParts = $installedVersion -split '\.'
  $expectedVersionParts = $ExpectedVersion -split '\.'
  if ($installedVersionParts.Count -lt 3 -or $expectedVersionParts.Count -lt 3) {
    throw "Não foi possível validar a versão instalada ($installedVersion; esperada $ExpectedVersion)."
  }
  $installedComparable = [version]::Parse(($installedVersionParts[0..2] -join '.') + '.0')
  $expectedComparable = [version]::Parse(($expectedVersionParts[0..2] -join '.') + '.0')
  if ($installedComparable -lt $expectedComparable) {
    throw "O instalador concluiu, mas a versão encontrada ($installedVersion) é anterior à esperada ($ExpectedVersion)."
  }
  Write-UpdateLog "Instalação confirmada; executável versão $installedVersion. Reabrindo aplicativo."
  Start-Process -FilePath $AppPath -WorkingDirectory (Split-Path -Parent $AppPath)
  $installSucceeded = $true
} catch {
  $message = $_.Exception.Message
  try { Write-UpdateLog "ERRO: $message`r`n$($_ | Out-String)" } catch { }
  Show-UpdateError "Não foi possível concluir a atualização. O Gestor UFU não foi fechado definitivamente. $message"
  if (Test-Path -LiteralPath $AppPath) {
    Start-Process -FilePath $AppPath -WorkingDirectory (Split-Path -Parent $AppPath)
  }
} finally {
  if ($installSucceeded) {
    Remove-Item -LiteralPath $MsiPath -Force -ErrorAction SilentlyContinue
  }
  Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
}
''';
}
