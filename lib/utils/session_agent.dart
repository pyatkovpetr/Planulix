/// Deduce which CLI agent owns a `/sessions` list row.
/// Matches server shape: [`extra.agent`], prefixes on `sessionId`, `kind` / `entrypoint`.
String? normalizeCliAgentRaw(String raw) {
  final a = raw.toLowerCase().trim();
  switch (a) {
    case 'claude-code':
    case 'claude':
      return 'claude-code';
    case 'kimi-cli':
    case 'kimi':
      return 'kimi-cli';
    case 'codex-cli':
    case 'codex':
      return 'codex-cli';
    case 'cursor':
    case 'cursor-agent':
      return 'cursor';
    case 'kiro-cli':
    case 'kiro':
      return 'kiro-cli';
    case 'opencode':
      return 'opencode';
  }
  if (a.contains('kimi')) return 'kimi-cli';
  if (a.contains('cursor')) return 'cursor';
  if (a.contains('codex')) return 'codex-cli';
  if (a.contains('claude')) return 'claude-code';
  if (a.contains('kiro')) return 'kiro-cli';
  if (a.contains('opencode')) return 'opencode';
  return null;
}

/// Canonical agent id aligned with `setupAgentIdForScope` / gateway `normalizeRequestedAgent`.
String? inferSessionCanonicalCli(dynamic session) {
  if (session is! Map) return null;

  String id(String k) => '${session[k] ?? ''}'.trim();

  final sid = id('sessionId');

  final exDyn = session['extra'];
  if (exDyn is Map) {
    final fromExtra = '${exDyn['agent'] ?? ''}'.trim();
    if (fromExtra.isNotEmpty) return normalizeCliAgentRaw(fromExtra);
  }

  final top = id('agent');
  if (top.isNotEmpty) return normalizeCliAgentRaw(top);

  if (sid.startsWith('kimi-')) return 'kimi-cli';
  if (sid.startsWith('cursor-')) return 'cursor';
  if (sid.startsWith('codex-')) return 'codex-cli';
  if (sid.startsWith('opencode-')) return 'opencode';
  if (sid.startsWith('kiro-')) return 'kiro-cli';

  final kRaw = ('${session['kind'] ?? ''}').toLowerCase();
  final entry = ('${session['entrypoint'] ?? ''}').toLowerCase();

  if (kRaw.contains('cursor') || entry.contains('cursor')) return 'cursor';
  if (kRaw.contains('kimi')) return 'kimi-cli';
  if (kRaw.contains('codex')) return 'codex-cli';
  if (kRaw.contains('kiro')) return 'kiro-cli';
  if (kRaw.contains('opencode')) return 'opencode';

  if (sid.startsWith('cd-')) {
    // Planulix-managed id; must rely on persisted `extra.agent` (handled above).
    return null;
  }

  if (kRaw.contains('claude') || entry.contains('claude')) return 'claude-code';

  // Native Claude Code metadata rows (uuid ids; `kind` often missing in JSON)
  if (sid.isNotEmpty &&
      !sid.startsWith('kimi-') &&
      !sid.startsWith('cursor-') &&
      !sid.startsWith('codex-') &&
      !sid.startsWith('opencode-') &&
      !sid.startsWith('kiro-') &&
      !sid.startsWith('cd-')) {
    if (kRaw.isEmpty ||
        kRaw.contains('claude') ||
        entry.contains('claude') ||
        entry == 'cli') {
      return 'claude-code';
    }
  }

  return null;
}

bool sessionMatchesCanonicalCli(dynamic session, String want) {
  final got = inferSessionCanonicalCli(session);
  if (got == null || want.isEmpty) return false;
  return got == want;
}
