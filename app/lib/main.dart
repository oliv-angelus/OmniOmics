import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'theme/app_theme.dart';
import 'l10n/app_strings.dart';
import 'services/api_client.dart';
import 'services/backend_launcher.dart';
import 'providers.dart';
import 'screens/shell/app_shell.dart';
import 'screens/shell/dependency_gate_screen.dart';

/// Spawns the FastAPI backend and waits for it to be healthy, showing a plain
/// (Riverpod-free) loading screen in the meantime, then calls `runApp` exactly
/// once for the real, Riverpod-backed app with a single root `ProviderScope`.
///
/// Deliberately NOT a nested/conditional ProviderScope inside a StatefulWidget's
/// build: that recreates the inner container (and loses its overrides) on every
/// rebuild of the outer widget -- e.g. the theme toggle rebuilding on
/// `themeModeProvider` would tear down `apiClientProvider`'s override and throw
/// "must be overridden after backend health check". Resolving the backend once,
/// before the one-and-only `runApp` call for the real app, avoids that entirely.
final _launcher = BackendLauncher();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _LoadingApp());
  _boot();
}

Future<void> _boot() async {
  try {
    await _launcher.start();
    final apiClient = ApiClient(baseUrl: _launcher.baseUrl);
    runApp(
      ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(apiClient)],
        child: const _OmniOmicsApp(),
      ),
    );
  } catch (e) {
    runApp(_BootErrorApp(error: e.toString()));
  }
}

class _LoadingApp extends StatelessWidget {
  const _LoadingApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: buildLightTheme(),
      debugShowCheckedModeBanner: false,
      home: const Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Iniciando OmniOmics…'),
            ],
          ),
        ),
      ),
    );
  }
}

class _BootErrorApp extends StatelessWidget {
  final String error;
  const _BootErrorApp({required this.error});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: buildLightTheme(),
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, color: Colors.red, size: 40),
                const SizedBox(height: 16),
                // Bilingual literal: this screen runs outside the root
                // ProviderScope (see runApp above), so the locale provider
                // that ref.t() reads is not available here.
                Text('Falha ao iniciar o backend / Failed to start the backend:\n$error',
                    textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OmniOmicsApp extends ConsumerStatefulWidget {
  const _OmniOmicsApp();

  @override
  ConsumerState<_OmniOmicsApp> createState() => _OmniOmicsAppState();
}

class _OmniOmicsAppState extends ConsumerState<_OmniOmicsApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      _launcher.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModeProvider);
    final locale = ref.watch(localeProvider);
    return MaterialApp(
      title: 'OmniOmics',
      debugShowCheckedModeBanner: false,
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: themeMode,
      locale: locale,
      home: const DependencyGateScreen(next: AppShell()),
    );
  }
}
