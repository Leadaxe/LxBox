import '../../controllers/home_controller.dart';
import '../../controllers/subscription_controller.dart';
import '../app_log.dart';
import '../subscription/auto_updater.dart';
import 'contract/errors.dart';
import 'debug_registry.dart';
import 'transport/config.dart';

/// Контекст, инжектимый в каждый handler. Абстрагирует доступ к
/// domain-компонентам (controllers, log, clock, server-config)
/// за явным интерфейсом — handlers не дёргают синглтоны
/// (`AppLog.I`, `DebugRegistry.I`) напрямую, а получают [DebugContext]
/// параметром. В тестах подменяется фейковым instance.
class DebugContext {
  DebugContext({
    required this.registry,
    required this.appStartedAt,
    this.config = const DebugServerConfig(port: 0, token: ''),
    DateTime Function()? clock,
    AppLog? log,
  })  : _clock = clock ?? DateTime.now,
        log = log ?? AppLog.I;

  final DebugRegistry registry;
  final DateTime appStartedAt;

  /// Конфиг текущего сервера (port/token/timeouts). Handler'ы читают
  /// `config.requestTimeout` чтобы согласовать внутренние тайминги
  /// (например, upstream-timeout в `/clash/*` proxy).
  final DebugServerConfig config;
  final AppLog log;
  final DateTime Function() _clock;

  /// Текущее время (через injectable clock). В тестах подменяется фикс-датой.
  DateTime now() => _clock();

  HomeController? get home => registry.home;
  SubscriptionController? get sub => registry.sub;
  AutoUpdater? get autoUpdater => registry.autoUpdater;

  /// Бросает [Conflict] если [HomeController] не зарегистрирован.
  /// Handler'ы вызывают один раз в начале и используют локальную переменную —
  /// не повторные дёргания `requireHome` по телу функции.
  HomeController requireHome() {
    final h = home;
    if (h == null) throw const Conflict('home controller not ready');
    return h;
  }

  /// Бросает [Conflict] если [SubscriptionController] не зарегистрирован.
  SubscriptionController requireSub() {
    final s = sub;
    if (s == null) throw const Conflict('subscription controller not ready');
    return s;
  }

  /// Возвращает копию контекста с новым [config]. Используется сервером
  /// при старте — базовый контекст из bootstrap'а не знает про порт/токен,
  /// они становятся известны только при binding'е.
  DebugContext withConfig(DebugServerConfig newConfig) => DebugContext(
        registry: registry,
        appStartedAt: appStartedAt,
        config: newConfig,
        log: log,
        clock: _clock,
      );
}
