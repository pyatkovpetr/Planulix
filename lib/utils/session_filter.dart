/// Agent source: whose sessions (API `kind` / id).
const List<String> kAgentScopeOptions = [
  'All',
  'Claude',
  'Kimi',
  'Codex',
  'Cursor',
  'Kiro',
  'OpenCode',
  'Planulix',
];

/// Narrow within current agent: all, starred, active, finished.
const List<String> kListScopeOptions = [
  'All',
  'Starred',
  'Active',
  'Finished',
];

/// Agents whose sessions are discovered from files only — server keeps `isActive: false`.
/// «Active» list filter would show none; map it to «All» in [applySessionQuery].
const Set<String> kFileDiscoveryAgents = {
  'Kimi',
  'Codex',
  'Cursor',
  'Kiro',
  'OpenCode',
};

/// Legacy single-dropdown options (settings migration).
final List<String> kSessionFilterOptions = [
  ...kListScopeOptions,
  ...kAgentScopeOptions.where((a) => a != 'All'),
];

/// Apply agent filter only (subset of [applySessionFilter] without Starred/Active/Finished).
List<dynamic> applyAgentScope(Iterable<dynamic> sessions, String agentScope) {
  return applySessionFilter(sessions, agentScope);
}

/// Apply starred/active/finished on top of an already agent-filtered list.
List<dynamic> applyListScope(Iterable<dynamic> sessions, String listScope) {
  var list = sessions.toList();
  switch (listScope) {
    case 'Starred':
      list = list.where((s) {
        final e = s['extra'];
        return e is Map && e['starred'] == true;
      }).toList();
      break;
    case 'Active':
      list = list.where((s) => s['isActive'] == true).toList();
      break;
    case 'Finished':
      list = list.where((s) => s['isActive'] != true).toList();
      break;
    case 'All':
    default:
      break;
  }
  return list;
}

/// Agent scope, then list scope (e.g. Claude + Starred).
List<dynamic> applySessionQuery(Iterable<dynamic> sessions, String agentScope, String listScope) {
  var effectiveList = listScope;
  if (listScope == 'Active' && kFileDiscoveryAgents.contains(agentScope)) {
    effectiveList = 'All';
  }
  return applyListScope(applyAgentScope(sessions, agentScope), effectiveList);
}

/// Apply the dashboard-style filter to a copy of [sessions] (single flat filter).
List<dynamic> applySessionFilter(Iterable<dynamic> sessions, String filter) {
  var list = sessions.toList();
  switch (filter) {
    case 'Starred':
      list = list.where((s) {
        final e = s['extra'];
        return e is Map && e['starred'] == true;
      }).toList();
      break;
    case 'Active':
      list = list.where((s) => s['isActive'] == true).toList();
      break;
    case 'Finished':
      list = list.where((s) => s['isActive'] != true).toList();
      break;
    case 'Claude':
      list = list.where((s) {
        final k = (s['kind'] ?? '').toString();
        final e = (s['entrypoint'] ?? '').toString();
        return k.isEmpty || k.contains('claude') || e.contains('claude') || e == 'cli';
      }).toList();
      break;
    case 'Codex':
      list = list.where((s) => (s['kind'] ?? '').toString().contains('codex')).toList();
      break;
    case 'Cursor':
      list = list.where((s) => (s['kind'] ?? '').toString().contains('cursor')).toList();
      break;
    case 'Kiro':
      list = list.where((s) => (s['kind'] ?? '').toString().contains('kiro')).toList();
      break;
    case 'Kimi':
      list = list.where((s) {
        final k = (s['kind'] ?? '').toString();
        final id = (s['sessionId'] ?? '').toString();
        return k.contains('kimi') || id.startsWith('kimi-');
      }).toList();
      break;
    case 'OpenCode':
      list = list.where((s) => (s['kind'] ?? '').toString().contains('opencode')).toList();
      break;
    case 'Planulix':
      list = list.where((s) {
        final k = (s['kind'] ?? '').toString();
        final e = (s['entrypoint'] ?? '').toString();
        return k == 'chat' || k == 'task' || e == 'planulix';
      }).toList();
      break;
    case 'All':
    default:
      break;
  }
  return list;
}
