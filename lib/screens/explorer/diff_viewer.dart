import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_state.dart';

class DiffViewer extends StatefulWidget {
  final String cwd;
  final String file;
  const DiffViewer({super.key, required this.cwd, required this.file});

  @override
  State<DiffViewer> createState() => _DiffViewerState();
}

class _DiffViewerState extends State<DiffViewer> {
  List<dynamic>? _lines;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(DiffViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file != widget.file || oldWidget.cwd != widget.cwd) _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final api = context.read<AppState>().api;
      final data = await api.getGitDiff(widget.cwd, widget.file);
      if (mounted) {
        setState(() {
          _lines = data['lines'] as List? ?? [];
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0f172a),
      child: Column(
        children: [
          // Header
          Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: const BoxDecoration(
              color: Color(0xFF0a0f1a),
              border: Border(bottom: BorderSide(color: Color(0xFF1a2234))),
            ),
            child: Row(
              children: [
                const Icon(Icons.difference_outlined, size: 12, color: Color(0xFFf59e0b)),
                const SizedBox(width: 6),
                const Text('DIFF', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Color(0xFFf59e0b), letterSpacing: 0.5)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.file,
                    style: const TextStyle(fontSize: 10, color: Color(0xFF94a3b8), fontFamily: 'monospace'),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_lines != null) ...[
                  _statBadge('+${_lines!.where((l) => l['type'] == 'add').length}', const Color(0xFF22c55e)),
                  const SizedBox(width: 4),
                  _statBadge('-${_lines!.where((l) => l['type'] == 'del').length}', const Color(0xFFef4444)),
                ],
                IconButton(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh, size: 13, color: Color(0xFF94a3b8)),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                ),
              ],
            ),
          ),

          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : _error != null
                    ? Center(child: Text(_error!, style: const TextStyle(color: Color(0xFFef4444))))
                    : _buildDiff(),
          ),
        ],
      ),
    );
  }

  Widget _statBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(text, style: TextStyle(fontSize: 9, color: color, fontWeight: FontWeight.w700, fontFamily: 'monospace')),
    );
  }

  Widget _buildDiff() {
    if (_lines == null || _lines!.isEmpty) {
      return const Center(
        child: Text('No changes', style: TextStyle(color: Color(0xFF64748b), fontSize: 13)),
      );
    }

    return Scrollbar(
      child: SingleChildScrollView(
        scrollDirection: Axis.vertical,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SelectionArea(
            child: IntrinsicWidth(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: _lines!.map<Widget>((line) => _diffLine(line)).toList(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _diffLine(dynamic line) {
    final type = line['type'] as String;
    final content = line['content'] as String? ?? '';
    final oldLine = line['oldLine'] as int? ?? 0;
    final newLine = line['newLine'] as int? ?? 0;

    Color? bgColor;
    Color? textColor;
    String prefix = ' ';

    switch (type) {
      case 'add':
        bgColor = const Color(0xFF22c55e).withAlpha(25);
        textColor = const Color(0xFFbbf7d0);
        prefix = '+';
        break;
      case 'del':
        bgColor = const Color(0xFFef4444).withAlpha(25);
        textColor = const Color(0xFFfecaca);
        prefix = '-';
        break;
      case 'hunk':
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          color: const Color(0xFF1e1b4b),
          child: Text(
            content,
            style: const TextStyle(fontSize: 11, color: Color(0xFF93c5fd), fontFamily: 'monospace'),
          ),
        );
      case 'header':
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          child: Text(
            content,
            style: const TextStyle(fontSize: 10, color: Color(0xFF64748b), fontFamily: 'monospace'),
          ),
        );
      default:
        textColor = const Color(0xFFcbd5e1);
    }

    return Container(
      color: bgColor,
      child: Row(
        children: [
          // Old line number
          Container(
            width: 50,
            padding: const EdgeInsets.only(right: 8),
            alignment: Alignment.centerRight,
            child: Text(
              type == 'add' ? '' : (oldLine > 0 ? '$oldLine' : ''),
              style: const TextStyle(fontSize: 10, color: Color(0xFF475569), fontFamily: 'monospace'),
            ),
          ),
          // New line number
          Container(
            width: 50,
            padding: const EdgeInsets.only(right: 8),
            alignment: Alignment.centerRight,
            child: Text(
              type == 'del' ? '' : (newLine > 0 ? '$newLine' : ''),
              style: const TextStyle(fontSize: 10, color: Color(0xFF475569), fontFamily: 'monospace'),
            ),
          ),
          // Prefix
          SizedBox(
            width: 16,
            child: Text(
              prefix,
              style: TextStyle(fontSize: 11, color: textColor, fontFamily: 'monospace', fontWeight: FontWeight.w700),
            ),
          ),
          // Content
          Text(
            content.isEmpty ? ' ' : content,
            style: TextStyle(fontSize: 11, color: textColor, fontFamily: 'monospace', height: 1.4),
          ),
        ],
      ),
    );
  }
}
