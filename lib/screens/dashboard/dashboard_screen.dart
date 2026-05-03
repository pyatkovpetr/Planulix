import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_state.dart';
import '../../utils/agent_catalog.dart';
import '../../utils/session_filter.dart';
import '../../widgets/activity_heatmap.dart';
import '../session/session_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  String _searchQuery = '';
  String _projectFilter = 'All';
  List<dynamic>? _deepSearchResults;
  bool _deepSearching = false;

  // Memo cache for _filtered.
  List<dynamic>? _cachedFiltered;
  Object? _cachedSessionsRef;
  String? _cachedQuery;
  String? _cachedScopeKey;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final s = context.read<AppState>();
      if (s.connectionMode == 'saas') {
        s.refreshSaasWorkspaces();
      } else {
        s.refreshSessions();
      }
    });
  }

  List<dynamic> _filtered(AppState state) {
    final scopeKey = '${state.agentScope}|${state.listScope}|$_projectFilter';
    if (identical(state.sessions, _cachedSessionsRef) &&
        _searchQuery == _cachedQuery &&
        scopeKey == _cachedScopeKey &&
        _cachedFiltered != null) {
      return _cachedFiltered!;
    }

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

    it = applySessionQuery(it, state.agentScope, state.listScope);
    if (_projectFilter != 'All') {
      it = it.where((s) => _projectLabel(s) == _projectFilter);
    }
    _cachedFiltered = it.toList();
    _cachedSessionsRef = state.sessions;
    _cachedQuery = _searchQuery;
    _cachedScopeKey = scopeKey;
    return _cachedFiltered!;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final sessions = _filtered(state);
    final activeAll = state.sessions.where((s) => s['isActive'] == true).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Sessions',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            tooltip: 'Change agent',
            icon: const Icon(Icons.switch_account_outlined),
            onPressed: () => _openAgentPicker(state),
          ),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            onPressed: () => _showCreateDialog(state),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          if (state.connectionMode == 'saas') {
            await state.refreshSaasWorkspaces();
          } else {
            await state.refreshSessions(refetchCosts: true);
          }
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (state.connectionMode == 'saas') _buildSaasStrip(context, state),
            _buildAgentHero(state, sessions),
            const SizedBox(height: 12),

            Text(
              'Show',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.white.withAlpha(180),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 36,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: kListScopeOptions
                    .map(
                      (f) => Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(
                            f,
                            style: TextStyle(
                              fontSize: 12,
                              color: state.listScope == f
                                  ? Colors.white
                                  : const Color(0xFF94a3b8),
                            ),
                          ),
                          selected: state.listScope == f,
                          onSelected: (_) async {
                            await state.setListScope(f);
                            if (mounted) setState(() {});
                          },
                          selectedColor: const Color(0xFF8b5cf6),
                          backgroundColor: const Color(0xFF1e293b),
                          side: const BorderSide(color: Color(0xFF334155)),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
            const SizedBox(height: 16),

            _buildProjectFilter(state),
            const SizedBox(height: 16),

            TextField(
              onChanged: (v) => setState(() {
                _searchQuery = v;
                _deepSearchResults = null;
              }),
              decoration: InputDecoration(
                hintText: 'Search in list…',
                hintStyle: const TextStyle(
                  color: Color(0xFF64748b),
                  fontSize: 14,
                ),
                prefixIcon: const Icon(
                  Icons.search,
                  color: Color(0xFF64748b),
                  size: 20,
                ),
                filled: true,
                fillColor: const Color(0xFF1e293b),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFF334155)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFF334155)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFF8b5cf6)),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
              ),
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),

            Row(
              children: [
                const Text(
                  'In this view',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Text(
                  '$activeAll active / ${state.sessions.length} on server',
                  style: const TextStyle(
                    color: Color(0xFF94a3b8),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
            if (state.lastRefreshed != null) ...[
              const SizedBox(height: 4),
              Text(
                _lastUpdatedText(state),
                style: const TextStyle(fontSize: 11, color: Color(0xFF64748b)),
              ),
            ],
            const SizedBox(height: 12),

            const ActivityHeatmap(),
            const SizedBox(height: 16),

            if (state.error != null)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFFef4444).withAlpha(30),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: const Color(0xFFef4444).withAlpha(80),
                  ),
                ),
                child: Text(
                  state.error!,
                  style: const TextStyle(
                    color: Color(0xFFef4444),
                    fontSize: 12,
                  ),
                ),
              ),

            if (sessions.isEmpty && !state.isLoading)
              _emptyState(state, sessions),

            if (state.sessions.isEmpty && state.isLoading) ...[
              _skeletonCard(),
              _skeletonCard(),
              _skeletonCard(),
            ],

            ..._sessionListWidgets(sessions, state),

            // Deep search button when query active and few results
            if (_searchQuery.isNotEmpty &&
                sessions.length < 3 &&
                _deepSearchResults == null) ...[
              const SizedBox(height: 12),
              Center(
                child: _deepSearching
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : TextButton.icon(
                        onPressed: () => _performDeepSearch(state),
                        icon: const Icon(Icons.manage_search, size: 18),
                        label: const Text('Deep search in messages'),
                      ),
              ),
            ],

            // Deep search results
            if (_deepSearchResults != null &&
                _deepSearchResults!.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text(
                'Message Search Results',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              ..._deepSearchResults!.map((r) => _searchResultCard(r)),
            ],
          ],
        ),
      ),
    );
  }

  void _openAgentPicker(AppState state) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1e293b),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.65,
          minChildSize: 0.35,
          maxChildSize: 0.95,
          expand: false,
          builder: (_, scrollController) {
            return ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xFF334155),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Switch agent',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Сессии Kimi Code и Claude Code приходят с вашего Planulix-сервера; переключатель — по каждому CLI.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF94a3b8)),
                ),
                const SizedBox(height: 16),
                ...kAgentCatalog.map(
                  (e) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Material(
                      color: state.agentScope == e.id
                          ? e.accent.withAlpha(24)
                          : const Color(0xFF0f172a),
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () async {
                          await state.setAgentScope(e.id);
                          if (ctx.mounted) Navigator.pop(ctx);
                          if (mounted) setState(() {});
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(
                                  color: e.accent.withAlpha(35),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Icon(e.icon, color: e.accent),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      e.title,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      e.subtitle,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: Color(0xFF94a3b8),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (state.agentScope == e.id)
                                Icon(
                                  Icons.check_circle,
                                  color: e.accent,
                                  size: 22,
                                )
                              else
                                const Icon(
                                  Icons.chevron_right,
                                  color: Color(0xFF64748b),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildAgentHero(AppState state, List<dynamic> filtered) {
    final catalog = catalogForAgent(state.agentScope);
    final title = catalog?.title ?? state.agentScope;
    final sub = catalog?.subtitle ?? '';
    final icon = catalog?.icon ?? Icons.hub_outlined;
    final accent = catalog?.accent ?? const Color(0xFF94a3b8);
    final activeIn = filtered.where((s) => s['isActive'] == true).length;

    return Material(
      color: const Color(0xFF1e293b),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _openAgentPicker(state),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: accent.withAlpha(90)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: accent.withAlpha(40),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: accent, size: 28),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        Icon(
                          Icons.unfold_more,
                          size: 20,
                          color: accent.withAlpha(220),
                        ),
                      ],
                    ),
                    if (sub.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        sub,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF94a3b8),
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Text(
                      '${filtered.length} in this view · $activeIn running here · ${state.sessions.length} total on server',
                      style: TextStyle(
                        fontSize: 12,
                        color: accent.withAlpha(230),
                        fontWeight: FontWeight.w500,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _projectLabel(dynamic session) {
    final explicit = (session['projectName'] ?? '').toString().trim();
    if (explicit.isNotEmpty) return explicit;
    final cwd = (session['cwd'] ?? '').toString().trim();
    if (cwd.isEmpty) return 'No project';
    final parts = cwd.split('/').where((p) => p.isNotEmpty).toList();
    final projectsIdx = parts.lastIndexOf('projects');
    if (projectsIdx >= 0 && projectsIdx + 1 < parts.length) {
      return parts[projectsIdx + 1];
    }
    if (parts.isEmpty) return cwd;
    return parts.last;
  }

  List<String> _projectOptions(AppState state) {
    final base = applySessionQuery(
      state.sessions,
      state.agentScope,
      state.listScope,
    );
    final set = <String>{};
    for (final s in base) {
      set.add(_projectLabel(s));
    }
    final out = set.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return ['All', ...out];
  }

  Widget _buildProjectFilter(AppState state) {
    final projects = _projectOptions(state);
    if (!projects.contains(_projectFilter)) {
      _projectFilter = 'All';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Project',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Colors.white.withAlpha(180),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 36,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: projects.map((p) {
              final selected = _projectFilter == p;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(
                    p,
                    style: TextStyle(
                      fontSize: 12,
                      color: selected ? Colors.white : const Color(0xFF94a3b8),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  selected: selected,
                  onSelected: (_) => setState(() {
                    _projectFilter = p;
                    _cachedFiltered = null;
                  }),
                  selectedColor: const Color(0xFF0ea5e9),
                  backgroundColor: const Color(0xFF1e293b),
                  side: const BorderSide(color: Color(0xFF334155)),
                  visualDensity: VisualDensity.compact,
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  List<Widget> _sessionListWidgets(List<dynamic> sessions, AppState state) {
    if (_projectFilter != 'All') {
      return sessions.map((s) => _sessionCard(s, state)).toList();
    }
    final grouped = <String, List<dynamic>>{};
    for (final s in sessions) {
      (grouped[_projectLabel(s)] ??= []).add(s);
    }
    final keys = grouped.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final widgets = <Widget>[];
    for (final key in keys) {
      final list = grouped[key]!;
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 8),
          child: Row(
            children: [
              const Icon(
                Icons.folder_outlined,
                size: 16,
                color: Color(0xFF38bdf8),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  key,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFFcbd5e1),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '${list.length}',
                style: const TextStyle(fontSize: 11, color: Color(0xFF64748b)),
              ),
            ],
          ),
        ),
      );
      widgets.addAll(list.map((s) => _sessionCard(s, state)));
    }
    return widgets;
  }

  Future<void> _performDeepSearch(AppState state) async {
    setState(() => _deepSearching = true);
    try {
      final data = await state.api.searchSessions(_searchQuery);
      if (mounted) {
        setState(() {
          _deepSearchResults = data['results'] as List? ?? [];
          _deepSearching = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _deepSearching = false);
    }
  }

  Widget _searchResultCard(dynamic result) {
    final title = (result['title'] ?? 'Untitled').toString();
    final snippet = (result['snippet'] ?? '').toString();
    final sessionId = (result['sessionId'] ?? '').toString();
    final score = (result['score'] as num?)?.toInt() ?? 0;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: const Color(0xFF1e293b),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => SessionScreen(sessionId: sessionId),
            ),
          ),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.search,
                      size: 14,
                      color: Color(0xFF8b5cf6),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF8b5cf6).withAlpha(30),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '$score%',
                        style: const TextStyle(
                          fontSize: 10,
                          color: Color(0xFF8b5cf6),
                        ),
                      ),
                    ),
                  ],
                ),
                if (snippet.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    snippet,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF94a3b8),
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _renameSessionDialog(
    AppState state,
    String sessionId,
    String currentTitle,
  ) async {
    final c = TextEditingController(text: currentTitle);
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
    if (next == null) return;
    await state.renameSession(sessionId, next);
  }

  Future<bool> _confirmDeleteSession(String title) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1e293b),
        title: const Text(
          'Remove session?',
          style: TextStyle(color: Color(0xFFf1f5f9)),
        ),
        content: Text(
          title.isEmpty
              ? 'This hides the session from the list and stops its tmux process if it is still running.'
              : 'Remove “$title” from the list and stop it if it is still running?',
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
    return ok == true;
  }

  Widget _sessionCard(dynamic session, AppState state) {
    final isActive = session['isActive'] == true;
    final sessionId = (session['sessionId'] ?? '').toString();
    final cwd = (session['cwd'] ?? '').toString();
    final title = (session['title'] ?? '').toString();
    final kind = (session['kind'] ?? '').toString();
    final entry = (session['entrypoint'] ?? '').toString();
    final age = state.sessionAge(session);
    final extra = session['extra'] as Map<String, dynamic>?;
    final isStarred = extra != null && extra['starred'] == true;
    final tags = (extra?['tags'] as List?)?.cast<String>() ?? [];

    final cost = state.sessionCostUsd[sessionId];
    final statusColor = isActive
        ? const Color(0xFF22c55e)
        : const Color(0xFF334155);

    // Short cwd: show last 2 path components
    final cwdShort = cwd.split('/').where((s) => s.isNotEmpty).toList();
    final cwdDisplay = cwdShort.length > 2
        ? '.../${cwdShort.sublist(cwdShort.length - 2).join('/')}'
        : cwd;

    return Dismissible(
      key: Key(sessionId),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) => _confirmDeleteSession(title),
      background: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFef4444),
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      onDismissed: (_) => state.stopSession(sessionId),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Material(
          color: const Color(0xFF1e293b),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => SessionScreen(sessionId: sessionId),
              ),
            ),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isActive
                      ? const Color(0xFF8b5cf6).withAlpha(80)
                      : const Color(0xFF334155),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      GestureDetector(
                        onTap: () =>
                            state.setSessionStar(sessionId, !isStarred),
                        child: Icon(
                          isStarred ? Icons.star : Icons.star_border,
                          size: 18,
                          color: isStarred
                              ? const Color(0xFFf59e0b)
                              : const Color(0xFF334155),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: statusColor,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          title.isNotEmpty ? title : cwdDisplay,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (cost != null)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Text(
                            '~\$${cost.toStringAsFixed(2)}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF94a3b8),
                              fontFeatures: [],
                            ),
                          ),
                        ),
                      if (age.isNotEmpty)
                        Text(
                          age,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF94a3b8),
                          ),
                        ),
                      const SizedBox(width: 8),
                      PopupMenuButton<String>(
                        icon: const Icon(
                          Icons.more_vert,
                          color: Color(0xFF64748b),
                          size: 20,
                        ),
                        onSelected: (v) async {
                          if (v == 'star') {
                            await state.setSessionStar(sessionId, !isStarred);
                          } else if (v == 'rename') {
                            await _renameSessionDialog(
                              state,
                              sessionId,
                              title.isNotEmpty ? title : cwdDisplay,
                            );
                          } else if (v == 'delete') {
                            if (await _confirmDeleteSession(title)) {
                              await state.stopSession(sessionId);
                            }
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'star',
                            child: Text(isStarred ? 'Unstar' : 'Star'),
                          ),
                          const PopupMenuItem(
                            value: 'rename',
                            child: Text('Rename'),
                          ),
                          const PopupMenuItem(
                            value: 'delete',
                            child: Text('Remove'),
                          ),
                        ],
                      ),
                    ],
                  ),
                  if (tags.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 4,
                      children: tags
                          .map(
                            (t) => Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF8b5cf6).withAlpha(25),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: const Color(0xFF8b5cf6).withAlpha(60),
                                ),
                              ),
                              child: Text(
                                t,
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: Color(0xFF8b5cf6),
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      if (cwd.isNotEmpty) ...[
                        const Icon(
                          Icons.folder_outlined,
                          size: 14,
                          color: Color(0xFF64748b),
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            cwdDisplay,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF64748b),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                      const Spacer(),
                      if (kind.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0f172a),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            kind,
                            style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xFF94a3b8),
                            ),
                          ),
                        ),
                      if (entry.isNotEmpty) ...[
                        const SizedBox(width: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0f172a),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            entry,
                            style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xFF94a3b8),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _emptyState(AppState state, List<dynamic> inView) {
    final agent = catalogForAgent(state.agentScope);
    final name = agent?.title ?? state.agentScope;
    final hint = state.agentScope == 'Planulix' || state.agentScope == 'All'
        ? 'Create a session from + or run a CLI on the server.'
        : 'Run this CLI on the server (see paths in Settings / agent cards), then pull to refresh.';

    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: const Color(0xFF1e293b),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: Column(
        children: [
          Icon(
            agent?.icon ?? Icons.inbox_outlined,
            size: 52,
            color: const Color(0xFF475569),
          ),
          const SizedBox(height: 14),
          Text(
            inView.isEmpty && state.sessions.isNotEmpty
                ? 'Nothing matches this filter'
                : 'No sessions for $name',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFF94a3b8),
              fontSize: 13,
              height: 1.4,
            ),
          ),
          if (state.listScope != 'All') ...[
            const SizedBox(height: 14),
            TextButton(
              onPressed: () async {
                await state.setListScope('All');
                if (mounted) setState(() {});
              },
              child: const Text('Show all in this agent'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _skeletonCard() {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.3, end: 0.7),
      duration: const Duration(milliseconds: 800),
      builder: (context, value, child) => Opacity(opacity: value, child: child),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1e293b),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF334155)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFF334155),
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  width: 160,
                  height: 16,
                  decoration: BoxDecoration(
                    color: const Color(0xFF334155),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const Spacer(),
                Container(
                  width: 40,
                  height: 14,
                  decoration: BoxDecoration(
                    color: const Color(0xFF334155),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              width: 120,
              height: 12,
              decoration: BoxDecoration(
                color: const Color(0xFF334155),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _lastUpdatedText(AppState state) {
    if (state.lastRefreshed == null) return '';
    final diff = DateTime.now().difference(state.lastRefreshed!);
    if (diff.inSeconds < 5) return 'updated just now';
    if (diff.inSeconds < 60) return 'updated ${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return 'updated ${diff.inMinutes}m ago';
    return 'updated ${diff.inHours}h ago';
  }

  void _showCreateDialog(AppState state) {
    const unsupportedCreate = {'Codex', 'Cursor', 'Kiro', 'OpenCode'};
    if (unsupportedCreate.contains(state.agentScope)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Создание сессий ${state.agentScope} из приложения пока не поддерживается — запустите соответствующий CLI на сервере.',
            style: const TextStyle(fontSize: 13),
          ),
          backgroundColor: const Color(0xFF334155),
        ),
      );
      return;
    }

    final nameController = TextEditingController();
    final isKimiScope = state.agentScope == 'Kimi';
    final isAllScope = state.agentScope == 'All';
    final defaultCwd = isKimiScope ? '/root' : '/home/claude';
    final cwdController = TextEditingController(text: defaultCwd);
    final promptController = TextEditingController();
    String selectedMode = 'chat';
    final claudeModels = state.modelsForAgent('Claude');
    final kimiModels = state.modelsForAgent('Kimi');
    String selectedClaudeModel = claudeModels.first.id;
    String selectedKimiModel = kimiModels.first.id;

    /// When agent filter is «All», user picks who to create for.
    String createProvider = isKimiScope ? 'Kimi' : 'Claude';

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1e293b),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final isKimi = createProvider == 'Kimi';
          final modelChoices = isKimi
              ? state.modelsForAgent('Kimi')
              : state.modelsForAgent('Claude');
          if (isKimi && !modelChoices.any((m) => m.id == selectedKimiModel)) {
            selectedKimiModel = modelChoices.first.id;
          }
          if (!isKimi &&
              !modelChoices.any((m) => m.id == selectedClaudeModel)) {
            selectedClaudeModel = modelChoices.first.id;
          }
          final accent = isKimi
              ? const Color(0xFF38bdf8)
              : const Color(0xFF8b5cf6);
          final title = isKimi ? 'Новая сессия Kimi' : 'Новая сессия Claude';
          final subtitle = isKimi
              ? 'Запускается kimi-cli на сервере (~/.kimi). Ключ API — в настройках приложения.'
              : 'Запускается Claude Code в tmux на сервере (~/.claude).';

          return SingleChildScrollView(
            child: Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: const Color(0xFF334155),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF94a3b8),
                      height: 1.35,
                    ),
                  ),
                  if (isAllScope) ...[
                    const SizedBox(height: 14),
                    const Text(
                      'Создать для',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF94a3b8),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: ChoiceChip(
                            label: const Text('Claude Code'),
                            selected: createProvider == 'Claude',
                            onSelected: (_) => setSheetState(() {
                              createProvider = 'Claude';
                              if (!cwdController.text.contains('kimi')) {
                                cwdController.text = '/home/claude';
                              }
                            }),
                            selectedColor: const Color(
                              0xFF8b5cf6,
                            ).withAlpha(80),
                            labelStyle: TextStyle(
                              color: createProvider == 'Claude'
                                  ? Colors.white
                                  : const Color(0xFF94a3b8),
                              fontSize: 13,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ChoiceChip(
                            label: const Text('Kimi Code'),
                            selected: createProvider == 'Kimi',
                            onSelected: (_) => setSheetState(() {
                              createProvider = 'Kimi';
                              if (cwdController.text == '/home/claude') {
                                cwdController.text = '/root';
                              }
                            }),
                            selectedColor: const Color(
                              0xFF38bdf8,
                            ).withAlpha(80),
                            labelStyle: TextStyle(
                              color: createProvider == 'Kimi'
                                  ? Colors.white
                                  : const Color(0xFF94a3b8),
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 16),

                  Row(
                    children: [
                      Expanded(
                        child: _modeCard(
                          icon: Icons.rocket_launch,
                          title: 'Task',
                          selected: selectedMode == 'task',
                          accent: accent,
                          onTap: () =>
                              setSheetState(() => selectedMode = 'task'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _modeCard(
                          icon: Icons.chat_bubble_outline,
                          title: 'Chat',
                          selected: selectedMode == 'chat',
                          accent: accent,
                          onTap: () =>
                              setSheetState(() => selectedMode = 'chat'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0f172a),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.lightbulb_outline,
                          size: 16,
                          color: accent.withAlpha(220),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            isKimi
                                ? (selectedMode == 'task'
                                      ? 'Kimi получит задачу и отработает в фоне (как в CLI). Подходит для правок и рефакторинга.'
                                      : 'Живой чат: вы и Kimi переписываетесь по очереди — как в веб-UI.')
                                : (selectedMode == 'task'
                                      ? 'Claude получит задачу и сможет доработать её автономно в tmux.'
                                      : 'Живой диалог с Claude в tmux: удобно для вопросов и итераций.'),
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF94a3b8),
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),

                  TextField(
                    controller: nameController,
                    decoration: _inputDecoration('Имя сессии (необязательно)'),
                    style: const TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 12),

                  TextField(
                    controller: cwdController,
                    decoration: _inputDecoration(
                      isKimi
                          ? 'Рабочая папка на сервере'
                          : 'Рабочая директория',
                    ),
                    style: const TextStyle(
                      fontSize: 14,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(height: 12),

                  Text(
                    isKimi ? 'Модель Kimi' : 'Модель Claude',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF94a3b8),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: modelChoices.map((m) {
                      final current = isKimi
                          ? selectedKimiModel
                          : selectedClaudeModel;
                      final sel = current == m.id;
                      return ChoiceChip(
                        label: Text(
                          m.label,
                          style: const TextStyle(fontSize: 12),
                        ),
                        labelPadding: const EdgeInsets.symmetric(horizontal: 8),
                        selected: sel,
                        onSelected: (_) => setSheetState(() {
                          if (isKimi) {
                            selectedKimiModel = m.id;
                          } else {
                            selectedClaudeModel = m.id;
                          }
                        }),
                        selectedColor: accent.withAlpha(90),
                        backgroundColor: const Color(0xFF0f172a),
                        side: BorderSide(
                          color: sel ? accent : const Color(0xFF334155),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 12),

                  TextField(
                    controller: promptController,
                    decoration: _inputDecoration(
                      selectedMode == 'task'
                          ? 'Описание задачи (обязательно)'
                          : 'Первое сообщение (необязательно)',
                    ),
                    style: const TextStyle(fontSize: 14),
                    maxLines: 4,
                    minLines: 2,
                  ),
                  const SizedBox(height: 16),

                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () {
                        if (selectedMode == 'task' &&
                            promptController.text.trim().isEmpty) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Для режима Task нужен текст задачи',
                              ),
                              backgroundColor: Color(0xFFb45309),
                            ),
                          );
                          return;
                        }
                        Navigator.pop(ctx);
                        state.createSession(
                          cwd: cwdController.text.trim().isEmpty
                              ? null
                              : cwdController.text.trim(),
                          prompt: promptController.text.isNotEmpty
                              ? promptController.text
                              : null,
                          name: nameController.text.isNotEmpty
                              ? nameController.text
                              : null,
                          mode: selectedMode,
                          model: isKimi
                              ? selectedKimiModel
                              : selectedClaudeModel,
                          agent: isKimi ? 'kimi-cli' : null,
                        );
                      },
                      icon: Icon(
                        selectedMode == 'task'
                            ? Icons.rocket_launch
                            : Icons.chat_bubble,
                        size: 18,
                      ),
                      label: Text(
                        isKimi
                            ? (selectedMode == 'task'
                                  ? 'Запустить Kimi'
                                  : 'Чат с Kimi')
                            : (selectedMode == 'task'
                                  ? 'Запустить Claude'
                                  : 'Чат с Claude'),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: selectedMode == 'task'
                            ? const Color(0xFFf59e0b)
                            : accent,
                        foregroundColor: selectedMode == 'task'
                            ? Colors.black
                            : Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSaasStrip(BuildContext context, AppState state) {
    final me = state.saasMe;
    final u = state.saasUsage;
    return Card(
      color: const Color(0xFF1e293b),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.cloud_outlined, color: Color(0xFF38bdf8)),
                const SizedBox(width: 8),
                Text(
                  'Planulix Cloud · ${me?['tenant_name'] ?? 'workspaces'}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
              ],
            ),
            if (state.saasWorkspaces.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text(
                'Managed servers',
                style: TextStyle(fontSize: 12, color: Color(0xFF94a3b8)),
              ),
              const SizedBox(height: 6),
              ...state.saasWorkspaces.map(
                (w) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      Icon(
                        w.online ? Icons.circle : Icons.circle_outlined,
                        size: 12,
                        color: w.online
                            ? Colors.greenAccent
                            : const Color(0xFF64748b),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          w.name,
                          style: const TextStyle(fontSize: 14),
                        ),
                      ),
                      Text(
                        w.online ? 'online' : 'offline',
                        style: TextStyle(
                          fontSize: 12,
                          color: w.online
                              ? Colors.greenAccent
                              : const Color(0xFF64748b),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (u != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  'Usage this month: ${u['month_used_tokens'] ?? 0} tokens · '
                  'budget ${u['monthly_token_budget'] ?? 0} · mode ${u['kimi_mode'] ?? ''}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF94a3b8),
                  ),
                ),
              ),
            const SizedBox(height: 6),
            Text(
              'Подсказка: для чата по сессиям Kimi/Claude включите Direct и добавьте профиль Planulix (URL сервера + токен).',
              style: TextStyle(
                fontSize: 11,
                color: Colors.white.withAlpha(150),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modeCard({
    required IconData icon,
    required String title,
    required bool selected,
    required Color accent,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: selected ? accent.withAlpha(40) : const Color(0xFF0f172a),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? accent : const Color(0xFF334155),
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Icon(
              icon,
              size: 28,
              color: selected ? accent : const Color(0xFF64748b),
            ),
            const SizedBox(height: 6),
            Text(
              title,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : const Color(0xFF94a3b8),
              ),
            ),
          ],
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Color(0xFF64748b), fontSize: 14),
      filled: true,
      fillColor: const Color(0xFF0f172a),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF334155)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF334155)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF8b5cf6)),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    );
  }
}
