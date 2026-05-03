import 'dart:convert';

/// One Planulix API backend + optional SSH параметры для SOCKS5-туннеля до того же хоста,
/// чтобы браузер (OAuth и т.д.) выходил в интернет с IP VPS.
class ServerProfile {
  final String id;
  final String name;
  final String baseUrl;
  final String token;

  /// Пользователь SSH к хосту из [baseUrl] (обычно `root`). Пусто → `root`.
  final String? sshUser;

  /// Порт SSH, по умолчанию 22.
  final int? sshPort;

  const ServerProfile({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.token,
    this.sshUser,
    this.sshPort,
  });

  String get resolvedSshUser =>
      (sshUser != null && sshUser!.trim().isNotEmpty) ? sshUser!.trim() : 'root';

  int get resolvedSshPort =>
      (sshPort != null && sshPort! > 0 && sshPort! < 65536) ? sshPort! : 22;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'token': token,
        if (sshUser != null && sshUser!.trim().isNotEmpty)
          'sshUser': sshUser!.trim(),
        if (sshPort != null && sshPort! > 0) 'sshPort': sshPort,
      };

  factory ServerProfile.fromJson(Map<String, dynamic> m) {
    final sp = m['sshPort'];
    int? port;
    if (sp is int) {
      port = sp;
    } else if (sp is num) {
      port = sp.toInt();
    } else if (sp != null && sp.toString().trim().isNotEmpty) {
      port = int.tryParse(sp.toString().trim());
    }
    final suRaw = m['sshUser']?.toString().trim();
    return ServerProfile(
      id: (m['id'] ?? '').toString(),
      name: (m['name'] ?? '').toString(),
      baseUrl: (m['baseUrl'] ?? '').toString(),
      token: (m['token'] ?? '').toString(),
      sshUser: (suRaw == null || suRaw.isEmpty) ? null : suRaw,
      sshPort: port,
    );
  }

  ServerProfile copyWithGatewaySsh({String? sshUser, int? sshPort}) {
    return ServerProfile(
      id: id,
      name: name,
      baseUrl: baseUrl,
      token: token,
      sshUser: sshUser ?? this.sshUser,
      sshPort: sshPort ?? this.sshPort,
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
