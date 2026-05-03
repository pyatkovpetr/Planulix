import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_state.dart';

class CostScreen extends StatefulWidget {
  const CostScreen({super.key});
  @override
  State<CostScreen> createState() => _CostScreenState();
}

class _CostScreenState extends State<CostScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final state = context.read<AppState>();
    if (state.connectionMode == 'saas' &&
        state.saas.isConfigured &&
        !state.api.isConfigured) {
      try {
        await state.refreshSaasWorkspaces();
        if (mounted) {
          setState(() {
            _loading = false;
            _data = _buildSaasCostPlaceholder(state);
            _error = null;
          });
        }
        return;
      } catch (e) {
        if (mounted) {
          setState(() {
            _error = e.toString();
            _loading = false;
          });
        }
        return;
      }
    }
    try {
      final data = await state.api.getCostSummary();
      if (mounted) {
        setState(() {
          _data = data;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  /// Minimal shape so existing summary widgets can render; SaaS has no Planulix session breakdown.
  Map<String, dynamic> _buildSaasCostPlaceholder(AppState state) {
    final u = state.saasUsage ?? {};
    final used = (u['month_used_tokens'] as num?)?.toInt() ?? 0;
    final budget = (u['monthly_token_budget'] as num?)?.toInt() ?? 0;
    final mode = (u['kimi_mode'] ?? '').toString();
    return {
      'totalCost': 0.0,
      'totalSessions': 0,
      'usage': {'inputTokens': 0, 'outputTokens': 0, 'totalTokens': used},
      'costByModel': <String, dynamic>{},
      'costByProject': <String, dynamic>{
        'saas': {'cost': 0.0, 'label': 'Planulix Cloud · $mode · budget $budget'},
      },
      'dailyCosts': <dynamic>[],
      'topSessions': <dynamic>[],
      '_saasNote':
          'Данные со страницы Planulix Cloud (/v1/usage/summary). Детальный разбор по сессиям — в режиме Direct с вашим Planulix-сервером.',
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Cost Analytics',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline, size: 48, color: Colors.red[300]),
                  const SizedBox(height: 8),
                  Text(_error!, style: const TextStyle(color: Colors.red)),
                  const SizedBox(height: 16),
                  ElevatedButton(onPressed: _load, child: const Text('Retry')),
                ],
              ),
            )
          : _buildContent(),
    );
  }

  Widget _buildContent() {
    if (_data == null) return const SizedBox.shrink();
    final totalCost = (_data!['totalCost'] as num?)?.toDouble() ?? 0;
    final totalSessions = (_data!['totalSessions'] as num?)?.toInt() ?? 0;
    final usage = _data!['usage'] as Map<String, dynamic>? ?? {};
    final costByModel = _data!['costByModel'] as Map<String, dynamic>? ?? {};
    final costByProject =
        _data!['costByProject'] as Map<String, dynamic>? ?? {};
    final dailyCosts = _data!['dailyCosts'] as List? ?? [];
    final topSessions = _data!['topSessions'] as List? ?? [];

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_data!['_saasNote'] != null) ...[
            Card(
              color: const Color(0xFF1e3a5f),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.info_outline, color: Color(0xFF38bdf8)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _data!['_saasNote'].toString(),
                        style: const TextStyle(
                          fontSize: 13,
                          height: 1.35,
                          color: Color(0xFFe2e8f0),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
          // Summary cards
          _buildSummaryRow(totalCost, totalSessions, usage),
          const SizedBox(height: 20),

          // Token usage breakdown
          _buildSectionTitle('Token Usage'),
          _buildTokenCard(usage),
          const SizedBox(height: 20),

          // Daily cost chart
          if (dailyCosts.isNotEmpty) ...[
            _buildSectionTitle('Daily Costs'),
            _buildDailyChart(dailyCosts),
            const SizedBox(height: 20),
          ],

          // Cost by model
          if (costByModel.isNotEmpty) ...[
            _buildSectionTitle('Cost by Model'),
            _buildCostBreakdown(costByModel, totalCost),
            const SizedBox(height: 20),
          ],

          // Cost by project
          if (costByProject.isNotEmpty) ...[
            _buildSectionTitle('Cost by Project'),
            _buildCostBreakdown(costByProject, totalCost),
            const SizedBox(height: 20),
          ],

          // Top expensive sessions
          if (topSessions.isNotEmpty) ...[
            _buildSectionTitle('Most Expensive Sessions'),
            ...topSessions.map((s) => _buildSessionCostTile(s)),
          ],

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildSummaryRow(
    double totalCost,
    int totalSessions,
    Map<String, dynamic> usage,
  ) {
    final totalTokens = (usage['inputTokens'] as num?)?.toInt() ?? 0;
    final outputTokens = (usage['outputTokens'] as num?)?.toInt() ?? 0;

    return Row(
      children: [
        Expanded(
          child: _buildStatCard(
            '\$${totalCost.toStringAsFixed(2)}',
            'Total Cost',
            Icons.attach_money,
            const Color(0xFF22c55e),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildStatCard(
            '$totalSessions',
            'Sessions',
            Icons.terminal,
            const Color(0xFF8b5cf6),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildStatCard(
            _formatTokens(totalTokens + outputTokens),
            'Total Tokens',
            Icons.token,
            const Color(0xFF3b82f6),
          ),
        ),
      ],
    );
  }

  Widget _buildStatCard(
    String value,
    String label,
    IconData icon,
    Color color,
  ) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1e293b),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withAlpha(60)),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: Color(0xFF94a3b8)),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        title,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _buildTokenCard(Map<String, dynamic> usage) {
    final items = [
      (
        'Input',
        (usage['inputTokens'] as num?)?.toInt() ?? 0,
        const Color(0xFF3b82f6),
      ),
      (
        'Output',
        (usage['outputTokens'] as num?)?.toInt() ?? 0,
        const Color(0xFF22c55e),
      ),
      (
        'Cache Read',
        (usage['cacheReadInputTokens'] as num?)?.toInt() ?? 0,
        const Color(0xFFf59e0b),
      ),
      (
        'Cache Create',
        (usage['cacheCreationInputTokens'] as num?)?.toInt() ?? 0,
        const Color(0xFFef4444),
      ),
    ];

    final total = items.fold<int>(0, (sum, e) => sum + e.$2);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1e293b),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: Column(
        children: [
          // Bar
          if (total > 0)
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                height: 8,
                child: Row(
                  children: items.where((e) => e.$2 > 0).map((e) {
                    return Expanded(
                      flex: e.$2,
                      child: Container(color: e.$3),
                    );
                  }).toList(),
                ),
              ),
            ),
          const SizedBox(height: 12),
          ...items.map(
            (e) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: e.$3,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    e.$1,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF94a3b8),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _formatTokens(e.$2),
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDailyChart(List dailyCosts) {
    // Show last 14 days
    final recent = dailyCosts.length > 14
        ? dailyCosts.sublist(dailyCosts.length - 14)
        : dailyCosts;
    final maxCost = recent.fold<double>(
      0,
      (m, d) => (d['totalCost'] as num).toDouble() > m
          ? (d['totalCost'] as num).toDouble()
          : m,
    );

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1e293b),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: SizedBox(
        height: 120,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: recent.map<Widget>((d) {
            final cost = (d['totalCost'] as num).toDouble();
            final ratio = maxCost > 0 ? cost / maxCost : 0.0;
            final date = d['date'] as String? ?? '';
            final day = date.length >= 10 ? date.substring(8, 10) : '';

            return Expanded(
              child: Tooltip(
                message: '$date\n\$${cost.toStringAsFixed(2)}',
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(
                        '\$${cost.toStringAsFixed(1)}',
                        style: const TextStyle(
                          fontSize: 8,
                          color: Color(0xFF64748b),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Container(
                        height: 80 * ratio,
                        decoration: BoxDecoration(
                          color: const Color(0xFF8b5cf6),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        day,
                        style: const TextStyle(
                          fontSize: 9,
                          color: Color(0xFF64748b),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildCostBreakdown(Map<String, dynamic> costMap, double totalCost) {
    final sorted = costMap.entries.toList()
      ..sort((a, b) => (b.value as num).compareTo(a.value as num));

    final colors = [
      const Color(0xFF8b5cf6),
      const Color(0xFF3b82f6),
      const Color(0xFF22c55e),
      const Color(0xFFf59e0b),
      const Color(0xFFef4444),
      const Color(0xFF06b6d4),
    ];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1e293b),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: Column(
        children: sorted.asMap().entries.map((e) {
          final idx = e.key;
          final entry = e.value;
          final cost = (entry.value as num).toDouble();
          final pct = totalCost > 0 ? (cost / totalCost * 100) : 0.0;
          final color = colors[idx % colors.length];
          // Shorten model name for display
          final name = _shortenModelName(entry.key);

          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        name,
                        style: const TextStyle(fontSize: 13),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '\$${cost.toStringAsFixed(2)}',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${pct.toStringAsFixed(1)}%',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF64748b),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: pct / 100,
                    backgroundColor: const Color(0xFF334155),
                    valueColor: AlwaysStoppedAnimation(color),
                    minHeight: 4,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildSessionCostTile(dynamic session) {
    final title = session['title'] as String? ?? 'Untitled';
    final cost = (session['totalCost'] as num?)?.toDouble() ?? 0;
    final usage = session['usage'] as Map<String, dynamic>? ?? {};
    final inp = (usage['inputTokens'] as num?)?.toInt() ?? 0;
    final out = (usage['outputTokens'] as num?)?.toInt() ?? 0;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1e293b),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  '${_formatTokens(inp)} in / ${_formatTokens(out)} out',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF64748b),
                  ),
                ),
              ],
            ),
          ),
          Text(
            '\$${cost.toStringAsFixed(2)}',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: cost > 1
                  ? const Color(0xFFef4444)
                  : const Color(0xFF22c55e),
            ),
          ),
        ],
      ),
    );
  }

  String _formatTokens(int tokens) {
    if (tokens >= 1000000) return '${(tokens / 1000000).toStringAsFixed(1)}M';
    if (tokens >= 1000) return '${(tokens / 1000).toStringAsFixed(1)}K';
    return '$tokens';
  }

  String _shortenModelName(String model) {
    if (model.contains('opus')) return 'Opus';
    if (model.contains('sonnet-4-5') || model.contains('sonnet-4.5')) {
      return 'Sonnet 4.5';
    }
    if (model.contains('sonnet-4') || model.contains('sonnet-4-20')) {
      return 'Sonnet 4';
    }
    if (model.contains('sonnet-3-7') || model.contains('3.7')) {
      return 'Sonnet 3.7';
    }
    if (model.contains('sonnet-3-5') || model.contains('3.5-sonnet')) {
      return 'Sonnet 3.5';
    }
    if (model.contains('haiku')) return 'Haiku';
    if (model.contains('gpt-5')) return 'GPT-5';
    if (model.contains('codex')) return 'Codex';
    if (model.length > 20) return '${model.substring(0, 20)}...';
    return model;
  }
}
