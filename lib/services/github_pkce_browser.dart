import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

/// GitHub PKCE: один callback в OAuth App.
const kGithubPkceLocalPort = 54801;
const kGithubPkceCallbackPath = '/planulix-github-callback';

String get githubPkceCallbackUrl =>
    'http://127.0.0.1:$kGithubPkceLocalPort$kGithubPkceCallbackPath';

String _randomString(int len) {
  const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~';
  final r = Random.secure();
  return List.generate(len, (_) => chars[r.nextInt(chars.length)]).join();
}

String _s256Challenge(String verifier) {
  final bytes = sha256.convert(utf8.encode(verifier)).bytes;
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// GitHub всё равно требует [clientSecret] на шаге обмена кода на токен (см. docs:
/// `client_secret` required), иначе ответ — `incorrect_client_credentials` при верном client_id.
Future<String?> githubAuthorizePkceBrowser(
  String clientId, {
  required String clientSecret,
}) async {
  if (kIsWeb) return null;
  if (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux) return null;

  final trimmed = clientId.trim();
  final secret = clientSecret.trim();
  if (trimmed.isEmpty || secret.isEmpty) return null;

  final verifier = _randomString(64);
  final challenge = _s256Challenge(verifier);
  final state = _randomString(24);
  final redirectUri = githubPkceCallbackUrl;

  HttpServer server;
  try {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, kGithubPkceLocalPort);
  } catch (e, st) {
    debugPrint('github_pkce: bind 127.0.0.1:$kGithubPkceLocalPort failed: $e');
    debugPrintStack(stackTrace: st);
    final isAddrInUse = e is SocketException &&
        (e.message.contains('Address already in use') ||
            e.osError?.errorCode == 48); // EADDRINUSE on macOS
    if (isAddrInUse) {
      throw StateError(
        'Порт $kGithubPkceLocalPort занят. Callback: $redirectUri. '
        'Кто слушает: lsof -nP -iTCP:$kGithubPkceLocalPort -sTCP:LISTEN',
      );
    }
    throw StateError(
      'Не удалось открыть локальный сервер на $kGithubPkceLocalPort '
      '(callback: $redirectUri).\n'
      'Причина: $e\n'
      'Если это Release-сборка macOS: в entitlements должен быть '
      'com.apple.security.network.server.',
    );
  }

  final completer = Completer<String?>();
  final subscription = server.listen((HttpRequest req) async {
    if (req.uri.path != kGithubPkceCallbackPath) {
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }
    final q = req.uri.queryParameters;
    final err = q['error'];
    final code = q['code'];
    final st = q['state'];

    req.response.statusCode = 200;
    req.response.headers.contentType = ContentType.html;
    req.response.write(
      '<!DOCTYPE html><meta charset="utf-8"><body style="font-family:system-ui;background:#0f172a;color:#e2e8f0;padding:2rem">Можно закрыть это окно.</body>',
    );
    await req.response.close();

    if (completer.isCompleted) return;
    if (err != null) {
      completer.complete(null);
      return;
    }
    if (st != state || code == null || code.isEmpty) {
      completer.complete(null);
      return;
    }
    completer.complete(code);
  });

  try {
    final uri = Uri.https('github.com', '/login/oauth/authorize', {
      'client_id': trimmed,
      'redirect_uri': redirectUri,
      'scope': 'repo read:user',
      'state': state,
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
    });

    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched) {
      throw StateError('Не удалось открыть браузер');
    }

    final code = await completer.future.timeout(
      const Duration(minutes: 10),
      onTimeout: () => null,
    );

    if (code == null) return null;

    final dio = Dio();
    final res = await dio.post<dynamic>(
      'https://github.com/login/oauth/access_token',
      data: {
        'client_id': trimmed,
        'client_secret': secret,
        'code': code,
        'redirect_uri': redirectUri,
        'code_verifier': verifier,
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        headers: {'Accept': 'application/json'},
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    final data = res.data;
    if (data is Map && data['access_token'] is String) {
      return data['access_token'] as String;
    }
    if (data is Map && data['error'] != null) {
      final err = data['error'].toString();
      final desc = data['error_description']?.toString() ?? '';
      if (err == 'incorrect_client_credentials') {
        throw StateError(
          'GitHub: неверная пара Client ID / Client Secret на шаге обмена кода. '
          'Проверьте `--dart-define=GITHUB_OAUTH_CLIENT_SECRET=...` (для PKCE) '
          'или используйте device flow / серверный OAuth. ($desc)',
        );
      }
      throw StateError('GitHub: $err $desc');
    }
    return null;
  } finally {
    await subscription.cancel();
    await server.close(force: true);
  }
}

bool githubPkceSupportedOnPlatform() {
  if (kIsWeb) return false;
  return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
}
