import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';

class ActivityHeatmap extends StatefulWidget {
  const ActivityHeatmap({super.key});
  @override
  State<ActivityHeatmap> createState() => _ActivityHeatmapState();
}

class _ActivityHeatmapState extends State<ActivityHeatmap> {
  Map<String, dynamic>? _data;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await context.read<AppState>().api.getActivity();
      if (mounted) setState(() { _data = data; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Container(
        height: 120,
        decoration: BoxDecoration(
          color: const Color(0xFF1e293b),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF334155)),
        ),
        child: const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }

    if (_data == null) return const SizedBox.shrink();

    final days = (_data!['days'] as List? ?? []);
    final currentStreak = (_data!['currentStreak'] as num?)?.toInt() ?? 0;
    final longestStreak = (_data!['longestStreak'] as num?)?.toInt() ?? 0;
    final activeDays = (_data!['activeDays'] as num?)?.toInt() ?? 0;

    // Build a map of date -> count
    final Map<String, int> dayCounts = {};
    for (final d in days) {
      if (d is! Map) continue;
      final date = d['date'];
      final count = d['count'];
      if (date is String && count is num) {
        dayCounts[date] = count.toInt();
      }
    }

    // Generate last 91 days (13 weeks)
    final today = DateTime.now();
    final startDate = today.subtract(const Duration(days: 90));

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1e293b),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Stats row
          Row(
            children: [
              _statBadge('$currentStreak', 'streak'),
              const SizedBox(width: 12),
              _statBadge('$longestStreak', 'best'),
              const SizedBox(width: 12),
              _statBadge('$activeDays', 'active days'),
            ],
          ),
          const SizedBox(height: 12),

          // Heatmap grid
          SizedBox(
            height: 7 * 13.0, // 7 rows x cell size
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(13, (week) {
                return Column(
                  children: List.generate(7, (day) {
                    final cellDate = startDate.add(Duration(days: week * 7 + day));
                    if (cellDate.isAfter(today)) {
                      return const SizedBox(width: 11, height: 11);
                    }
                    final dateStr = '${cellDate.year}-${cellDate.month.toString().padLeft(2, '0')}-${cellDate.day.toString().padLeft(2, '0')}';
                    final count = dayCounts[dateStr] ?? 0;

                    return Tooltip(
                      message: '$dateStr: $count sessions',
                      child: Container(
                        width: 11,
                        height: 11,
                        margin: const EdgeInsets.all(1),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(2),
                          color: _heatColor(count),
                        ),
                      ),
                    );
                  }),
                );
              }),
            ),
          ),

          // Legend
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              const Text('Less', style: TextStyle(fontSize: 9, color: Color(0xFF64748b))),
              const SizedBox(width: 4),
              ...[0, 1, 3, 5, 8].map((n) => Container(
                width: 10, height: 10,
                margin: const EdgeInsets.only(right: 2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(2),
                  color: _heatColor(n),
                ),
              )),
              const Text('More', style: TextStyle(fontSize: 9, color: Color(0xFF64748b))),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statBadge(String value, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFF0f172a),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF8b5cf6))),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 10, color: Color(0xFF64748b))),
        ],
      ),
    );
  }

  Color _heatColor(int count) {
    if (count == 0) return const Color(0xFF1a1a2e);
    if (count <= 1) return const Color(0xFF3b1f7e);
    if (count <= 3) return const Color(0xFF5b21b6);
    if (count <= 5) return const Color(0xFF7c3aed);
    return const Color(0xFFa78bfa);
  }
}
