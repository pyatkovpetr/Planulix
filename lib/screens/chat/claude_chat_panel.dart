import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../../providers/app_state.dart';
import '../../utils/chat_models.dart';

class ClaudeChatPanel extends StatefulWidget {
  final String? projectPath;
  final VoidCallback? onClose;

  /// If set, absolute paths in assistant/user messages become tappable and open the file tab.
  final void Function(String absolutePath)? onPathOpen;

  const ClaudeChatPanel({
    super.key,
    this.projectPath,
    this.onClose,
    this.onPathOpen,
  });

  @override
  State<ClaudeChatPanel> createState() => _ClaudeChatPanelState();
}

class _PendingAttachment {
  final String name;
  final Uint8List bytes;
  final String ext;
  String? remotePath;
  bool uploading;
  _PendingAttachment({
    required this.name,
    required this.bytes,
    required this.ext,
    this.uploading = false,
  });
}

class _ClaudeChatPanelState extends State<ClaudeChatPanel> {
  /// Same roots as session screen + macOS /Users for local hints.
  static final _chatPathRegex = RegExp(
    r'(/(?:home|tmp|root|etc|var|usr|opt|Users)/[\w./\-]+)',
  );

  final _inputController = TextEditingController();
  final _inputFocusNode = FocusNode();
  final _scrollController = ScrollController();
  final List<_PendingAttachment> _attachments = [];
  List<dynamic> _messages = [];
  String? _sessionId;
  String _title = 'Chat';
  bool _loading = false;
  bool _sending = false;
  Timer? _pollTimer;
  Timer? _slashDebounce;
  StreamSubscription<dynamic>? _eventsSub;
  WebSocketChannel? _eventsChannel;
  Map<String, dynamic>? _sessionDiagnostics;

  /// From GET /sessions/:id/cost — running tally for this chat (server parses JSONL).
  Map<String, dynamic>? _sessionCost;

  /// How message tail updates: `ws` (events socket) or `poll` (HTTP refresh).
  String _eventSource = 'poll';

  /// Provider model id for new lines (--model / -m). Scope comes from dashboard filter.
  String _chatModelId = kClaudeChatModels.first.id;
  // Monotonic counter to drop stale async results when project switches quickly.
  int _initGen = 0;

  /// While true, list refresh / stream appends scroll to bottom; false if user scrolled up to read.
  bool _userPinnedToBottom = true;
  static const double _bottomPinThreshold = 120;

  // Slash commands state
  List<dynamic>? _allSkills;
  bool _slashMenuOpen = false;
  String _slashQuery = '';
  int _slashSelectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_updateScrollPin);
    unawaited(context.read<AppState>().loadCapabilitiesIfNeeded());
    _initSession();
    _loadSkills();
    _inputController.addListener(_handleInputChange);
  }

  Future<void> _loadSkills() async {
    try {
      final list = await context.read<AppState>().api.getSkills();
      if (mounted) setState(() => _allSkills = list);
    } catch (_) {}
  }

  void _handleInputChange() {
    _slashDebounce?.cancel();
    _slashDebounce = Timer(
      const Duration(milliseconds: 80),
      _recomputeSlashMenu,
    );
  }

  void _recomputeSlashMenu() {
    if (!mounted) return;
    final text = _inputController.text;
    final cursorPos = _inputController.selection.baseOffset;
    if (cursorPos < 0) return;

    // Look for / at start of line or after whitespace
    final beforeCursor = text.substring(0, cursorPos);
    final slashIdx = beforeCursor.lastIndexOf('/');

    bool shouldShow = false;
    String query = '';
    if (slashIdx >= 0) {
      final isStart =
          slashIdx == 0 ||
          beforeCursor[slashIdx - 1] == ' ' ||
          beforeCursor[slashIdx - 1] == '\n';
      if (isStart) {
        final afterSlash = beforeCursor.substring(slashIdx + 1);
        if (!afterSlash.contains(' ') && !afterSlash.contains('\n')) {
          shouldShow = true;
          query = afterSlash;
        }
      }
    }

    if (shouldShow != _slashMenuOpen || query != _slashQuery) {
      setState(() {
        _slashMenuOpen = shouldShow;
        _slashQuery = query;
        _slashSelectedIndex = 0;
      });
    }
  }

  List<dynamic> get _filteredSkills {
    if (_allSkills == null) return [];
    if (_slashQuery.isEmpty) return _allSkills!.take(20).toList();
    final q = _slashQuery.toLowerCase();
    return _allSkills!
        .where((s) {
          final name = (s['name'] as String).toLowerCase();
          return name.contains(q);
        })
        .take(20)
        .toList();
  }

  void _insertSkill(String name) {
    final text = _inputController.text;
    final cursorPos = _inputController.selection.baseOffset;
    final beforeCursor = text.substring(0, cursorPos);
    final slashIdx = beforeCursor.lastIndexOf('/');
    if (slashIdx < 0) return;

    final newText =
        '${text.substring(0, slashIdx)}/$name ${text.substring(cursorPos)}';
    _inputController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: slashIdx + name.length + 2),
    );
    setState(() => _slashMenuOpen = false);
  }

  @override
  void didUpdateWidget(ClaudeChatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.projectPath != widget.projectPath) {
      _pollTimer?.cancel();
      _teardownEventsChannel();
      _messages = [];
      _sessionId = null;
      _sessionDiagnostics = null;
      _sessionCost = null;
      _eventSource = 'poll';
      _userPinnedToBottom = true;
      _attachments.clear();
      final st = context.read<AppState>();
      _chatModelId = st.agentScope == 'Kimi'
          ? kKimiChatModels.first.id
          : kClaudeChatModels.first.id;
      _initSession();
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _slashDebounce?.cancel();
    _teardownEventsChannel();
    _inputController.removeListener(_handleInputChange);
    _scrollController.removeListener(_updateScrollPin);
    _inputController.dispose();
    _inputFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _initSession() async {
    if (widget.projectPath == null) return;
    final gen = ++_initGen;
    setState(() => _loading = true);
    try {
      final state = context.read<AppState>();
      // Look for existing session with matching cwd
      final existing = state.sessions.firstWhere(
        (s) => s['cwd'] == widget.projectPath && s['isActive'] == true,
        orElse: () => null,
      );
      if (existing != null) {
        final id = existing['sessionId'];
        if (id is String) {
          _sessionId = id;
          await _loadMessages();
        }
      }
      if (!mounted || gen != _initGen) return;
      setState(() => _loading = false);
      _startPolling();
      _subscribeSessionEvents();
    } catch (_) {
      if (!mounted || gen != _initGen) return;
      setState(() => _loading = false);
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_sessionId == null) return;
      // Always refresh messages from the API, even when the events WebSocket is connected.
      // WS can stop emitting `message` while JSONL already has new turns; skipping REST
      // left optimistic `pending` user bubbles spinning forever.
      unawaited(_loadMessages());
    });
  }

  void _teardownEventsChannel() {
    _eventsSub?.cancel();
    _eventsSub = null;
    _eventsChannel?.sink.close();
    _eventsChannel = null;
  }

  void _subscribeSessionEvents() {
    _teardownEventsChannel();
    final id = _sessionId;
    if (id == null || !mounted) return;
    final api = context.read<AppState>().api;
    WebSocketChannel? ch;
    try {
      ch = WebSocketChannel.connect(Uri.parse(api.sessionEventsWsUrl(id)));
    } catch (_) {
      if (mounted) setState(() => _eventSource = 'poll');
      return;
    }
    _eventsChannel = ch;
    setState(() => _eventSource = 'ws');
    _eventsSub = ch.stream.listen(
      (ev) {
        if (!mounted) return;
        String raw;
        if (ev is String) {
          raw = ev;
        } else if (ev is List<int>) {
          raw = utf8.decode(ev);
        } else {
          return;
        }
        Map<String, dynamic>? j;
        try {
          final o = jsonDecode(raw);
          if (o is Map<String, dynamic>) {
            j = o;
          } else if (o is Map) {
            j = Map<String, dynamic>.from(
              o.map((k, v) => MapEntry(k.toString(), v)),
            );
          }
        } catch (_) {
          return;
        }
        if (j == null) return;
        final jj = j;
        final kind = (jj['kind'] ?? jj['type'])?.toString();
        if (kind == 'init') {
          final title = jj['title'];
          setState(() {
            _sessionDiagnostics = {
              'agent': jj['agent'],
              'tmuxAlive': jj['tmuxAlive'],
              'historyLinked': (jj['historyPath'] is String)
                  ? ((jj['historyPath'] as String).isNotEmpty)
                  : false,
            };
            if (title is String && title.isNotEmpty) _title = title;
          });
          return;
        }
        if (kind == 'message') {
          final m = jj['message'];
          if (m is Map) {
            final msg = Map<String, dynamic>.from(
              m.map((k, v) => MapEntry(k.toString(), v)),
            );
            _appendStreamMessage(msg);
          }
        }
        if (kind == 'error') {
          setState(() => _eventSource = 'poll');
        }
      },
      onError: (_) {
        if (mounted) setState(() => _eventSource = 'poll');
      },
      onDone: () {
        if (mounted) setState(() => _eventSource = 'poll');
      },
    );
  }

  /// Kimi-cli often stores multiline user text as literal backslash-n in JSON; the app
  /// sends real newlines. Same prompt then mismatches pending merge / dedup → two bubbles.
  static String _kimiNormalizeLiteralEscapes(String s) {
    return s
        .replaceAll(r'\r\n', '\n')
        .replaceAll(r'\n', '\n')
        .replaceAll(r'\t', '\t')
        .trim();
  }

  static String _rawMessageContentKey(dynamic msg) {
    if (msg is! Map) return '';
    final content = msg['content'];
    if (content is String) return content.trim();
    if (content is List) {
      final b = StringBuffer();
      for (final block in content) {
        if (block is Map && block['type'] == 'text') {
          b.write((block['text'] ?? '').toString());
        }
      }
      return b.toString().trim();
    }
    return '';
  }

  static String _messageContentKeyKimi(dynamic msg) =>
      _kimiNormalizeLiteralEscapes(_rawMessageContentKey(msg));

  static bool _serverHasUserWithContent(
    List<dynamic> server,
    String contentNorm,
    bool kimi,
  ) {
    if (contentNorm.isEmpty) return true;
    for (final s in server) {
      if (s is! Map) continue;
      final t = (s['type'] ?? s['role'] ?? '').toString();
      if (t != 'user') continue;
      final key = kimi ? _messageContentKeyKimi(s) : _rawMessageContentKey(s);
      if (key == contentNorm) return true;
    }
    return false;
  }

  List<dynamic> _mergePendingFromServer(
    List<dynamic> server,
    List<dynamic> current,
    bool kimi,
  ) {
    final pending = current
        .where((m) => m is Map && m['pending'] == true)
        .toList();
    if (pending.isEmpty) return List<dynamic>.from(server);
    final out = List<dynamic>.from(server);
    for (final p in pending) {
      final key = kimi ? _messageContentKeyKimi(p) : _rawMessageContentKey(p);
      if (!_serverHasUserWithContent(server, key, kimi)) {
        out.add(p);
      }
    }
    return out;
  }

  /// Kimi context.jsonl can replay the same long user line; WS may stream empty assistant rows.
  /// This mirrors deduplicateKimiReplay on the server: if a prefix of the canonical list
  /// appears again starting at position i (≥2 messages = one full turn), it is a context
  /// replay and we skip it. This handles both user and assistant duplicates of any length.
  List<dynamic> _sanitizeKimiMessagesForDisplay(List<dynamic> list) {
    if (list.isEmpty) return list;
    // First pass: remove empty messages.
    final filtered = <dynamic>[];
    for (final m in list) {
      if (m is! Map) {
        filtered.add(m);
        continue;
      }
      final t = (m['type'] ?? m['role'] ?? '').toString();
      final ck = _messageContentKeyKimi(m);
      if ((t == 'user' || t == 'assistant') && ck.isEmpty) continue;
      filtered.add(m);
    }
    // Second pass: prefix-replay dedup.
    return _deduplicateKimiReplay(filtered);
  }

  /// Detects and removes kimi context replays. A "replay" is a run of ≥2 messages at
  /// position i that exactly matches the beginning of the canonical list built so far.
  List<dynamic> _deduplicateKimiReplay(List<dynamic> list) {
    // Each canonical entry: (role, content-key)
    final known = <(String, String)>[];
    final result = <dynamic>[];
    int i = 0;
    while (i < list.length) {
      if (known.length >= 2) {
        int k = 0;
        while (k < known.length && i + k < list.length) {
          final m = list[i + k];
          if (m is! Map) break;
          final role = (m['type'] ?? m['role'] ?? '').toString();
          final ck = _messageContentKeyKimi(m);
          if (known[k].$1 == role && known[k].$2 == ck) {
            k++;
          } else {
            break;
          }
        }
        if (k >= 2) {
          i += k; // skip replay prefix
          continue;
        }
      }
      final m = list[i];
      if (m is Map) {
        final role = (m['type'] ?? m['role'] ?? '').toString();
        final ck = _messageContentKeyKimi(m);
        known.add((role, ck));
      }
      result.add(m);
      i++;
    }
    return result;
  }

  void _appendStreamMessage(Map<String, dynamic> msg) {
    final kimi = mounted && context.read<AppState>().agentScope == 'Kimi';
    String ckFor(dynamic m) =>
        kimi ? _messageContentKeyKimi(m) : _rawMessageContentKey(m);
    final role = (msg['type'] ?? msg['role'] ?? '').toString();
    final ck = ckFor(msg);
    if (role.isEmpty && ck.isEmpty) return;
    if (kimi) {
      if (role == 'assistant' && ck.isEmpty) return;
      if (role == 'user' && ck.isEmpty) return;
      if (role == 'user') {
        for (final existing in _messages.reversed.take(48)) {
          if (existing is! Map) continue;
          final er = (existing['type'] ?? existing['role'] ?? '').toString();
          if (er == 'user' && ckFor(existing) == ck) return;
        }
      }
    }

    var next = List<dynamic>.from(_messages);
    next.removeWhere((m) {
      if (m is! Map || m['pending'] != true) return false;
      final mr = (m['type'] ?? m['role'] ?? '').toString();
      return mr == role && ckFor(m) == ck;
    });

    for (final existing in next.reversed.take(24)) {
      if (existing is! Map || existing['pending'] == true) continue;
      final er = (existing['type'] ?? existing['role'] ?? '').toString();
      if (er == role && ckFor(existing) == ck) {
        setState(() => _messages = next);
        _scrollToBottom();
        return;
      }
    }

    setState(() => _messages = [...next, msg]);
    _scrollToBottom();
  }

  Future<void> _loadMessages() async {
    if (_sessionId == null || !mounted) return;
    final api = context.read<AppState>().api;
    try {
      final data = await api.getSession(_sessionId!);
      Map<String, dynamic>? costMap;
      try {
        final c = await api.getSessionCost(_sessionId!);
        costMap = Map<String, dynamic>.from(c);
      } catch (_) {}
      if (!mounted) return;
      final diag = data['diagnostics'];
      if (diag is Map) {
        _sessionDiagnostics = Map<String, dynamic>.from(
          diag.map((k, v) => MapEntry(k.toString(), v)),
        );
      }
      final newMessages = (data['messages'] is List)
          ? data['messages'] as List
          : const [];
      final scope = context.read<AppState>().agentScope;
      final merged = _mergePendingFromServer(
        newMessages,
        _messages,
        scope == 'Kimi',
      );
      final forDisplay = scope == 'Kimi'
          ? _sanitizeKimiMessagesForDisplay(merged)
          : merged;
      setState(() {
        _messages = forDisplay;
        _title =
            (data['title'] is String &&
                (data['title'] as String).trim().isNotEmpty)
            ? data['title'] as String
            : '${scope == 'Kimi' ? 'Kimi' : 'Claude'} Chat';
        if (costMap != null) _sessionCost = costMap;
      });
      _scrollToBottom();
    } catch (_) {}
  }

  List<ChatModelChoice> _modelListForScope(String scope) => context
      .read<AppState>()
      .modelsForAgent(scope == 'Kimi' ? 'Kimi' : 'Claude');

  String _effectiveChatModelId(String agentScope) {
    final list = _modelListForScope(agentScope);
    if (list.any((c) => c.id == _chatModelId)) return _chatModelId;
    return list.first.id;
  }

  void _syncModelIdIfNeeded(String agentScope) {
    final want = _effectiveChatModelId(agentScope);
    if (want != _chatModelId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _effectiveChatModelId(agentScope) != _chatModelId) {
          setState(() => _chatModelId = _effectiveChatModelId(agentScope));
        }
      });
    }
  }

  static int _asIntLoose(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is double) return v.round();
    return int.tryParse(v.toString()) ?? 0;
  }

  String _formatTokBrief(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }

  /// One line for the diagnostics strip (session cost from server JSONL).
  String? _sessionCostSummaryText() {
    final c = _sessionCost;
    if (c == null) return null;
    final total = c['totalCost'];
    var t = 0.0;
    if (total is num) t = total.toDouble();
    final u = c['usage'];
    if (u is! Map) {
      return 'Σ ~\$${t.toStringAsFixed(3)} · list est.';
    }
    final inp = _asIntLoose(u['inputTokens']);
    final out = _asIntLoose(u['outputTokens']);
    final cread = _asIntLoose(u['cacheReadInputTokens']);
    final ccreate = _asIntLoose(u['cacheCreationInputTokens']);
    final parts = <String>[
      'Σ ~\$${t.toStringAsFixed(3)}',
      '${_formatTokBrief(inp)} in',
      '${_formatTokBrief(out)} out',
    ];
    if (cread > 0 || ccreate > 0) {
      parts.add('cache ${_formatTokBrief(cread)}/${_formatTokBrief(ccreate)}');
    }
    parts.add('list est.');
    return parts.join(' · ');
  }

  Widget _buildModelPicker(AppState appState) {
    final scope = appState.agentScope;
    final list = _modelListForScope(scope);
    final id = _effectiveChatModelId(scope);
    final selected = list.firstWhere(
      (c) => c.id == id,
      orElse: () => list.first,
    );

    return MenuAnchor(
      style: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(Color(0xFF1e293b)),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: Color(0xFF334155)),
          ),
        ),
      ),
      menuChildren: list
          .map(
            (c) => MenuItemButton(
              onPressed: () => setState(() => _chatModelId = c.id),
              child: SizedBox(
                width: 200,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            c.label,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFFe2e8f0),
                            ),
                          ),
                        ),
                        if (c.id == id)
                          const Icon(
                            Icons.check,
                            size: 14,
                            color: Color(0xFF8b5cf6),
                          ),
                      ],
                    ),
                    if (c.tier != null)
                      Text(
                        c.tier!,
                        style: const TextStyle(
                          fontSize: 10,
                          color: Color(0xFF64748b),
                        ),
                      ),
                    Text(
                      '${c.priceInOutLabel} · \$ / 1M',
                      style: const TextStyle(
                        fontSize: 9,
                        color: Color(0xFF475569),
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          )
          .toList(),
      builder: (context, controller, child) {
        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () {
              if (controller.isOpen) {
                controller.close();
              } else {
                controller.open();
              }
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF151e2e),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF334155)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(
                    scope == 'Kimi' ? Icons.bolt_outlined : Icons.auto_awesome,
                    size: 12,
                    color: const Color(0xFF94a3b8),
                  ),
                  const SizedBox(width: 4),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 138),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          selected.label,
                          style: const TextStyle(
                            fontSize: 10,
                            color: Color(0xFFcbd5e1),
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                        Text(
                          selected.priceInOutLabel,
                          style: const TextStyle(
                            fontSize: 8,
                            color: Color(0xFF64748b),
                            fontFamily: 'monospace',
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 2),
                  const Icon(
                    Icons.arrow_drop_down,
                    size: 16,
                    color: Color(0xFF94a3b8),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _updateScrollPin() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final dist = pos.maxScrollExtent - pos.pixels;
    _userPinnedToBottom = dist <= _bottomPinThreshold;
  }

  void _scrollToBottom({bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      if (!force && !_userPinnedToBottom) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _pickImages() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
      withData: true,
    );
    if (result == null || !mounted) return;

    final api = context.read<AppState>().api;
    final messenger = ScaffoldMessenger.of(context);
    for (final file in result.files) {
      if (file.bytes == null) continue;
      final ext = (file.extension ?? 'png').toLowerCase();
      final pending = _PendingAttachment(
        name: file.name,
        bytes: file.bytes!,
        ext: ext,
        uploading: true,
      );
      setState(() => _attachments.add(pending));

      try {
        final remotePath = await api.uploadChatImage(file.bytes!, ext);
        if (!mounted) return;
        setState(() {
          pending.remotePath = remotePath;
          pending.uploading = false;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() => _attachments.remove(pending));
        messenger.showSnackBar(
          SnackBar(
            content: Text('Upload failed: $e'),
            backgroundColor: const Color(0xFFef4444),
          ),
        );
      }
    }
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    if (text.isEmpty && _attachments.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    if (widget.projectPath == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Open a project first')),
      );
      return;
    }

    setState(() => _sending = true);
    final state = context.read<AppState>();
    final modelId = _effectiveChatModelId(state.agentScope);

    try {
      // Build message with image references
      var finalText = text;
      if (_attachments.isNotEmpty) {
        final refs = _attachments
            .where((a) => a.remotePath != null)
            .map((a) => a.remotePath!)
            .join('\n');
        finalText = '$refs\n\n$text'.trim();
      }

      // Create session if none exists
      if (_sessionId == null) {
        final data = await state.api.createSession(
          cwd: widget.projectPath,
          mode: 'chat',
          prompt: finalText,
          model: modelId,
          agent: state.agentScope == 'Kimi' ? 'kimi-cli' : null,
          agentEnv: state.agentEnvForServer(),
        );
        final session = data['session'];
        final id = (session is Map) ? session['id'] : null;
        if (id is! String) {
          throw StateError('createSession: missing session.id in response');
        }
        _sessionId = id;
        await state.refreshSessions();
        _subscribeSessionEvents();
      } else {
        await state.api.sendMessage(
          _sessionId!,
          finalText,
          agentEnv: state.agentEnvForServer(),
          model: modelId,
        );
      }

      if (!mounted) return;
      setState(() {
        _inputController.clear();
        _attachments.clear();
        _sending = false;
        // Optimistic pending message
        _messages = [
          ..._messages,
          {
            'type': 'user',
            'role': 'user',
            'content': finalText,
            'pending': true,
          },
        ];
      });
      _scrollToBottom(force: true);

      unawaited(_loadMessages());
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) _loadMessages();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text('Send failed: $e'),
          backgroundColor: const Color(0xFFef4444),
        ),
      );
    }
  }

  Future<void> _tmuxInterrupt() async {
    final id = _sessionId;
    if (id == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<AppState>().api.interruptSession(id);
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Агент прерван (Ctrl+C)')),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('Стоп: $e'),
          backgroundColor: const Color(0xFFef4444),
        ),
      );
    }
  }

  Future<void> _tmuxContinue() async {
    final id = _sessionId;
    if (id == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<AppState>().api.continueSession(id);
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Отправлен Enter в tmux')),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('Play: $e'),
          backgroundColor: const Color(0xFFef4444),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    _syncModelIdIfNeeded(appState.agentScope);

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF0d1420),
        border: Border(left: BorderSide(color: Color(0xFF1a2234))),
      ),
      child: Column(
        children: [
          // Header
          Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: const BoxDecoration(
              color: Color(0xFF0a0f1a),
              border: Border(bottom: BorderSide(color: Color(0xFF1a2234))),
            ),
            child: Row(
              children: [
                const Icon(Icons.smart_toy, size: 14, color: Color(0xFF8b5cf6)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _title,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFFcbd5e1),
                      letterSpacing: 0.3,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_sessionId != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF22c55e).withAlpha(25),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: const Text(
                      'active',
                      style: TextStyle(
                        fontSize: 9,
                        color: Color(0xFF22c55e),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                if (_sessionId != null) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF334155).withAlpha(180),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(
                      _eventSource == 'ws' ? 'live' : 'poll',
                      style: const TextStyle(
                        fontSize: 9,
                        color: Color(0xFF94a3b8),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
                if (_sessionId != null &&
                    _sessionDiagnostics != null &&
                    _sessionDiagnostics!['tmuxAlive'] == true) ...[
                  Tooltip(
                    message: 'Стоп: прервать агента (Ctrl+C в tmux)',
                    child: IconButton(
                      onPressed: _tmuxInterrupt,
                      icon: const Icon(
                        Icons.stop_circle_outlined,
                        size: 15,
                        color: Color(0xFFf87171),
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 24,
                        minHeight: 22,
                      ),
                    ),
                  ),
                  Tooltip(
                    message: 'Play: Enter в tmux (продолжить после паузы)',
                    child: IconButton(
                      onPressed: _tmuxContinue,
                      icon: const Icon(
                        Icons.play_circle_outline,
                        size: 15,
                        color: Color(0xFF4ade80),
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 24,
                        minHeight: 22,
                      ),
                    ),
                  ),
                ],
                IconButton(
                  onPressed: _loadMessages,
                  icon: const Icon(
                    Icons.refresh,
                    size: 13,
                    color: Color(0xFF94a3b8),
                  ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 22,
                    minHeight: 22,
                  ),
                ),
                if (widget.onClose != null)
                  IconButton(
                    onPressed: widget.onClose,
                    icon: const Icon(
                      Icons.close,
                      size: 13,
                      color: Color(0xFF94a3b8),
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 22,
                      minHeight: 22,
                    ),
                  ),
              ],
            ),
          ),
          if (_sessionId != null &&
              (_sessionDiagnostics != null || _sessionCost != null))
            Builder(
              builder: (context) {
                final d = _sessionDiagnostics;
                final agent = d != null ? (d['agent'] ?? '').toString() : '';
                final tmux = d != null && d['tmuxAlive'] == true;
                final hist = d != null && d['historyLinked'] == true;
                final authHint = d != null ? d['authHint']?.toString() : null;
                final lines = <String>[
                  if (agent.isNotEmpty) agent,
                  if (d != null) ...[
                    'tmux ${tmux ? "on" : "off"}',
                    'history ${hist ? "ok" : "…"}',
                    if ((_sessionId ?? '').length > 6)
                      'id …${_sessionId!.substring(_sessionId!.length - 6)}',
                  ],
                ];
                final costLine = _sessionCostSummaryText();
                return Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: const BoxDecoration(
                    color: Color(0xFF0c1220),
                    border: Border(
                      bottom: BorderSide(color: Color(0xFF1a2234)),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (lines.isNotEmpty)
                        Text(
                          lines.join(' · '),
                          style: const TextStyle(
                            fontSize: 9,
                            color: Color(0xFF64748b),
                            fontFamily: 'monospace',
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      if (costLine != null) ...[
                        if (lines.isNotEmpty) const SizedBox(height: 4),
                        Text(
                          costLine,
                          style: const TextStyle(
                            fontSize: 9,
                            color: Color(0xFF94a3b8),
                            fontFamily: 'monospace',
                            height: 1.3,
                          ),
                        ),
                      ],
                      if (authHint != null && authHint.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          authHint,
                          style: const TextStyle(
                            fontSize: 9,
                            color: Color(0xFFf59e0b),
                            height: 1.35,
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),

          // Project context line
          if (widget.projectPath != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              color: const Color(0xFF0f172a),
              child: Row(
                children: [
                  const Icon(
                    Icons.folder_outlined,
                    size: 10,
                    color: Color(0xFF64748b),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      widget.projectPath!,
                      style: const TextStyle(
                        fontSize: 9,
                        color: Color(0xFF64748b),
                        fontFamily: 'monospace',
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),

          // Messages
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : widget.projectPath == null
                ? _buildEmptyState('Open a project to start chatting')
                : _messages.isEmpty
                ? _buildEmptyState('Say something to start a new chat session')
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(10),
                    itemCount: _messages.length,
                    itemBuilder: (_, i) => _buildMessage(_messages[i]),
                  ),
          ),

          // Attachments preview
          if (_attachments.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: const BoxDecoration(
                color: Color(0xFF0f172a),
                border: Border(top: BorderSide(color: Color(0xFF1a2234))),
              ),
              child: SizedBox(
                height: 52,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: _attachments.length,
                  itemBuilder: (_, i) => _buildAttachment(_attachments[i]),
                ),
              ),
            ),

          // Input
          Container(
            padding: const EdgeInsets.all(8),
            decoration: const BoxDecoration(
              color: Color(0xFF0f172a),
              border: Border(top: BorderSide(color: Color(0xFF1a2234))),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Slash commands popup
                if (_slashMenuOpen && _filteredSkills.isNotEmpty)
                  Container(
                    constraints: const BoxConstraints(maxHeight: 220),
                    margin: const EdgeInsets.only(bottom: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1e293b),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFF334155)),
                      boxShadow: const [
                        BoxShadow(color: Color(0x66000000), blurRadius: 12),
                      ],
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: _filteredSkills.length,
                      itemBuilder: (_, i) {
                        final s = _filteredSkills[i];
                        final name = s['name'] as String;
                        final desc = s['description'] as String? ?? '';
                        final selected = i == _slashSelectedIndex;
                        return InkWell(
                          onTap: () => _insertSkill(name),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            color: selected
                                ? const Color(0xFF8b5cf6).withAlpha(30)
                                : null,
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.auto_awesome,
                                  size: 11,
                                  color: Color(0xFF8b5cf6),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '/$name',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontFamily: 'monospace',
                                    color: selected
                                        ? const Color(0xFFe2e8f0)
                                        : const Color(0xFFcbd5e1),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (desc.isNotEmpty) ...[
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      desc,
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: Color(0xFF64748b),
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                TextField(
                  controller: _inputController,
                  focusNode: _inputFocusNode,
                  minLines: 1,
                  maxLines: 6,
                  enabled: !_sending,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFFe2e8f0),
                  ),
                  decoration: InputDecoration(
                    hintText: _sessionId == null
                        ? 'Start new chat... (use / for commands)'
                        : (appState.agentScope == 'Kimi'
                              ? 'Message Kimi...'
                              : 'Message Claude...'),
                    hintStyle: const TextStyle(
                      color: Color(0xFF64748b),
                      fontSize: 12,
                    ),
                    filled: true,
                    fillColor: const Color(0xFF151e2e),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: const BorderSide(color: Color(0xFF1e2a3d)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: const BorderSide(color: Color(0xFF1e2a3d)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: const BorderSide(color: Color(0xFF8b5cf6)),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    isDense: true,
                  ),
                  onSubmitted: (_) => _send(),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    _buildPlusMenu(),
                    const SizedBox(width: 6),
                    _buildModelPicker(appState),
                    const Spacer(),
                    if (_allSkills != null)
                      Text(
                        '${_allSkills!.length} skills',
                        style: const TextStyle(
                          fontSize: 9,
                          color: Color(0xFF475569),
                        ),
                      ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: _sending ? null : _send,
                      icon: _sending
                          ? const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.send, size: 13),
                      label: const Text('Send', style: TextStyle(fontSize: 11)),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF8b5cf6),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        minimumSize: const Size(0, 28),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlusMenu() {
    return PopupMenuButton<String>(
      tooltip: 'Add attachment or context',
      padding: EdgeInsets.zero,
      icon: const Icon(Icons.add, size: 17, color: Color(0xFF94a3b8)),
      color: const Color(0xFF1e293b),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: const BorderSide(color: Color(0xFF334155)),
      ),
      onSelected: (value) async {
        switch (value) {
          case 'image':
            _pickImages();
            break;
          case 'context':
            _addContextFile();
            break;
          case 'browse':
            _browseUrl();
            break;
          case 'slash':
            _inputController.text =
                (_inputController.text +
                (_inputController.text.isEmpty ? '/' : ' /'));
            _inputController.selection = TextSelection.collapsed(
              offset: _inputController.text.length,
            );
            _inputFocusNode.requestFocus();
            break;
        }
      },
      itemBuilder: (ctx) => [
        _menuItem(
          'image',
          Icons.upload_file,
          'Upload image',
          'Attach screenshot or picture',
        ),
        _menuItem(
          'context',
          Icons.description_outlined,
          'Add file as context',
          'Paste file path into prompt',
        ),
        _menuItem(
          'browse',
          Icons.language,
          'Browse the web',
          'Open URL on remote server',
        ),
        const PopupMenuDivider(),
        _menuItem(
          'slash',
          Icons.auto_awesome,
          'Slash commands',
          'Browse all skills',
        ),
      ],
    );
  }

  PopupMenuItem<String> _menuItem(
    String value,
    IconData icon,
    String title,
    String subtitle,
  ) {
    return PopupMenuItem<String>(
      value: value,
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Icon(icon, size: 14, color: const Color(0xFF8b5cf6)),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFFe2e8f0),
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                subtitle,
                style: const TextStyle(fontSize: 10, color: Color(0xFF64748b)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _addContextFile() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null || widget.projectPath == null) return;
    final paths = result.files
        .map((f) => f.path)
        .where((p) => p != null)
        .join('\n');
    if (paths.isNotEmpty) {
      _inputController.text = '$paths\n\n${_inputController.text}';
      _inputFocusNode.requestFocus();
    }
  }

  static Process? _socksProxy;
  static bool _proxyRunning = false;
  static const _socksPort = 1080;

  Future<void> _ensureSocksProxy() async {
    // Reuse existing tunnel if still alive; reset if child exited.
    if (_proxyRunning && _socksProxy != null) return;

    final messenger = ScaffoldMessenger.of(context);
    final baseUrl = context.read<AppState>().api.baseUrl;
    final host = Uri.tryParse(baseUrl)?.host;
    if (host == null || host.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('SOCKS proxy: server host not configured'),
          backgroundColor: Color(0xFFef4444),
        ),
      );
      return;
    }

    // Start SSH SOCKS5 proxy: ssh -D 1080 -N -o ... claude@host
    try {
      _socksProxy = await Process.start('ssh', [
        '-D',
        '$_socksPort',
        '-N',
        '-o',
        'StrictHostKeyChecking=no',
        '-o',
        'ServerAliveInterval=30',
        '-o',
        'ExitOnForwardFailure=yes',
        'claude@$host',
      ]);
      _proxyRunning = true;

      // Clear static refs when the tunnel dies so the next call spawns a fresh one.
      _socksProxy!.exitCode.then((_) {
        _proxyRunning = false;
        _socksProxy = null;
      });

      // Wait a moment for tunnel to establish
      await Future.delayed(const Duration(seconds: 1));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('SOCKS proxy failed: $e'),
          backgroundColor: const Color(0xFFef4444),
        ),
      );
    }
  }

  Future<void> _browseUrl() async {
    final controller = TextEditingController(text: 'https://google.com');
    if (!mounted) return;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1e293b),
        title: const Row(
          children: [
            Icon(Icons.language, size: 18, color: Color(0xFF8b5cf6)),
            SizedBox(width: 8),
            Text('Remote Browser', style: TextStyle(fontSize: 15)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Opens Chrome via SSH SOCKS proxy through the remote server. All traffic routes through VPS.\n\n'
              '• Any URL — browsed from the server\'s IP\n'
              '• localhost:PORT — reaches server\'s local services',
              style: TextStyle(
                fontSize: 11,
                color: Color(0xFF94a3b8),
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              decoration: InputDecoration(
                hintText: 'https://google.com',
                hintStyle: const TextStyle(
                  color: Color(0xFF64748b),
                  fontSize: 12,
                ),
                filled: true,
                fillColor: const Color(0xFF0f172a),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(color: Color(0xFF334155)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(color: Color(0xFF334155)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(color: Color(0xFF8b5cf6)),
                ),
              ),
              onSubmitted: (v) => Navigator.pop(ctx, v),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF0f172a),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Icon(
                    _proxyRunning
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 12,
                    color: _proxyRunning
                        ? const Color(0xFF22c55e)
                        : const Color(0xFF64748b),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _proxyRunning
                        ? 'SOCKS proxy active on :$_socksPort'
                        : 'SOCKS proxy will start automatically',
                    style: TextStyle(
                      fontSize: 10,
                      color: _proxyRunning
                          ? const Color(0xFF22c55e)
                          : const Color(0xFF64748b),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF8b5cf6),
            ),
            child: const Text('Open in Chrome'),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty || !mounted) return;

    // Start SOCKS proxy if not running
    await _ensureSocksProxy();

    // Open Chrome with proxy
    try {
      await Process.run('open', [
        '-na',
        'Google Chrome',
        '--args',
        '--proxy-server=socks5://127.0.0.1:$_socksPort',
        '--user-data-dir=/tmp/planulix-chrome-proxy',
        result,
      ]);
    } catch (e) {
      // Fallback: try opening without Chrome-specific args
      if (mounted) {
        try {
          await Process.run('open', [result]);
        } catch (_) {}
      }
    }
  }

  Widget _buildEmptyState(String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFF8b5cf6).withAlpha(20),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.smart_toy,
                size: 22,
                color: Color(0xFF8b5cf6),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: Color(0xFF64748b)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageBodySelectable(String text) {
    const baseStyle = TextStyle(
      fontSize: 11,
      color: Color(0xFFcbd5e1),
      height: 1.4,
    );
    final onOpen = widget.onPathOpen;
    if (text.isEmpty) {
      return const SelectableText('...', style: baseStyle);
    }
    if (onOpen == null) {
      return SelectableText(text, style: baseStyle);
    }
    final matches = _chatPathRegex.allMatches(text).toList();
    if (matches.isEmpty) {
      return SelectableText(text, style: baseStyle);
    }

    final children = <Widget>[];
    var lastEnd = 0;
    for (final m in matches) {
      if (m.start > lastEnd) {
        final chunk = text.substring(lastEnd, m.start);
        if (chunk.isNotEmpty) {
          children.add(SelectableText(chunk, style: baseStyle));
        }
      }
      final path = m.group(0)!;
      children.add(
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: TextButton.icon(
              onPressed: () => onOpen(path),
              icon: const Icon(
                Icons.insert_drive_file_outlined,
                size: 14,
                color: Color(0xFF60a5fa),
              ),
              label: Text(
                path,
                overflow: TextOverflow.ellipsis,
                maxLines: 3,
                style: const TextStyle(
                  fontSize: 10,
                  fontFamily: 'monospace',
                  color: Color(0xFF60a5fa),
                  decoration: TextDecoration.underline,
                  height: 1.3,
                ),
              ),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF60a5fa),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                alignment: Alignment.centerLeft,
              ),
            ),
          ),
        ),
      );
      lastEnd = m.end;
    }
    if (lastEnd < text.length) {
      final chunk = text.substring(lastEnd);
      if (chunk.isNotEmpty) {
        children.add(SelectableText(chunk, style: baseStyle));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _buildMessage(dynamic msg) {
    final type = (msg['type'] ?? msg['role'] ?? '').toString();
    final isUser = type == 'user';
    final pending = msg['pending'] == true;
    final content = msg['content'];

    String text = '';
    if (content is String) {
      text = content;
    } else if (content is List) {
      for (final block in content) {
        if (block is Map && block['type'] == 'text') {
          text += (block['text'] ?? '').toString();
        }
      }
    }
    if (Provider.of<AppState>(context, listen: false).agentScope == 'Kimi') {
      text = _kimiNormalizeLiteralEscapes(text);
    }

    final agentLabel =
        Provider.of<AppState>(context, listen: false).agentScope == 'Kimi'
        ? 'Kimi'
        : 'Claude';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isUser ? Icons.person_outline : Icons.smart_toy,
                size: 11,
                color: isUser
                    ? const Color(0xFF3b82f6)
                    : const Color(0xFF8b5cf6),
              ),
              const SizedBox(width: 4),
              Text(
                isUser ? 'You' : agentLabel,
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  color: isUser
                      ? const Color(0xFF3b82f6)
                      : const Color(0xFF8b5cf6),
                  letterSpacing: 0.3,
                ),
              ),
              if (pending) ...[
                const SizedBox(width: 6),
                const SizedBox(
                  width: 8,
                  height: 8,
                  child: CircularProgressIndicator(strokeWidth: 1),
                ),
              ],
            ],
          ),
          const SizedBox(height: 3),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: isUser ? const Color(0xFF151e2e) : const Color(0xFF1e293b),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFF1e2a3d)),
            ),
            child: _buildMessageBodySelectable(text.isEmpty ? '...' : text),
          ),
        ],
      ),
    );
  }

  Widget _buildAttachment(_PendingAttachment att) {
    return Container(
      width: 52,
      margin: const EdgeInsets.only(right: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF151e2e),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: const Color(0xFF1e2a3d)),
      ),
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: Image.memory(
              att.bytes,
              fit: BoxFit.cover,
              width: 52,
              height: 52,
              cacheWidth: 104, // 2x for DPR; avoids full-size decode in preview
              gaplessPlayback: true,
              errorBuilder: (context, error, stackTrace) =>
                  const Icon(Icons.image, size: 20, color: Color(0xFF64748b)),
            ),
          ),
          if (att.uploading)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x88000000),
                child: Center(
                  child: SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
                ),
              ),
            ),
          Positioned(
            top: 0,
            right: 0,
            child: InkWell(
              onTap: () => setState(() => _attachments.remove(att)),
              child: Container(
                padding: const EdgeInsets.all(1),
                decoration: BoxDecoration(
                  color: const Color(0xFFef4444),
                  borderRadius: BorderRadius.circular(2),
                ),
                child: const Icon(Icons.close, size: 9, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
