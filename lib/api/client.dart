import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ApiClient {
  late final Dio _dio;
  String? _authToken;
  String? _baseUrl;

  // Compile-time defaults via --dart-define=PLANULIX_BASE_URL=... --dart-define=PLANULIX_TOKEN=...
  // Empty strings by default so release builds ship without embedded credentials.
  static const String defaultBaseUrl = String.fromEnvironment(
    'PLANULIX_BASE_URL',
  );
  static const String defaultToken = String.fromEnvironment('PLANULIX_TOKEN');

  /// Planulix mounts REST under `/api`. `http://host:8990` → `http://host:8990/api`.
  /// Схлопывает лишний суффикс `/api/api` (частая опечатка в настройках).
  static String normalizeApiBaseUrl(String input) {
    var s = input.trim();
    if (s.isEmpty) return s;
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    while (s.endsWith('/api/api')) {
      s = s.substring(0, s.length - 4);
    }
    if (s.endsWith('/api')) return s;
    return '$s/api';
  }

  String? _resolveAuthTokenForRequest() {
    if (_authToken != null && _authToken!.isNotEmpty) return _authToken;
    if (defaultToken.isNotEmpty) return defaultToken;
    return null;
  }

  /// Единый базовый URL для Dio и геттера [baseUrl] (prefs + dart-define).
  String _resolvedBaseUrl() {
    final raw = (_baseUrl != null && _baseUrl!.isNotEmpty)
        ? _baseUrl!
        : defaultBaseUrl;
    return raw.isNotEmpty ? normalizeApiBaseUrl(raw) : '';
  }

  ApiClient({String? baseUrl}) {
    final raw = baseUrl ?? (defaultBaseUrl.isNotEmpty ? defaultBaseUrl : '');
    _baseUrl = raw.isNotEmpty ? normalizeApiBaseUrl(raw) : null;
    _dio = Dio(
      BaseOptions(
        baseUrl: '',
        // Tailscale / VPN paths can be slow to establish; avoid spurious timeouts.
        connectTimeout: const Duration(seconds: 60),
        receiveTimeout: const Duration(seconds: 120),
        headers: {'Content-Type': 'application/json'},
      ),
    );
    _dio.options.baseUrl = _resolvedBaseUrl();

    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final tok = _resolveAuthTokenForRequest();
          if (tok != null && tok.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer $tok';
          }
          handler.next(options);
        },
      ),
    );
  }

  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final tokPref = prefs.getString('authToken');
    if (tokPref != null && tokPref.isNotEmpty) {
      _authToken = tokPref;
    } else {
      _authToken = defaultToken.isNotEmpty ? defaultToken : null;
    }

    // Пустая строка в prefs не считается значением — иначе ломается fallback на dart-define.
    final fromPrefs = prefs.getString('baseUrl');
    final raw = (fromPrefs != null && fromPrefs.trim().isNotEmpty)
        ? fromPrefs.trim()
        : (defaultBaseUrl.isNotEmpty ? defaultBaseUrl : '');
    _baseUrl = raw.isNotEmpty ? normalizeApiBaseUrl(raw) : null;
    if (fromPrefs != null &&
        fromPrefs.trim().isNotEmpty &&
        _baseUrl != null &&
        _baseUrl!.isNotEmpty &&
        _baseUrl != fromPrefs.trim()) {
      await prefs.setString('baseUrl', _baseUrl!);
    }
    _dio.options.baseUrl = _resolvedBaseUrl();
  }

  void updateTimeouts({Duration? connect, Duration? receive}) {
    if (connect != null) _dio.options.connectTimeout = connect;
    if (receive != null) _dio.options.receiveTimeout = receive;
  }

  Future<void> saveSettings(String baseUrl, String token) async {
    final norm = baseUrl.trim().isEmpty ? '' : normalizeApiBaseUrl(baseUrl);
    _baseUrl = norm.isEmpty ? null : norm;
    _authToken = token.isEmpty ? null : token;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('baseUrl', norm);
    await prefs.setString('authToken', token);
    _dio.options.baseUrl = _resolvedBaseUrl();
  }

  Future<void> clearSettings() async {
    _authToken = null;
    _baseUrl = null;
    _dio.options.baseUrl = _resolvedBaseUrl();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('authToken');
    await prefs.remove('baseUrl');
  }

  bool get isConfigured {
    final t = _resolveAuthTokenForRequest();
    return baseUrl.isNotEmpty && t != null && t.isNotEmpty;
  }

  String get baseUrl => _resolvedBaseUrl();

  String? get authToken => _resolveAuthTokenForRequest();

  // Sessions
  /// Server truncates after [limit] (sorted). Keep high enough that Kimi/Codex
  /// sessions are not dropped when many Claude tmux sessions exist.
  Future<List<dynamic>> getSessions({int limit = 500}) async {
    final res = await _dio.get('/sessions', queryParameters: {'limit': limit});
    final data = res.data;
    if (data is Map && data['sessions'] is List) {
      return data['sessions'] as List;
    }
    return const [];
  }

  Future<Map<String, dynamic>> getSession(
    String id, {
    int limit = 100,
    int offset = 0,
  }) async {
    final res = await _dio.get(
      '/sessions/$id',
      queryParameters: {'limit': limit, 'offset': offset},
    );
    return res.data;
  }

  Future<Map<String, dynamic>> createSession({
    String? cwd,
    String? prompt,
    String? name,
    String mode = 'chat',
    String? model,
    String? agent,
    Map<String, String>? agentEnv,
  }) async {
    final body = <String, dynamic>{'mode': mode};
    if (cwd != null) body['cwd'] = cwd;
    if (prompt != null) body['prompt'] = prompt;
    if (name != null) body['name'] = name;
    if (model != null) body['model'] = model;
    if (agent != null) body['agent'] = agent;
    if (agentEnv != null && agentEnv.isNotEmpty) body['agentEnv'] = agentEnv;
    final res = await _dio.post('/sessions', data: body);
    return res.data;
  }

  Future<Map<String, dynamic>> sendMessage(
    String sessionId,
    String text, {
    Map<String, String>? agentEnv,
    String? model,
  }) async {
    final body = <String, dynamic>{
      'text': text,
      if (model != null && model.trim().isNotEmpty) 'model': model.trim(),
      if (agentEnv != null && agentEnv.isNotEmpty) 'agentEnv': agentEnv,
    };
    final res = await _dio.post('/sessions/$sessionId/message', data: body);
    return Map<String, dynamic>.from(res.data as Map? ?? {});
  }

  Future<void> stopSession(String sessionId) async {
    await _dio.delete('/sessions/$sessionId');
  }

  String streamUrl(String sessionId) {
    return '$baseUrl/sessions/$sessionId/stream';
  }

  /// WebSocket URL for normalized session events (`/sessions/:id/events`).
  String sessionEventsWsUrl(String sessionId) {
    final t = _resolveAuthTokenForRequest();
    final q = (t != null && t.isNotEmpty)
        ? '?token=${Uri.encodeQueryComponent(t)}'
        : '';
    var root = baseUrl;
    if (root.startsWith('https://')) {
      root = 'wss://${root.substring(8)}';
    } else if (root.startsWith('http://')) {
      root = 'ws://${root.substring(7)}';
    }
    return '$root/sessions/${Uri.encodeComponent(sessionId)}/events$q';
  }

  Future<Map<String, dynamic>> readFile(String path) async {
    final res = await _dio.get('/file', queryParameters: {'path': path});
    return res.data;
  }

  // Cost Analytics
  Future<Map<String, dynamic>> getCostSummary() async {
    final res = await _dio.get('/cost');
    return res.data;
  }

  Future<Map<String, dynamic>> getPricing() async {
    final res = await _dio.get('/pricing');
    return res.data;
  }

  Future<Map<String, dynamic>> getCapabilities() async {
    final res = await _dio.get('/capabilities');
    return Map<String, dynamic>.from(res.data as Map);
  }

  Future<Map<String, dynamic>> getSessionCost(String sessionId) async {
    final res = await _dio.get('/sessions/$sessionId/cost');
    return res.data;
  }

  Future<void> interruptSession(String sessionId) async {
    await _dio.post('/sessions/$sessionId/interrupt');
  }

  Future<void> continueSession(String sessionId) async {
    await _dio.post('/sessions/$sessionId/continue');
  }

  // Activity heatmap
  Future<Map<String, dynamic>> getActivity() async {
    final res = await _dio.get('/activity');
    return res.data;
  }

  // Search
  Future<Map<String, dynamic>> searchSessions(String query) async {
    final res = await _dio.get('/search', queryParameters: {'q': query});
    return res.data;
  }

  // Tags & Stars
  Future<void> setStar(String sessionId, bool starred) async {
    await _dio.put('/sessions/$sessionId/star', data: {'starred': starred});
  }

  Future<void> setTags(String sessionId, List<String> tags) async {
    await _dio.put('/sessions/$sessionId/tags', data: {'tags': tags});
  }

  Future<void> setSessionTitle(String sessionId, String title) async {
    await _dio.put('/sessions/$sessionId/title', data: {'title': title});
  }

  Future<Map<String, dynamic>> getAllTags() async {
    final res = await _dio.get('/tags');
    return res.data;
  }

  // Projects & Files
  Future<List<dynamic>> getProjects({String? path}) async {
    final res = await _dio.get(
      '/projects',
      queryParameters: path != null ? {'path': path} : null,
    );
    return res.data['projects'] ?? [];
  }

  Future<Map<String, dynamic>> getFileTree(String path) async {
    final res = await _dio.get('/files/tree', queryParameters: {'path': path});
    return res.data;
  }

  Future<Map<String, dynamic>> getGitStatus(String cwd) async {
    final res = await _dio.get('/git/status', queryParameters: {'cwd': cwd});
    return res.data;
  }

  Future<Map<String, dynamic>> getGitDiff(String cwd, String file) async {
    final res = await _dio.get(
      '/git/diff',
      queryParameters: {'cwd': cwd, 'file': file},
    );
    return res.data;
  }

  Future<List<dynamic>> getGitLog(String cwd, {int limit = 30}) async {
    final res = await _dio.get(
      '/git/log',
      queryParameters: {'cwd': cwd, 'limit': limit},
    );
    return res.data['commits'] ?? [];
  }

  // Project upload
  Future<Map<String, dynamic>> uploadProject(
    String name,
    List<int> tarGzBytes, {
    bool overwrite = false,
  }) async {
    final res = await _dio.post(
      '/upload',
      queryParameters: {'name': name, if (overwrite) 'overwrite': 'true'},
      data: Stream.fromIterable([tarGzBytes]),
      options: Options(
        headers: {
          'Content-Type': 'application/octet-stream',
          'Content-Length': tarGzBytes.length.toString(),
        },
        sendTimeout: const Duration(minutes: 10),
        receiveTimeout: const Duration(minutes: 10),
      ),
    );
    return res.data;
  }

  Future<void> deleteProject(String name) async {
    await _dio.delete('/projects', queryParameters: {'name': name});
  }

  /// Полный URL к эндпоинту под префиксом [baseUrl] (игнорирует устаревший [_dio.options.baseUrl]).
  Uri _apiUri(String relativePath) {
    final b = baseUrl;
    if (b.isEmpty) {
      throw StateError('Не задан URL API (Настройки → сервер Planulix).');
    }
    final trimmedBase = b.endsWith('/') ? b.substring(0, b.length - 1) : b;
    final p = relativePath.startsWith('/')
        ? relativePath.substring(1)
        : relativePath;
    return Uri.parse('$trimmedBase/$p');
  }

  /// Clone a GitHub (HTTPS) repo on the server into ~/projects/[name].
  Future<Map<String, dynamic>> cloneGitHubProject({
    required String cloneUrl,
    required String name,
    String? githubToken,
    bool overwrite = false,
  }) async {
    _dio.options.baseUrl = baseUrl;
    final data = <String, dynamic>{
      'clone_url': cloneUrl,
      'name': name,
      if (githubToken != null && githubToken.isNotEmpty)
        'github_token': githubToken,
      'overwrite': overwrite,
    };
    final options = Options(
      sendTimeout: const Duration(seconds: 120),
      receiveTimeout: const Duration(minutes: 25),
    );

    Future<Response<dynamic>> postClone(String pathSuffix) {
      return _dio.postUri(_apiUri(pathSuffix), data: data, options: options);
    }

    try {
      final res = await postClone('projects/clone');
      final d = res.data;
      if (d is Map<String, dynamic>) return d;
      if (d is Map) return Map<String, dynamic>.from(d);
      return <String, dynamic>{};
    } on DioException catch (e) {
      if (e.response?.statusCode != 404) rethrow;
      final res = await postClone('clone');
      final d = res.data;
      if (d is Map<String, dynamic>) return d;
      if (d is Map) return Map<String, dynamic>.from(d);
      return <String, dynamic>{};
    }
  }

  /// Server-side GitHub OAuth (browser login; requires env on Planulix server).
  Future<bool> githubOAuthConfigured() async {
    try {
      final res = await _dio.get('/github/oauth/status');
      final d = res.data;
      return d is Map && d['configured'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> githubOAuthStart() async {
    final res = await _dio.post('/github/oauth/start');
    final d = res.data;
    if (d is Map<String, dynamic>) return d;
    if (d is Map) return Map<String, dynamic>.from(d);
    return <String, dynamic>{};
  }

  /// Returns token when ready; `null` if still waiting (HTTP 404 pending).
  Future<String?> githubOAuthResult(String state) async {
    try {
      final res = await _dio.get(
        '/github/oauth/result',
        queryParameters: {'state': state},
      );
      final d = res.data;
      if (d is Map && d['access_token'] is String) {
        return d['access_token'] as String;
      }
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
    return null;
  }

  // Disk info (server + Yandex Disk)
  Future<Map<String, dynamic>> getDiskInfo() async {
    final res = await _dio.get('/disk-info');
    return res.data;
  }

  // Yandex Disk flow
  Future<Map<String, dynamic>> getYadiskUploadUrl(String name) async {
    final res = await _dio.get(
      '/yadisk/upload-url',
      queryParameters: {'name': name},
    );
    return res.data;
  }

  Future<Map<String, dynamic>> importFromYadisk(
    String diskPath,
    String name, {
    bool overwrite = false,
  }) async {
    final res = await _dio.post(
      '/yadisk/import',
      data: {'diskPath': diskPath, 'name': name, 'overwrite': overwrite},
    );
    return res.data;
  }

  // List available Claude skills (slash commands)
  Future<List<dynamic>> getSkills() async {
    final res = await _dio.get('/skills');
    return res.data['skills'] as List? ?? [];
  }

  // Image upload for chat attachments — returns remote server path
  Future<String> uploadChatImage(List<int> bytes, String ext) async {
    final res = await _dio.post(
      '/upload-image',
      queryParameters: {'ext': ext},
      data: Stream.fromIterable([bytes]),
      options: Options(
        headers: {
          'Content-Type': 'application/octet-stream',
          'Content-Length': bytes.length.toString(),
        },
      ),
    );
    final data = res.data;
    final path = (data is Map) ? data['path'] : null;
    if (path is String) return path;
    throw StateError('uploadChatImage: missing "path" in response');
  }

  // Editor
  Future<void> writeFile(String path, String content) async {
    await _dio.put(
      '/file',
      queryParameters: {'path': path},
      data: {'content': content},
    );
  }

  Future<Map<String, dynamic>> grepInFiles(String cwd, String query) async {
    final res = await _dio.get(
      '/grep',
      queryParameters: {'cwd': cwd, 'q': query},
    );
    return res.data;
  }

  Future<List<String>> listFiles(String cwd) async {
    final res = await _dio.get('/files/list', queryParameters: {'cwd': cwd});
    final data = res.data;
    final list = (data is Map ? data['files'] : null);
    if (list is List) return list.whereType<String>().toList();
    return const [];
  }

  Future<Map<String, dynamic>> getNetworkInfo() async {
    final res = await _dio.get('/network-info');
    return res.data;
  }

  // Raw ping: GET /healthz (no auth) to measure latency
  Future<int> pingHealthz(
    String baseUrl, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final sw = Stopwatch()..start();
    final dio = Dio(
      BaseOptions(connectTimeout: timeout, receiveTimeout: timeout),
    );
    final healthUrl = '${baseUrl.replaceFirst('/api', '')}/healthz';
    await dio.get(healthUrl);
    sw.stop();
    return sw.elapsedMilliseconds;
  }

  String terminalWebSocketUrl(String cwd) {
    final norm = baseUrl;
    final base = norm
        .replaceFirst('http://', 'ws://')
        .replaceFirst('https://', 'wss://');
    return '$base/terminal?cwd=${Uri.encodeQueryComponent(cwd)}';
  }

  /// Установка Claude Code на gateway (может выполняться долго).
  Future<Map<String, dynamic>> setupClaudeCodeInstall({
    bool force = false,
  }) async {
    return setupAgentInstall('claude-code', force: force);
  }

  Future<Map<String, dynamic>> setupAgentInstall(
    String agentId, {
    bool force = false,
  }) async {
    try {
      final res = await _dio.post(
        '/setup/agents/${Uri.encodeComponent(agentId)}'
        '/install',
        queryParameters: force ? {'force': '1'} : null,
        options: Options(receiveTimeout: const Duration(minutes: 10)),
      );
      return Map<String, dynamic>.from(res.data as Map? ?? {});
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        // Backward compatibility: older gateways only know Claude's first setup route.
        if (agentId == 'claude-code') {
          final res = await _dio.post(
            '/setup/claude-code/install',
            queryParameters: force ? {'force': '1'} : null,
            options: Options(receiveTimeout: const Duration(minutes: 10)),
          );
          return Map<String, dynamic>.from(res.data as Map? ?? {});
        }
        return <String, dynamic>{
          'ok': false,
          'gatewayNeedsUpdate': true,
          'agent': agentId,
          'error':
              'Этот Planulix Gateway старее клиента и не поддерживает /setup/agents/:id/install.',
          'log':
              'Сначала обновите gateway на сервере, затем повторите установку агента.\n\n'
              'Команда по SSH:\n'
              'curl -fsSL https://raw.githubusercontent.com/pyatkovpetr/Planulix/main/scripts/install_gateway_remote.sh | AUTH_TOKEN="<ваш токен>" bash -\n\n'
              'После обновления снова откройте Settings -> CLI-агенты на сервере.',
        };
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> setupClaudeCodeAuthStart() async {
    final res = await _dio.post('/setup/claude-code/auth/start');
    return Map<String, dynamic>.from(res.data as Map? ?? {});
  }

  Future<Map<String, dynamic>> setupClaudeCodeAuthState() async {
    final res = await _dio.get('/setup/claude-code/auth/state');
    return Map<String, dynamic>.from(res.data as Map? ?? {});
  }

  Future<void> setupClaudeCodeAuthStop() async {
    await _dio.post('/setup/claude-code/auth/stop');
  }
}
