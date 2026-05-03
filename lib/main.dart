import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'api/client.dart';
import 'providers/app_state.dart';
import 'screens/dashboard/dashboard_screen.dart';
import 'screens/cost/cost_screen.dart';
import 'screens/settings/settings_screen.dart';
import 'screens/desktop/desktop_shell.dart';
import 'screens/onboarding/agent_welcome_screen.dart';
import 'screens/onboarding/connection_welcome_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux) {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }
  runApp(const PlanulixApp());
}

class PlanulixApp extends StatelessWidget {
  const PlanulixApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState(api: ApiClient())..init(),
      child: MaterialApp(
        title: 'Planulix',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF8b5cf6),
            brightness: Brightness.dark,
            surface: const Color(0xFF0f172a),
          ),
          scaffoldBackgroundColor: const Color(0xFF0f172a),
          cardColor: const Color(0xFF1e293b),
          useMaterial3: true,
        ),
        home: Consumer<AppState>(
          builder: (context, state, _) {
            if (state.isLoading &&
                state.sessions.isEmpty &&
                state.api.isConfigured) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }
            if (!state.isConfigured) {
              return const SettingsScreen(isInitial: true);
            }
            return const MainShell();
          },
        ),
      ),
    );
  }
}

class MainShell extends StatefulWidget {
  const MainShell({super.key});
  @override
  State<MainShell> createState() => MainShellState();
}

class MainShellState extends State<MainShell> {
  int _currentIndex = 0;

  final _screens = const [
    DashboardScreen(),
    CostScreen(),
    SettingsScreen(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _runMobileOnboardingSequence());
  }

  Future<void> _runMobileOnboardingSequence() async {
    if (!mounted) return;
    final width = MediaQuery.of(context).size.width;
    if (width >= 900) return;
    final state = context.read<AppState>();
    if (!state.isConfigured) return;

    if (!state.welcomeOnboardingDone) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => const ConnectionWelcomeScreen(),
        ),
      );
      if (!mounted) return;
    }
    _maybeShowAgentOnboarding();
  }

  void _maybeShowAgentOnboarding() {
    if (!mounted) return;
    final width = MediaQuery.of(context).size.width;
    if (width >= 900) return;
    final state = context.read<AppState>();
    if (!state.isConfigured || state.agentOnboardingDone) return;
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => const AgentWelcomeScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // On desktop with wide screens, use IDE-style layout
    final width = MediaQuery.of(context).size.width;
    if (width >= 900) {
      return const DesktopShell();
    }

    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (i) => setState(() => _currentIndex = i),
        backgroundColor: const Color(0xFF1e293b),
        indicatorColor: const Color(0xFF8b5cf6).withAlpha(50),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.terminal_outlined),
            selectedIcon: Icon(Icons.terminal),
            label: 'Sessions',
          ),
          NavigationDestination(
            icon: Icon(Icons.analytics_outlined),
            selectedIcon: Icon(Icons.analytics),
            label: 'Costs',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
