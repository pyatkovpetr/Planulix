import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';

class DiskInfoWidget extends StatefulWidget {
  const DiskInfoWidget({super.key});
  @override
  State<DiskInfoWidget> createState() => _DiskInfoWidgetState();
}

class _DiskInfoWidgetState extends State<DiskInfoWidget> {
  Map<String, dynamic>? _data;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _load();
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) => _load());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final data = await context.read<AppState>().api.getDiskInfo();
      if (mounted) setState(() => _data = data);
    } catch (_) {}
  }

  String _fmt(num bytes) {
    final gb = bytes / 1024 / 1024 / 1024;
    if (gb >= 1) return '${gb.toStringAsFixed(1)}G';
    final mb = bytes / 1024 / 1024;
    return '${mb.toStringAsFixed(0)}M';
  }

  num _n(dynamic v) => (v is num) ? v : 0;

  Map<String, dynamic>? _asMap(dynamic v) => (v is Map) ? v.cast<String, dynamic>() : null;

  @override
  Widget build(BuildContext context) {
    if (_data == null) return const SizedBox.shrink();

    final server = _asMap(_data!['server']);
    final yadisk = _asMap(_data!['yadisk']);

    return Tooltip(
      message: _buildTooltip(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (server != null) ...[
            const Icon(Icons.storage, size: 11, color: Colors.white),
            const SizedBox(width: 3),
            Text(
              '${_fmt(_n(server['used']))}/${_fmt(_n(server['total']))}',
              style: const TextStyle(fontSize: 10, color: Colors.white),
            ),
          ],
          if (yadisk != null && yadisk['configured'] == true) ...[
            const SizedBox(width: 12),
            const Icon(Icons.cloud, size: 11, color: Colors.white),
            const SizedBox(width: 3),
            Text(
              '${_fmt(_n(yadisk['used']))}/${_fmt(_n(yadisk['total']))}',
              style: const TextStyle(fontSize: 10, color: Colors.white),
            ),
          ],
        ],
      ),
    );
  }

  String _buildTooltip() {
    final lines = <String>[];
    final server = _asMap(_data?['server']);
    if (server != null) {
      lines.add('Remote server ${server['projectsPath'] ?? ''}:');
      lines.add('  used ${_fmt(_n(server['used']))} / ${_fmt(_n(server['total']))}');
      lines.add('  free ${_fmt(_n(server['free']))}');
      lines.add('  projects ${_fmt(_n(server['projectsSize']))}');
    }
    final yadisk = _asMap(_data?['yadisk']);
    if (yadisk != null && yadisk['configured'] == true) {
      lines.add('');
      lines.add('Yandex Disk:');
      lines.add('  used ${_fmt(_n(yadisk['used']))} / ${_fmt(_n(yadisk['total']))}');
      lines.add('  free ${_fmt(_n(yadisk['free']))}');
    }
    return lines.join('\n');
  }
}
