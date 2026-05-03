import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/app_state.dart';
import '../../utils/agent_catalog.dart';

/// First-run: pick primary session source (Kimi / Claude first; others optional).
class AgentWelcomeScreen extends StatefulWidget {
  const AgentWelcomeScreen({super.key});

  @override
  State<AgentWelcomeScreen> createState() => _AgentWelcomeScreenState();
}

class _AgentWelcomeScreenState extends State<AgentWelcomeScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<AppState>().loadPricingIfNeeded();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0f172a),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Kimi или Claude', style: TextStyle(fontWeight: FontWeight.w700)),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          const Text(
            'С чего начать: сессии Kimi Code или Claude Code на сервере (остальные инструменты — ниже в списке). Сменить можно в любой момент на вкладке Sessions.',
            style: TextStyle(color: Color(0xFF94a3b8), fontSize: 14, height: 1.4),
          ),
          const SizedBox(height: 20),
          Consumer<AppState>(
            builder: (context, st, _) {
              final models = st.pricingSnapshot?['models'] as List<dynamic>?;
              return Column(
                children: kAgentCatalog
                    .map((e) => _AgentTile(entry: e, pricingHint: pricingHintForCatalogAgent(e.id, models)))
                    .toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _AgentTile extends StatelessWidget {
  final AgentCatalogEntry entry;
  final String? pricingHint;

  const _AgentTile({required this.entry, this.pricingHint});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: const Color(0xFF1e293b),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () async {
            final state = context.read<AppState>();
            await state.setAgentScope(entry.id);
            await state.setListScope('All');
            await state.completeAgentOnboarding();
            if (context.mounted) Navigator.of(context).pop();
          },
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: entry.accent.withAlpha(35),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(entry.icon, color: entry.accent, size: 26),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.title,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        entry.subtitle,
                        style: const TextStyle(fontSize: 12, color: Color(0xFF94a3b8)),
                      ),
                      if (pricingHint != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          pricingHint!,
                          style: const TextStyle(fontSize: 11, color: Color(0xFF64748b), height: 1.25),
                        ),
                      ],
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: entry.accent.withAlpha(180)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
