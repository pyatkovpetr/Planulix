class SaasWorkspace {
  final String id;
  final String name;
  final bool online;
  final bool hasSecret;

  const SaasWorkspace({
    required this.id,
    required this.name,
    required this.online,
    this.hasSecret = true,
  });

  factory SaasWorkspace.fromJson(Map<String, dynamic> m) {
    return SaasWorkspace(
      id: (m['id'] ?? '').toString(),
      name: (m['name'] ?? '').toString(),
      online: m['online'] == true,
      hasSecret: m['has_secret'] != false,
    );
  }
}
