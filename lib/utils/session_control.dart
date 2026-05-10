String sessionAgentLabel(Map<String, dynamic> session) {
  final extra = session['extra'];
  final raw = extra is Map
      ? (extra['agent'] ?? session['kind'])
      : session['kind'];
  final id = (raw ?? '').toString();
  switch (id) {
    case 'claude-code':
      return 'Claude';
    case 'kimi-cli':
      return 'Kimi';
    case 'codex-cli':
      return 'Codex';
    case 'kiro-cli':
      return 'Kiro';
    case 'opencode':
      return 'OpenCode';
    case 'cursor':
      return 'Cursor';
    default:
      return id.isEmpty ? 'Agent' : id;
  }
}

String sessionBranchLabel(Map<String, dynamic> session) {
  final extra = session['extra'];
  if (extra is! Map) return '';
  final branch = (extra['branch'] ?? '').toString();
  if (branch.isEmpty) return '';
  return branch.length > 22 ? '${branch.substring(0, 22)}...' : branch;
}

String sessionCommitPushLabel(Map<String, dynamic> session) {
  final extra = session['extra'];
  if (extra is! Map) return '';
  final commit = (extra['commitStatus'] ?? '').toString();
  final push = (extra['pushStatus'] ?? '').toString();
  if (commit.isEmpty && push.isEmpty) return '';
  if (commit == 'clean' && push == 'up to date') return 'clean';
  if (commit.isNotEmpty && push.isNotEmpty) return '$commit / $push';
  return commit.isNotEmpty ? commit : push;
}

String sessionFailureReason(Map<String, dynamic> session) {
  final extra = session['extra'];
  if (extra is! Map) return '';
  return (extra['failureReason'] ?? '').toString();
}

int sessionDiffFiles(Map<String, dynamic> session) {
  final extra = session['extra'];
  if (extra is! Map) return 0;
  final v = extra['diffFiles'];
  if (v is num) return v.toInt();
  return int.tryParse((v ?? '').toString()) ?? 0;
}
