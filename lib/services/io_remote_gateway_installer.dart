import 'dart:async';
import 'dart:convert';
import 'dart:io';

bool get remoteGatewayInstallSupported =>
    Platform.isMacOS || Platform.isWindows || Platform.isLinux;

class RemoteGatewayInstallResult {
  const RemoteGatewayInstallResult({
    required this.ok,
    required this.exitCode,
    required this.log,
  });
  final bool ok;
  final int exitCode;
  final String log;
}

String _shellSingleQuote(String s) {
  return "'${s.replaceAll("'", "'\\''")}'";
}

/// Запускает `ssh user@host bash -s` и передаёт скрипт в stdin (AUTH_TOKEN экспортируется первой строкой).
Future<RemoteGatewayInstallResult> runRemoteGatewayInstall({
  required String host,
  required String sshUser,
  int sshPort = 22,
  String? identityFilePath,
  required String authToken,
  required String bashScriptBody,
  void Function(String line)? onLog,
}) async {
  final logBuf = StringBuffer();
  void logLine(String s) {
    logBuf.writeln(s);
    onLog?.call(s);
  }

  if (host.trim().isEmpty || sshUser.trim().isEmpty) {
    return RemoteGatewayInstallResult(ok: false, exitCode: -1, log: logBuf.toString());
  }

  final args = <String>[
    '-p',
    '$sshPort',
    '-o',
    'BatchMode=yes',
    '-o',
    'StrictHostKeyChecking=accept-new',
    if (identityFilePath != null && identityFilePath.trim().isNotEmpty) ...[
      '-i',
      identityFilePath.trim(),
    ],
    '$sshUser@$host',
    'bash',
    '-s',
    '--',
  ];

  final payload =
      'export AUTH_TOKEN=${_shellSingleQuote(authToken)}\n$bashScriptBody';

  Process? proc;
  try {
    proc = await Process.start(
      Platform.isWindows ? 'ssh.exe' : 'ssh',
      args,
      runInShell: false,
      environment: {...Platform.environment},
    );

    proc.stdin.add(utf8.encode(payload));
    await proc.stdin.close();

    Future<void> pipe(Stream<List<int>> stream, bool err) async {
      await for (final chunk in stream.transform(utf8.decoder)) {
        for (final line in chunk.split('\n')) {
          if (line.isEmpty) continue;
          logLine(err ? '[stderr] $line' : line);
        }
      }
    }

    await Future.wait([
      pipe(proc.stdout, false),
      pipe(proc.stderr, true),
    ]);
    final code = await proc.exitCode.timeout(const Duration(seconds: 360));
    final ok =
        code == 0 &&
        logBuf.toString().split('\n').any((l) => l.contains('PLANULIX_INSTALL_OK'));
    return RemoteGatewayInstallResult(ok: ok, exitCode: code, log: logBuf.toString());
  } on SocketException catch (e, st) {
    logLine('Socket: $e\n$st');
    return RemoteGatewayInstallResult(ok: false, exitCode: -2, log: logBuf.toString());
  } on TimeoutException catch (e) {
    logLine('Timeout: $e');
    try {
      proc?.kill(ProcessSignal.sigkill);
    } catch (_) {}
    return RemoteGatewayInstallResult(ok: false, exitCode: -3, log: logBuf.toString());
  } catch (e, st) {
    logLine('Error: $e\n$st');
    return RemoteGatewayInstallResult(ok: false, exitCode: -4, log: logBuf.toString());
  }
}
