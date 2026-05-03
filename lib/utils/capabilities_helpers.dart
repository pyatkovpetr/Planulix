// Утилиты для ответа `GET /capabilities` (agents[].installed).

bool agentInstalledFromCapabilities(
  Map<String, dynamic>? caps,
  String agentId,
) {
  if (caps == null) return false;
  final agents = caps['agents'];
  if (agents is! List) return false;
  final want = agentId.toLowerCase().trim();
  for (final raw in agents) {
    if (raw is! Map) continue;
    final id = '${raw['id'] ?? ''}'.toLowerCase().trim();
    if (id != want) continue;
    return raw['installed'] == true;
  }
  return false;
}

bool claudeCodeInstalledFromCaps(Map<String, dynamic>? caps) =>
    agentInstalledFromCapabilities(caps, 'claude-code');
