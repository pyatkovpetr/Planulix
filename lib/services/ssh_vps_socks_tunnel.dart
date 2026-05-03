import 'dart:io';

import 'package:url_launcher/url_launcher.dart';

/// SSH SOCKS5 до хоста VPS: весь трафик браузера через [socksPort] выходит с IP сервера (удобно для OAuth / зарубежного VPS).
class SshVpsSocksTunnel {
  SshVpsSocksTunnel._();
  static Process? _socks;
  static bool _live = false;

  static const socksPort = 1080;

  static bool get isLive => _live && _socks != null;

  static Future<String?> ensureRunning({
    required String host,
    required String sshUser,
    int sshPort = 22,
  }) async {
    if (_live && _socks != null) return null;
    try {
      final exe = Platform.isWindows ? 'ssh.exe' : 'ssh';
      _socks = await Process.start(exe, [
        '-p',
        '$sshPort',
        '-D',
        '$socksPort',
        '-N',
        '-o',
        'StrictHostKeyChecking=no',
        '-o',
        'ServerAliveInterval=30',
        '-o',
        'ExitOnForwardFailure=yes',
        '$sshUser@$host',
      ]);
      _live = true;
      _socks!.exitCode.then((_) {
        _live = false;
        _socks = null;
      });
      await Future<void>.delayed(const Duration(milliseconds: 900));
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  /// macOS: Chrome с отдельным profile + SOCKS5 → HTTPS идёт через VPS.
  static Future<bool> openChromeWithSocksMacos(String url) async {
    final u = url.trim();
    if (u.isEmpty) return false;
    try {
      final r = await Process.run('open', [
        '-na',
        'Google Chrome',
        '--args',
        '--proxy-server=socks5://127.0.0.1:$socksPort',
        '--user-data-dir=/tmp/planulix-chrome-vps-egress',
        u,
      ]);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Если Chrome не доступен — обычное открытие (без гарантии IP VPS).
  static Future<void> openUrlFallbackBrowser(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  static void stop() {
    final p = _socks;
    if (p != null) {
      try {
        p.kill();
      } catch (_) {}
    }
    _socks = null;
    _live = false;
  }
}
