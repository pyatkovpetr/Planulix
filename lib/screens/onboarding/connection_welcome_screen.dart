import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/app_state.dart';

/// First-launch welcome: positions Planulix as desktop + mobile client for Kimi/Claude sessions; Direct vs Planulix Cloud.
class ConnectionWelcomeScreen extends StatefulWidget {
  const ConnectionWelcomeScreen({super.key});

  @override
  State<ConnectionWelcomeScreen> createState() => _ConnectionWelcomeScreenState();
}

class _ConnectionWelcomeScreenState extends State<ConnectionWelcomeScreen> {
  final _page = PageController();
  int _index = 0;

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    await context.read<AppState>().completeWelcomeOnboarding();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isLast = _index >= 2;
    return Scaffold(
      backgroundColor: const Color(0xFF0f172a),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text('Шаг ${_index + 1} из 3', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: _finish,
            child: const Text('Пропустить'),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView(
              controller: _page,
              onPageChanged: (i) => setState(() => _index = i),
              children: const [
                _WelcomePage(
                  icon: Icons.rocket_launch_outlined,
                  title: 'Добро пожаловать в Planulix',
                  body:
                      'Planulix — десктопный и мобильный клиент для управления сессиями Kimi Code и Claude Code на вашем сервере (остальные coding CLI — опционально). '
                      'Два режима: напрямую к вашему Planulix API или через облачную панель Planulix Cloud.',
                ),
                _WelcomePage(
                  icon: Icons.hub_outlined,
                  title: 'Два способа подключения',
                  body:
                      'Прямой (Direct) — URL и токен вашего Planulix-сервера на VPS или локальной машине. '
                      'Сессии Kimi/Claude и чат идут через него.\n\n'
                      'Planulix Cloud — вход по email и паролю в control plane: видите зарегистрированные серверы, '
                      'онлайн-статус и лимиты usage. Чат с сессиями пока открывается в режиме Direct (добавьте профиль того же сервера).',
                ),
                _WelcomePage(
                  icon: Icons.check_circle_outline,
                  title: 'Что сделать дальше',
                  body:
                      '1. Откройте «Настройки» и выберите режим.\n'
                      '2. Для Direct: введите URL вида https://…:8990/api и AUTH_TOKEN с сервера.\n'
                      '3. Для Planulix Cloud: сохраните URL API (без /api), войдите — затем на VPS установите агент по README репозитория Planulix Cloud.\n'
                      '4. На вкладке «Sessions» выберите источник сессий: в первую очередь Kimi Code или Claude Code (или другой CLI).',
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Row(
              children: [
                ...List.generate(3, (i) {
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        height: 4,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(2),
                          color: i == _index ? const Color(0xFF8b5cf6) : const Color(0xFF334155),
                        ),
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: const Color(0xFF8b5cf6),
                ),
                onPressed: () async {
                  if (isLast) {
                    await _finish();
                  } else {
                    await _page.nextPage(duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
                  }
                },
                child: Text(isLast ? 'Понятно, поехали' : 'Далее'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WelcomePage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;

  const _WelcomePage({
    required this.icon,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        const SizedBox(height: 12),
        Icon(icon, size: 56, color: const Color(0xFF8b5cf6)),
        const SizedBox(height: 20),
        Text(
          title,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, height: 1.2),
        ),
        const SizedBox(height: 16),
        Text(
          body,
          style: const TextStyle(fontSize: 15, height: 1.45, color: Color(0xFF94a3b8)),
        ),
      ],
    );
  }
}
