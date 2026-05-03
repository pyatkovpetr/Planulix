import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import '../../providers/app_state.dart';

class FileViewer extends StatefulWidget {
  final String path;
  const FileViewer({super.key, required this.path});

  @override
  State<FileViewer> createState() => _FileViewerState();
}

class _FileViewerState extends State<FileViewer> {
  String? _content;
  String? _originalContent;
  String? _error;
  bool _loading = true;
  bool _editing = false;
  bool _saving = false;
  final TextEditingController _controller = TextEditingController();
  final ScrollController _vScroll = ScrollController();
  final ScrollController _hScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(FileViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    _vScroll.dispose();
    _hScroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; _editing = false; });
    try {
      final api = context.read<AppState>().api;
      final data = await api.readFile(widget.path);
      if (!mounted) return;
      final content = (data['content'] is String) ? data['content'] as String : '';
      setState(() {
        _content = content;
        _originalContent = content;
        _controller.text = content;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _save() async {
    setState(() { _saving = true; });
    final messenger = ScaffoldMessenger.of(context);
    try {
      final api = context.read<AppState>().api;
      await api.writeFile(widget.path, _controller.text);
      if (!mounted) return;
      setState(() {
        _content = _controller.text;
        _originalContent = _controller.text;
        _editing = false;
        _saving = false;
      });
      messenger.showSnackBar(
        const SnackBar(content: Text('Saved'), duration: Duration(seconds: 1), backgroundColor: Color(0xFF22c55e)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() { _saving = false; });
      messenger.showSnackBar(
        SnackBar(content: Text('Save failed: $e'), backgroundColor: const Color(0xFFef4444)),
      );
    }
  }

  String _language() {
    final name = widget.path.split('/').last.toLowerCase();
    final ext = name.contains('.') ? name.split('.').last : '';
    switch (ext) {
      case 'dart': return 'dart';
      case 'ts': case 'tsx': return 'typescript';
      case 'js': case 'jsx': case 'mjs': return 'javascript';
      case 'py': return 'python';
      case 'go': return 'go';
      case 'rs': return 'rust';
      case 'java': return 'java';
      case 'kt': return 'kotlin';
      case 'swift': return 'swift';
      case 'c': case 'h': return 'c';
      case 'cpp': case 'hpp': case 'cc': return 'cpp';
      case 'cs': return 'csharp';
      case 'rb': return 'ruby';
      case 'php': return 'php';
      case 'sh': case 'bash': return 'bash';
      case 'json': return 'json';
      case 'yaml': case 'yml': return 'yaml';
      case 'toml': return 'ini';
      case 'xml': case 'html': case 'svg': return 'xml';
      case 'css': case 'scss': case 'sass': return 'css';
      case 'md': case 'markdown': return 'markdown';
      case 'sql': return 'sql';
      case 'dockerfile': return 'dockerfile';
      default:
        if (name == 'dockerfile') return 'dockerfile';
        if (name == 'makefile') return 'makefile';
        return 'plaintext';
    }
  }

  bool get _dirty => _editing && _controller.text != (_originalContent ?? '');

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyS): const _SaveIntent(),
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyS): const _SaveIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _SaveIntent: CallbackAction<_SaveIntent>(onInvoke: (_) {
            if (_editing) _save();
            return null;
          }),
        },
        child: Focus(
          autofocus: true,
          child: Container(
            color: const Color(0xFF0f172a),
            child: Column(
              children: [
                // Header bar
                Container(
                  height: 30,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: const BoxDecoration(
                    color: Color(0xFF0a0f1a),
                    border: Border(bottom: BorderSide(color: Color(0xFF1a2234))),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _editing ? Icons.edit : Icons.insert_drive_file_outlined,
                        size: 11,
                        color: _editing ? const Color(0xFFf59e0b) : const Color(0xFF64748b),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          widget.path + (_dirty ? ' •' : ''),
                          style: TextStyle(
                            fontSize: 10,
                            color: _dirty ? const Color(0xFFf59e0b) : const Color(0xFF94a3b8),
                            fontFamily: 'monospace',
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (_content != null)
                        Text(
                          '${(_editing ? _controller.text : _content!).split('\n').length}L · ${_language()}',
                          style: const TextStyle(fontSize: 9, color: Color(0xFF475569)),
                        ),
                      const SizedBox(width: 10),
                      if (_editing) ...[
                        IconButton(
                          onPressed: _dirty && !_saving ? _save : null,
                          icon: _saving
                              ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5))
                              : const Icon(Icons.save, size: 14, color: Color(0xFF22c55e)),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                          tooltip: 'Save (⌘S)',
                        ),
                        IconButton(
                          onPressed: () => setState(() {
                            _editing = false;
                            _controller.text = _originalContent ?? '';
                          }),
                          icon: const Icon(Icons.close, size: 14, color: Color(0xFFef4444)),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                          tooltip: 'Discard',
                        ),
                      ] else
                        IconButton(
                          onPressed: () => setState(() => _editing = true),
                          icon: const Icon(Icons.edit_outlined, size: 13, color: Color(0xFF94a3b8)),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                          tooltip: 'Edit',
                        ),
                    ],
                  ),
                ),

                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                      : _error != null
                          ? Center(child: Padding(
                              padding: const EdgeInsets.all(20),
                              child: Text(_error!, style: const TextStyle(color: Color(0xFFef4444))),
                            ))
                          : _editing
                              ? _buildEditor()
                              : _buildViewer(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEditor() {
    return Scrollbar(
      controller: _vScroll,
      child: SingleChildScrollView(
        controller: _vScroll,
        child: TextField(
          controller: _controller,
          onChanged: (_) => setState(() {}),
          maxLines: null,
          minLines: 20,
          style: const TextStyle(
            fontSize: 12,
            fontFamily: 'monospace',
            color: Color(0xFFe2e8f0),
            height: 1.5,
          ),
          decoration: const InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.all(12),
            border: InputBorder.none,
            filled: true,
            fillColor: Color(0xFF0f172a),
          ),
          keyboardType: TextInputType.multiline,
        ),
      ),
    );
  }

  Widget _buildViewer() {
    final text = _content ?? '';
    final language = _language();

    return Scrollbar(
      controller: _vScroll,
      child: SingleChildScrollView(
        controller: _vScroll,
        scrollDirection: Axis.vertical,
        child: SingleChildScrollView(
          controller: _hScroll,
          scrollDirection: Axis.horizontal,
          child: SelectionArea(
            child: language == 'plaintext'
                ? Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      text,
                      style: const TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        color: Color(0xFFe2e8f0),
                        height: 1.5,
                      ),
                    ),
                  )
                : HighlightView(
                    text,
                    language: language,
                    theme: atomOneDarkTheme,
                    padding: const EdgeInsets.all(12),
                    textStyle: const TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      height: 1.5,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _SaveIntent extends Intent {
  const _SaveIntent();
}
