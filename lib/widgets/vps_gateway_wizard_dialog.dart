import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../providers/app_state.dart';
import '../services/remote_gateway_installer.dart';

/// Мастер: установка gateway на VPS по SSH и автоподключение клиента (только desktop).
/// Основной путь быстрый: скачать готовый Linux-бинарник из GitHub Releases.
class VpsGatewayWizardDialog extends StatefulWidget {
  const VpsGatewayWizardDialog({super.key, required this.installScript});

  final String installScript;

  /// `true`, если установка успешно завершилась и клиент сохранил URL/токен.
  static Future<bool> open(BuildContext context) async {
    if (!remoteGatewayInstallSupported) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Авто-установка по SSH доступна в десктопном приложении (macOS / Windows / Linux).',
          ),
        ),
      );
      return false;
    }
    final bundle = DefaultAssetBundle.of(context);
    late final String script;
    try {
      script = await bundle.loadString('scripts/install_gateway_remote.sh');
    } catch (e) {
      if (!context.mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось загрузить скрипт установки: $e')),
      );
      return false;
    }
    if (!context.mounted) return false;
    final r = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => VpsGatewayWizardDialog(installScript: script),
    );
    return r ?? false;
  }

  @override
  State<VpsGatewayWizardDialog> createState() => _VpsGatewayWizardDialogState();
}

class _VpsGatewayWizardDialogState extends State<VpsGatewayWizardDialog> {
  final _page = PageController();
  int _step = 0;

  final _hostC = TextEditingController();
  final _userC = TextEditingController(text: 'root');
  final _portC = TextEditingController(text: '22');
  final _keyPathC = TextEditingController();
  late final TextEditingController _tokenC;

  bool _busy = false;
  final _logLines = <String>[];
  RemoteGatewayInstallResult? _result;

  static const _stepCount = 3;

  @override
  void initState() {
    super.initState();
    _tokenC = TextEditingController(text: const Uuid().v4());
  }

  @override
  void dispose() {
    _page.dispose();
    _hostC.dispose();
    _userC.dispose();
    _portC.dispose();
    _keyPathC.dispose();
    _tokenC.dispose();
    super.dispose();
  }

  Future<void> _pickKey() async {
    final r = await FilePicker.platform.pickFiles(
      dialogTitle: 'Приватный ключ SSH',
      allowMultiple: false,
    );
    final p = r?.files.single.path;
    if (p != null && mounted) {
      setState(() => _keyPathC.text = p);
    }
  }

  Future<void> _runInstall() async {
    final host = _hostC.text.trim();
    final user = _userC.text.trim();
    final port = int.tryParse(_portC.text.trim()) ?? 22;
    final tok = _tokenC.text.trim();

    if (host.isEmpty || user.isEmpty || tok.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Заполните хост, пользователя и токен')),
      );
      return;
    }

    setState(() {
      _busy = true;
      _logLines.clear();
      _result = null;
    });

    final res = await runRemoteGatewayInstall(
      host: host,
      sshUser: user,
      sshPort: port,
      identityFilePath: _keyPathC.text.trim().isEmpty
          ? null
          : _keyPathC.text.trim(),
      authToken: tok,
      bashScriptBody: widget.installScript,
      onLog: (line) {
        if (mounted) {
          setState(() {
            _logLines.add(line);
            if (_logLines.length > 500) {
              _logLines.removeAt(0);
            }
          });
        }
      },
    );

    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = res;
    });

    if (res.ok) {
      final base = 'http://$host:8990/api';
      if (!mounted) return;
      final state = context.read<AppState>();
      await state.configure(base, tok);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Подключено: $base'),
          backgroundColor: Colors.green.shade800,
        ),
      );
      Navigator.of(context).pop(true);
      return;
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Ошибка установки (код ${res.exitCode}). См. журнал ниже.',
          ),
          backgroundColor: Colors.red.shade900,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    final dlgW = w > 720 ? 560.0 : w * 0.92;

    return Dialog(
      backgroundColor: const Color(0xFF0f172a),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: SizedBox(
        width: dlgW,
        height: MediaQuery.sizeOf(context).height * 0.82,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
              child: Row(
                children: [
                  const Icon(Icons.router_outlined, color: Color(0xFF8b5cf6)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Шаг ${_step + 1} из $_stepCount · VPS и SSH',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _busy ? null : () => Navigator.pop(context, false),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PageView(
                controller: _page,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (i) => setState(() => _step = i),
                children: [
                  _stepConnection(),
                  _stepToken(),
                  _stepRun(),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  if (_step > 0)
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () {
                              _page.previousPage(
                                duration: const Duration(milliseconds: 240),
                                curve: Curves.easeOutCubic,
                              );
                            },
                      child: const Text('Назад'),
                    ),
                  const Spacer(),
                  if (_step < _stepCount - 1)
                    FilledButton(
                      onPressed: _busy
                          ? null
                          : () {
                              if (_step == 0) {
                                if (_hostC.text.trim().isEmpty ||
                                    _userC.text.trim().isEmpty) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Укажите хост и пользователя SSH'),
                                    ),
                                  );
                                  return;
                                }
                              }
                              _page.nextPage(
                                duration: const Duration(milliseconds: 240),
                                curve: Curves.easeOutCubic,
                              );
                            },
                      child: const Text('Далее'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stepConnection() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      children: [
        const Text(
          'Нужен Linux VPS с SSH. Мастер скачает готовый gateway-бинарник из GitHub Releases, '
          'запустит его через systemd (или nohup fallback) и проверит /healthz. '
          'Если используете Tailscale, введите Tailscale-IP сервера (100.x.x.x).',
          style: TextStyle(fontSize: 13, color: Color(0xFF94a3b8), height: 1.35),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _hostC,
          decoration: const InputDecoration(
            labelText: 'Хост (IP или DNS)',
            hintText: '203.0.113.10',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _userC,
          decoration: const InputDecoration(
            labelText: 'Пользователь SSH',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _portC,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Порт SSH',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _keyPathC,
          readOnly: true,
          decoration: InputDecoration(
            labelText: 'Приватный ключ (опционально)',
            hintText: 'Пусто — ~/.ssh из ssh-agent',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: const Icon(Icons.folder_open_outlined),
              onPressed: _busy ? null : _pickKey,
            ),
          ),
        ),
      ],
    );
  }

  Widget _stepToken() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      children: [
        const Text(
          'Этот токен задаёт AUTH_TOKEN на сервере и Auth Token в приложении '
          '(сервер ожидает тот же секрет без префикса Bearer). При необходимости сгенерируйте новый.',
          style: TextStyle(fontSize: 13, color: Color(0xFF94a3b8), height: 1.35),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _tokenC,
          maxLines: 2,
          decoration: InputDecoration(
            labelText: 'Секрет (AUTH_TOKEN)',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: const Icon(Icons.refresh_outlined),
              onPressed: _busy
                  ? null
                  : () => setState(() => _tokenC.text = const Uuid().v4()),
            ),
          ),
        ),
      ],
    );
  }

  Widget _stepRun() {
    final host = _hostC.text.trim();
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      children: [
        Text(
          'Будет выполнено: ssh → download release binary → systemd/nohup → healthcheck на $host. '
          'После успеха URL http://$host:8990/api и токен автоматически сохранятся в приложении.',
          style: const TextStyle(fontSize: 13, color: Color(0xFF94a3b8), height: 1.35),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: (_busy || host.isEmpty) ? null : _runInstall,
          icon: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.cloud_upload_outlined),
          label: Text(_busy ? 'Установка…' : 'Установить и подключить'),
        ),
        if (_busy) ...[
          const SizedBox(height: 12),
          const LinearProgressIndicator(color: Color(0xFF8b5cf6)),
        ],
        if (_result != null && !_result!.ok) ...[
          const SizedBox(height: 12),
          Text(
            'Код выхода: ${_result!.exitCode}',
            style: TextStyle(color: Colors.red.shade300),
          ),
        ],
        const SizedBox(height: 12),
        const Text(
          'Журнал',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        ),
        const SizedBox(height: 8),
        Container(
          height: 220,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFF020617),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF334155)),
          ),
          child: SingleChildScrollView(
            child: SelectableText(
              _logLines.isEmpty ? '—' : _logLines.join('\n'),
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                height: 1.25,
                color: Color(0xFFe2e8f0),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
