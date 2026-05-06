import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../../app_log.dart';
import '../../settings_storage.dart';
import '../context.dart';
import '../contract/errors.dart';
import '../handlers/action.dart';
import '../handlers/backup.dart';
import '../handlers/clash.dart';
import '../handlers/config.dart';
import '../handlers/device.dart';
import '../handlers/diag.dart';
import '../handlers/files.dart';
import '../handlers/logs.dart';
import '../handlers/help.dart';
import '../handlers/ping.dart';
import '../handlers/rules.dart';
import '../handlers/settings.dart';
import '../handlers/state.dart';
import '../handlers/subs.dart';
import 'config.dart';
import 'middleware/access_log.dart';
import 'middleware/auth.dart';
import 'middleware/error_mapper.dart';
import 'middleware/host_check.dart';
import 'middleware/timeout.dart';
import 'pipeline.dart';
import 'request.dart';
import 'response.dart';
import 'router.dart';

/// Точка входа Debug API. Синглтон — один сервер на приложение.
/// Wires вместе [Router], [Middleware] pipeline и [HttpServer].
///
/// Lifecycle:
/// * `start(config, ctx)` — bind на `127.0.0.1:port`, accept connections
/// * `stop()` — force-close сервера, in-flight responses обрываются
/// * `restartFromSettings(ctx)` — читает `SettingsStorage.debug_*` и
///   запускает/останавливает/рестартит согласно состоянию
///
/// Thread-safety: внутри event loop'а Dart, весь state под одним
/// "потоком" — mutex не нужен.
class DebugServer {
  DebugServer._();
  static final DebugServer I = DebugServer._();

  HttpServer? _server;
  DebugServerConfig? _config;
  DebugContext? _context;
  Router? _router;
  List<Middleware>? _pipeline;

  bool get running => _server != null;
  int get port => _config?.port ?? 0;

  /// Биндит сервер на `127.0.0.1:config.port`. При активном предыдущем
  /// инстансе сначала [stop]. Бросает [SocketException] если порт занят.
  Future<void> start(DebugServerConfig config, DebugContext context) async {
    await stop();

    if (config.token.isEmpty) {
      AppLog.I.warning('Debug API: token empty — refusing to start');
      return;
    }

    final router = _buildRouter();
    final pipeline = _buildPipeline(config);

    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      config.port,
    );

    _server = server;
    _config = config;
    // Handlers видят config через context.config — сервер на старте
    // инжектит его в контекст. Bootstrap создаёт context без config
    // (ещё не знает порт/токен); они подмешиваются здесь.
    _context = context.withConfig(config);
    _router = router;
    _pipeline = pipeline;

    AppLog.I.info('Debug API: listening on 127.0.0.1:${config.port}');

    server.listen(
      _onRequest,
      onError: (Object e, StackTrace st) {
        AppLog.I.error('Debug API listen: $e');
      },
      cancelOnError: false,
    );
  }

  Future<void> stop() async {
    final s = _server;
    if (s == null) return;
    _server = null;
    _config = null;
    _context = null;
    _router = null;
    _pipeline = null;
    try {
      await s.close(force: true);
      AppLog.I.info('Debug API: stopped');
    } catch (e) {
      AppLog.I.warning('Debug API: stop error: $e');
    }
  }

  /// Перечитывает `debug_enabled/port/token` из [SettingsStorage] и
  /// приводит сервер в соответствие: start/stop/rebind. Вызывается
  /// из `main.dart` на старте и из App Settings toggle/port-change.
  Future<void> restartFromSettings(DebugContext context) async {
    final enabled = await SettingsStorage.getDebugEnabled();
    if (!enabled) {
      await stop();
      return;
    }
    final port = await SettingsStorage.getDebugPort();
    final token = await SettingsStorage.getDebugToken();
    try {
      await start(
        DebugServerConfig(port: port, token: token),
        context,
      );
    } on SocketException catch (e) {
      AppLog.I.error('Debug API: bind failed on :$port — ${e.message}');
    } catch (e) {
      AppLog.I.error('Debug API: start failed — $e');
    }
  }

  /// 32-hex token через [Random.secure] (128 bits).
  static String generateToken() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  // ---------------------------------------------------------------------------
  // Internal wiring
  // ---------------------------------------------------------------------------

  /// Двухуровневая маршрутизация:
  ///
  /// 1. **Router (здесь)** — prefix-match: `/state/...` → `stateHandler`
  /// 2. **Handler-файл** — exact `switch (req.path)` по sub-path'ам
  ///    (`/state` → _root, `/state/clash` → _clash, ...).
  ///
  /// Это не случайность — намеренный компромисс. Плюсы:
  /// - handler-файл держит связанные sub-endpoints рядом (всё `/state/*`
  ///   в одном `handlers/state.dart`);
  /// - mount-таблица компактная (8 строк вместо 30);
  /// - минус один уровень абстракции в сравнении с path-параметрами
  ///   (`/state/:sub`) или аннотациями.
  ///
  /// Trade-off: незнакомый endpoint возвращает `NotFound` через switch
  /// внутри handler'а, а не из router'а. Для клиента — тот же 404.
  Router _buildRouter() {
    return Router()
      ..mount('/ping', pingHandler)
      ..mount('/help', helpHandler)
      ..mount('/state', stateHandler)
      ..mount('/device', deviceHandler)
      ..mount('/config', configHandler)
      ..mount('/logs', logsHandler)
      ..mount('/clash', clashHandler)
      ..mount('/action', actionHandler)
      ..mount('/files', filesHandler)
      ..mount('/diag', diagHandler)
      ..mount('/backup', backupHandler)
      ..mount('/rules', rulesHandler)
      ..mount('/subs', subsHandler)
      ..mount('/settings', settingsHandler);
  }

  List<Middleware> _buildPipeline(DebugServerConfig config) {
    // Порядок: внешний → внутренний.
    // errorMapper — самый внешний, ловит всё включая accessLog crash'и.
    // accessLog — после errorMapper чтобы видеть финальный статус.
    // hostCheck — дёшево, рано отрезаем rebind.
    // auth — после hostCheck (не мучаем auth если запрос уже отклонён).
    // timeout — обёртывает handler, не должен мешать 401/403 ответам.
    return [
      errorMapper,
      accessLog(),
      hostCheck,
      auth(
        token: config.token,
        unauthenticatedPaths: config.unauthenticatedPaths,
      ),
      timeoutMiddleware(config.requestTimeout),
    ];
  }

  Future<void> _onRequest(HttpRequest raw) async {
    final cfg = _config;
    final ctx = _context;
    final router = _router;
    final pipeline = _pipeline;
    if (cfg == null || ctx == null || router == null || pipeline == null) {
      // Сервер остановлен между accept'ом и обработкой — закрываем соединение.
      await raw.response.close().catchError((_) {});
      return;
    }

    DebugResponse resp;
    try {
      final req = await DebugRequest.from(raw, maxBodyBytes: cfg.maxBodyBytes);
      resp = await runPipeline(req, ctx, pipeline, router.handle);
    } on DebugError catch (e) {
      // Ошибки из DebugRequest.from (PayloadTooLarge и т.п.) — pipeline
      // ещё не начался, errorMapper не сработал. Логируем вручную чтобы
      // line matched access_log middleware formatu — иначе эти ошибки
      // были бы невидимы в AppLog.
      AppLog.I.warning(
        '[debug-api] ${raw.method} ${raw.uri.path} → ${e.status} (pre-pipeline)',
      );
      resp = ErrorResponse(e);
    } catch (e, st) {
      AppLog.I.error(
        '[debug-api] ${raw.method} ${raw.uri.path} → 500 (pre-pipeline): $e\n$st',
      );
      resp = ErrorResponse(InternalError('$e'));
    }

    try {
      await resp.writeTo(raw.response);
    } catch (e) {
      // Клиент отвалился мид-запись — ничего не делаем, connection закрыт.
      AppLog.I.debug('Debug API: write failed — $e');
    }
  }
}
