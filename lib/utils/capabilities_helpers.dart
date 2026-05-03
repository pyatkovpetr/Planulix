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

Map<String, dynamic>? agentCapabilityFromCapabilities(
  Map<String, dynamic>? caps,
  String agentId,
) {
  if (caps == null) return null;
  final agents = caps['agents'];
  if (agents is! List) return null;
  final want = agentId.toLowerCase().trim();
  for (final raw in agents) {
    if (raw is! Map) continue;
    final m = Map<String, dynamic>.from(raw);
    final id = '${m['id'] ?? ''}'.toLowerCase().trim();
    if (id == want) return m;
  }
  return null;
}

bool claudeCodeInstalledFromCaps(Map<String, dynamic>? caps) =>
    agentInstalledFromCapabilities(caps, 'claude-code');

String setupAgentIdForScope(String scope) {
  switch (scope) {
    case 'Claude':
      return 'claude-code';
    case 'Kimi':
      return 'kimi-cli';
    case 'Codex':
      return 'codex-cli';
    case 'Cursor':
      return 'cursor';
    case 'Kiro':
      return 'kiro-cli';
    case 'OpenCode':
      return 'opencode';
    default:
      return '';
  }
}

bool scopeHasInstallableCli(String scope) =>
    setupAgentIdForScope(scope).isNotEmpty;

bool scopeCliInstalledFromCaps(Map<String, dynamic>? caps, String scope) {
  final agentId = setupAgentIdForScope(scope);
  if (agentId.isEmpty) return true;
  return agentInstalledFromCapabilities(caps, agentId);
}
