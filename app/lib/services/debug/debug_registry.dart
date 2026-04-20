import '../../controllers/home_controller.dart';
import '../../controllers/subscription_controller.dart';
import '../subscription/auto_updater.dart';

/// Singleton-хранилище ссылок на long-lived контроллеры приложения.
/// Биндится в `HomeScreen.initState` после создания HomeController/
/// SubscriptionController. Handlers получают Registry внутри [DebugContext].
///
/// Поля nullable: до первой инициализации handlers бросают
/// [Conflict('controller not ready')] — сервер ещё мог стартануть раньше
/// чем UI догрузился, это ожидаемое состояние.
class DebugRegistry {
  DebugRegistry._();
  static final DebugRegistry I = DebugRegistry._();

  HomeController? home;
  SubscriptionController? sub;
  AutoUpdater? autoUpdater;

  bool get ready => home != null && sub != null;
}
