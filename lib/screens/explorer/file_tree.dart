import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_state.dart';

typedef OnFileOpen = void Function(String path, String cwd);
typedef OnDiffOpen = void Function(String cwd, String file);

class FileTreePanel extends StatefulWidget {
  final String? projectPath;
  final OnFileOpen? onFileOpen;
  final OnDiffOpen? onDiffOpen;
  final VoidCallback? onChangeProject;

  const FileTreePanel({
    super.key,
    this.projectPath,
    this.onFileOpen,
    this.onDiffOpen,
    this.onChangeProject,
  });

  @override
  State<FileTreePanel> createState() => _FileTreePanelState();
}

class _FileTreePanelState extends State<FileTreePanel> {
  final Map<String, List<dynamic>> _children = {};
  final Set<String> _expanded = {};
  String? _branch;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    if (widget.projectPath != null) _loadRoot();
  }

  @override
  void didUpdateWidget(FileTreePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.projectPath != widget.projectPath && widget.projectPath != null) {
      _children.clear();
      _expanded.clear();
      _loadRoot();
    }
  }

  Future<void> _loadRoot() async {
    if (widget.projectPath == null) return;
    setState(() => _loading = true);
    try {
      final api = context.read<AppState>().api;
      final data = await api.getFileTree(widget.projectPath!);
      final status = await api.getGitStatus(widget.projectPath!).catchError((_) => <String, dynamic>{});
      if (mounted) {
        setState(() {
          _children[widget.projectPath!] = data['entries'] as List? ?? [];
          _branch = status['branch'] as String?;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadChildren(String path) async {
    final api = context.read<AppState>().api;
    try {
      final data = await api.getFileTree(path);
      if (mounted) {
        setState(() {
          _children[path] = data['entries'] as List? ?? [];
        });
      }
    } catch (_) {}
  }

  void _toggle(String path, bool isDir) {
    if (!isDir) return;
    setState(() {
      if (_expanded.contains(path)) {
        _expanded.remove(path);
      } else {
        _expanded.add(path);
        if (!_children.containsKey(path)) {
          _loadChildren(path);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.projectPath == null) {
      return _buildEmptyState();
    }

    return Container(
      decoration: const BoxDecoration(color: Color(0xFF0d1420)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                const Text(
                  'EXPLORER',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF94a3b8), letterSpacing: 0.5),
                ),
                const Spacer(),
                InkWell(
                  onTap: _loadRoot,
                  child: const Padding(
                    padding: EdgeInsets.all(2),
                    child: Icon(Icons.refresh, size: 13, color: Color(0xFF94a3b8)),
                  ),
                ),
              ],
            ),
          ),

          // Project chip
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: InkWell(
              onTap: widget.onChangeProject,
              borderRadius: BorderRadius.circular(4),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF151e2e),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: const Color(0xFF1e2a3d)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.folder_outlined, size: 12, color: Color(0xFF8b5cf6)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _projectName(),
                        style: const TextStyle(fontSize: 11, color: Color(0xFFe2e8f0), fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_branch != null) ...[
                      const SizedBox(width: 4),
                      const Icon(Icons.account_tree_outlined, size: 10, color: Color(0xFF64748b)),
                      const SizedBox(width: 2),
                      Text(
                        _branch!,
                        style: const TextStyle(fontSize: 9, color: Color(0xFF64748b)),
                      ),
                    ],
                    const SizedBox(width: 4),
                    const Icon(Icons.swap_horiz, size: 11, color: Color(0xFF64748b)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Container(height: 1, color: const Color(0xFF1a2234)),

          // Tree
          Expanded(
            child: _loading
                ? const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                : ListView(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    children: _buildTree(widget.projectPath!, 0),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Container(
      decoration: const BoxDecoration(color: Color(0xFF0d1420)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: const Text(
              'EXPLORER',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF94a3b8), letterSpacing: 0.5),
            ),
          ),
          const SizedBox(height: 20),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              'No project open',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Color(0xFF64748b)),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: FilledButton.icon(
              onPressed: widget.onChangeProject,
              icon: const Icon(Icons.folder_open, size: 14),
              label: const Text('Open Project', style: TextStyle(fontSize: 12)),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF8b5cf6),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildTree(String path, int depth) {
    final entries = _children[path] ?? [];
    final widgets = <Widget>[];
    for (final entry in entries) {
      final isDir = entry['isDir'] == true;
      final entryPath = entry['path'] as String;
      final name = entry['name'] as String;
      final gitState = (entry['gitState'] ?? '') as String;

      widgets.add(_fileRow(name, entryPath, isDir, gitState, depth));

      if (isDir && _expanded.contains(entryPath)) {
        widgets.addAll(_buildTree(entryPath, depth + 1));
      }
    }
    return widgets;
  }

  Widget _fileRow(String name, String path, bool isDir, String gitState, int depth) {
    final hasChanges = gitState.isNotEmpty;
    final color = _colorForGitState(gitState);

    return InkWell(
      onTap: () {
        if (isDir) {
          _toggle(path, true);
        } else {
          widget.onFileOpen?.call(path, widget.projectPath!);
        }
      },
      onSecondaryTap: hasChanges ? () => widget.onDiffOpen?.call(widget.projectPath!, _relPath(path)) : null,
      child: Container(
        padding: EdgeInsets.only(left: 8.0 + depth * 12, right: 8, top: 3, bottom: 3),
        child: Row(
          children: [
            SizedBox(
              width: 12,
              child: isDir
                  ? Icon(
                      _expanded.contains(path) ? Icons.expand_more : Icons.chevron_right,
                      size: 12,
                      color: const Color(0xFF94a3b8),
                    )
                  : null,
            ),
            const SizedBox(width: 2),
            Icon(
              isDir ? Icons.folder_outlined : _iconForFile(name),
              size: 12,
              color: isDir ? const Color(0xFF8b5cf6) : const Color(0xFF64748b),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                name,
                style: TextStyle(
                  fontSize: 11,
                  color: color ?? const Color(0xFFcbd5e1),
                  fontWeight: hasChanges ? FontWeight.w600 : FontWeight.w400,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (hasChanges)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(
                  gitState,
                  style: TextStyle(fontSize: 9, color: color ?? const Color(0xFF94a3b8), fontWeight: FontWeight.w700),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Color? _colorForGitState(String state) {
    switch (state) {
      case 'M':
        return const Color(0xFFf59e0b); // modified — amber
      case 'A':
      case '??':
        return const Color(0xFF22c55e); // added — green
      case 'D':
        return const Color(0xFFef4444); // deleted — red
      case 'R':
        return const Color(0xFF3b82f6); // renamed — blue
      default:
        return null;
    }
  }

  IconData _iconForFile(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    switch (ext) {
      case 'dart':
      case 'ts':
      case 'js':
      case 'py':
      case 'go':
      case 'rs':
      case 'java':
      case 'kt':
      case 'swift':
      case 'c':
      case 'cpp':
      case 'h':
        return Icons.code;
      case 'md':
      case 'txt':
      case 'log':
        return Icons.description_outlined;
      case 'json':
      case 'yaml':
      case 'yml':
      case 'toml':
      case 'xml':
        return Icons.data_object;
      case 'png':
      case 'jpg':
      case 'jpeg':
      case 'gif':
      case 'svg':
      case 'webp':
        return Icons.image_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }

  String _relPath(String path) {
    if (widget.projectPath == null) return path;
    final prefix = widget.projectPath!.endsWith('/') ? widget.projectPath! : '${widget.projectPath!}/';
    if (path.startsWith(prefix)) return path.substring(prefix.length);
    return path;
  }

  String _projectName() {
    if (widget.projectPath == null) return '';
    final parts = widget.projectPath!.split('/').where((s) => s.isNotEmpty).toList();
    return parts.isNotEmpty ? parts.last : widget.projectPath!;
  }
}
