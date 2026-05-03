import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../api/client.dart' show ApiClient;
import '../../models/server_profile.dart';
import '../../providers/app_state.dart';
import '../../services/agent_key_tester.dart';
import '../../services/remote_gateway_installer.dart';
import '../../utils/agent_catalog.dart';
import '../../utils/capabilities_helpers.dart';
import '../../utils/session_filter.dart';
import '../../widgets/vps_gateway_wizard_dialog.dart';
import '../onboarding/connection_welcome_screen.dart';

class SettingsScreen extends StatefulWidget {
  final bool isInitial;
  const SettingsScreen({super.key, this.isInitial = false});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _urlController;
  late TextEditingController _tokenController;
  late TextEditingController _gatewaySshUserController;
  late TextEditingController _gatewaySshPortController;
  late TextEditingController _kimiKeyController;
  late TextEditingController _anthropicKeyController;
  late TextEditingController _openaiKeyController;
  bool _testing = false;
  String? _testResult;
  bool _testingKeys = false;
  String? _keysTestResult;
  bool _agentKeysExpanded = false;

  /// Установка CLI на gateway через `POST /setup/agents/:id/install`.
  final Set<String> _installingAgents = <String>{};

  /// Подсказки на экране подключения: Tailscale (клиент) vs SSH-install gateway на VPS.
  bool _connectViaTailscale = true;

  static const _kPlanulixInstallScript =
      'https://raw.githubusercontent.com/pyatkovpetr/Planulix/main/scripts/install_gateway_remote.sh';

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    final api = state.api;
    _urlController = TextEditingController(text: api.baseUrl);
    _tokenController = TextEditingController(text: api.authToken ?? '');
    final ap = state.activeProfile;
    _gatewaySshUserController = TextEditingController(
      text: (ap?.sshUser ?? '').trim(),
    );
    _gatewaySshPortController = TextEditingController(
      text: '${ap?.resolvedSshPort ?? 22}',
    );
    _kimiKeyController = TextEditingController(
      text: state.agentApiKeys['kimi'] ?? '',
    );
    _anthropicKeyController = TextEditingController(
      text: state.agentApiKeys['anthropic'] ?? '',
    );
    _openaiKeyController = TextEditingController(
      text: state.agentApiKeys['openai'] ?? '',
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(context.read<AppState>().loadCapabilitiesIfNeeded());
    });
  }

  @override
  void dispose() {
    _urlController.dispose();
    _tokenController.dispose();
    _gatewaySshUserController.dispose();
    _gatewaySshPortController.dispose();
    _kimiKeyController.dispose();
    _anthropicKeyController.dispose();
    _openaiKeyController.dispose();
    super.dispose();
  }

  void _syncControllersFromApi(AppState state) {
    _urlController.text = state.api.baseUrl;
    _tokenController.text = state.api.authToken ?? '';
    final p = state.activeProfile;
    if (p != null) {
      _gatewaySshUserController.text = (p.sshUser ?? '').trim();
      _gatewaySshPortController.text = '${p.resolvedSshPort}';
    }
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not open $url')));
      }
    }
  }

  String _tailscaleDownloadUrl() {
    if (Platform.isMacOS) return 'https://tailscale.com/download/macos';
    if (Platform.isIOS) {
      return 'https://apps.apple.com/app/tailscale/id1470499037';
    }
    if (Platform.isAndroid) {
      return 'https://play.google.com/store/apps/details?id=com.tailscale.ipn';
    }
    if (Platform.isWindows) return 'https://tailscale.com/download/windows';
    if (Platform.isLinux) return 'https://tailscale.com/download/linux';
    return 'https://tailscale.com/download';
  }

  String _sshGatewaySetupCommands() {
    return '''# На своём VPS (Linux) после SSH:
ssh user@ваш-сервер-ip

curl -fsSL $_kPlanulixInstallScript \\
  | AUTH_TOKEN='замените-на-свой-секрет' bash -s

# Скрипт скачает готовый бинарник из GitHub Releases и запустит сервис.
# В этом приложении Server URL → http://<IP_или_TS>:8990/api
''';
  }

  Future<void> _openVpsInstallWizard() async {
    final ok = await VpsGatewayWizardDialog.open(context);
    if (!mounted || !ok) return;
    final state = context.read<AppState>();
    setState(() {
      _syncControllersFromApi(state);
    });
  }

  Future<void> _showAddProfileDialog() async {
    final nameC = TextEditingController(text: 'VPS');
    final urlC = TextEditingController(text: _urlController.text);
    final tokC = TextEditingController(text: _tokenController.text);
    final sshUserC =
        TextEditingController(text: _gatewaySshUserController.text.trim());
    final sshPortC =
        TextEditingController(text: _gatewaySshPortController.text.trim());

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1e293b),
        title: const Text(
          'New server profile',
          style: TextStyle(color: Color(0xFFf1f5f9)),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameC,
                style: const TextStyle(color: Color(0xFFe2e8f0)),
                decoration: _dialogFieldDecoration('Display name'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: urlC,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  color: Color(0xFFe2e8f0),
                ),
                decoration: _dialogFieldDecoration('http://100.x.x.x:8990/api'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: tokC,
                obscureText: true,
                style: const TextStyle(color: Color(0xFFe2e8f0)),
                decoration: _dialogFieldDecoration('Auth token'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: sshUserC,
                style: const TextStyle(fontSize: 13, color: Color(0xFFe2e8f0)),
                decoration: _dialogFieldDecoration(
                  'SSH user (oauth browser); пусто = root',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: sshPortC,
                keyboardType: TextInputType.number,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: _dialogFieldDecoration('SSH port (22)'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Add & use'),
          ),
        ],
      ),
    );

    void releaseDialogControllers() {
      nameC.dispose();
      urlC.dispose();
      tokC.dispose();
      sshUserC.dispose();
      sshPortC.dispose();
    }

    if (ok != true || !mounted) {
      releaseDialogControllers();
      return;
    }

    final su = sshUserC.text.trim();
    final sp = int.tryParse(sshPortC.text.trim());
    releaseDialogControllers();

    final state = context.read<AppState>();
    final p = ServerProfile(
      id: const Uuid().v4(),
      name: nameC.text.trim().isEmpty ? 'Server' : nameC.text.trim(),
      baseUrl: urlC.text.trim(),
      token: tokC.text.trim(),
      sshUser: su.isEmpty ? null : su,
      sshPort: (sp != null && sp > 0 && sp < 65536) ? sp : null,
    );
    await state.persistServerProfiles([
      ...state.serverProfiles,
      p,
    ], activateId: p.id);
    await state.activateProfile(p);
    setState(() => _syncControllersFromApi(state));
  }

  static InputDecoration _dialogFieldDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Color(0xFF64748b)),
      filled: true,
      fillColor: const Color(0xFF0f172a),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
    );
  }

  Future<void> _showAgentInstallSheet(
    BuildContext context,
    String command, {
    String? subtitle,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1e293b),
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Установка gateway на сервере',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFFf1f5f9),
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF94a3b8),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                const Text(
                  'В SSH выполните одну команду:',
                  style: TextStyle(fontSize: 13, color: Color(0xFFcbd5e1)),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0f172a),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF334155)),
                  ),
                  child: SelectableText(
                    command,
                    style: const TextStyle(
                      fontSize: 13,
                      fontFamily: 'monospace',
                      color: Color(0xFFe2e8f0),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: command));
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Команда скопирована')),
                      );
                    }
                  },
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Копировать'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.isInitial ? 'Подключение' : 'Настройки',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        backgroundColor: Colors.transparent,
        automaticallyImplyLeading: !widget.isInitial,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.isInitial) ...[
            const Icon(Icons.terminal, size: 64, color: Color(0xFF8b5cf6)),
            const SizedBox(height: 16),
            const Text(
              'Подключение к Planulix',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            const Text(
              'Открытый исходный код: свой gateway на сервере, клиент ниже задаёт только URL API и Bearer-токен.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF94a3b8)),
            ),
            const SizedBox(height: 32),
          ],

          const Text(
            'Как подготовить доступ к gateway',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                label: const Text('Tailscale'),
                selected: _connectViaTailscale,
                onSelected: (_) => setState(() => _connectViaTailscale = true),
              ),
              ChoiceChip(
                label: const Text('SSH · авто-установка gateway'),
                selected: !_connectViaTailscale,
                onSelected: (_) => setState(() => _connectViaTailscale = false),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Независимо от способа внизу укажите один и тот же Server URL (/api в конце) и Auth Token с сервера.',
            style: TextStyle(fontSize: 11, color: Color(0xFF64748b)),
          ),
          const SizedBox(height: 12),
          if (_connectViaTailscale)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF1e293b),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF334155)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Адреса вида 100.x.x.x — это машина вашего VPS в общей Tailscale-сети. '
                    'Установите приложение здесь и войдите в тот же tailnet.',
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.35,
                      color: Color(0xFFcbd5e1),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    onPressed: () => _openUrl(_tailscaleDownloadUrl()),
                    icon: const Icon(Icons.download_outlined, size: 18),
                    label: const Text('Клиент Tailscale для этой ОС'),
                  ),
                ],
              ),
            )
          else
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF1e293b),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF334155)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Мастер подключится по SSH, скачает готовый Linux-бинарник из GitHub Releases, '
                    'запустит gateway как сервис и сохранит тот же AUTH_TOKEN в приложении.',
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.35,
                      color: Color(0xFFcbd5e1),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    onPressed: () => _showAgentInstallSheet(
                      context,
                      _sshGatewaySetupCommands(),
                      subtitle:
                          'Подставьте пользователя, IP и токен. Скрипт скачает готовый бинарник и запустит сервис.',
                    ),
                    icon: const Icon(Icons.copy_all_outlined, size: 18),
                    label: const Text('Команды для SSH-сессии'),
                  ),
                  if (remoteGatewayInstallSupported) ...[
                    const SizedBox(height: 10),
                    FilledButton.icon(
                      onPressed: _openVpsInstallWizard,
                      icon: const Icon(Icons.cloud_sync_outlined, size: 20),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF7c3aed),
                      ),
                      label: const Text('Подключить VPS по SSH — мастер'),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Обычно нужны только SSH-доступ и curl/tar. Если systemd недоступен, будет nohup fallback.',
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.3,
                        color: Color(0xFF94a3b8),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          const SizedBox(height: 20),
          const Text(
            'Server profile',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0f172a),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF334155)),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<ServerProfile>(
                      isExpanded: true,
                      dropdownColor: const Color(0xFF1e293b),
                      value: () {
                        final id = state.activeProfileId;
                        if (id == null) return null;
                        for (final p in state.serverProfiles) {
                          if (p.id == id) return p;
                        }
                        return state.serverProfiles.isEmpty
                            ? null
                            : state.serverProfiles.first;
                      }(),
                      hint: const Text(
                        'Select server…',
                        style: TextStyle(color: Color(0xFF64748b)),
                      ),
                      items: state.serverProfiles
                          .map(
                            (p) => DropdownMenuItem(
                              value: p,
                              child: Text(
                                p.name,
                                style: const TextStyle(
                                  fontSize: 14,
                                  color: Color(0xFFe2e8f0),
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: state.serverProfiles.isEmpty
                          ? null
                          : (p) async {
                              if (p == null) return;
                              await state.activateProfile(p);
                              if (mounted) {
                                setState(() => _syncControllersFromApi(state));
                              }
                            },
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                onPressed: _showAddProfileDialog,
                icon: const Icon(Icons.add),
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xFF334155),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Each profile is its own Planulix API (URL + token). Sessions come from the machine running that API.',
            style: TextStyle(fontSize: 11, color: Color(0xFF64748b)),
          ),
          const SizedBox(height: 20),
          const Text(
            'Session filters',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          const Text(
            'Agent (whose sessions) and list scope (starred, active, …) apply on the dashboard and desktop sidebar.',
            style: TextStyle(fontSize: 11, color: Color(0xFF64748b)),
          ),
          const SizedBox(height: 10),
          const Text(
            'Agent',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: Color(0xFF94a3b8),
            ),
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF0f172a),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                isExpanded: true,
                dropdownColor: const Color(0xFF1e293b),
                value: kAgentScopeOptions.contains(state.agentScope)
                    ? state.agentScope
                    : 'All',
                items: kAgentScopeOptions
                    .map(
                      (f) => DropdownMenuItem(
                        value: f,
                        child: Text(
                          f,
                          style: const TextStyle(
                            color: Color(0xFFe2e8f0),
                            fontSize: 14,
                          ),
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (v) async {
                  if (v == null) return;
                  await state.setAgentScope(v);
                  setState(() {});
                },
              ),
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'List',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: Color(0xFF94a3b8),
            ),
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF0f172a),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                isExpanded: true,
                dropdownColor: const Color(0xFF1e293b),
                value: kListScopeOptions.contains(state.listScope)
                    ? state.listScope
                    : 'All',
                items: kListScopeOptions
                    .map(
                      (f) => DropdownMenuItem(
                        value: f,
                        child: Text(
                          f,
                          style: const TextStyle(
                            color: Color(0xFFe2e8f0),
                            fontSize: 14,
                          ),
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (v) async {
                  if (v == null) return;
                  await state.setListScope(v);
                  setState(() {});
                },
              ),
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Server URL',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _urlController,
            decoration: _inputDecoration('http://100.x.x.x:8990/api'),
            style: const TextStyle(fontSize: 14, fontFamily: 'monospace'),
          ),
          const SizedBox(height: 16),
          const Text(
            'Auth Token',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _tokenController,
            decoration: _inputDecoration('Bearer token'),
            style: const TextStyle(fontSize: 14),
            obscureText: true,
          ),
          const SizedBox(height: 20),
          const Text(
            'SSH до gateway',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          const Text(
            'Для «Remote Browser» и OAuth через IP VPS (SOCKS на тот же хост, что в Server URL): пользователь SSH и порт. Пустой пользователь = root.',
            style: TextStyle(fontSize: 11, color: Color(0xFF64748b), height: 1.35),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _gatewaySshUserController,
            decoration: _inputDecoration('SSH user (обычно root)'),
            style: const TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _gatewaySshPortController,
            keyboardType: TextInputType.number,
            decoration: _inputDecoration('SSH port'),
            style: const TextStyle(fontSize: 14, fontFamily: 'monospace'),
          ),
          const SizedBox(height: 24),
          if (_testResult != null) _testBanner(),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _testing ? null : _testConnection,
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Color(0xFF334155)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: _testing
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Test connection'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _save,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF8b5cf6),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    widget.isInitial ? 'Save & Connect' : 'Save',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () async {
              await state.resetWelcomeOnboarding();
              if (!context.mounted) return;
              await Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  fullscreenDialog: true,
                  builder: (_) => const ConnectionWelcomeScreen(),
                ),
              );
            },
            icon: const Icon(Icons.school_outlined, size: 20),
            label: const Text('Показать вводный тур снова'),
          ),

          const SizedBox(height: 20),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(top: 8),
            title: const Text(
              'Ключи CLI-агентов',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            subtitle: const Text(
              'Сохраняются на устройстве. При создании сессии и при отправке (resume) передаются на сервер в agentEnv '
              '(KIMI_API_KEY, KIMI_BASE_URL, MOONSHOT_*, ANTHROPIC_API_KEY, OPENAI_API_KEY) и подмешиваются в bash перед агентом.',
              style: TextStyle(fontSize: 11, color: Color(0xFF64748b)),
            ),
            initiallyExpanded: _agentKeysExpanded,
            onExpansionChanged: (x) => setState(() => _agentKeysExpanded = x),
            children: [
              TextField(
                controller: _kimiKeyController,
                obscureText: true,
                decoration: _inputDecoration('Moonshot / Kimi API key'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Международный Moonshot (api.moonshot.ai)',
                  style: TextStyle(fontSize: 13),
                ),
                subtitle: const Text(
                  'Вкл. для ключей с platform.moonshot.ai — в agentEnv уйдут MOONSHOT_BASE_URL и KIMI_BASE_URL (.ai). Выкл. для platform.moonshot.cn. После смены начните новую сессию в чате.',
                  style: TextStyle(fontSize: 11, color: Color(0xFF64748b)),
                ),
                value: state.moonshotInternational,
                onChanged: (v) => state.setMoonshotInternational(v),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _anthropicKeyController,
                obscureText: true,
                decoration: _inputDecoration('Anthropic API key'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _openaiKeyController,
                obscureText: true,
                decoration: _inputDecoration('OpenAI API key'),
              ),
              if (_keysTestResult != null) ...[
                const SizedBox(height: 8),
                Text(
                  _keysTestResult!,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF94a3b8),
                    height: 1.3,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: _testingKeys
                        ? null
                        : () async {
                            setState(() {
                              _testingKeys = true;
                              _keysTestResult = null;
                            });
                            try {
                              final r = await AgentKeyTester.testAll(
                                kimi: _kimiKeyController.text,
                                anthropic: _anthropicKeyController.text,
                                openai: _openaiKeyController.text,
                              );
                              if (!mounted) return;
                              setState(() {
                                _testingKeys = false;
                                _keysTestResult = r.entries
                                    .map((e) => '${e.key}: ${e.value}')
                                    .join('\n');
                              });
                            } catch (e) {
                              if (!mounted) return;
                              setState(() {
                                _testingKeys = false;
                                _keysTestResult = e.toString();
                              });
                            }
                          },
                    child: _testingKeys
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Проверить ключи'),
                  ),
                  FilledButton(
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      await state.persistAgentApiKeys({
                        'kimi': _kimiKeyController.text,
                        'anthropic': _anthropicKeyController.text,
                        'openai': _openaiKeyController.text,
                      });
                      if (!context.mounted) return;
                      messenger.showSnackBar(
                        const SnackBar(content: Text('Ключи сохранены')),
                      );
                    },
                    child: const Text('Сохранить'),
                  ),
                ],
              ),
            ],
          ),

          if (state.api.isConfigured) ...[
            const SizedBox(height: 20),
            _buildAgentCliInstallPanel(context, state),
          ],

          if (!widget.isInitial) ...[
            const SizedBox(height: 24),
            const Divider(color: Color(0xFF334155)),
            const SizedBox(height: 16),
            const Text(
              'Network diagnostics',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const _ConnectionDiagnostics(),

            const SizedBox(height: 24),
            const Divider(color: Color(0xFF334155)),
            const SizedBox(height: 16),
            const Text(
              'About',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1e293b),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF334155)),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Planulix v1.0.0',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'AI coding agent session manager',
                    style: TextStyle(fontSize: 13, color: Color(0xFF94a3b8)),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _testBanner() {
    return Container(
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: _testResult == 'ok'
            ? const Color(0xFF22c55e).withAlpha(30)
            : const Color(0xFFef4444).withAlpha(30),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        _testResult == 'ok' ? 'Connection successful!' : 'Error: $_testResult',
        style: TextStyle(
          color: _testResult == 'ok'
              ? const Color(0xFF22c55e)
              : const Color(0xFFef4444),
          fontSize: 13,
        ),
      ),
    );
  }

  Future<void> _testConnection() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });

    try {
      final url = _urlController.text.trim();
      final token = _tokenController.text.trim();
      final testApi = ApiClient(baseUrl: url);
      await testApi.saveSettings(url, token);
      await testApi.pingHealthz(url, timeout: const Duration(seconds: 25));
      await testApi.getSessions(limit: 1);
      setState(() => _testResult = 'ok');
    } catch (e) {
      setState(() => _testResult = 'URL: ${_urlController.text.trim()}\n$e');
    } finally {
      setState(() => _testing = false);
    }
  }

  Widget _buildAgentCliInstallPanel(BuildContext context, AppState state) {
    final entries = kAgentCatalog.where((e) => scopeHasInstallableCli(e.id));
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1e293b),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'CLI-агенты на сервере',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Color(0xFFf1f5f9),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Planulix видит сессии из файлов конкретных CLI. Если агент выбран в Switch agent, но чат не стартует — сначала поставьте его CLI на ту же машину, где работает gateway.',
            style: TextStyle(fontSize: 12, height: 1.35, color: Color(0xFF94a3b8)),
          ),
          const SizedBox(height: 12),
          ...entries.map((e) {
            final setupId = setupAgentIdForScope(e.id);
            final installed = agentInstalledFromCapabilities(
              state.capabilitiesSnapshot,
              setupId,
            );
            final installing = _installingAgents.contains(setupId);
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF0f172a),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: installed
                        ? const Color(0xFF22c55e).withAlpha(100)
                        : const Color(0xFF334155),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(e.icon, size: 20, color: e.accent),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            e.title,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              color: Color(0xFFe2e8f0),
                            ),
                          ),
                        ),
                        Icon(
                          installed
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                          size: 18,
                          color: installed
                              ? const Color(0xFF22c55e)
                              : const Color(0xFF64748b),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _agentInstallNote(e.id),
                      style: const TextStyle(
                        fontSize: 11,
                        height: 1.35,
                        color: Color(0xFF94a3b8),
                      ),
                    ),
                    if (!installed) ...[
                      const SizedBox(height: 10),
                      FilledButton.icon(
                        onPressed: installing
                            ? null
                            : () => _installAgentCliFromServer(
                                  context,
                                  state,
                                  setupId,
                                  e.title,
                                ),
                        icon: installing
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.downloading_outlined, size: 20),
                        style: FilledButton.styleFrom(
                          backgroundColor: e.accent.withAlpha(210),
                        ),
                        label: Text(
                          installing
                              ? 'Установка на сервере…'
                              : 'Установить ${e.title} на сервер',
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  String _agentInstallNote(String scope) {
    switch (scope) {
      case 'Claude':
        return 'Команда: claude. Сессии: ~/.claude/sessions/**/*.jsonl. Чат/таски уже поддержаны; нужен ANTHROPIC_API_KEY или claude auth login.';
      case 'Kimi':
        return 'Команда: kimi. Сессии: ~/.kimi/sessions/*/<id>/context.jsonl. Чат/таски уже поддержаны; нужен KIMI_API_KEY/MOONSHOT_API_KEY или config/login Kimi.';
      case 'Codex':
        return 'Команда: codex. Сессии читаются из ~/.codex/**/*.jsonl. Сейчас Planulix показывает историю; запуск/резюм Codex из чата будет отдельным шагом.';
      case 'Cursor':
        return 'Команда Cursor CLI: agent. Planulix читает ~/.cursor/projects/**/agent-transcripts/*.jsonl; это в основном просмотр транскриптов.';
      case 'Kiro':
        return 'Команда: kiro-cli/kiro. Данные: ~/.local/share/kiro-cli (Linux). Требуется login через браузер; запуск из UI пока не подключён.';
      case 'OpenCode':
        return 'Команда: opencode. Данные: ~/.local/share/opencode. Planulix пока ищет JSON/JSONL экспорты/логи; запуск из UI позже.';
      default:
        return '';
    }
  }

  Future<void> _installAgentCliFromServer(
    BuildContext context,
    AppState state,
    String agentId,
    String label,
  ) async {
    if (_installingAgents.contains(agentId)) return;
    setState(() => _installingAgents.add(agentId));
    Map<String, dynamic>? res;
    Object? thrown;
    try {
      res = await state.api.setupAgentInstall(agentId);
    } catch (e, st) {
      thrown = e;
      debugPrint('setupAgentInstall($agentId) $e\n$st');
    }
    if (!context.mounted) return;
    setState(() => _installingAgents.remove(agentId));

    await state.loadCapabilitiesIfNeeded();
    if (!context.mounted) return;

    if (thrown != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Сеть/API: $thrown')),
      );
      return;
    }

    final ok = res?['ok'] == true;
    final log = '${res?['log'] ?? ''}'.trim();
    final err = '${res?['error'] ?? ''}'.trim();

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1e293b),
        title: Text(
          ok
              ? '$label установлен'
              : 'Установка не удалась полностью',
          style: const TextStyle(color: Color(0xFFf1f5f9), fontSize: 18),
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (err.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    err,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFFf87171),
                      height: 1.3,
                    ),
                  ),
                ),
              if (log.isNotEmpty)
                SelectableText(
                  log,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: Color(0xFFcbd5e1),
                    height: 1.35,
                  ),
                )
              else
                const Text(
                  'Нет текста лога от сервера.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF94a3b8)),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Готово. При необходимости сохраните API key/login для $label и обновите сессии.'
              : 'Смотрите лог в диалоге или ставьте CLI вручную по SSH.',
        ),
      ),
    );
  }

  Future<void> _save() async {
    try {
      final messenger = ScaffoldMessenger.of(context);
      final state = context.read<AppState>();
      await state.configure(_urlController.text, _tokenController.text);
      final sshPort = int.tryParse(_gatewaySshPortController.text.trim()) ?? 22;
      await state.saveGatewaySshForActiveProfile(
        sshUserRaw: _gatewaySshUserController.text,
        sshPort: sshPort,
      );
      if (!context.mounted) return;
      setState(() => _testResult = 'ok');
      messenger.showSnackBar(const SnackBar(content: Text('Saved')));
    } catch (e) {
      if (!context.mounted) return;
      setState(() => _testResult = e.toString());
    }
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

class _ConnectionDiagnostics extends StatefulWidget {
  const _ConnectionDiagnostics();

  @override
  State<_ConnectionDiagnostics> createState() => _ConnectionDiagnosticsState();
}

class _CheckResult {
  final String label;
  final String? detail;
  final _CheckStatus status;
  final int? latencyMs;
  _CheckResult({
    required this.label,
    this.detail,
    required this.status,
    this.latencyMs,
  });
}

enum _CheckStatus { pending, running, ok, fail }

class _ConnectionDiagnosticsState extends State<_ConnectionDiagnostics> {
  final Map<String, _CheckResult> _results = {};
  bool _running = false;
  Map<String, dynamic>? _networkInfo;

  @override
  void initState() {
    super.initState();
    _runAllChecks();
  }

  void _set(String key, _CheckResult r) {
    if (mounted) setState(() => _results[key] = r);
  }

  Future<void> _runAllChecks() async {
    if (_running) return;
    setState(() {
      _running = true;
      _results.clear();
    });

    final api = context.read<AppState>().api;

    _set(
      'api',
      _CheckResult(label: 'API /healthz', status: _CheckStatus.running),
    );
    try {
      final ms = await api.pingHealthz(
        api.baseUrl,
        timeout: const Duration(seconds: 20),
      );
      _set(
        'api',
        _CheckResult(
          label: 'API /healthz',
          status: _CheckStatus.ok,
          latencyMs: ms,
          detail: api.baseUrl,
        ),
      );
    } catch (e) {
      _set(
        'api',
        _CheckResult(
          label: 'API /healthz',
          status: _CheckStatus.fail,
          detail: e.toString(),
        ),
      );
    }

    _set(
      'auth',
      _CheckResult(label: 'Auth token', status: _CheckStatus.running),
    );
    try {
      await api.getSessions(limit: 1);
      _set(
        'auth',
        _CheckResult(
          label: 'Auth token',
          status: _CheckStatus.ok,
          detail: 'Token accepted',
        ),
      );
    } catch (e) {
      _set(
        'auth',
        _CheckResult(
          label: 'Auth token',
          status: _CheckStatus.fail,
          detail: e.toString(),
        ),
      );
    }

    _set(
      'caps',
      _CheckResult(label: 'Agents & models', status: _CheckStatus.running),
    );
    try {
      final caps = await api.getCapabilities();
      final agents = (caps['agents'] as List? ?? []).whereType<Map>().toList();
      final summary = agents
          .map((a) {
            final label = (a['label'] ?? a['id'] ?? 'agent').toString();
            final installed = a['installed'] == true ? 'installed' : 'missing';
            final models = (a['models'] as List? ?? []).length;
            return '$label $installed, $models models';
          })
          .join(' · ');
      _set(
        'caps',
        _CheckResult(
          label: 'Agents & models',
          status: _CheckStatus.ok,
          detail: summary.isEmpty ? 'No agents reported' : summary,
        ),
      );
    } catch (e) {
      _set(
        'caps',
        _CheckResult(
          label: 'Agents & models',
          status: _CheckStatus.fail,
          detail: e.toString(),
        ),
      );
    }

    _set(
      'net',
      _CheckResult(label: 'Server network info', status: _CheckStatus.running),
    );
    try {
      final info = await api.getNetworkInfo();
      _networkInfo = info;
      final ifaces = info['interfaces'] as List? ?? [];
      _set(
        'net',
        _CheckResult(
          label: 'Server network info',
          status: _CheckStatus.ok,
          detail: '${ifaces.length} interfaces',
        ),
      );
    } catch (e) {
      _set(
        'net',
        _CheckResult(
          label: 'Server network info',
          status: _CheckStatus.fail,
          detail: e.toString(),
        ),
      );
    }

    if (_networkInfo != null) {
      final ifaces = (_networkInfo!['interfaces'] as List?) ?? [];
      for (final iface in ifaces) {
        final kind = iface['kind'] as String;
        if (kind == 'loopback' || kind == 'docker' || kind == 'other') continue;
        final ips = (iface['ips'] as List).cast<String>();
        for (final ip in ips) {
          final key = '$kind:$ip';
          final label = _kindLabel(kind, iface['name'] as String);
          _set(
            key,
            _CheckResult(
              label: label,
              status: _CheckStatus.running,
              detail: ip,
            ),
          );
          final ms = await _tcpProbe(
            ip,
            (_networkInfo!['port'] as num).toInt(),
          );
          if (ms != null) {
            _set(
              key,
              _CheckResult(
                label: label,
                status: _CheckStatus.ok,
                latencyMs: ms,
                detail: ip,
              ),
            );
          } else {
            _set(
              key,
              _CheckResult(
                label: label,
                status: _CheckStatus.fail,
                detail: '$ip unreachable',
              ),
            );
          }
        }
      }
    }

    _set(
      'public',
      _CheckResult(label: 'Public port 8990', status: _CheckStatus.running),
    );
    final publicMs = await _tcpProbe('82.26.93.158', 8990);
    if (publicMs == null) {
      _set(
        'public',
        _CheckResult(
          label: 'Public port 8990',
          status: _CheckStatus.ok,
          detail: 'Blocked (good)',
        ),
      );
    } else {
      _set(
        'public',
        _CheckResult(
          label: 'Public port 8990',
          status: _CheckStatus.fail,
          detail: 'Exposed to internet!',
        ),
      );
    }

    if (mounted) setState(() => _running = false);
  }

  String _kindLabel(String kind, String ifaceName) {
    switch (kind) {
      case 'tailscale':
        return 'Tailscale ($ifaceName)';
      case 'amnezia':
        return 'Amnezia VPN ($ifaceName)';
      case 'public':
        return 'Public ($ifaceName)';
      default:
        return ifaceName;
    }
  }

  Future<int?> _tcpProbe(String host, int port) async {
    final sw = Stopwatch()..start();
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 3),
      );
      sw.stop();
      socket.destroy();
      return sw.elapsedMilliseconds;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
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
              const Text(
                'Connectivity checks',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF94a3b8),
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _running ? null : _runAllChecks,
                icon: _running
                    ? const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 1.5),
                      )
                    : const Icon(Icons.refresh, size: 14),
                label: const Text('Run tests', style: TextStyle(fontSize: 11)),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF8b5cf6),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (_results.isEmpty)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Running checks...',
                style: TextStyle(fontSize: 11, color: Color(0xFF64748b)),
              ),
            )
          else
            ..._results.entries.map((e) => _buildRow(e.value)),
        ],
      ),
    );
  }

  Widget _buildRow(_CheckResult r) {
    IconData icon;
    Color color;
    switch (r.status) {
      case _CheckStatus.pending:
        icon = Icons.remove_circle_outline;
        color = const Color(0xFF64748b);
        break;
      case _CheckStatus.running:
        icon = Icons.more_horiz;
        color = const Color(0xFFf59e0b);
        break;
      case _CheckStatus.ok:
        icon = Icons.check_circle;
        color = const Color(0xFF22c55e);
        break;
      case _CheckStatus.fail:
        icon = Icons.cancel;
        color = const Color(0xFFef4444);
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
      margin: const EdgeInsets.only(bottom: 3),
      decoration: BoxDecoration(
        color: const Color(0xFF0f172a),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.label,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFFcbd5e1),
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (r.detail != null)
                  Text(
                    r.detail!,
                    style: const TextStyle(
                      fontSize: 10,
                      color: Color(0xFF64748b),
                      fontFamily: 'monospace',
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          if (r.latencyMs != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF22c55e).withAlpha(25),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                '${r.latencyMs}ms',
                style: const TextStyle(
                  fontSize: 10,
                  color: Color(0xFF22c55e),
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
