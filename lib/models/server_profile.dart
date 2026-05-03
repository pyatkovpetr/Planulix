import 'dart:convert';

class ServerProfile {
  final String id;
  final String name;
  final String baseUrl;
  final String token;

  const ServerProfile({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.token,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'token': token,
      };

  factory ServerProfile.fromJson(Map<String, dynamic> m) {
    return ServerProfile(
      id: (m['id'] ?? '').toString(),
      name: (m['name'] ?? '').toString(),
      baseUrl: (m['baseUrl'] ?? '').toString(),
      token: (m['token'] ?? '').toString(),
    );
  }

  static List<ServerProfile> listFromJson(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((e) => ServerProfile.fromJson(Map<String, dynamic>.from(e)))
          .where((p) => p.id.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  static String listToJson(List<ServerProfile> list) {
    return jsonEncode(list.map((e) => e.toJson()).toList());
  }
}
