import 'package:dio/dio.dart';

/// HTTP client for Planulix Cloud control plane (`/v1/...`). Base URL is the API root (no `/api` suffix).
class SaasClient {
  late final Dio _dio;
  String? _baseUrl;
  String? _jwt;

  SaasClient({String? baseUrl, String? jwt}) {
    _baseUrl = baseUrl != null && baseUrl.isNotEmpty ? normalizeSaasBaseUrl(baseUrl) : null;
    _jwt = jwt;
    _dio = Dio(BaseOptions(
      baseUrl: _baseUrl ?? '',
      connectTimeout: const Duration(seconds: 45),
      receiveTimeout: const Duration(seconds: 90),
      headers: const {'Content-Type': 'application/json'},
    ));
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        final t = _jwt;
        if (t != null && t.isNotEmpty) {
          options.headers['Authorization'] = 'Bearer $t';
        }
        handler.next(options);
      },
    ));
  }

  static String normalizeSaasBaseUrl(String input) {
    var s = input.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  void update({String? baseUrl, String? jwt}) {
    if (baseUrl != null) {
      _baseUrl = baseUrl.isEmpty ? null : normalizeSaasBaseUrl(baseUrl);
      _dio.options.baseUrl = _baseUrl ?? '';
    }
    if (jwt != null) {
      _jwt = jwt.isEmpty ? null : jwt;
    }
  }

  String? get baseUrl => _baseUrl;
  String? get jwt => _jwt;

  bool get isConfigured =>
      (_baseUrl != null && _baseUrl!.isNotEmpty) && (_jwt != null && _jwt!.isNotEmpty);

  Future<Map<String, dynamic>> register({
    required String email,
    required String password,
    String tenantName = 'My workspace',
  }) async {
    final res = await _dio.post<Map<String, dynamic>>('/v1/auth/register', data: {
      'email': email,
      'password': password,
      'tenant_name': tenantName,
    });
    return Map<String, dynamic>.from(res.data ?? {});
  }

  Future<Map<String, dynamic>> login({
    required String email,
    required String password,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>('/v1/auth/login', data: {
      'email': email,
      'password': password,
    });
    return Map<String, dynamic>.from(res.data ?? {});
  }

  Future<Map<String, dynamic>> me() async {
    final res = await _dio.get<Map<String, dynamic>>('/v1/me');
    return Map<String, dynamic>.from(res.data ?? {});
  }

  Future<List<Map<String, dynamic>>> listServers() async {
    final res = await _dio.get<Map<String, dynamic>>('/v1/servers');
    final raw = res.data?['servers'];
    if (raw is! List) return [];
    return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<Map<String, dynamic>> usageSummary() async {
    final res = await _dio.get<Map<String, dynamic>>('/v1/usage/summary');
    return Map<String, dynamic>.from(res.data ?? {});
  }

  Future<Map<String, dynamic>> createServer({required String name}) async {
    final res = await _dio.post<Map<String, dynamic>>('/v1/servers', data: {'name': name});
    return Map<String, dynamic>.from(res.data ?? {});
  }

  /// Returns fresh one-liner [install_command] (invalidates previous agent secret when the link is used).
  Future<Map<String, dynamic>> requestInstallCommand(String serverId) async {
    final res = await _dio.post<Map<String, dynamic>>('/v1/servers/$serverId/install-command');
    return Map<String, dynamic>.from(res.data ?? {});
  }

  Future<List<Map<String, dynamic>>> workspaceFiles(String serverId) async {
    final res = await _dio.get<Map<String, dynamic>>('/v1/workspaces/$serverId/files');
    final raw = res.data?['files'];
    if (raw is! List) return [];
    return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<void> postUsageBatch(List<Map<String, dynamic>> events) async {
    await _dio.post<void>('/v1/usage/batch', data: {'events': events});
  }
}
