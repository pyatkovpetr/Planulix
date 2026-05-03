import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/app_state.dart';

/// First launch: Planulix — opensource self-hosted, Tailscale vs SSH, затем действия в приложении.
class ConnectionWelcomeScreen extends StatefulWidget {
  const ConnectionWelcomeScreen({super.key});

  static const stepCount = 4;

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
    const n = ConnectionWelcomeScreen.stepCount;
    final isLast = _index >= n - 1;
    return Scaffold(
      backgroundColor: const Color(0xFF0f172a),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text(
          'Шаг ${_index + 1} из $n',
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
        centerTitle: true,
        actions: [
          TextButton(onPressed: _finish, child: const Text('Пропустить')),
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
                  title: 'Planulix — ваш сервер, ваш ключ',
                  body:
                      'Открытый исходный код: ставите Gateway (Go) на VPS или домашнюю машину и подключаетесь клиентом. '
                      'Ключи API агентов (Kimi, Claude…) остаются у вас; Planulix лишь маршрутизирует сессии.',
                ),
                _WelcomePage(
                  icon: Icons.vpn_key_outlined,
                  title: 'Через Tailscale',
                  body:
                      'Если Gateway в приватной сети Tailscale (адрес 100.x.x.x), на этом же устройстве войдите в Tailscale. '
                      'Тогда клиент может ходить на http://100.…:8990/api без проброса портов в интернет.',
                ),
                _WelcomePage(
                  icon: Icons.terminal_outlined,
                  title: 'Через SSH на сервер',
                  body:
                      'Подключитесь по SSH и соберите бинарь из репозитория (каталог server). Обязательно задайте AUTH_TOKEN — без него процесс не стартует. '
                      'Дальше в клиенте укажите публичный URL или LAN/Tailscale-адрес с суффиксом /api и тот же токен в поле Bearer.',
                ),
                _WelcomePage(
                  icon: Icons.check_circle_outline,
                  title: 'Дальше в приложении',
                  body:
                      'На экране «Подключение» выберите подсказки Tailscale или SSH, введите Server URL и Auth Token, нажмите «Save & Connect». '
                      'При необходимости заполните «Ключи CLI-агентов». На вкладке Sessions начните с Kimi Code или Claude Code.',
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Row(
              children: [
                ...List.generate(n, (i) {
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
                    await _page.nextPage(
                      duration: const Duration(milliseconds: 280),
                      curve: Curves.easeOutCubic,
                    );
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
