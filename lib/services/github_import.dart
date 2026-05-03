import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// GitHub OAuth (device flow) + repo listing for "Import from GitHub".
/// OAuth App needs **Device authorization** enabled in GitHub settings.
class GitHubImportConfig {
  static const _kToken = 'githubAccessToken';
  static const _kClientId = 'githubOAuthClientId';

  /// `--dart-define=GITHUB_OAUTH_CLIENT_ID=...` overrides stored value.
  static Future<String?> getClientId() async {
    const env = String.fromEnvironment('GITHUB_OAUTH_CLIENT_ID');
    if (env.isNotEmpty) return env;
    final p = await SharedPreferences.getInstance();
    return p.getString(_kClientId);
  }

  static Future<void> setClientId(String value) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kClientId, value.trim());
  }

  static Future<String?> getAccessToken() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kToken);
  }

  static Future<void> setAccessToken(String token) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kToken, token);
  }

  static Future<void> clearAccessToken() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kToken);
  }
}

class GitHubDeviceStart {
  GitHubDeviceStart({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.verificationUriComplete,
    required this.expiresIn,
    required this.interval,
  });

  final String deviceCode;
  final String userCode;
  final String verificationUri;
  final String? verificationUriComplete;
  final int expiresIn;
  final int interval;
}

class GitHubRepoItem {
  GitHubRepoItem({
    required this.name,
    required this.fullName,
    required this.cloneUrl,
    required this.private,
  });

  final String name;
  final String fullName;
  final String cloneUrl;
  final bool private;

  static GitHubRepoItem? fromJson(Map<String, dynamic> m) {
    final name = m['name'];
    final full = m['full_name'];
    final clone = m['clone_url'];
    if (name is! String || full is! String || clone is! String) return null;
    return GitHubRepoItem(
      name: name,
      fullName: full,
      cloneUrl: clone,
      private: m['private'] == true,
    );
  }
}

class GitHubImportService {
  GitHubImportService._();

  static final Dio _io = Dio();

  static Future<GitHubDeviceStart> requestDeviceCode(String clientId) async {
    final res = await _io.post<Map<String, dynamic>>(
      'https://github.com/login/device/code',
      data: {
        'client_id': clientId,
        'scope': 'repo read:user',
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        headers: {'Accept': 'application/json'},
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    final data = res.data;
    if (data == null) throw StateError('Empty response from GitHub');
    if (data['error'] != null) {
      throw StateError('${data['error']}: ${data['error_description'] ?? ''}');
    }
    final dc = data['device_code'];
    final uc = data['user_code'];
    final vu = data['verification_uri'];
    if (dc is! String || uc is! String || vu is! String) {
      throw StateError('Unexpected device code response');
    }
    return GitHubDeviceStart(
      deviceCode: dc,
      userCode: uc,
      verificationUri: vu,
      verificationUriComplete: data['verification_uri_complete'] as String?,
      expiresIn: (data['expires_in'] as num?)?.toInt() ?? 900,
      interval: (data['interval'] as num?)?.toInt() ?? 5,
    );
  }

  /// Returns access token, or `null` if denied / expired.
  static Future<String?> pollDeviceAccessToken({
    required String clientId,
    required String deviceCode,
    required int interval,
    required int expiresIn,
    bool Function()? cancelled,
  }) async {
    final deadline = DateTime.now().add(Duration(seconds: expiresIn));
    var sleepSec = interval.clamp(1, 60);
    while (DateTime.now().isBefore(deadline)) {
      if (cancelled?.call() == true) return null;
      await Future<void>.delayed(Duration(seconds: sleepSec));
      if (cancelled?.call() == true) return null;

      final res = await _io.post<Map<String, dynamic>>(
        'https://github.com/login/oauth/access_token',
        data: {
          'client_id': clientId,
          'device_code': deviceCode,
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        },
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: {'Accept': 'application/json'},
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final data = res.data;
      if (data == null) continue;

      final tok = data['access_token'];
      if (tok is String && tok.isNotEmpty) return tok;

      final err = data['error'] as String?;
      if (err == 'authorization_pending') {
        sleepSec = interval.clamp(1, 60);
        continue;
      }
      if (err == 'slow_down') {
        sleepSec = (sleepSec + 5).clamp(1, 60);
        continue;
      }
      return null;
    }
    return null;
  }

  static Future<List<GitHubRepoItem>> listRepos(String accessToken, {int maxPages = 3}) async {
    final out = <GitHubRepoItem>[];
    for (var page = 1; page <= maxPages; page++) {
      final res = await _io.get<List<dynamic>>(
        'https://api.github.com/user/repos',
        queryParameters: {
          'per_page': 100,
          'page': page,
          'sort': 'updated',
          'affiliation': 'owner,collaborator,organization_member',
        },
        options: Options(
          headers: {
            'Authorization': 'Bearer $accessToken',
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
          },
          validateStatus: (s) => s == 200,
        ),
      );
      final list = res.data;
      if (list == null || list.isEmpty) break;
      for (final raw in list) {
        if (raw is Map) {
          final item = GitHubRepoItem.fromJson(Map<String, dynamic>.from(raw));
          if (item != null) out.add(item);
        }
      }
      if (list.length < 100) break;
    }
    return out;
  }

  static Future<String?> getLogin(String accessToken) async {
    final res = await _io.get<Map<String, dynamic>>(
      'https://api.github.com/user',
      options: Options(
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Accept': 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2022-11-28',
        },
        validateStatus: (s) => s == 200,
      ),
    );
    final login = res.data?['login'];
    return login is String ? login : null;
  }
}
