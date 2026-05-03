import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../providers/app_state.dart';

enum PaletteMode { files, commands, findInFiles }

class PaletteAction {
  final String label;
  final String? hint;
  final IconData icon;
  final VoidCallback onInvoke;
  final String? shortcut;
  const PaletteAction({
    required this.label,
    this.hint,
    required this.icon,
    required this.onInvoke,
    this.shortcut,
  });
}

class CommandPalette extends StatefulWidget {
  final PaletteMode mode;
  final String? projectPath;
  final List<PaletteAction> commands;
  final void Function(String path)? onFilePicked;
  final void Function(String file, int line)? onGrepResultPicked;

  const CommandPalette({
    super.key,
    required this.mode,
    this.projectPath,
    this.commands = const [],
    this.onFilePicked,
    this.onGrepResultPicked,
  });

  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<CommandPalette> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  List<String> _allFiles = [];
  List<String> _filteredFiles = [];
  List<PaletteAction> _filteredCommands = [];
  List<dynamic> _grepResults = [];
  bool _loading = false;
  int _selectedIndex = 0;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    if (widget.mode == PaletteMode.files && widget.projectPath != null) {
      _loadFiles();
    }
    if (widget.mode == PaletteMode.commands) {
      _filteredCommands = widget.commands;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _loadFiles() async {
    if (widget.projectPath == null) return;
    setState(() => _loading = true);
    try {
      final api = context.read<AppState>().api;
      final files = await api.listFiles(widget.projectPath!);
      if (mounted) {
        setState(() {
          _allFiles = files;
          _filteredFiles = files.take(100).toList();
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onQueryChanged(String q) {
    setState(() => _selectedIndex = 0);
    _debounce?.cancel();

    if (widget.mode == PaletteMode.files) {
      _filterFiles(q);
    } else if (widget.mode == PaletteMode.commands) {
      _filterCommands(q);
    } else if (widget.mode == PaletteMode.findInFiles) {
      _debounce = Timer(const Duration(milliseconds: 300), () => _runGrep(q));
    }
  }

  void _filterFiles(String q) {
    if (q.isEmpty) {
      setState(() => _filteredFiles = _allFiles.take(100).toList());
      return;
    }
    final lower = q.toLowerCase();
    // Score: exact substring match, then fuzzy (contains all chars in order)
    final scored = <MapEntry<String, int>>[];
    for (final f in _allFiles) {
      final fLower = f.toLowerCase();
      int score = 0;
      if (fLower.contains(lower)) {
        score = 100 - fLower.indexOf(lower);
      } else if (_fuzzyMatch(fLower, lower)) {
        score = 50;
      }
      if (score > 0) {
        // Boost filename matches over path
        final name = f.split('/').last.toLowerCase();
        if (name.contains(lower)) score += 30;
        scored.add(MapEntry(f, score));
      }
    }
    scored.sort((a, b) => b.value.compareTo(a.value));
    setState(() => _filteredFiles = scored.take(50).map((e) => e.key).toList());
  }

  bool _fuzzyMatch(String haystack, String needle) {
    int hi = 0;
    for (int ni = 0; ni < needle.length; ni++) {
      while (hi < haystack.length && haystack[hi] != needle[ni]) {
        hi++;
      }
      if (hi >= haystack.length) return false;
      hi++;
    }
    return true;
  }

  void _filterCommands(String q) {
    if (q.isEmpty) {
      setState(() => _filteredCommands = widget.commands);
      return;
    }
    final lower = q.toLowerCase();
    setState(() {
      _filteredCommands = widget.commands.where((c) {
        return c.label.toLowerCase().contains(lower) ||
            (c.hint?.toLowerCase().contains(lower) ?? false);
      }).toList();
    });
  }

  Future<void> _runGrep(String q) async {
    if (q.isEmpty || widget.projectPath == null) {
      setState(() => _grepResults = []);
      return;
    }
    setState(() => _loading = true);
    try {
      final api = context.read<AppState>().api;
      final data = await api.grepInFiles(widget.projectPath!, q);
      if (mounted) {
        setState(() {
          _grepResults = data['matches'] as List? ?? [];
          _loading = false;
          _selectedIndex = 0;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _invoke() {
    switch (widget.mode) {
      case PaletteMode.files:
        if (_filteredFiles.isNotEmpty && _selectedIndex < _filteredFiles.length) {
          final rel = _filteredFiles[_selectedIndex];
          final fullPath = '${widget.projectPath}/$rel';
          Navigator.pop(context);
          widget.onFilePicked?.call(fullPath);
        }
        break;
      case PaletteMode.commands:
        if (_filteredCommands.isNotEmpty && _selectedIndex < _filteredCommands.length) {
          final cmd = _filteredCommands[_selectedIndex];
          Navigator.pop(context);
          cmd.onInvoke();
        }
        break;
      case PaletteMode.findInFiles:
        if (_grepResults.isNotEmpty && _selectedIndex < _grepResults.length) {
          final r = _grepResults[_selectedIndex];
          Navigator.pop(context);
          widget.onGrepResultPicked?.call(r['file'] as String, r['line'] as int);
        }
        break;
    }
  }

  int get _itemCount {
    switch (widget.mode) {
      case PaletteMode.files:
        return _filteredFiles.length;
      case PaletteMode.commands:
        return _filteredCommands.length;
      case PaletteMode.findInFiles:
        return _grepResults.length;
    }
  }

  String get _hint {
    switch (widget.mode) {
      case PaletteMode.files:
        return 'Search files by name...';
      case PaletteMode.commands:
        return 'Type command name...';
      case PaletteMode.findInFiles:
        return 'Search in files (regex)...';
    }
  }

  IconData get _iconPrefix {
    switch (widget.mode) {
      case PaletteMode.files:
        return Icons.search;
      case PaletteMode.commands:
        return Icons.terminal;
      case PaletteMode.findInFiles:
        return Icons.travel_explore;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.only(top: 100),
      child: KeyboardListener(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: (event) {
          if (event is! KeyDownEvent) return;
          if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
            setState(() => _selectedIndex = (_selectedIndex + 1) % (_itemCount == 0 ? 1 : _itemCount));
          } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
            setState(() => _selectedIndex = (_selectedIndex - 1 + _itemCount) % (_itemCount == 0 ? 1 : _itemCount));
          } else if (event.logicalKey == LogicalKeyboardKey.enter) {
            _invoke();
          } else if (event.logicalKey == LogicalKeyboardKey.escape) {
            Navigator.pop(context);
          }
        },
        child: Container(
          width: 640,
          decoration: BoxDecoration(
            color: const Color(0xFF1e293b),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF334155)),
            boxShadow: const [
              BoxShadow(color: Color(0xAA000000), blurRadius: 30, spreadRadius: 2),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Search input
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: Color(0xFF334155))),
                ),
                child: Row(
                  children: [
                    Icon(_iconPrefix, size: 16, color: const Color(0xFF8b5cf6)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        autofocus: true,
                        onChanged: _onQueryChanged,
                        style: const TextStyle(fontSize: 14, color: Color(0xFFe2e8f0)),
                        decoration: InputDecoration(
                          hintText: _hint,
                          hintStyle: const TextStyle(color: Color(0xFF64748b), fontSize: 14),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(vertical: 10),
                        ),
                      ),
                    ),
                    if (_loading)
                      const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                  ],
                ),
              ),

              // Results
              Container(
                constraints: const BoxConstraints(maxHeight: 480),
                child: _buildResults(),
              ),

              // Footer hint
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                decoration: const BoxDecoration(
                  color: Color(0xFF0f172a),
                  border: Border(top: BorderSide(color: Color(0xFF334155))),
                  borderRadius: BorderRadius.vertical(bottom: Radius.circular(8)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.keyboard_arrow_up, size: 11, color: Color(0xFF64748b)),
                    Icon(Icons.keyboard_arrow_down, size: 11, color: Color(0xFF64748b)),
                    SizedBox(width: 3),
                    Text('navigate', style: TextStyle(fontSize: 9, color: Color(0xFF64748b))),
                    SizedBox(width: 14),
                    Text('↵', style: TextStyle(fontSize: 11, color: Color(0xFF64748b))),
                    SizedBox(width: 3),
                    Text('open', style: TextStyle(fontSize: 9, color: Color(0xFF64748b))),
                    SizedBox(width: 14),
                    Text('esc', style: TextStyle(fontSize: 9, color: Color(0xFF64748b))),
                    SizedBox(width: 3),
                    Text('close', style: TextStyle(fontSize: 9, color: Color(0xFF64748b))),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResults() {
    if (_itemCount == 0) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(
            widget.mode == PaletteMode.files && widget.projectPath == null
                ? 'Open a project first'
                : 'No matches',
            style: const TextStyle(color: Color(0xFF64748b), fontSize: 12),
          ),
        ),
      );
    }

    switch (widget.mode) {
      case PaletteMode.files:
        return ListView.builder(
          shrinkWrap: true,
          itemCount: _filteredFiles.length,
          itemBuilder: (_, i) {
            final rel = _filteredFiles[i];
            final parts = rel.split('/');
            final name = parts.last;
            final dir = parts.length > 1 ? parts.sublist(0, parts.length - 1).join('/') : '';
            return _resultTile(
              icon: Icons.insert_drive_file_outlined,
              title: name,
              subtitle: dir,
              selected: i == _selectedIndex,
              onTap: () {
                setState(() => _selectedIndex = i);
                _invoke();
              },
            );
          },
        );
      case PaletteMode.commands:
        return ListView.builder(
          shrinkWrap: true,
          itemCount: _filteredCommands.length,
          itemBuilder: (_, i) {
            final cmd = _filteredCommands[i];
            return _resultTile(
              icon: cmd.icon,
              title: cmd.label,
              subtitle: cmd.hint,
              trailing: cmd.shortcut,
              selected: i == _selectedIndex,
              onTap: () {
                setState(() => _selectedIndex = i);
                _invoke();
              },
            );
          },
        );
      case PaletteMode.findInFiles:
        return ListView.builder(
          shrinkWrap: true,
          itemCount: _grepResults.length,
          itemBuilder: (_, i) {
            final r = _grepResults[i];
            final file = r['file'] as String;
            final line = r['line'] as int;
            final content = r['content'] as String? ?? '';
            final shortFile = widget.projectPath != null && file.startsWith(widget.projectPath!)
                ? file.substring(widget.projectPath!.length + 1)
                : file;
            return _resultTile(
              icon: Icons.code,
              title: '$shortFile:$line',
              subtitle: content.trim(),
              selected: i == _selectedIndex,
              onTap: () {
                setState(() => _selectedIndex = i);
                _invoke();
              },
            );
          },
        );
    }
  }

  Widget _resultTile({
    required IconData icon,
    required String title,
    String? subtitle,
    String? trailing,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        color: selected ? const Color(0xFF8b5cf6).withAlpha(30) : null,
        child: Row(
          children: [
            Icon(icon, size: 13, color: selected ? const Color(0xFF8b5cf6) : const Color(0xFF94a3b8)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 12,
                      color: selected ? const Color(0xFFe2e8f0) : const Color(0xFFcbd5e1),
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitle != null && subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      style: const TextStyle(fontSize: 10, color: Color(0xFF64748b), fontFamily: 'monospace'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF0f172a),
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: const Color(0xFF334155)),
                ),
                child: Text(
                  trailing,
                  style: const TextStyle(fontSize: 9, color: Color(0xFF94a3b8), fontFamily: 'monospace'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
