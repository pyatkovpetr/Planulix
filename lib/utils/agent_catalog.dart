import 'package:flutter/material.dart';

import 'session_filter.dart';

/// UI metadata for agent scope picker (mobile-first).
class AgentCatalogEntry {
  final String id;
  final String title;
  final String subtitle;
  final IconData icon;
  final Color accent;

  const AgentCatalogEntry({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accent,
  });
}

const List<AgentCatalogEntry> kAgentCatalog = [
  AgentCatalogEntry(
    id: 'All',
    title: 'All agents',
    subtitle: 'Every session on this server',
    icon: Icons.hub_outlined,
    accent: Color(0xFF94a3b8),
  ),
  AgentCatalogEntry(
    id: 'Claude',
    title: 'Claude Code',
    subtitle: 'Anthropic · ~/.claude',
    icon: Icons.auto_awesome,
    accent: Color(0xFFc084fc),
  ),
  AgentCatalogEntry(
    id: 'Kimi',
    title: 'Kimi Code',
    subtitle: 'Moonshot · ~/.kimi',
    icon: Icons.bolt_outlined,
    accent: Color(0xFF38bdf8),
  ),
  AgentCatalogEntry(
    id: 'Codex',
    title: 'Codex CLI',
    subtitle: 'OpenAI · ~/.codex',
    icon: Icons.integration_instructions_outlined,
    accent: Color(0xFFfbbf24),
  ),
  AgentCatalogEntry(
    id: 'Cursor',
    title: 'Cursor',
    subtitle: 'Transcripts · ~/.cursor',
    icon: Icons.mouse_outlined,
    accent: Color(0xFF22d3ee),
  ),
  AgentCatalogEntry(
    id: 'Kiro',
    title: 'Kiro CLI',
    subtitle: 'Amazon · kiro data',
    icon: Icons.terminal_outlined,
    accent: Color(0xFFfb7185),
  ),
  AgentCatalogEntry(
    id: 'OpenCode',
    title: 'OpenCode',
    subtitle: 'opencode sessions',
    icon: Icons.code_outlined,
    accent: Color(0xFFa78bfa),
  ),
  AgentCatalogEntry(
    id: 'Planulix',
    title: 'Planulix',
    subtitle: 'Managed tmux on server',
    icon: Icons.dns_outlined,
    accent: Color(0xFF8b5cf6),
  ),
];

AgentCatalogEntry? catalogForAgent(String id) {
  for (final e in kAgentCatalog) {
    if (e.id == id) return e;
  }
  return null;
}

bool isValidAgentScope(String v) => kAgentScopeOptions.contains(v);

bool isValidListScope(String v) => kListScopeOptions.contains(v);

/// One-line USD/M estimate from server `/pricing` for catalog tiles (onboarding / docs).
String? pricingHintForCatalogAgent(String agentId, List<dynamic>? modelsRaw) {
  if (modelsRaw == null || modelsRaw.isEmpty) return null;
  final rows = modelsRaw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  bool fam(Map<String, dynamic> m, String needle) =>
      (m['family'] as String? ?? '').toLowerCase().contains(needle);
  String fmt(Map<String, dynamic> m) {
    final id = (m['id'] ?? '').toString();
    final inp = (m['input'] as num?)?.toDouble();
    final out = (m['output'] as num?)?.toDouble();
    if (inp == null || out == null) return id;
    return '$id \$${inp.toStringAsFixed(2)}/\$${out.toStringAsFixed(2)}';
  }
  switch (agentId) {
    case 'Claude':
      final sub = rows.where((m) => fam(m, 'anthropic')).toList();
      if (sub.isEmpty) return null;
      sub.sort((a, b) => (a['id'] as String? ?? '').compareTo(b['id'] as String? ?? ''));
      Map<String, dynamic> pick = sub.first;
      for (final m in sub) {
        if ((m['id'] as String? ?? '').contains('sonnet')) {
          pick = m;
          break;
        }
      }
      return 'Оценка: ${fmt(pick)} USD за 1M in/out (см. Cost)';
    case 'Kimi':
      final sub = rows.where((m) => fam(m, 'moonshot') || fam(m, 'kimi')).toList();
      if (sub.isEmpty) return null;
      return 'Оценка: ${fmt(sub.first)} USD за 1M in/out';
    case 'Codex':
      final sub = rows.where((m) => fam(m, 'openai')).toList();
      if (sub.isEmpty) return null;
      Map<String, dynamic> pick = sub.first;
      for (final m in sub) {
        if ((m['id'] as String? ?? '').toLowerCase().contains('codex')) {
          pick = m;
          break;
        }
      }
      return 'Оценка: ${fmt(pick)} USD за 1M in/out';
    default:
      return null;
  }
}
