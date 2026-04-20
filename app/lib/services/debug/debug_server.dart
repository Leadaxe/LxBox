/// Public API Debug-модуля (§031). Consumers импортируют этот файл —
/// все имена publicно доступны.
///
/// ```dart
/// import 'package:lxbox/services/debug/debug_server.dart';
///
/// // На старте app:
/// DebugRegistry.I.home = homeController;
/// DebugRegistry.I.sub = subscriptionController;
/// final ctx = DebugContext(registry: DebugRegistry.I, appStartedAt: ...);
/// await DebugServer.I.restartFromSettings(ctx);
///
/// // Из UI после toggle:
/// await DebugServer.I.restartFromSettings(ctx);
/// ```
library;

export 'context.dart' show DebugContext;
export 'contract/errors.dart';
export 'debug_registry.dart' show DebugRegistry;
export 'transport/config.dart' show DebugServerConfig;
export 'transport/server.dart' show DebugServer;
