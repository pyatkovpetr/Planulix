import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api/client.dart';
import '../../config/github_public_client_id.dart';
import '../../providers/app_state.dart';
import '../../services/github_import.dart';
import '../../services/github_pkce_browser.dart' show githubAuthorizePkceBrowser, githubPkceCallbackUrl, githubPkceSupportedOnPlatform;

const String _kDartDefineGithubClientId = String.fromEnvironment('GITHUB_OAUTH_CLIENT_ID');
const String _kDartDefineGithubClientSecret = String.fromEnvironment('GITHUB_OAUTH_CLIENT_SECRET');

/// GitHub import: browser via server OAuth, browser via PKCE (desktop), or device flow.
class GitHubImportDialog extends StatefulWidget {
  const GitHubImportDialog({super.key});

  @override
  State<GitHubImportDialog> createState() => _GitHubImportDialogState();
}

class _GitHubImportDialogState extends State<GitHubImportDialog> {
  final _clientIdController = TextEditingController();
  final _searchController = TextEditingController();

  /// Server-side OAuth env present — login only in browser, no app Client ID.
  bool _browserOAuthAvailable = false;

  bool get _clientIdBundled =>
      kGithubEmbeddedOAuthClientId.isNotEmpty || _kDartDefineGithubClientId.isNotEmpty;

  bool get _hideManualClientIdField => _browserOAuthAvailable || _clientIdBundled;

  String? _accessToken;
  String? _githubLogin;
  List<GitHubRepoItem> _repos = [];
  String _search = '';
  bool _loadingRepos = false;
  bool _authorizing = false;
  String? _error;
  String? _authHint; // user_code while waiting
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _hydrate());
  }

  Future<void> _hydrate() async {
    final api = context.read<AppState>().api;
    var browser = false;
    try {
      browser = await api.githubOAuthConfigured();
    } catch (_) {}

    final cid = await GitHubImportConfig.getClientId();
    final tok = await GitHubImportConfig.getAccessToken();
    if (!mounted) return;
    setState(() {
      _browserOAuthAvailable = browser;
      if (cid != null) _clientIdController.text = cid;
      _accessToken = tok;
    });
    if (tok != null) {
      await _loadUserAndRepos(tok);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _clientIdController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  bool get _pollCancelled => _disposed || !mounted;

  Future<String?> _resolveClientId() async {
    if (kGithubEmbeddedOAuthClientId.isNotEmpty) return kGithubEmbeddedOAuthClientId;
    if (_kDartDefineGithubClientId.isNotEmpty) return _kDartDefineGithubClientId;
    final p = await GitHubImportConfig.getClientId();
    if (p != null && p.isNotEmpty) return p;
    final t = _clientIdController.text.trim();
    return t.isEmpty ? null : t;
  }

  Future<void> _saveClientId() async {
    var v = _clientIdController.text.trim();
    if (v.isEmpty) {
      v = (await _resolveClientId()) ?? '';
    }
    if (v.isEmpty) {
      setState(() => _error = 'Введите Client ID OAuth-приложения GitHub');
      return;
    }
    await GitHubImportConfig.setClientId(v);
    setState(() {
      _error = null;
    });
  }

  Future<void> _openUrl(String url) async {
    final u = Uri.parse(url);
    await launchUrl(u, mode: LaunchMode.externalApplication);
  }

  Future<void> _disconnect() async {
    await GitHubImportConfig.clearAccessToken();
    if (!mounted) return;
    setState(() {
      _accessToken = null;
      _githubLogin = null;
      _repos = [];
      _error = null;
    });
  }

  Future<void> _authorize() async {
    final api = context.read<AppState>().api;
    var useBrowser = _browserOAuthAvailable;
    if (!useBrowser) {
      try {
        useBrowser = await api.githubOAuthConfigured();
      } catch (_) {}
    }

    if (useBrowser) {
      if (!mounted) return;
      setState(() => _browserOAuthAvailable = true);
      await _authorizeViaBrowserOnServer(api);
      return;
    }

    final cid = await _resolveClientId();
    if (githubPkceSupportedOnPlatform() &&
        cid != null &&
        cid.isNotEmpty &&
        _kDartDefineGithubClientSecret.isNotEmpty) {
      await _authorizePkceBrowserFlow(cid);
      return;
    }

    await _authorizeDeviceFlow();
  }

  Future<void> _authorizePkceBrowserFlow(String clientId) async {
    setState(() {
      _authorizing = true;
      _error = null;
      _authHint = 'Откроется GitHub в браузере — войдите и разрешите доступ.';
    });
    try {
      final token = await githubAuthorizePkceBrowser(
        clientId,
        clientSecret: _kDartDefineGithubClientSecret,
      );
      if (!mounted) return;
      if (token == null || token.isEmpty) {
        setState(() {
          _authorizing = false;
          _authHint = null;
          _error =
              'Вход отменён или истекло время. В OAuth App callback должен быть: $githubPkceCallbackUrl';
        });
        return;
      }
      await GitHubImportConfig.setAccessToken(token);
      setState(() {
        _accessToken = token;
        _authorizing = false;
        _authHint = null;
      });
      await _loadUserAndRepos(token);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _authorizing = false;
        _authHint = null;
        _error = e.toString();
      });
    }
  }

  Future<void> _authorizeViaBrowserOnServer(ApiClient api) async {
    setState(() {
      _authorizing = true;
      _error = null;
      _authHint = 'Сейчас откроется GitHub в браузере — войдите и подтвердите доступ.';
    });
    try {
      final data = await api.githubOAuthStart();
      final url = data['authorize_url'] as String?;
      final state = data['state'] as String?;
      if (url == null || state == null || url.isEmpty) {
        throw StateError('Сервер не вернул ссылку для входа');
      }
      await _openUrl(url);
      if (!mounted) return;
      setState(() => _authHint = 'Завершите вход в браузере. Это окно подождёт…');

      final deadline = DateTime.now().add(const Duration(minutes: 14));
      while (DateTime.now().isBefore(deadline) && mounted && !_pollCancelled) {
        await Future<void>.delayed(const Duration(seconds: 2));
        String? tok;
        try {
          tok = await api.githubOAuthResult(state);
        } on DioException catch (e) {
          if (e.response?.statusCode != 404) rethrow;
        }
        if (!mounted) return;
        if (tok != null && tok.isNotEmpty) {
          await GitHubImportConfig.setAccessToken(tok);
          setState(() {
            _accessToken = tok;
            _authorizing = false;
            _authHint = null;
          });
          await _loadUserAndRepos(tok);
          return;
        }
      }
      if (!mounted) return;
      setState(() {
        _authorizing = false;
        _authHint = null;
        _error = 'Время ожидания истекло или вход отменён. Попробуйте снова.';
      });
    } on DioException catch (e) {
      if (!mounted) return;
      final code = e.response?.statusCode;
      final body = e.response?.data;
      String? hint;
      if (body is Map && body['hint'] != null) hint = body['hint'].toString();
      if (code == 501) {
        setState(() {
          _browserOAuthAvailable = false;
          _authorizing = false;
          _authHint = null;
          _error =
              'Сервер не настроен для входа через браузер. Администратору: задать GITHUB_OAUTH_CLIENT_ID и '
              'GITHUB_OAUTH_CLIENT_SECRET на машине Planulix и в OAuth App указать callback '
              'http(s)://<хост>:<порт>/api/github/oauth/callback (при необходимости GITHUB_OAUTH_PUBLIC_BASE). '
              '${hint ?? ''}';
        });
        return;
      }
      setState(() {
        _authorizing = false;
        _authHint = null;
        _error = e.message ?? e.toString();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _authorizing = false;
        _authHint = null;
        _error = e.toString();
      });
    }
  }

  Future<void> _authorizeDeviceFlow() async {
    await _saveClientId();
    final clientId = await GitHubImportConfig.getClientId();
    if (clientId == null || clientId.isEmpty) return;

    setState(() {
      _authorizing = true;
      _error = null;
      _authHint = null;
    });

    try {
      final start = await GitHubImportService.requestDeviceCode(clientId);
      if (!mounted) return;

      final open = start.verificationUriComplete ?? start.verificationUri;
      await _openUrl(open);

      setState(() {
        _authHint =
            'Код: ${start.userCode}\nЕсли браузер не подставил код, введите его на github.com/login/device';
      });

      final token = await GitHubImportService.pollDeviceAccessToken(
        clientId: clientId,
        deviceCode: start.deviceCode,
        interval: start.interval,
        expiresIn: start.expiresIn,
        cancelled: () => _pollCancelled,
      );

      if (!mounted) return;
      if (token == null || token.isEmpty) {
        setState(() {
          _authorizing = false;
          _authHint = null;
          _error = 'Авторизация отменена или истекло время. Попробуйте снова.';
        });
        return;
      }

      await GitHubImportConfig.setAccessToken(token);
      setState(() {
        _accessToken = token;
        _authorizing = false;
        _authHint = null;
      });
      await _loadUserAndRepos(token);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _authorizing = false;
        _authHint = null;
        _error = e.toString();
      });
    }
  }

  Future<void> _loadUserAndRepos(String token) async {
    setState(() {
      _loadingRepos = true;
      _error = null;
    });
    try {
      final login = await GitHubImportService.getLogin(token);
      final repos = await GitHubImportService.listRepos(token);
      if (!mounted) return;
      setState(() {
        _githubLogin = login;
        _repos = repos;
        _loadingRepos = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingRepos = false;
        _error = 'Не удалось загрузить репозитории: $e';
      });
    }
  }

  Future<void> _cloneRepo(GitHubRepoItem repo) async {
    final nameCtl = TextEditingController(text: repo.name);
    var overwrite = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1e293b),
        title: const Text('Клонировать на сервер', style: TextStyle(fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              repo.fullName,
              style: const TextStyle(fontSize: 12, color: Color(0xFF94a3b8), fontFamily: 'monospace'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nameCtl,
              decoration: const InputDecoration(
                labelText: 'Папка в ~/projects',
                labelStyle: TextStyle(color: Color(0xFF94a3b8)),
              ),
              style: const TextStyle(fontSize: 13),
            ),
            StatefulBuilder(
              builder: (context, setLocal) => CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Заменить, если уже есть', style: TextStyle(fontSize: 12)),
                value: overwrite,
                onChanged: (v) => setLocal(() => overwrite = v ?? false),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF8b5cf6)),
            child: const Text('Клонировать'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) {
      nameCtl.dispose();
      return;
    }
    final folder = nameCtl.text.trim();
    nameCtl.dispose();
    if (folder.isEmpty) return;

    final api = context.read<AppState>().api;
    try {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        useRootNavigator: true,
        builder: (_) => const Center(
          child: Card(
            color: Color(0xFF1e293b),
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(strokeWidth: 2),
                  SizedBox(height: 16),
                  Text('Клонирование на сервер…', style: TextStyle(fontSize: 13)),
                ],
              ),
            ),
          ),
        ),
      );

      final data = await api.cloneGitHubProject(
        cloneUrl: repo.cloneUrl,
        name: folder,
        githubToken: _accessToken,
        overwrite: overwrite,
      );

      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop(); // close progress

      final path = data['path'] as String?;
      if (path != null && path.isNotEmpty) {
        Navigator.of(context).pop(path);
        return;
      }
      final err = data['error'] ?? 'unknown';
      setState(() => _error = err.toString());
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop(); // progress
      var msg = e.toString();
      if (e is DioException && e.response?.statusCode == 404) {
        final uri = e.requestOptions.uri;
        final isLocal = uri.host == '127.0.0.1' || uri.host == 'localhost';
        final remoteHint = !isLocal
            ? '\n\nСервер ${uri.host} отвечает 404 — на этой машине почти наверняка старая сборка Planulix без клонирования. '
                'Зайдите по SSH на ${uri.host}, обновите каталог server из репозитория, выполните там: '
                'go build -o planulix . и перезапустите процесс с тем же AUTH_TOKEN. '
                'Пока бинарник не обновлён, клонирование на этот хост работать не будет.'
            : '';
        msg =
            'Клонирование: 404. Запрос: $uri.'
            '$remoteHint'
            '\n\nТехнически: $e';
      }
      setState(() => _error = msg);
    }
  }

  Iterable<GitHubRepoItem> get _filteredRepos {
    final q = _search.trim().toLowerCase();
    if (q.isEmpty) return _repos;
    return _repos.where((r) => r.fullName.toLowerCase().contains(q));
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1e293b),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Container(
        width: 520,
        height: 560,
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.code, size: 18, color: Color(0xFF8b5cf6)),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Импорт с GitHub',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
                if (_accessToken != null)
                  TextButton(
                    onPressed: _loadingRepos || _authorizing ? null : _disconnect,
                    child: const Text('Выйти', style: TextStyle(fontSize: 12)),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _browserOAuthAvailable
                  ? 'Откроется обычная страница GitHub: войдите и подтвердите доступ. Client ID и токены в приложение вводить не нужно.'
                  : _clientIdBundled
                      ? 'Нажмите кнопку — откроется GitHub. Client ID уже в сборке. '
                          'Обычно откроется device flow (код на github.com/login/device). '
                          'Редирект на $githubPkceCallbackUrl без ввода кода: при сборке добавьте '
                          '--dart-define=GITHUB_OAUTH_CLIENT_SECRET=… (Client secret этого OAuth App).'
                      : githubPkceSupportedOnPlatform()
                          ? 'Откроется браузер с GitHub. В OAuth App один callback: $githubPkceCallbackUrl. Client ID — в lib/config/github_public_client_id.dart или ниже.'
                          : 'Сервер Planulix пока без браузерного OAuth: вставьте Client ID OAuth App (Device flow) или попросите администратора задать GITHUB_OAUTH_* на сервере.',
              style: const TextStyle(fontSize: 11, color: Color(0xFF64748b), height: 1.35),
            ),
            if (!_hideManualClientIdField) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _clientIdController,
                decoration: InputDecoration(
                  hintText: 'OAuth App Client ID (только запасной режим)',
                  hintStyle: const TextStyle(color: Color(0xFF64748b), fontSize: 12),
                  filled: true,
                  fillColor: const Color(0xFF0f172a),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Color(0xFF334155))),
                ),
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: _saveClientId,
                  child: const Text('Сохранить Client ID', style: TextStyle(fontSize: 12)),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: _authorizing ? null : _authorize,
                  icon: _authorizing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.open_in_browser, size: 14),
                  label: Text(
                    _authorizing
                        ? 'Ожидание…'
                        : (_browserOAuthAvailable || githubPkceSupportedOnPlatform() || _clientIdBundled
                            ? 'Войти через GitHub'
                            : 'Подключить GitHub'),
                    style: const TextStyle(fontSize: 12),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF8b5cf6),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                ),
              ],
            ),
            if (_authHint != null) ...[
              const SizedBox(height: 8),
              Text(_authHint!, style: const TextStyle(fontSize: 12, color: Color(0xFFc4b5fd))),
            ],
            if (_githubLogin != null) ...[
              const SizedBox(height: 8),
              Text('Аккаунт: $_githubLogin', style: const TextStyle(fontSize: 12, color: Color(0xFF94a3b8))),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(fontSize: 12, color: Color(0xFFf87171))),
            ],
            const SizedBox(height: 12),
            const Text(
              'РЕПОЗИТОРИИ',
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Color(0xFF94a3b8), letterSpacing: 0.5),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _searchController,
              onChanged: (v) => setState(() => _search = v),
              enabled: _accessToken != null && !_loadingRepos,
              decoration: InputDecoration(
                hintText: 'Поиск…',
                hintStyle: const TextStyle(color: Color(0xFF64748b), fontSize: 12),
                filled: true,
                fillColor: const Color(0xFF0f172a),
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 16, color: Color(0xFF64748b)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Color(0xFF334155))),
              ),
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _accessToken == null
                  ? const Center(
                      child: Text(
                        'Подключите GitHub, чтобы увидеть список репозиториев.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Color(0xFF64748b), fontSize: 12),
                      ),
                    )
                  : _loadingRepos
                      ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                      : ListView.builder(
                          itemCount: _filteredRepos.length,
                          itemBuilder: (context, i) {
                            final r = _filteredRepos.elementAt(i);
                            return InkWell(
                              onTap: () => _cloneRepo(r),
                              child: Container(
                                margin: const EdgeInsets.only(bottom: 4),
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF0f172a),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: const Color(0xFF334155)),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      r.private ? Icons.lock_outline : Icons.public,
                                      size: 14,
                                      color: const Color(0xFF64748b),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        r.fullName,
                                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                                      ),
                                    ),
                                    const Icon(Icons.download_outlined, size: 14, color: Color(0xFF64748b)),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}
