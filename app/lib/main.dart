import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/home_screen.dart';
import 'services/app_log.dart';
import 'services/debug/bootstrap.dart' as debug_bootstrap;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Первый read `appStartedAt` фиксирует момент старта для /device и /ping.
  // ignore: unused_local_variable
  final _ = debug_bootstrap.appStartedAt;

  // Top-level error boundary (night T2-1). Любой uncaught Flutter-error
  // (build/layout/paint) и async error роутятся в AppLog как error-entry,
  // чтобы были видны на DebugScreen и в /logs endpoint'е. Red-screen
  // заменён на компактный fallback чтобы юзер видел описание, а не голый
  // stacktrace.
  final prevOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    AppLog.I.error(
      'Flutter error: ${details.exceptionAsString()}'
      '${details.context != null ? " @ ${details.context}" : ""}',
    );
    if (kDebugMode) prevOnError?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLog.I.error('Uncaught async: $error');
    return true;
  };
  ErrorWidget.builder = (details) => _FallbackErrorWidget(details: details);

  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);
  runApp(const LxBoxApp());
}

/// Fallback-widget для UI-ошибок (replace Flutter's red screen).
/// Показывает краткое описание + подсказку открыть Debug → Logs.
class _FallbackErrorWidget extends StatelessWidget {
  final FlutterErrorDetails details;
  const _FallbackErrorWidget({required this.details});

  @override
  Widget build(BuildContext context) {
    // В release сборке showDialog недоступен из ErrorWidget.builder
    // (context может быть без Material ancestor). Рендерим minimal UI.
    return Container(
      color: const Color(0xFF2A1515),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.white70, size: 40),
          const SizedBox(height: 12),
          const Text(
            'Something went wrong in this section.\nCheck Debug → Logs.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white, fontSize: 14),
          ),
          if (kDebugMode) ...[
            const SizedBox(height: 12),
            Text(
              details.exceptionAsString(),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}

/// Global theme notifier — allows changing theme from anywhere.
class ThemeNotifier extends ChangeNotifier {
  ThemeNotifier() {
    _load();
  }

  ThemeMode _mode = ThemeMode.system;
  ThemeMode get mode => _mode;

  static const _key = 'app_theme_mode';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_key);
    _mode = switch (stored) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    notifyListeners();
  }

  Future<void> setMode(ThemeMode mode) async {
    _mode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    });
  }
}

final themeNotifier = ThemeNotifier();

class LxBoxApp extends StatelessWidget {
  const LxBoxApp({super.key});

  static const _seed = Colors.indigo;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: themeNotifier,
      builder: (context, _) {
        return MaterialApp(
          title: 'L×Box',
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: _seed),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: _seed,
              brightness: Brightness.dark,
            ),
            useMaterial3: true,
          ),
          themeMode: themeNotifier.mode,
          home: const HomeScreen(),
        );
      },
    );
  }
}
