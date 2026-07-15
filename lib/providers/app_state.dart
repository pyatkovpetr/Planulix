import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../api/client.dart';
import '../models/server_profile.dart';
import '../utils/agent_catalog.dart';
import '../utils/capabilities_helpers.dart';
import '../utils/chat_models.dart';

class AppState extends ChangeNotifier {
  final ApiClient api;

  List<dynamic> sessions = [];
  Map<String, dynamic>? currentSession;
  List<dynamic> currentMessages = [];
  bool isLoading = false;
  String? error;
  DateTime? lastRefreshed;
  Timer? _pollTimer;

  /// Whose sessions (Claude / Kimi / … / All).
  String agentScope = 'All';

  /// Starred / active / finished within [agentScope].
  String listScope = 'All';

  /// First-launch agent picker on phone (skipped for upgraded installs).
  bool agentOnboardingDone = false;

  /// First-run welcome: Tailscale vs SSH paths + что дальше (shown once).
  bool welcomeOnboardingDone = false;

  List<ServerProfile> serverProfiles = [];
  String? activeProfileId;

  /// Local API keys; forwarded to the server with `agentEnv` on create/resume message (whitelisted keys only).
  Map<String, String> agentApiKeys = {};

  /// Last successful GET /pricing (models + USD/M rates).
  Map<String, dynamic>? pricingSnapshot;

  /// Last successful GET /capabilities (agents + exact model lists from server).
  Map<String, dynamic>? capabilitiesSnapshot;

  /// Cached per-session total USD from GET /sessions/:id/cost (null = unknown / error).
  final Map<String, double?> sessionCostUsd = {};

  /// Last workspace opened in Desktop explorer (sessions default cwd).
  String? workspacePath;

  /// Keys from platform.moonshot.ai need `.ai` API host; `.cn` for China console.
  bool moonshotInternational = true;

  AppState({required this.api});

  static const _kProfiles = 'serverProfilesJson';
  static const _kActiveProfile = 'activeProfileId';
  static const _kSessionFilter = 'sessionListFilter';
  static const _kAgentScope = 'agentScope';
  static const _kListScope = 'listScope';
  static const _kAgentOnboardingDone = 'agentOnboardingDone';
  static const _kWelcomeOnboardingDone = 'welcomeOnboardingDone';
  static const _kAgentKeys = 'agentApiKeysJson';
  static const _kMoonshotIntl = 'moonshotInternational';
  static const _kWorkspacePath = 'workspacePath';
  static const _listOnlyFilters = {'Starred', 'Active', 'Finished'};

  Future<void> init() async {
    isLoading = true;
    notifyListeners();
    try {
      await api.loadSettings();
      await _loadUserPrefs();
      await _migrateLegacyProfileIfNeeded();
      if (api.isConfigured) {
        await refreshSessions();
        unawaited(loadCapabilitiesIfNeeded());
        unawaited(loadPricingIfNeeded());
        _startPolling();
      }
    } catch (_) {
      // Proceed to settings screen
    }
    isLoading = false;
    notifyListeners();
  }

  Future<void> _loadUserPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    agentOnboardingDone = prefs.getBool(_kAgentOnboardingDone) ?? false;
    if (prefs.containsKey(_kWelcomeOnboardingDone)) {
      welcomeOnboardingDone = prefs.getBool(_kWelcomeOnboardingDone) ?? false;
    } else if (agentOnboardingDone) {
      // Upgraded install: skip the new welcome carousel once.
      welcomeOnboardingDone = true;
      await prefs.setBool(_kWelcomeOnboardingDone, true);
    } else {
      welcomeOnboardingDone = false;
    }

    if (prefs.containsKey(_kAgentScope)) {
      agentScope = prefs.getString(_kAgentScope) ?? 'All';
      listScope = prefs.getString(_kListScope) ?? 'All';
    } else if (prefs.containsKey(_kSessionFilter)) {
      final legacy = prefs.getString(_kSessionFilter) ?? 'All';
      if (_listOnlyFilters.contains(legacy)) {
        agentScope = 'All';
        listScope = legacy;
      } else {
        agentScope = legacy;
        listScope = 'All';
      }
      await prefs.setString(_kAgentScope, agentScope);
      await prefs.setString(_kListScope, listScope);
      agentOnboardingDone = true;
      await prefs.setBool(_kAgentOnboardingDone, true);
    } else {
      agentScope = 'All';
      listScope = 'All';
    }

    if (!isValidAgentScope(agentScope)) agentScope = 'All';
    if (!isValidListScope(listScope)) listScope = 'All';

    serverProfiles = ServerProfile.listFromJson(prefs.getString(_kProfiles));
    activeProfileId = prefs.getString(_kActiveProfile);

    final keysRaw = prefs.getString(_kAgentKeys);
    if (keysRaw != null && keysRaw.isNotEmpty) {
      try {
        final m = jsonDecode(keysRaw);
        if (m is Map) {
          agentApiKeys = m.map((k, v) => MapEntry(k.toString(), v.toString()));
        }
      } catch (_) {}
    }

    moonshotInternational = prefs.getBool(_kMoonshotIntl) ?? true;

    workspacePath = prefs.getString(_kWorkspacePath);
    final ws = workspacePath?.trim();
    workspacePath = (ws != null && ws.isNotEmpty) ? ws : null;

    // Older builds: strip legacy Planulix Cloud prefs.
    await prefs.remove('connectionMode');
    await prefs.remove('saasBaseUrl');
    await prefs.remove('saasJwt');
  }

  Future<void> setMoonshotInternational(bool value) async {
    moonshotInternational = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kMoonshotIntl, value);
    notifyListeners();
  }

  Future<void> setWorkspacePath(String? path) async {
    final t = path?.trim();
    workspacePath = (t != null && t.isNotEmpty) ? t : null;
    final prefs = await SharedPreferences.getInstance();
    if (workspacePath == null) {
      await prefs.remove(_kWorkspacePath);
    } else {
      await prefs.setString(_kWorkspacePath, workspacePath!);
    }
    notifyListeners();
  }

  /// If user had URL/token but no profiles yet, create one profile.
  Future<void> _migrateLegacyProfileIfNeeded() async {
    if (serverProfiles.isNotEmpty) return;
    if (!api.isConfigured) return;
    final p = ServerProfile(
      id: const Uuid().v4(),
      name: 'Default',
      baseUrl: api.baseUrl,
      token: api.authToken ?? '',
      sshUser: null,
      sshPort: null,
    );
    serverProfiles = [p];
    activeProfileId = p.id;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kProfiles, ServerProfile.listToJson(serverProfiles));
    await prefs.setString(_kActiveProfile, p.id);
  }

  Future<void> setAgentScope(String value) async {
    if (!isValidAgentScope(value)) return;
    agentScope = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAgentScope, value);
    notifyListeners();
  }

  Future<void> setListScope(String value) async {
    if (!isValidListScope(value)) return;
    listScope = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kListScope, value);
    notifyListeners();
  }

  Future<void> completeAgentOnboarding() async {
    agentOnboardingDone = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAgentOnboardingDone, true);
    notifyListeners();
  }

  Future<void> completeWelcomeOnboarding() async {
    welcomeOnboardingDone = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kWelcomeOnboardingDone, true);
    notifyListeners();
  }

  /// Открыть приветственный тур снова (из настроек).
  Future<void> resetWelcomeOnboarding() async {
    welcomeOnboardingDone = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kWelcomeOnboardingDone);
    notifyListeners();
  }

  Future<void> persistServerProfiles(
    List<ServerProfile> list, {
    String? activateId,
  }) async {
    serverProfiles = List.unmodifiable(list);
    if (activateId != null) activeProfileId = activateId;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kProfiles, ServerProfile.listToJson(serverProfiles));
    if (activeProfileId != null) {
      await prefs.setString(_kActiveProfile, activeProfileId!);
    }
    notifyListeners();
  }

  /// Хост gateway из активного профиля + пользователь/port SSH для SOCKS5-туннеля до того же VPS.
  ({String host, String sshUser, int sshPort})? get gatewayVpsTunnelTarget {
    final p = activeProfile;
    if (p == null) return null;
    final normalized = ApiClient.normalizeApiBaseUrl(p.baseUrl);
    final uri = Uri.tryParse(normalized);
    final host = uri?.host;
    if (host == null || host.isEmpty) return null;
    return (host: host, sshUser: p.resolvedSshUser, sshPort: p.resolvedSshPort);
  }

  /// Сохраняет SSH-поля для OAuth/браузера через VPS (профиль).
  Future<void> saveGatewaySshForActiveProfile({
    required String sshUserRaw,
    required int sshPort,
  }) async {
    await _migrateLegacyProfileIfNeeded();
    if (activeProfileId == null || serverProfiles.isEmpty) {
      await _ensureProfileForCurrentConnection(name: 'Default');
    }
    final id = activeProfileId;
    if (id == null) return;
    final u = sshUserRaw.trim();
    final userStored = u.isEmpty ? null : u;
    final portStored = sshPort > 0 && sshPort < 65536 ? sshPort : 22;

    serverProfiles = serverProfiles.map((p) {
      if (p.id != id) return p;
      return ServerProfile(
        id: p.id,
        name: p.name,
        baseUrl: p.baseUrl,
        token: p.token,
        sshUser: userStored,
        sshPort: portStored,
      );
    }).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kProfiles, ServerProfile.listToJson(serverProfiles));
    notifyListeners();
  }

  Future<void> loadPricingIfNeeded() async {
    if (!api.isConfigured) return;
    try {
      pricingSnapshot = await api.getPricing();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> loadCapabilitiesIfNeeded() async {
    if (!api.isConfigured) return;
    try {
      capabilitiesSnapshot = await api.getCapabilities();
      notifyListeners();
    } catch (_) {}
  }

  List<ChatModelChoice> modelsForAgent(String agentLabelOrId) {
    final wanted = agentLabelOrId.toLowerCase();
    final fallback = wanted.contains('kimi')
        ? kKimiChatModels
        : wanted.contains('cursor')
        ? kCursorChatModels
        : wanted.contains('codex')
        ? kCodexChatModels
        : wanted.contains('kiro') || wanted.contains('opencode')
        ? kProviderDefaultChatModels
        : kClaudeChatModels;
    final agents = capabilitiesSnapshot?['agents'];
    if (agents is! List) return fallback;

    bool wantedAgent(String id, String label) {
      if (wanted == 'all') return id == 'claude-code' || label == 'claude';
      if (wanted.contains('kimi')) return id == 'kimi-cli' || label == 'kimi';
      if (wanted.contains('claude')) {
        return id == 'claude-code' || label == 'claude';
      }
      if (wanted.contains('cursor')) return id == 'cursor' || label == 'cursor';
      if (wanted.contains('codex')) {
        return id == 'codex-cli' || label == 'codex';
      }
      if (wanted.contains('kiro')) return id == 'kiro-cli' || label == 'kiro';
      if (wanted.contains('opencode') || wanted.contains('open-code')) {
        return id == 'opencode' || label == 'opencode';
      }
      return false;
    }

    Map<String, dynamic>? found;
    for (final raw in agents) {
      if (raw is! Map) continue;
      final a = Map<String, dynamic>.from(raw);
      final id = (a['id'] ?? '').toString().toLowerCase();
      final label = (a['label'] ?? '').toString().toLowerCase();
      if (wantedAgent(id, label)) {
        found = a;
        break;
      }
    }
    final models = found?['models'];
    if (models is! List || models.isEmpty) return fallback;
    final parsed = <ChatModelChoice>[];
    for (final raw in models) {
      if (raw is! Map) continue;
      final m = Map<String, dynamic>.from(raw);
      final id = (m['id'] ?? '').toString();
      final label = (m['label'] ?? '').toString();
      if (id.isEmpty || label.isEmpty) continue;
      double asDouble(String key) => (m[key] is num)
          ? (m[key] as num).toDouble()
          : double.tryParse('${m[key]}') ?? 0;
      parsed.add(
        ChatModelChoice(
          id: id,
          label: label,
          tier: (m['tier'] ?? '').toString().isEmpty
              ? null
              : (m['tier'] ?? '').toString(),
          priceInPerM: asDouble('priceInPerM'),
          priceOutPerM: asDouble('priceOutPerM'),
        ),
      );
    }
    if (wanted.contains('codex')) {
      final hasDefault = parsed.any((m) => m.id == 'provider-default');
      if (!hasDefault) {
        parsed.insert(0, kCodexChatModels.first);
      }
    }
    return parsed.isEmpty ? fallback : parsed;
  }

  /// Whitelisted env vars merged into tmux/bash on the server (create + resume send).
  Map<String, String> agentEnvForServer() {
    final m = <String, String>{};
    final k = agentApiKeys['kimi']?.trim();
    if (k != null && k.isNotEmpty) {
      final base = moonshotInternational
          ? 'https://api.moonshot.ai/v1'
          : 'https://api.moonshot.cn/v1';
      m['KIMI_API_KEY'] = k;
      m['MOONSHOT_API_KEY'] = k;
      m['MOONSHOT_BASE_URL'] = base;
      m['KIMI_BASE_URL'] = base;
    }
    final a = agentApiKeys['anthropic']?.trim();
    if (a != null && a.isNotEmpty) m['ANTHROPIC_API_KEY'] = a;
    final o = agentApiKeys['openai']?.trim();
    if (o != null && o.isNotEmpty) m['OPENAI_API_KEY'] = o;
    return m;
  }

  Future<void> _prefetchSessionCosts() async {
    if (!api.isConfigured || sessions.isEmpty) return;
    final ids = <String>[];
    for (final s in sessions) {
      final id = s['sessionId']?.toString();
      if (id == null || id.isEmpty) continue;
      final cached = sessionCostUsd[id];
      if (cached != null && cached > 0) continue;
      ids.add(id);
      if (ids.length >= 100) break;
    }
    var changed = false;
    for (final id in ids) {
      try {
        final c = await api.getSessionCost(id);
        sessionCostUsd[id] = (c['totalCost'] as num?)?.toDouble() ?? 0.0;
        changed = true;
      } catch (_) {
        sessionCostUsd[id] = null;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  Future<void> activateProfile(ServerProfile p) async {
    await api.saveSettings(p.baseUrl.trim(), p.token.trim());
    activeProfileId = p.id;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kActiveProfile, p.id);
    error = null;
    notifyListeners();
    try {
      await refreshSessions();
      unawaited(loadCapabilitiesIfNeeded());
      unawaited(loadPricingIfNeeded());
    } catch (_) {}
    _startPolling();
  }

  Future<void> persistAgentApiKeys(Map<String, String> keys) async {
    agentApiKeys = Map<String, String>.from(keys);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAgentKeys, jsonEncode(agentApiKeys));
    notifyListeners();
  }

  ServerProfile? get activeProfile {
    if (activeProfileId == null) return null;
    for (final p in serverProfiles) {
      if (p.id == activeProfileId) return p;
    }
    return null;
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      refreshSessions();
    });
  }

  Future<void> configure(
    String baseUrl,
    String token, {
    bool refreshNow = true,
  }) async {
    await api.saveSettings(baseUrl.trim(), token.trim());
    await _ensureProfileForCurrentConnection(name: 'Default');
    notifyListeners();
    if (refreshNow) {
      try {
        await refreshSessions();
      } catch (_) {}
    } else {
      unawaited(refreshSessions());
    }
    unawaited(loadCapabilitiesIfNeeded());
    unawaited(loadPricingIfNeeded());
    _startPolling();
  }

  Future<void> _ensureProfileForCurrentConnection({
    required String name,
  }) async {
    final url = api.baseUrl.trim();
    final tok = api.authToken ?? '';
    final prefs = await SharedPreferences.getInstance();

    if (activeProfileId != null) {
      final id = activeProfileId!;
      var found = false;
      serverProfiles = serverProfiles.map((p) {
        if (p.id == id) {
          found = true;
          return ServerProfile(
            id: p.id,
            name: p.name,
            baseUrl: url,
            token: tok,
            sshUser: p.sshUser,
            sshPort: p.sshPort,
          );
        }
        return p;
      }).toList();
      if (found) {
        await prefs.setString(
          _kProfiles,
          ServerProfile.listToJson(serverProfiles),
        );
        await prefs.setString(_kActiveProfile, id);
        return;
      }
    }

    ServerProfile? match;
    for (final p in serverProfiles) {
      if (p.baseUrl.trim() == url && p.token == tok) {
        match = p;
        break;
      }
    }
    if (match != null) {
      activeProfileId = match.id;
    } else {
      final p = ServerProfile(
        id: const Uuid().v4(),
        name: name,
        baseUrl: url,
        token: tok,
        sshUser: null,
        sshPort: null,
      );
      serverProfiles = [...serverProfiles, p];
      activeProfileId = p.id;
    }
    await prefs.setString(_kProfiles, ServerProfile.listToJson(serverProfiles));
    await prefs.setString(_kActiveProfile, activeProfileId!);
  }

  bool get isConfigured => api.isConfigured;

  Future<void> refreshSessions({bool refetchCosts = false}) async {
    try {
      if (refetchCosts) {
        sessionCostUsd.clear();
      }
      sessions = await api.getSessions();
      lastRefreshed = DateTime.now();
      error = null;
      notifyListeners();
      unawaited(_prefetchSessionCosts());
    } catch (e) {
      error = e.toString();
      notifyListeners();
    }
  }

  Future<void> loadSession(String id) async {
    try {
      isLoading = true;
      error = null;
      notifyListeners();
      final data = await api.getSession(id);
      currentSession = data;
      currentMessages = data['messages'] ?? [];
    } catch (e) {
      error = e.toString();
      currentSession = {'sessionId': id, 'title': 'Session'};
      currentMessages = [];
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  /// Creates a remote tmux-backed session. Returns `false` on API failure ([error] is set).
  Future<bool> createSession({
    String? cwd,
    String? prompt,
    String? name,
    String mode = 'chat',
    String? model,
    String? agent,
  }) async {
    try {
      await api.createSession(
        cwd: cwd,
        prompt: prompt,
        name: name,
        mode: mode,
        model: model,
        agent:
            agent ??
            (setupAgentIdForScope(agentScope).isEmpty
                ? null
                : setupAgentIdForScope(agentScope)),
        agentEnv: agentEnvForServer(),
      );
      if (listScope != 'All') {
        listScope = 'All';
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kListScope, listScope);
      }
      await refreshSessions();
      return true;
    } catch (e) {
      error = e.toString();
      notifyListeners();
      return false;
    }
  }

  Future<Map<String, dynamic>?> createTaskSpec({
    required String cwd,
    required String prompt,
    String? name,
    String? model,
    String? agent,
  }) async {
    try {
      final data = await api.createTaskSpec(
        cwd: cwd,
        prompt: prompt,
        title: name,
        model: model,
        agent:
            agent ??
            (setupAgentIdForScope(agentScope).isEmpty
                ? null
                : setupAgentIdForScope(agentScope)),
      );
      error = null;
      notifyListeners();
      return data;
    } catch (e) {
      error = e.toString();
      notifyListeners();
      return null;
    }
  }

  Future<void> sendMessage(
    String sessionId,
    String text, {
    String? model,
  }) async {
    try {
      await api.sendMessage(
        sessionId,
        text,
        agentEnv: agentEnvForServer(),
        model: model,
      );
    } catch (e) {
      error = e.toString();
      notifyListeners();
    }
  }

  Future<void> stopSession(String sessionId) async {
    try {
      await api.stopSession(sessionId);
      await refreshSessions();
    } catch (e) {
      error = e.toString();
      notifyListeners();
    }
  }

  Future<void> setSessionStar(String sessionId, bool starred) async {
    try {
      await api.setStar(sessionId, starred);
      await refreshSessions();
    } catch (e) {
      error = e.toString();
      notifyListeners();
    }
  }

  Future<void> renameSession(String sessionId, String title) async {
    try {
      await api.setSessionTitle(sessionId, title);
      await refreshSessions();
    } catch (e) {
      error = e.toString();
      notifyListeners();
    }
  }

  String _formatTimestamp(int ts) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ts);
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  String sessionAge(dynamic session) {
    final ts = session['startedAt'];
    if (ts == null) return '';
    if (ts is int) return _formatTimestamp(ts);
    return '';
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }
}
