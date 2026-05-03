import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../providers/app_state.dart';
import '../../utils/chat_models.dart';

class SessionScreen extends StatefulWidget {
  final String sessionId;
  final bool embedded;
  const SessionScreen({
    super.key,
    required this.sessionId,
    this.embedded = false,
  });
  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  bool _loading = true;
  Timer? _pollTimer;

  // Local state — not from provider
  String _title = 'Session';
  String _cwd = '';
  String _agentName = 'Claude';
  String _selectedModelId = kClaudeChatModels.first.id;
  bool _starred = false;
  bool _sending = false;
  String? _sendStatus;
  List<dynamic> _serverMessages = [];
  final List<Map<String, dynamic>> _pendingMessages = [];

  // Replay mode
  bool _replayMode = false;
  int _replayIndex = 0;
  bool _replayPlaying = false;
  Timer? _replayTimer;

  List<dynamic> get _allMessages => [..._serverMessages, ..._pendingMessages];
  List<dynamic> get _visibleMessages => _replayMode
      ? _serverMessages.take(_replayIndex + 1).toList()
      : _allMessages;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    final scope = state.agentScope;
    if (scope == 'Kimi' || widget.sessionId.startsWith('kimi-')) {
      _agentName = 'Kimi';
      _selectedModelId = state.modelsForAgent('Kimi').first.id;
    } else {
      _selectedModelId = state.modelsForAgent('Claude').first.id;
    }
    unawaited(state.loadCapabilitiesIfNeeded());
    _load();
  }

  String _agentNameFromDiagnostics(dynamic diagnostics) {
    final agentRaw = diagnostics is Map
        ? (diagnostics['agent'] ?? '').toString()
        : '';
    final canonical = diagnostics is Map
        ? (diagnostics['canonicalId'] ?? '').toString()
        : '';
    if (agentRaw == 'kimi-cli' ||
        widget.sessionId.startsWith('kimi-') ||
        canonical.startsWith('kimi-')) {
      return 'Kimi';
    }
    if (agentRaw == 'cursor') return 'Cursor';
    if (agentRaw == 'codex-cli') return 'Codex';
    if (agentRaw == 'kiro-cli') return 'Kiro';
    if (agentRaw == 'opencode') return 'OpenCode';
    final scope = context.read<AppState>().agentScope;
    if (scope != 'All') return scope;
    return 'Claude';
  }

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    try {
      final data = await api.getSession(widget.sessionId);
      Map<String, dynamic> tags = {};
      try {
        final all = await api.getAllTags();
        final raw = all['tags'];
        if (raw is Map && raw[widget.sessionId] is Map) {
          tags = Map<String, dynamic>.from(raw[widget.sessionId] as Map);
        }
      } catch (_) {}
      if (!mounted) return;
      final newMessages = (data['messages'] is List)
          ? data['messages'] as List
          : const [];
      final diagnostics = data['diagnostics'];
      final detectedAgent = _agentNameFromDiagnostics(diagnostics);

      final changed =
          _messagesSignature(newMessages) !=
          _messagesSignature(_serverMessages);

      setState(() {
        _loading = false;
        _title = (data['title'] is String)
            ? data['title'] as String
            : 'Session';
        _cwd = (data['cwd'] is String) ? data['cwd'] as String : '';
        _agentName = detectedAgent;
        final models = _modelListForAgent(detectedAgent);
        if (!models.any((m) => m.id == _selectedModelId)) {
          _selectedModelId = models.first.id;
        }
        _starred = tags['starred'] == true;
        _serverMessages = newMessages;
        if (changed || _serverConfirmsPending(newMessages)) {
          _pendingMessages.clear();
        }
      });
      _scrollToBottom();
      _startPolling();
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
  }

  Future<void> _poll() async {
    if (!mounted) return;
    final api = context.read<AppState>().api;
    try {
      final data = await api.getSession(widget.sessionId);
      if (!mounted) return;
      final newMessages = (data['messages'] is List)
          ? data['messages'] as List
          : const [];
      final changed =
          _messagesSignature(newMessages) !=
          _messagesSignature(_serverMessages);
      if (changed) {
        setState(() {
          _serverMessages = newMessages;
          _pendingMessages.removeWhere(
            (m) => m['localOnly'] == true && _serverHasMessage(newMessages, m),
          );
          if (_serverConfirmsPending(newMessages)) {
            _pendingMessages.clear();
          }
          _title = (data['title'] is String) ? data['title'] as String : _title;
          final diagnostics = data['diagnostics'];
          final detectedAgent = _agentNameFromDiagnostics(diagnostics);
          if (detectedAgent != _agentName) {
            _agentName = detectedAgent;
            final models = _modelListForAgent(detectedAgent);
            if (!models.any((m) => m.id == _selectedModelId)) {
              _selectedModelId = models.first.id;
            }
          }
        });
        _scrollToBottom();
      }
    } catch (_) {}
  }

  String _messagesSignature(List<dynamic> messages) {
    if (messages.isEmpty) return '';
    final tail = messages.length > 8
        ? messages.sublist(messages.length - 8)
        : messages;
    return tail
        .map((m) {
          if (m is! Map) return m.toString();
          final type = (m['type'] ?? m['role'] ?? '').toString();
          final content = _extractContent(m['content']);
          return '$type:${content.length}:${content.hashCode}';
        })
        .join('|');
  }

  bool _serverConfirmsPending(List<dynamic> messages) {
    if (_pendingMessages.isEmpty || messages.isEmpty) return false;
    final lastPending = _extractContent(
      _pendingMessages.last['content'],
    ).trim();
    if (lastPending.isEmpty) return messages.length > _serverMessages.length;
    return messages.any((m) {
      if (m is! Map) return false;
      final type = (m['type'] ?? m['role'] ?? '').toString();
      return type == 'user' &&
          _extractContent(m['content']).trim() == lastPending;
    });
  }

  bool _serverHasMessage(List<dynamic> messages, dynamic candidate) {
    if (candidate is! Map) return false;
    final candidateType = (candidate['type'] ?? candidate['role'] ?? '')
        .toString();
    final candidateContent = _extractContent(candidate['content']).trim();
    if (candidateType.isEmpty || candidateContent.isEmpty) return false;
    return messages.any((m) {
      if (m is! Map) return false;
      final type = (m['type'] ?? m['role'] ?? '').toString();
      final content = _extractContent(m['content']).trim();
      return type == candidateType && content == candidateContent;
    });
  }

  String _displayContent(String content, {required bool isUser}) {
    if (isUser || _agentName != 'Codex') return content;
    return _cleanCodexExecOutput(content);
  }

  String _cleanCodexExecOutput(String stdout) {
    final normalized = stdout.trim().replaceAll('\r\n', '\n');
    if (normalized.isEmpty) return normalized;
    final lines = normalized.split('\n');
    var start = -1;
    for (var i = lines.length - 1; i >= 0; i--) {
      if (lines[i].trim().toLowerCase() == 'codex') {
        start = i + 1;
        break;
      }
    }
    if (start < 0 || start >= lines.length) return normalized;

    var end = lines.length;
    for (var i = start; i < lines.length; i++) {
      final t = lines[i].trim().toLowerCase();
      if (t == 'tokens used' || (t == '--------' && i > start)) {
        end = i;
        break;
      }
    }

    final answer = lines.sublist(start, end).join('\n').trim();
    return answer.isEmpty ? normalized : answer;
  }

  Future<void> _copyMessage(String content) async {
    final text = content.trim();
    if (text.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Скопировано в буфер'),
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _showMessageMenu(Offset globalPosition, String content) async {
    if (content.trim().isEmpty) return;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem<String>(
          value: 'copy',
          child: Row(
            children: [
              Icon(Icons.content_copy_rounded, size: 16),
              SizedBox(width: 8),
              Text('Copy message'),
            ],
          ),
        ),
      ],
    );
    if (selected == 'copy') {
      await _copyMessage(content);
    }
  }

  Future<void> _pollSoonAfterSend() async {
    for (final delay in const [
      Duration(milliseconds: 700),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 7),
    ]) {
      await Future.delayed(delay);
      if (!mounted) return;
      await _poll();
    }
  }

  Future<void> _toggleStar() async {
    final next = !_starred;
    setState(() => _starred = next);
    await context.read<AppState>().api.setStar(widget.sessionId, next);
    if (mounted) unawaited(context.read<AppState>().refreshSessions());
  }

  Future<void> _rename() async {
    final c = TextEditingController(text: _title);
    final next = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1e293b),
        title: const Text(
          'Rename session',
          style: TextStyle(color: Color(0xFFf1f5f9)),
        ),
        content: TextField(
          controller: c,
          autofocus: true,
          style: const TextStyle(color: Color(0xFFe2e8f0)),
          decoration: InputDecoration(
            hintText: 'Session title',
            hintStyle: const TextStyle(color: Color(0xFF64748b)),
            filled: true,
            fillColor: const Color(0xFF0f172a),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (next == null || next.isEmpty || !mounted) return;
    await context.read<AppState>().renameSession(widget.sessionId, next);
    if (mounted) setState(() => _title = next);
  }

  Future<void> _removeSession() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1e293b),
        title: const Text(
          'Remove session?',
          style: TextStyle(color: Color(0xFFf1f5f9)),
        ),
        content: Text(
          'Remove “$_title” from the list and stop it if it is still running?',
          style: const TextStyle(color: Color(0xFFcbd5e1)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFef4444),
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await context.read<AppState>().stopSession(widget.sessionId);
    if (mounted && !widget.embedded) Navigator.pop(context);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _toggleReplay() {
    setState(() {
      _replayMode = !_replayMode;
      if (_replayMode) {
        _replayIndex = 0;
        _replayPlaying = false;
        _pollTimer?.cancel();
      } else {
        _replayTimer?.cancel();
        _replayPlaying = false;
        _startPolling();
      }
    });
  }

  void _toggleReplayPlay() {
    if (_replayPlaying) {
      _replayTimer?.cancel();
      setState(() => _replayPlaying = false);
    } else {
      setState(() => _replayPlaying = true);
      _replayTimer = Timer.periodic(const Duration(milliseconds: 800), (_) {
        if (_replayIndex < _serverMessages.length - 1) {
          setState(() => _replayIndex++);
          _scrollToBottom();
        } else {
          _replayTimer?.cancel();
          setState(() => _replayPlaying = false);
        }
      });
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _replayTimer?.cancel();
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final messages = _visibleMessages;

    return Scaffold(
      backgroundColor: widget.embedded ? const Color(0xFF0f172a) : null,
      appBar: widget.embedded
          ? PreferredSize(
              preferredSize: const Size.fromHeight(36),
              child: Container(
                decoration: const BoxDecoration(
                  color: Color(0xFF0f172a),
                  border: Border(bottom: BorderSide(color: Color(0xFF1a2234))),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  children: [
                    const Icon(
                      Icons.folder_outlined,
                      size: 13,
                      color: Color(0xFF64748b),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _cwd.isNotEmpty ? _cwd : _title,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF94a3b8),
                          fontFamily: 'monospace',
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        _replayMode ? Icons.stop_circle_outlined : Icons.replay,
                        size: 16,
                        color: _replayMode
                            ? const Color(0xFFf59e0b)
                            : const Color(0xFF94a3b8),
                      ),
                      onPressed: _serverMessages.length > 1
                          ? _toggleReplay
                          : null,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      tooltip: _replayMode ? 'Exit replay' : 'Session replay',
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.refresh,
                        size: 16,
                        color: Color(0xFF94a3b8),
                      ),
                      onPressed: _replayMode ? null : _load,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                    ),
                    PopupMenuButton<String>(
                      padding: EdgeInsets.zero,
                      icon: const Icon(
                        Icons.more_vert,
                        size: 16,
                        color: Color(0xFF94a3b8),
                      ),
                      onSelected: (v) {
                        if (v == 'stop') {
                          context.read<AppState>().stopSession(
                            widget.sessionId,
                          );
                        } else if (v == 'star') {
                          _toggleStar();
                        } else if (v == 'rename') {
                          _rename();
                        } else if (v == 'delete') {
                          _removeSession();
                        }
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'star',
                          child: Text(_starred ? 'Unstar' : 'Star'),
                        ),
                        const PopupMenuItem(
                          value: 'rename',
                          child: Text('Rename'),
                        ),
                        const PopupMenuItem(
                          value: 'stop',
                          child: Text('Stop session'),
                        ),
                        const PopupMenuItem(
                          value: 'delete',
                          child: Text('Remove'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            )
          : AppBar(
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (_cwd.isNotEmpty)
                    Text(
                      _cwd,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF64748b),
                      ),
                    ),
                ],
              ),
              backgroundColor: Colors.transparent,
              actions: [
                IconButton(
                  icon: Icon(
                    _replayMode ? Icons.stop_circle_outlined : Icons.replay,
                    size: 20,
                    color: _replayMode ? const Color(0xFFf59e0b) : null,
                  ),
                  onPressed: _serverMessages.length > 1 ? _toggleReplay : null,
                  tooltip: _replayMode ? 'Exit replay' : 'Session replay',
                ),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 20),
                  onPressed: _replayMode ? null : _load,
                ),
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'stop') {
                      context.read<AppState>().stopSession(widget.sessionId);
                      Navigator.pop(context);
                    } else if (v == 'star') {
                      _toggleStar();
                    } else if (v == 'rename') {
                      _rename();
                    } else if (v == 'delete') {
                      _removeSession();
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'star',
                      child: Text(_starred ? 'Unstar' : 'Star'),
                    ),
                    const PopupMenuItem(value: 'rename', child: Text('Rename')),
                    const PopupMenuItem(
                      value: 'stop',
                      child: Text('Stop session'),
                    ),
                    const PopupMenuItem(value: 'delete', child: Text('Remove')),
                  ],
                ),
              ],
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Status bar
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  color: const Color(0xFF1e293b),
                  child: Row(
                    children: [
                      if (_replayMode) ...[
                        const Icon(
                          Icons.replay,
                          size: 12,
                          color: Color(0xFFf59e0b),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Replay ${_replayIndex + 1}/${_serverMessages.length}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFFf59e0b),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ] else ...[
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(0xFF22c55e),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'Auto-refresh 3s',
                          style: TextStyle(
                            fontSize: 11,
                            color: Color(0xFF22c55e),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                      const Spacer(),
                      Text(
                        '${messages.length} messages',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF64748b),
                        ),
                      ),
                    ],
                  ),
                ),

                // Replay controls
                if (_replayMode && _serverMessages.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    color: const Color(0xFF1e293b).withAlpha(200),
                    child: Row(
                      children: [
                        IconButton(
                          icon: Icon(
                            _replayPlaying ? Icons.pause : Icons.play_arrow,
                            size: 28,
                          ),
                          color: const Color(0xFFf59e0b),
                          onPressed: _toggleReplayPlay,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Slider(
                            value: _replayIndex.toDouble(),
                            min: 0,
                            max: (_serverMessages.length - 1).toDouble().clamp(
                              0,
                              double.infinity,
                            ),
                            divisions: _serverMessages.length > 1
                                ? _serverMessages.length - 1
                                : 1,
                            activeColor: const Color(0xFFf59e0b),
                            inactiveColor: const Color(0xFF334155),
                            onChanged: (v) {
                              setState(() => _replayIndex = v.round());
                              _scrollToBottom();
                            },
                          ),
                        ),
                      ],
                    ),
                  ),

                Expanded(
                  child: messages.isEmpty
                      ? const Center(
                          child: Text(
                            'No messages yet',
                            style: TextStyle(color: Color(0xFF64748b)),
                          ),
                        )
                      : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.all(12),
                          itemCount: messages.length,
                          itemBuilder: (_, i) => _messageBubble(messages[i]),
                        ),
                ),
                if (!_replayMode) _buildInput(),
              ],
            ),
    );
  }

  Widget _messageBubble(dynamic msg) {
    final type = msg['type'] ?? msg['role'] ?? '';
    final isUser = type == 'user';
    final isPending = msg['pending'] == true;
    final rawContent = _extractContent(msg['content']);
    final content = _displayContent(rawContent, isUser: isUser);
    final toolCalls = _extractToolCalls(msg['content']);
    final model = msg['model'] ?? '';

    if (content.isEmpty && toolCalls.isEmpty) return const SizedBox.shrink();

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onSecondaryTapDown: content.isNotEmpty && !isPending
            ? (details) => _showMessageMenu(details.globalPosition, content)
            : null,
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.88,
          ),
          decoration: BoxDecoration(
            color: isUser
                ? const Color(0xFF8b5cf6).withAlpha(30)
                : const Color(0xFF1e293b),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isPending
                  ? const Color(0xFF8b5cf6).withAlpha(30)
                  : isUser
                  ? const Color(0xFF8b5cf6).withAlpha(60)
                  : const Color(0xFF334155),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    isUser ? Icons.person : Icons.smart_toy,
                    size: 13,
                    color: isUser
                        ? const Color(0xFF8b5cf6)
                        : const Color(0xFF22c55e),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    isUser ? 'You' : _agentName,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: isUser
                          ? const Color(0xFF8b5cf6)
                          : const Color(0xFF22c55e),
                    ),
                  ),
                  if (isPending) ...[
                    const SizedBox(width: 6),
                    const Text(
                      'sending...',
                      style: TextStyle(
                        fontSize: 9,
                        color: Color(0xFF64748b),
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (content.isNotEmpty && !isPending)
                    Tooltip(
                      message: 'Копировать сообщение',
                      child: InkWell(
                        borderRadius: BorderRadius.circular(5),
                        onTap: () => _copyMessage(content),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0f172a),
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(color: const Color(0xFF334155)),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.content_copy_rounded,
                                size: 12,
                                color: Color(0xFFcbd5e1),
                              ),
                              SizedBox(width: 4),
                              Text(
                                'Copy',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Color(0xFFcbd5e1),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (model.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0f172a),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        model,
                        style: const TextStyle(
                          fontSize: 9,
                          color: Color(0xFF64748b),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              if (toolCalls.isNotEmpty) ...[
                const SizedBox(height: 6),
                ...toolCalls.map((t) => _toolCallChip(t)),
              ],
              if (content.isNotEmpty) ...[
                const SizedBox(height: 6),
                SelectionArea(child: _buildRichContent(content)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _toolCallChip(Map<String, String> t) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF0f172a),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _toolIcon(t['name'] ?? ''),
            size: 12,
            color: const Color(0xFFf59e0b),
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              t['name'] ?? 'tool',
              style: const TextStyle(
                fontSize: 11,
                color: Color(0xFFf59e0b),
                fontFamily: 'monospace',
              ),
            ),
          ),
          if (t['input_summary'] != null) ...[
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                t['input_summary']!,
                style: const TextStyle(fontSize: 10, color: Color(0xFF64748b)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }

  IconData _toolIcon(String name) {
    if (name.contains('Read')) return Icons.description_outlined;
    if (name.contains('Write') || name.contains('Edit')) {
      return Icons.edit_outlined;
    }
    if (name.contains('Bash')) return Icons.terminal;
    if (name.contains('Grep') || name.contains('Search')) return Icons.search;
    if (name.contains('Glob')) return Icons.folder_outlined;
    if (name.contains('Agent')) return Icons.smart_toy_outlined;
    if (name.contains('Web')) return Icons.language;
    if (name.contains('Todo')) return Icons.checklist;
    return Icons.build_outlined;
  }

  // --- File path detection and rendering ---

  static final _pathRegex = RegExp(
    r'(/(?:home|tmp|root|etc|var|usr)/[\w./\-]+)',
  );

  Widget _buildRichContent(String content) {
    final matches = _pathRegex.allMatches(content).toList();
    if (matches.isEmpty) {
      return SelectableText(
        content,
        style: const TextStyle(fontSize: 13, height: 1.5),
      );
    }

    final widgets = <Widget>[];
    int lastEnd = 0;
    for (final m in matches) {
      if (m.start > lastEnd) {
        final text = content.substring(lastEnd, m.start);
        if (text.trim().isNotEmpty) {
          widgets.add(
            SelectableText(
              text,
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
          );
        }
      }
      final path = m.group(0)!;
      widgets.add(_filePathButton(path));
      lastEnd = m.end;
    }
    if (lastEnd < content.length) {
      final text = content.substring(lastEnd);
      if (text.trim().isNotEmpty) {
        widgets.add(
          SelectableText(
            text,
            style: const TextStyle(fontSize: 13, height: 1.5),
          ),
        );
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }

  Widget _filePathButton(String path) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: TextButton.icon(
        onPressed: () => _openFile(path),
        icon: const Icon(Icons.open_in_new, size: 14),
        label: Text(
          path,
          style: const TextStyle(
            fontSize: 12,
            fontFamily: 'monospace',
            decoration: TextDecoration.underline,
          ),
        ),
        style: TextButton.styleFrom(
          foregroundColor: const Color(0xFF60a5fa),
          backgroundColor: const Color(0xFF0f172a),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
            side: const BorderSide(color: Color(0xFF334155)),
          ),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }

  void _openFile(String path) {
    final api = context.read<AppState>().api;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1e293b),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        minChildSize: 0.3,
        expand: false,
        builder: (ctx, scrollCtrl) => FutureBuilder<Map<String, dynamic>>(
          future: api.readFile(path),
          builder: (ctx, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Error: ${snap.error}',
                  style: const TextStyle(color: Color(0xFFef4444)),
                ),
              );
            }
            final data = snap.data!;
            final type = data['type'] ?? 'file';
            final fileContent = data['content'] ?? '';
            final fileName = path.split('/').last;

            if (type == 'directory') {
              final files = (data['files'] as List?) ?? [];
              return Column(
                children: [
                  _fileHeader(path, fileName, isDir: true),
                  Expanded(
                    child: ListView.builder(
                      controller: scrollCtrl,
                      itemCount: files.length,
                      itemBuilder: (_, i) {
                        final f = files[i];
                        final isDir = f['isDir'] == true;
                        return ListTile(
                          leading: Icon(
                            isDir ? Icons.folder : Icons.description_outlined,
                            color: isDir
                                ? const Color(0xFFf59e0b)
                                : const Color(0xFF60a5fa),
                            size: 20,
                          ),
                          title: Text(
                            f['name'] ?? '',
                            style: const TextStyle(fontSize: 14),
                          ),
                          onTap: () {
                            Navigator.pop(ctx);
                            _openFile('$path/${f['name']}');
                          },
                        );
                      },
                    ),
                  ),
                ],
              );
            }

            return Column(
              children: [
                _fileHeader(path, fileName),
                Expanded(
                  child: SingleChildScrollView(
                    controller: scrollCtrl,
                    padding: const EdgeInsets.all(16),
                    child: SelectableText(
                      fileContent,
                      style: const TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        height: 1.6,
                        color: Color(0xFFe2e8f0),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _fileHeader(String path, String name, {bool isDir = false}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFF334155))),
      ),
      child: Row(
        children: [
          Icon(
            isDir ? Icons.folder : Icons.description_outlined,
            color: isDir ? const Color(0xFFf59e0b) : const Color(0xFF60a5fa),
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  path,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF64748b),
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- Content extraction ---

  String _extractContent(dynamic content) {
    if (content == null) return '';
    if (content is String) return content;
    if (content is List) {
      final parts = <String>[];
      for (final item in content) {
        if (item is String) {
          parts.add(item);
        } else if (item is Map) {
          if (item['type'] == 'text') {
            final text = item['text'] ?? '';
            if (text.isNotEmpty) parts.add(text);
          } else if (item['type'] == 'tool_result') {
            final rc = item['content'];
            if (rc is String && rc.isNotEmpty) {
              parts.add(rc.length > 200 ? '${rc.substring(0, 200)}...' : rc);
            }
          }
        }
      }
      return parts.join('\n');
    }
    return content.toString();
  }

  List<Map<String, String>> _extractToolCalls(dynamic content) {
    if (content is! List) return [];
    final tools = <Map<String, String>>[];
    for (final item in content) {
      if (item is Map && item['type'] == 'tool_use') {
        final name = (item['name'] ?? 'unknown').toString();
        String? summary;
        final input = item['input'];
        if (input is Map) {
          if (input.containsKey('file_path')) {
            summary = _shortPath(input['file_path'].toString());
          } else if (input.containsKey('command')) {
            final cmd = input['command'].toString();
            summary = cmd.length > 40 ? '${cmd.substring(0, 40)}...' : cmd;
          } else if (input.containsKey('pattern')) {
            summary = input['pattern'].toString();
          }
        }
        final tool = <String, String>{'name': name};
        if (summary != null) tool['input_summary'] = summary;
        tools.add(tool);
      }
    }
    return tools;
  }

  String _shortPath(String path) {
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    if (parts.length <= 2) return path;
    return '.../${parts.sublist(parts.length - 2).join('/')}';
  }

  // --- Input ---

  List<ChatModelChoice> _modelListForAgent(String agentName) {
    return context.read<AppState>().modelsForAgent(agentName);
  }

  ChatModelChoice _selectedModel() {
    final list = _modelListForAgent(_agentName);
    for (final m in list) {
      if (m.id == _selectedModelId) return m;
    }
    return list.first;
  }

  Widget _modelPicker() {
    final list = _modelListForAgent(_agentName);
    final selected = _selectedModel();
    return PopupMenuButton<String>(
      tooltip: 'Model',
      onSelected: (id) => setState(() => _selectedModelId = id),
      itemBuilder: (_) => list.map((m) {
        return PopupMenuItem<String>(
          value: m.id,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                m.label,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(
                m.priceInOutLabel,
                style: const TextStyle(fontSize: 11, color: Color(0xFF64748b)),
              ),
            ],
          ),
        );
      }).toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF0f172a),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFF334155)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _agentName == 'Kimi' ? Icons.bolt_outlined : Icons.auto_awesome,
              size: 14,
              color: const Color(0xFF94a3b8),
            ),
            const SizedBox(width: 5),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 82),
              child: Text(
                selected.label,
                style: const TextStyle(
                  fontSize: 11,
                  color: Color(0xFFcbd5e1),
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(
              Icons.arrow_drop_down,
              size: 16,
              color: Color(0xFF94a3b8),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInput() {
    return Container(
      padding: EdgeInsets.only(
        left: 12,
        right: 8,
        top: 8,
        bottom: MediaQuery.of(context).viewPadding.bottom + 8,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF1e293b),
        border: Border(top: BorderSide(color: Color(0xFF334155))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _modelPicker(),
              const SizedBox(width: 6),
              Expanded(
                child: TextField(
                  controller: _inputController,
                  decoration: InputDecoration(
                    hintText: 'Send message...',
                    hintStyle: const TextStyle(
                      color: Color(0xFF64748b),
                      fontSize: 14,
                    ),
                    filled: true,
                    fillColor: const Color(0xFF0f172a),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                  ),
                  style: const TextStyle(fontSize: 14),
                  maxLines: 1,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (value) => unawaited(_send(value)),
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 48,
                height: 48,
                child: FilledButton(
                  onPressed: _sending ? null : () => unawaited(_send()),
                  style: FilledButton.styleFrom(
                    padding: EdgeInsets.zero,
                    backgroundColor: const Color(0xFF8b5cf6),
                    disabledBackgroundColor: const Color(0xFF475569),
                    shape: const CircleBorder(),
                  ),
                  child: _sending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.send, color: Colors.white, size: 20),
                ),
              ),
            ],
          ),
          if (_sendStatus != null) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _sendStatus!,
                style: const TextStyle(fontSize: 11, color: Color(0xFF94a3b8)),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _send([String? submittedText]) async {
    final text = (submittedText ?? _inputController.text).trim();
    if (text.isEmpty || _sending) return;
    final api = context.read<AppState>().api;
    setState(() {
      _sending = true;
      _sendStatus = 'POST ${api.baseUrl}/sessions/${widget.sessionId}/message';
      _pendingMessages.add({'type': 'user', 'content': text, 'pending': true});
    });
    _scrollToBottom();
    try {
      final result = await api.sendMessage(
        widget.sessionId,
        text,
        agentEnv: context.read<AppState>().agentEnvForServer(),
        model: _selectedModel().id,
      );
      _inputController.clear();
      final assistant = (result['assistant'] ?? '').toString().trim();
      if (assistant.isNotEmpty && mounted) {
        setState(() {
          _pendingMessages.removeWhere(
            (m) =>
                m['pending'] == true &&
                m['type'] == 'user' &&
                m['content'] == text,
          );
          _pendingMessages.addAll([
            {'type': 'user', 'content': text, 'localOnly': true},
            {'type': 'assistant', 'content': assistant, 'localOnly': true},
          ]);
          _sendStatus = 'Ответ получен напрямую от $_agentName';
        });
        _scrollToBottom();
      }
      await _poll();
      unawaited(_pollSoonAfterSend());
      if (mounted && assistant.isEmpty) {
        setState(() => _sendStatus = 'Сервер принял сообщение, жду ответ...');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _pendingMessages.removeWhere(
          (m) =>
              m['pending'] == true &&
              m['type'] == 'user' &&
              m['content'] == text,
        );
        _sendStatus = 'Ошибка отправки: $e';
        _pendingMessages.add({
          'type': 'assistant',
          'content': 'Не удалось отправить сообщение: $e',
          'pending': true,
        });
      });
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }
}
