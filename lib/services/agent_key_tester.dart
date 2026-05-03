import 'package:dio/dio.dart';

/// Calls each provider’s lightweight endpoint from this device (keys never go through Planulix).
class AgentKeyTester {
  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 25),
    validateStatus: (s) => s != null && s < 500,
  ));

  static Future<Map<String, String>> testAll({
    String? kimi,
    String? anthropic,
    String? openai,
  }) async {
    final out = <String, String>{};
    final k = kimi?.trim();
    if (k != null && k.isNotEmpty) {
      out['Kimi / Moonshot'] = await _moonshotModels(k);
    }
    final a = anthropic?.trim();
    if (a != null && a.isNotEmpty) {
      out['Anthropic'] = await _anthropicModels(a);
    }
    final o = openai?.trim();
    if (o != null && o.isNotEmpty) {
      out['OpenAI'] = await _openaiModels(o);
    }
    if (out.isEmpty) {
      out['_'] = 'Нет непустых ключей для проверки';
    }
    return out;
  }

  /// Moonshot Open Platform is OpenAI-compatible; keys issued on `.ai` vs `.cn` consoles
  /// must use the matching API host or you get HTTP 401.
  static Future<String> _moonshotModels(String key) async {
    const bases = <String>[
      'https://api.moonshot.ai',
      'https://api.moonshot.cn',
    ];
    String? bestDetail;
    for (final base in bases) {
      try {
        final r = await _dio.get<Map<String, dynamic>>(
          '$base/v1/models',
          options: Options(
            headers: {'Authorization': 'Bearer $key'},
            validateStatus: (s) => s != null && s < 600,
          ),
        );
        final code = r.statusCode ?? 0;
        if (code == 200) {
          final n = r.data?['data'] is List ? (r.data!['data'] as List).length : '?';
          return 'OK ($n models, $base)';
        }
        final err = r.data is Map && (r.data! as Map)['error'] != null
            ? ((r.data! as Map)['error']).toString()
            : '';
        bestDetail = 'HTTP $code @ $base${err.isNotEmpty ? ' — $err' : ''}';
        if (code != 401) {
          return bestDetail;
        }
      } catch (e) {
        bestDetail = '$e @ $base';
      }
    }
    return bestDetail ?? 'Не удалось достучаться до Moonshot';
  }

  static Future<String> _anthropicModels(String key) async {
    try {
      final r = await _dio.get<dynamic>(
        'https://api.anthropic.com/v1/models',
        options: Options(headers: {
          'x-api-key': key,
          'anthropic-version': '2023-06-01',
        }),
      );
      if (r.statusCode == 200) return 'OK';
      if (r.statusCode == 404) {
        return 'HTTP 404 (эндпоинт недоступен для ключа — попробуйте ключ в консоли Anthropic)';
      }
      return 'HTTP ${r.statusCode}';
    } catch (e) {
      return e.toString();
    }
  }

  static Future<String> _openaiModels(String key) async {
    try {
      final r = await _dio.get<Map<String, dynamic>>(
        'https://api.openai.com/v1/models',
        options: Options(headers: {'Authorization': 'Bearer $key'}),
      );
      if (r.statusCode == 200) {
        final data = r.data?['data'];
        final n = data is List ? data.length : '?';
        return 'OK ($n models)';
      }
      return 'HTTP ${r.statusCode}';
    } catch (e) {
      return e.toString();
    }
  }
}
