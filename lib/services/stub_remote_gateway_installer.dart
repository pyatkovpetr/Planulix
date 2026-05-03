/// Web / не-VM: установка через локальный SSH недоступна.
bool get remoteGatewayInstallSupported => false;

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

Future<RemoteGatewayInstallResult> runRemoteGatewayInstall({
  required String host,
  required String sshUser,
  int sshPort = 22,
  String? identityFilePath,
  required String authToken,
  required String bashScriptBody,
  void Function(String line)? onLog,
}) async {
  onLog?.call(
    'SSH-мастер доступен только в десктопных сборках macOS / Windows / Linux.',
  );
  return const RemoteGatewayInstallResult(
    ok: false,
    exitCode: -1,
    log: 'unsupported platform',
  );
}
