import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../providers/app_state.dart';
import '../../utils/capabilities_helpers.dart';
import '../../utils/session_filter.dart';
import '../session/session_screen.dart';
import '../cost/cost_screen.dart';
import '../settings/settings_screen.dart';
import '../../widgets/activity_heatmap.dart';
import '../../widgets/disk_info_widget.dart';
import '../explorer/file_tree.dart';
import '../explorer/file_viewer.dart';
import '../explorer/diff_viewer.dart';
import '../explorer/project_picker.dart';
import '../explorer/command_palette.dart';
import '../explorer/terminal_panel.dart';
import '../chat/claude_chat_panel.dart';
import '../../widgets/resizable_divider.dart';
import '../onboarding/agent_welcome_screen.dart';
import '../onboarding/connection_welcome_screen.dart';

class DesktopShell extends StatefulWidget {
  const DesktopShell({super.key});
  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

// Types of tabs in the main area
enum TabType { session, file, diff, terminal }

class OpenTab {
  final String id;
  final TabType type;
  final String label;
  final String? cwd; // for file/diff
  const OpenTab({
    required this.id,
    required this.type,
    required this.label,
    this.cwd,
  });
}

class _DesktopShellState extends State<DesktopShell> {
  String? _activeTabId;
  final List<OpenTab> _openTabs = [];
  String _searchQuery = '';
  int _activityBarIndex = 0; // 0=explorer, 1=sessions, 2=costs, 3=settings
  bool _heatmapCollapsed = true;
  String? _projectPath;
  bool _chatPanelOpen = true;

  // Resizable panel widths
  double _sidebarWidth = 280;
  double _chatWidth = 380;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrapDesktop());
  }

  Future<void> _bootstrapDesktop() async {
    if (!mounted) return;
    final state = context.read<AppState>();
    await state.refreshSessions();
    if (!mounted || !state.isConfigured) return;
    if (!state.welcomeOnboardingDone) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => const ConnectionWelcomeScreen(),
        ),
      );
      if (!mounted) return;
    }
    _maybeDesktopAgentWelcome();
  }

  void _maybeDesktopAgentWelcome() {
    if (!mounted) return;
    final state = context.read<AppState>();
    if (!state.isConfigured || state.agentOnboardingDone) return;
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => const AgentWelcomeScreen(),
      ),
    );
  }

  void _openSession(String id, String label) {
    final tabId = 'session:$id';
    setState(() {
      _activeTabId = tabId;
      if (!_openTabs.any((t) => t.id == tabId)) {
        _openTabs.add(OpenTab(id: tabId, type: TabType.session, label: label));
      }
    });
  }

  void _openFile(String path, String cwd) {
    final tabId = 'file:$path';
    final name = path.split('/').last;
    setState(() {
      _activeTabId = tabId;
      if (!_openTabs.any((t) => t.id == tabId)) {
        _openTabs.add(
          OpenTab(id: tabId, type: TabType.file, label: name, cwd: cwd),
        );
      }
    });
  }

  void _openDiff(String cwd, String file) {
    final tabId = 'diff:$cwd:$file';
    final name = file.split('/').last;
    setState(() {
      _activeTabId = tabId;
      if (!_openTabs.any((t) => t.id == tabId)) {
        _openTabs.add(
          OpenTab(id: tabId, type: TabType.diff, label: 'Δ $name', cwd: cwd),
        );
      }
    });
  }

  void _openTerminal([String? cwd]) {
    final terminalCwd = cwd ?? _projectPath ?? '/home/claude';
    final tabId = 'terminal:${DateTime.now().millisecondsSinceEpoch}';
    final name =
        terminalCwd.split('/').where((s) => s.isNotEmpty).lastOrNull ?? 'shell';
    setState(() {
      _activeTabId = tabId;
      _openTabs.add(
        OpenTab(
          id: tabId,
          type: TabType.terminal,
          label: '\$ $name',
          cwd: terminalCwd,
        ),
      );
    });
  }

  void _openCommandPalette(PaletteMode mode) {
    final commands = mode == PaletteMode.commands
        ? _buildCommands()
        : <PaletteAction>[];
    showDialog(
      context: context,
      barrierColor: const Color(0x88000000),
      builder: (_) => CommandPalette(
        mode: mode,
        projectPath: _projectPath,
        commands: commands,
        onFilePicked: (path) => _openFile(path, _projectPath ?? ''),
        onGrepResultPicked: (file, line) {
          // TODO: jump to line in file viewer (future)
          _openFile(file, _projectPath ?? '');
        },
      ),
    );
  }

  List<PaletteAction> _buildCommands() {
    return [
      PaletteAction(
        label: 'Open Project...',
        hint: 'Pick or upload a project',
        icon: Icons.folder_open,
        onInvoke: _pickProject,
      ),
      PaletteAction(
        label: 'New Terminal',
        hint: 'Open shell in project directory',
        icon: Icons.terminal,
        shortcut: '⌃`',
        onInvoke: () => _openTerminal(),
      ),
      PaletteAction(
        label: 'Find in Files',
        hint: 'Global grep',
        icon: Icons.travel_explore,
        shortcut: '⌘⇧F',
        onInvoke: () => _openCommandPalette(PaletteMode.findInFiles),
      ),
      PaletteAction(
        label: 'Go to File...',
        hint: 'Fuzzy file picker',
        icon: Icons.search,
        shortcut: '⌘P',
        onInvoke: () => _openCommandPalette(PaletteMode.files),
      ),
      PaletteAction(
        label: 'New Session',
        hint: 'Start Claude Code task or chat',
        icon: Icons.add_circle_outline,
        onInvoke: () => _showCreateDialog(context.read<AppState>()),
      ),
      PaletteAction(
        label: 'Refresh Sessions',
        icon: Icons.refresh,
        shortcut: '⌘R',
        onInvoke: () =>
            context.read<AppState>().refreshSessions(refetchCosts: true),
      ),
    ];
  }

  void _closeTab(String id) {
    setState(() {
      final idx = _openTabs.indexWhere((t) => t.id == id);
      if (idx < 0) return;
      _openTabs.removeAt(idx);
      if (_activeTabId == id) {
        _activeTabId = _openTabs.isNotEmpty ? _openTabs.last.id : null;
      }
    });
  }

  Future<void> _confirmRemoveSession(
    BuildContext context,
    AppState state,
    String sessionId,
    String label,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1e293b),
        title: const Text(
          'Remove session?',
          style: TextStyle(color: Color(0xFFe2e8f0), fontSize: 16),
        ),
        content: Text(
          '«$label» will be removed from the list. Server-side history files are kept.',
          style: const TextStyle(color: Color(0xFF94a3b8), fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Color(0xFF94a3b8)),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Remove',
              style: TextStyle(color: Color(0xFFef4444)),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await state.stopSession(sessionId);
    _closeTab('session:$sessionId');
    if (mounted) setState(() {});
  }

  Future<void> _pickProject() async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => const ProjectPicker(),
    );
    if (result != null && mounted) {
      setState(() {
        _projectPath = result;
        _activityBarIndex = 0;
      });
    }
  }

  List<dynamic> _filtered(AppState state) {
    Iterable<dynamic> it = state.sessions;
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      it = it.where((s) {
        final cwd = (s['cwd'] ?? '').toString().toLowerCase();
        final title = (s['title'] ?? '').toString().toLowerCase();
        final id = (s['sessionId'] ?? '').toString().toLowerCase();
        return cwd.contains(q) || title.contains(q) || id.contains(q);
      });
    }
    return applySessionQuery(it, state.agentScope, state.listScope);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyP):
            const _OpenFilePickerIntent(),
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyP):
            const _OpenFilePickerIntent(),
        LogicalKeySet(
          LogicalKeyboardKey.meta,
          LogicalKeyboardKey.shift,
          LogicalKeyboardKey.keyP,
        ): const _OpenCommandPaletteIntent(),
        LogicalKeySet(
          LogicalKeyboardKey.control,
          LogicalKeyboardKey.shift,
          LogicalKeyboardKey.keyP,
        ): const _OpenCommandPaletteIntent(),
        LogicalKeySet(
          LogicalKeyboardKey.meta,
          LogicalKeyboardKey.shift,
          LogicalKeyboardKey.keyF,
        ): const _FindInFilesIntent(),
        LogicalKeySet(
          LogicalKeyboardKey.control,
          LogicalKeyboardKey.shift,
          LogicalKeyboardKey.keyF,
        ): const _FindInFilesIntent(),
        LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.backquote):
            const _OpenTerminalIntent(),
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.backquote):
            const _OpenTerminalIntent(),
        LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyL):
            const _ToggleChatIntent(),
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyL):
            const _ToggleChatIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _OpenFilePickerIntent: CallbackAction<_OpenFilePickerIntent>(
            onInvoke: (_) {
              _openCommandPalette(PaletteMode.files);
              return null;
            },
          ),
          _OpenCommandPaletteIntent: CallbackAction<_OpenCommandPaletteIntent>(
            onInvoke: (_) {
              _openCommandPalette(PaletteMode.commands);
              return null;
            },
          ),
          _FindInFilesIntent: CallbackAction<_FindInFilesIntent>(
            onInvoke: (_) {
              _openCommandPalette(PaletteMode.findInFiles);
              return null;
            },
          ),
          _OpenTerminalIntent: CallbackAction<_OpenTerminalIntent>(
            onInvoke: (_) {
              _openTerminal();
              return null;
            },
          ),
          _ToggleChatIntent: CallbackAction<_ToggleChatIntent>(
            onInvoke: (_) {
              setState(() => _chatPanelOpen = !_chatPanelOpen);
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: const Color(0xFF0a0f1a),
            body: Column(
              children: [
                // Title bar (empty area at top for window controls on macOS)
                Container(
                  height: 38,
                  decoration: const BoxDecoration(
                    color: Color(0xFF0a0f1a),
                    border: Border(
                      bottom: BorderSide(color: Color(0xFF1a2234), width: 1),
                    ),
                  ),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 80,
                      ), // Reserve space for traffic lights
                      const Icon(
                        Icons.terminal,
                        size: 14,
                        color: Color(0xFF8b5cf6),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'Planulix',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFFcbd5e1),
                        ),
                      ),
                      const SizedBox(width: 24),
                      _quickButton(
                        '⌘P',
                        'Go to File',
                        () => _openCommandPalette(PaletteMode.files),
                      ),
                      _quickButton(
                        '⌘⇧F',
                        'Find in Files',
                        () => _openCommandPalette(PaletteMode.findInFiles),
                      ),
                      _quickButton(
                        '⌘⇧P',
                        'Commands',
                        () => _openCommandPalette(PaletteMode.commands),
                      ),
                      const Spacer(),
                      _titleBarButton(
                        Icons.terminal,
                        'New Terminal (⌃`)',
                        () => _openTerminal(),
                      ),
                      _titleBarButton(
                        _chatPanelOpen ? Icons.chat : Icons.chat_bubble_outline,
                        'Toggle Claude Chat (⌘L)',
                        () => setState(() => _chatPanelOpen = !_chatPanelOpen),
                      ),
                      _titleBarButton(
                        Icons.add,
                        'New Session',
                        () => _showCreateDialog(state),
                      ),
                      _titleBarButton(
                        Icons.refresh,
                        'Refresh',
                        () => state.refreshSessions(refetchCosts: true),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ),
                ),

                // Main body: activity bar | sidebar | content | chat
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      // Clamp widths to reasonable bounds
                      final maxSidebar = constraints.maxWidth * 0.4;
                      final maxChat = constraints.maxWidth * 0.5;
                      _sidebarWidth = _sidebarWidth.clamp(180.0, maxSidebar);
                      _chatWidth = _chatWidth.clamp(280.0, maxChat);

                      return Row(
                        children: [
                          _buildActivityBar(),
                          SizedBox(
                            width: _sidebarWidth,
                            child: _buildSidebar(state),
                          ),
                          ResizableDivider(
                            onDrag: (dx) => setState(() {
                              _sidebarWidth = (_sidebarWidth + dx).clamp(
                                180.0,
                                maxSidebar,
                              );
                            }),
                          ),
                          Expanded(child: _buildMainContent(state)),
                          if (_chatPanelOpen) ...[
                            ResizableDivider(
                              onDrag: (dx) => setState(() {
                                _chatWidth = (_chatWidth - dx).clamp(
                                  280.0,
                                  maxChat,
                                );
                              }),
                            ),
                            SizedBox(
                              width: _chatWidth,
                              child: ClaudeChatPanel(
                                projectPath: _projectPath,
                                onClose: () =>
                                    setState(() => _chatPanelOpen = false),
                                onPathOpen: (path) =>
                                    _openFile(path, _projectPath ?? ''),
                              ),
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                ),

                // Status bar
                _buildStatusBar(state),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _quickButton(String label, String tooltip, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          margin: const EdgeInsets.only(right: 4),
          decoration: BoxDecoration(
            color: const Color(0xFF151e2e),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: const Color(0xFF1e2a3d)),
          ),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 10,
              color: Color(0xFF94a3b8),
              fontFamily: 'monospace',
            ),
          ),
        ),
      ),
    );
  }

  Widget _titleBarButton(IconData icon, String tooltip, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: 32,
          height: 38,
          alignment: Alignment.center,
          child: Icon(icon, size: 15, color: const Color(0xFF94a3b8)),
        ),
      ),
    );
  }

  Widget _buildActivityBar() {
    return Container(
      width: 48,
      decoration: const BoxDecoration(
        color: Color(0xFF0a0f1a),
        border: Border(right: BorderSide(color: Color(0xFF1a2234), width: 1)),
      ),
      child: Column(
        children: [
          _activityButton(Icons.folder_outlined, Icons.folder, 0, 'Explorer'),
          _activityButton(
            Icons.terminal_outlined,
            Icons.terminal,
            1,
            'Sessions',
          ),
          _activityButton(
            Icons.analytics_outlined,
            Icons.analytics,
            2,
            'Costs',
          ),
          const Spacer(),
          _activityButton(
            Icons.settings_outlined,
            Icons.settings,
            3,
            'Settings',
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _activityButton(
    IconData icon,
    IconData activeIcon,
    int index,
    String tooltip,
  ) {
    final selected = _activityBarIndex == index;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: () => setState(() => _activityBarIndex = index),
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: selected ? const Color(0xFF8b5cf6) : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Icon(
            selected ? activeIcon : icon,
            size: 20,
            color: selected ? const Color(0xFFe2e8f0) : const Color(0xFF64748b),
          ),
        ),
      ),
    );
  }

  Widget _buildSidebar(AppState state) {
    if (_activityBarIndex == 0) {
      return FileTreePanel(
        projectPath: _projectPath,
        onFileOpen: _openFile,
        onDiffOpen: _openDiff,
        onChangeProject: _pickProject,
      );
    }
    if (_activityBarIndex == 2) {
      return const CostScreen();
    }
    if (_activityBarIndex == 3) {
      return const SettingsScreen();
    }

    final sessions = _filtered(state);
    final active = state.sessions.where((s) => s['isActive'] == true).length;

    return Container(
      decoration: const BoxDecoration(color: Color(0xFF0d1420)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Sidebar header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                const Text(
                  'SESSIONS',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF94a3b8),
                    letterSpacing: 0.5,
                  ),
                ),
                const Spacer(),
                Text(
                  '$active/${state.sessions.length}',
                  style: const TextStyle(
                    fontSize: 10,
                    color: Color(0xFF64748b),
                  ),
                ),
              ],
            ),
          ),

          // Search
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Container(
              height: 28,
              decoration: BoxDecoration(
                color: const Color(0xFF151e2e),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: const Color(0xFF1e2a3d)),
              ),
              child: TextField(
                onChanged: (v) => setState(() => _searchQuery = v),
                style: const TextStyle(fontSize: 12, color: Color(0xFFe2e8f0)),
                decoration: const InputDecoration(
                  hintText: 'Search sessions...',
                  hintStyle: TextStyle(color: Color(0xFF64748b), fontSize: 12),
                  prefixIcon: Icon(
                    Icons.search,
                    size: 14,
                    color: Color(0xFF64748b),
                  ),
                  prefixIconConstraints: BoxConstraints(
                    minWidth: 28,
                    minHeight: 28,
                  ),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  isDense: true,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),

          // Agent + list scope chips
          const Padding(
            padding: EdgeInsets.only(left: 12, right: 12, bottom: 2),
            child: Text(
              'Agent',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                color: Color(0xFF64748b),
                letterSpacing: 0.4,
              ),
            ),
          ),
          SizedBox(
            height: 24,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: kAgentScopeOptions.map((f) {
                final selected = state.agentScope == f;
                return Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: InkWell(
                    onTap: () async {
                      await state.setAgentScope(f);
                      if (mounted) setState(() {});
                    },
                    borderRadius: BorderRadius.circular(3),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: selected
                            ? const Color(0xFF8b5cf6).withAlpha(40)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(
                          color: selected
                              ? const Color(0xFF8b5cf6)
                              : const Color(0xFF1e2a3d),
                        ),
                      ),
                      child: Text(
                        f,
                        style: TextStyle(
                          fontSize: 10,
                          color: selected
                              ? const Color(0xFFc4b5fd)
                              : const Color(0xFF94a3b8),
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(left: 12, right: 12, top: 6, bottom: 2),
            child: Text(
              'List',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                color: Color(0xFF64748b),
                letterSpacing: 0.4,
              ),
            ),
          ),
          SizedBox(
            height: 24,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: kListScopeOptions.map((f) {
                final selected = state.listScope == f;
                return Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: InkWell(
                    onTap: () async {
                      await state.setListScope(f);
                      if (mounted) setState(() {});
                    },
                    borderRadius: BorderRadius.circular(3),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: selected
                            ? const Color(0xFF8b5cf6).withAlpha(40)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(
                          color: selected
                              ? const Color(0xFF8b5cf6)
                              : const Color(0xFF1e2a3d),
                        ),
                      ),
                      child: Text(
                        f,
                        style: TextStyle(
                          fontSize: 10,
                          color: selected
                              ? const Color(0xFFc4b5fd)
                              : const Color(0xFF94a3b8),
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 8),
          Container(height: 1, color: const Color(0xFF1a2234)),

          // Heatmap (collapsible)
          InkWell(
            onTap: () => setState(() => _heatmapCollapsed = !_heatmapCollapsed),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Row(
                children: [
                  Icon(
                    _heatmapCollapsed ? Icons.chevron_right : Icons.expand_more,
                    size: 14,
                    color: const Color(0xFF94a3b8),
                  ),
                  const SizedBox(width: 4),
                  const Text(
                    'ACTIVITY',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF94a3b8),
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (!_heatmapCollapsed)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: ActivityHeatmap(),
            ),
          Container(height: 1, color: const Color(0xFF1a2234)),

          // Sessions tree
          Expanded(
            child: sessions.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        state.isLoading ? 'Loading...' : 'No sessions',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF64748b),
                        ),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: sessions.length,
                    itemBuilder: (_, i) =>
                        _sidebarSessionItem(sessions[i], state),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _sidebarSessionItem(dynamic session, AppState state) {
    final id = (session['sessionId'] ?? '').toString();
    final cwd = (session['cwd'] ?? '').toString();
    final title = (session['title'] ?? '').toString();
    final isActive = session['isActive'] == true;
    final kind = (session['kind'] ?? '').toString();
    final extra = session['extra'] as Map<String, dynamic>?;
    final isStarred = extra != null && extra['starred'] == true;
    final isSelected = _activeTabId == 'session:$id';

    final parts = cwd.split('/').where((s) => s.isNotEmpty).toList();
    final shortCwd = parts.isNotEmpty ? parts.last : cwd;
    final displayTitle = title.isNotEmpty ? title : shortCwd;
    final cost = state.sessionCostUsd[id];
    final statusColor = isActive
        ? const Color(0xFF22c55e)
        : const Color(0xFF475569);

    return Container(
      color: isSelected ? const Color(0xFF1e293b) : null,
      padding: const EdgeInsets.only(left: 4, right: 2, top: 1, bottom: 1),
      child: Row(
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () async {
                await state.api.setStar(id, !isStarred);
                await state.refreshSessions();
                if (mounted) setState(() {});
              },
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                width: 30,
                height: 36,
                child: Icon(
                  isStarred ? Icons.star : Icons.star_border,
                  size: 16,
                  color: isStarred
                      ? const Color(0xFFf59e0b)
                      : const Color(0xFF475569),
                ),
              ),
            ),
          ),
          Container(
            width: 7,
            height: 7,
            margin: const EdgeInsets.only(right: 2),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: statusColor,
            ),
          ),
          Expanded(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => _openSession(id, displayTitle),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          displayTitle,
                          style: TextStyle(
                            fontSize: 12,
                            color: isSelected
                                ? const Color(0xFFe2e8f0)
                                : const Color(0xFFcbd5e1),
                            fontWeight: isSelected
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (cost != null) ...[
                        Text(
                          '~\$${cost.toStringAsFixed(2)}',
                          style: const TextStyle(
                            fontSize: 9,
                            color: Color(0xFF64748b),
                          ),
                        ),
                        const SizedBox(width: 4),
                      ],
                      if (kind.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 1,
                          ),
                          margin: const EdgeInsets.only(left: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1e2a3d),
                            borderRadius: BorderRadius.circular(2),
                          ),
                          child: Text(
                            kind.substring(
                              0,
                              kind.length > 6 ? 6 : kind.length,
                            ),
                            style: const TextStyle(
                              fontSize: 8,
                              color: Color(0xFF94a3b8),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () =>
                  _confirmRemoveSession(context, state, id, displayTitle),
              borderRadius: BorderRadius.circular(4),
              child: const SizedBox(
                width: 30,
                height: 36,
                child: Icon(
                  Icons.delete_outline,
                  size: 15,
                  color: Color(0xFF64748b),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMainContent(AppState state) {
    return Container(
      color: const Color(0xFF0f172a),
      child: Column(
        children: [
          // Tab bar
          if (_openTabs.isNotEmpty)
            Container(
              height: 34,
              decoration: const BoxDecoration(
                color: Color(0xFF0a0f1a),
                border: Border(bottom: BorderSide(color: Color(0xFF1a2234))),
              ),
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: _openTabs.map((tab) => _buildTab(tab)).toList(),
              ),
            ),

          // Content
          Expanded(child: _buildActiveTabContent()),
        ],
      ),
    );
  }

  Widget _buildActiveTabContent() {
    if (_activeTabId == null) return _buildWelcome();
    final tab = _openTabs.firstWhere(
      (t) => t.id == _activeTabId,
      orElse: () => const OpenTab(id: '', type: TabType.session, label: ''),
    );
    if (tab.id.isEmpty) return _buildWelcome();

    switch (tab.type) {
      case TabType.session:
        final sessionId = tab.id.substring('session:'.length);
        return SessionScreen(
          key: ValueKey(tab.id),
          sessionId: sessionId,
          embedded: true,
        );
      case TabType.file:
        final path = tab.id.substring('file:'.length);
        return FileViewer(key: ValueKey(tab.id), path: path);
      case TabType.diff:
        final rest = tab.id.substring('diff:'.length);
        final sepIdx = rest.indexOf(':');
        final cwd = rest.substring(0, sepIdx);
        final file = rest.substring(sepIdx + 1);
        return DiffViewer(key: ValueKey(tab.id), cwd: cwd, file: file);
      case TabType.terminal:
        return TerminalPanel(
          key: ValueKey(tab.id),
          cwd: tab.cwd ?? '/home/claude',
        );
    }
  }

  Widget _buildTab(OpenTab tab) {
    final isSelected = _activeTabId == tab.id;
    IconData icon;
    Color iconColor;
    switch (tab.type) {
      case TabType.session:
        icon = Icons.smart_toy_outlined;
        iconColor = const Color(0xFF8b5cf6);
        break;
      case TabType.file:
        icon = Icons.insert_drive_file_outlined;
        iconColor = const Color(0xFF94a3b8);
        break;
      case TabType.diff:
        icon = Icons.difference_outlined;
        iconColor = const Color(0xFFf59e0b);
        break;
      case TabType.terminal:
        icon = Icons.terminal;
        iconColor = const Color(0xFF22c55e);
        break;
    }

    return InkWell(
      onTap: () => setState(() => _activeTabId = tab.id),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF0f172a) : const Color(0xFF0a0f1a),
          border: Border(
            right: const BorderSide(color: Color(0xFF1a2234)),
            top: BorderSide(
              color: isSelected ? const Color(0xFF8b5cf6) : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 11, color: iconColor),
            const SizedBox(width: 6),
            Text(
              tab.label,
              style: TextStyle(
                fontSize: 12,
                color: isSelected
                    ? const Color(0xFFe2e8f0)
                    : const Color(0xFF94a3b8),
              ),
            ),
            const SizedBox(width: 8),
            InkWell(
              onTap: () => _closeTab(tab.id),
              borderRadius: BorderRadius.circular(3),
              child: Container(
                padding: const EdgeInsets.all(2),
                child: const Icon(
                  Icons.close,
                  size: 12,
                  color: Color(0xFF64748b),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWelcome() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: const Color(0xFF8b5cf6).withAlpha(20),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(
              Icons.terminal,
              size: 40,
              color: Color(0xFF8b5cf6),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Planulix',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          const Text(
            'Десктоп и мобильный клиент для сессий Kimi Code и Claude Code',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: Color(0xFF64748b)),
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1e293b),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Keyboard Shortcuts',
                  style: TextStyle(
                    fontSize: 11,
                    color: Color(0xFF94a3b8),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 8),
                _ShortcutHint('⌘N', 'New session'),
                _ShortcutHint('⌘R', 'Refresh'),
                _ShortcutHint('⌘W', 'Close tab'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBar(AppState state) {
    return Container(
      height: 22,
      decoration: const BoxDecoration(
        color: Color(0xFF8b5cf6),
        border: Border(top: BorderSide(color: Color(0xFF1a2234))),
      ),
      child: Row(
        children: [
          const SizedBox(width: 8),
          const Icon(Icons.cloud_done, size: 12, color: Colors.white),
          const SizedBox(width: 4),
          Text(
            state.api.baseUrl
                .replaceFirst('http://', '')
                .replaceFirst('/api', ''),
            style: const TextStyle(fontSize: 10, color: Colors.white),
          ),
          const SizedBox(width: 16),
          Text(
            '${state.sessions.length} sessions',
            style: const TextStyle(fontSize: 10, color: Colors.white),
          ),
          const SizedBox(width: 16),
          const DiskInfoWidget(),
          const Spacer(),
          if (_openTabs.isNotEmpty) ...[
            Text(
              '${_openTabs.length} open',
              style: const TextStyle(fontSize: 10, color: Colors.white),
            ),
            const SizedBox(width: 12),
          ],
          const Text(
            'Planulix v1.0.0',
            style: TextStyle(fontSize: 10, color: Colors.white),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  void _showCreateDialog(AppState state) {
    final nameController = TextEditingController();
    final cwdController = TextEditingController(text: '/home/claude');
    final promptController = TextEditingController();
    String selectedMode = 'task';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => Dialog(
          backgroundColor: const Color(0xFF1e293b),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          child: Container(
            width: 520,
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'New Session',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: _dialogModeCard(
                        Icons.rocket_launch,
                        'Task',
                        selectedMode == 'task',
                        () => setDialogState(() => selectedMode = 'task'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _dialogModeCard(
                        Icons.chat_bubble_outline,
                        'Chat',
                        selectedMode == 'chat',
                        () => setDialogState(() => selectedMode = 'chat'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: nameController,
                  decoration: _dialogInputDecoration('Session name (optional)'),
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: cwdController,
                  decoration: _dialogInputDecoration('Working directory'),
                  style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: promptController,
                  decoration: _dialogInputDecoration(
                    selectedMode == 'task'
                        ? 'Task description (required)'
                        : 'Initial message (optional)',
                  ),
                  style: const TextStyle(fontSize: 13),
                  maxLines: 4,
                  minLines: 3,
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () async {
                        if (selectedMode == 'task' &&
                            promptController.text.trim().isEmpty) {
                          return;
                        }
                        Navigator.pop(ctx);
                        final messenger = ScaffoldMessenger.of(context);
                        final agentId = setupAgentIdForScope(state.agentScope);
                        final modelScope = state.agentScope == 'All'
                            ? 'Claude'
                            : state.agentScope;
                        final model = state.modelsForAgent(modelScope).first.id;
                        final ok = await state.createSession(
                          cwd: cwdController.text,
                          prompt: promptController.text.isNotEmpty
                              ? promptController.text
                              : null,
                          name: nameController.text.isNotEmpty
                              ? nameController.text
                              : null,
                          mode: selectedMode,
                          model: model,
                          agent: agentId.isEmpty ? null : agentId,
                        );
                        if (!context.mounted) return;
                        if (ok) {
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text(
                                '${state.agentScope == 'All' ? 'Claude' : state.agentScope} session started on server',
                              ),
                              backgroundColor: const Color(0xFF15803d),
                            ),
                          );
                        } else {
                          final msg = state.error ?? 'Failed to create session';
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text(
                                msg.length > 280
                                    ? '${msg.substring(0, 280)}…'
                                    : msg,
                              ),
                              backgroundColor: const Color(0xFFb91c1c),
                            ),
                          );
                        }
                      },
                      style: FilledButton.styleFrom(
                        backgroundColor: selectedMode == 'task'
                            ? const Color(0xFFf59e0b)
                            : const Color(0xFF8b5cf6),
                      ),
                      child: Text(
                        selectedMode == 'task' ? 'Launch Task' : 'Start Chat',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _dialogModeCard(
    IconData icon,
    String label,
    bool selected,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF8b5cf6).withAlpha(25)
              : const Color(0xFF0f172a),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? const Color(0xFF8b5cf6) : const Color(0xFF334155),
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Icon(
              icon,
              size: 24,
              color: selected
                  ? const Color(0xFF8b5cf6)
                  : const Color(0xFF64748b),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : const Color(0xFF94a3b8),
              ),
            ),
          ],
        ),
      ),
    );
  }

  InputDecoration _dialogInputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Color(0xFF64748b), fontSize: 13),
      filled: true,
      fillColor: const Color(0xFF0f172a),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
    );
  }
}

class _ShortcutHint extends StatelessWidget {
  final String key_;
  final String label;
  const _ShortcutHint(this.key_, this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFF0f172a),
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: Text(
              key_,
              style: const TextStyle(
                fontSize: 10,
                fontFamily: 'monospace',
                color: Color(0xFFcbd5e1),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: Color(0xFF94a3b8)),
          ),
        ],
      ),
    );
  }
}

class _OpenFilePickerIntent extends Intent {
  const _OpenFilePickerIntent();
}

class _OpenCommandPaletteIntent extends Intent {
  const _OpenCommandPaletteIntent();
}

class _FindInFilesIntent extends Intent {
  const _FindInFilesIntent();
}

class _OpenTerminalIntent extends Intent {
  const _OpenTerminalIntent();
}

class _ToggleChatIntent extends Intent {
  const _ToggleChatIntent();
}
