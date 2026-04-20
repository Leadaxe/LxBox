import 'context.dart';
import 'debug_registry.dart';
import 'transport/server.dart';

/// Время старта приложения. Инициализируется при первом доступе —
/// т.е. при первом импорте этого файла, что происходит в `main.dart`
/// до `runApp`. Используется в `GET /device.uptimeSeconds` и `/ping`.
final DateTime appStartedAt = DateTime.now();

/// Приводит Debug-сервер в соответствие с `SettingsStorage.debug_*`:
/// старт/стоп/рестарт. Вызывается:
/// 1. Из `HomeScreen.initState` после того как биндится DebugRegistry
/// 2. Из `AppSettingsScreen` после toggle / port change / regenerate token
///
/// Сама функция тонкая — вся логика в [DebugServer.restartFromSettings].
/// Здесь только сборка [DebugContext] из глобальных синглтонов.
Future<void> applyDebugApiSettings() async {
  final ctx = DebugContext(
    registry: DebugRegistry.I,
    appStartedAt: appStartedAt,
  );
  await DebugServer.I.restartFromSettings(ctx);
}
