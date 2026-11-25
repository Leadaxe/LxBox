import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../services/app_log.dart';
import 'platform_channels.dart';
import '../services/selector_info.dart'; // §251 — fold «селектор (выбор)»
import '../services/diagnostics/connection_test.dart';
import 'cc_openconnect.dart';

export 'cc_openconnect.dart';

part 'cc_channel/method_names.dart';
part 'cc_channel/models_tailscale.dart';
part 'cc_channel/models_status.dart';
part 'cc_channel/models_traffic.dart';
part 'cc_channel/models_probe.dart';

/// §122 Фаза 1a — Dart-клиент нативного libbox `CommandClient`-канала
/// (`BoxCommandClient.kt`, Фаза 0). Замена `ClashApiClient` (HTTP-петли).
///
/// **Модель** (§2.2): не pull-снапшоты по таймеру, а **push-стримы** —
/// ядро эмитит изменения, UI подписывается. Императивы (`urlTestOutbound`,
/// `selectOutbound`, …) — через MethodChannel.
///
/// **Lifecycle стримов** управляется на native (§2.8: status always-on,
/// screen/profiler — по сигналу). Тут — broadcast-стримы поверх EventChannel:
/// подписчик получает последний снапшот, когда канал активен.
///
/// Singleton: один набор каналов на процесс.
class CcChannel {
  CcChannel._();

  static final CcChannel instance = CcChannel._();

  static const MethodChannel _methods = MethodChannel(PlatformChannels.methods);

  static const EventChannel _statusChannel = EventChannel(
    PlatformChannels.ccStatus,
  );
  static const EventChannel _outboundsChannel = EventChannel(
    PlatformChannels.ccOutbounds,
  );
  static const EventChannel _groupsChannel = EventChannel(
    PlatformChannels.ccGroups,
  );
  static const EventChannel _connectionsChannel = EventChannel(
    PlatformChannels.ccConnections,
  );
  static const EventChannel _dnsChannel = EventChannel(
    PlatformChannels.ccDns,
  ); // §180
  static const EventChannel _tailscaleChannel = EventChannel(
    PlatformChannels.ccTailscale,
  ); // §579
  static const EventChannel _tailscalePingChannel = EventChannel(
    PlatformChannels.ccTailscalePing,
  ); // §581
  static const EventChannel _connectionTestChannel = EventChannel(
    PlatformChannels.ccConnectionTest,
  ); // §687
  static const EventChannel _openConnectChannel = EventChannel(
    PlatformChannels.ccOpenConnect,
  ); // §654
  static const EventChannel _taildropInboxChannel = EventChannel(
    PlatformChannels.ccTaildropInbox,
  ); // §707

  // ─────────────────────────── Streams ───────────────────────────
  //
  // §122 КРИТИЧНО: каждый EventChannel держит РОВНО ОДИН native sink
  // (`BoxVpnService.cc*Sink`). Если разные потребители (главный экран +
  // StatsScreen + ConnectionsView) делают независимый `EventChannel
  // .receiveBroadcastStream().listen()`, их cancel'ы (dispose Stats) шлют
  // `onCancel` → native обнуляет sink → стрим главного экрана умирает →
  // watchdog видит «тишину» → ложный dead-tunnel/revoke. Симптом: «при заходе
  // в Statistics слетает VPN».
  //
  // Решение: ОДИН внутренний listen на EventChannel, фан-аут через
  // `StreamController.broadcast`. Native sink ставится при появлении первого
  // Dart-подписчика и снимается, только когда ушёл ПОСЛЕДНИЙ (onListen/onCancel
  // контроллера). Несколько потребителей больше не воюют за sink.

  late final Stream<CcStatus> _statusStream = _sharedStream<CcStatus>(
    _statusChannel,
    (e) => CcStatus.fromMap(_asMap(e)),
  );
  late final Stream<List<CcOutbound>> _outboundsStream =
      _sharedStream<List<CcOutbound>>(
        _outboundsChannel,
        (e) => _asList(e).map((m) => CcOutbound.fromMap(_asMap(m))).toList(),
      );
  late final Stream<List<CcGroup>> _groupsStream = _sharedStream<List<CcGroup>>(
    _groupsChannel,
    (e) => _asList(e).map((m) => CcGroup.fromMap(_asMap(m))).toList(),
  );
  late final Stream<List<CcConnection>> _connectionsStream =
      _sharedStream<List<CcConnection>>(
        _connectionsChannel,
        (e) => _asList(e).map((m) => CcConnection.fromMap(_asMap(m))).toList(),
      );
  // §180 — DNS-журнал (SPEC 018). Батч событий списком (EventEmitter native).
  late final Stream<List<CcDnsQuery>> _dnsQueriesStream =
      _sharedStream<List<CcDnsQuery>>(
        _dnsChannel,
        (e) => _asList(e).map((m) => CcDnsQuery.fromMap(_asMap(m))).toList(),
      );

  /// Статус-снапшот (always-on, §2.8): скорость, объём, память, число
  /// соединений. Shared — главный экран (watchdog/traffic_bar) + StatsScreen.
  Stream<CcStatus> get status => _statusStream;

  /// Плоский список ВСЕХ узлов (outbound + endpoint, §2.4): tag/type/delay.
  Stream<List<CcOutbound>> get outbounds => _outboundsStream;

  /// Дерево групп (§2.4): группа → items, selectable/selected.
  Stream<List<CcGroup>> get groups => _groupsStream;

  /// Снапшот активных соединений (дельты → native-аккумулятор → снапшот, §3.2).
  /// Shared — StatsScreen + ConnectionsView одновременно.
  Stream<List<CcConnection>> get connections => _connectionsStream;

  /// §180 — DNS-журнал из ядра (SPEC 018): батч `CcDnsQuery` на резолв(ы).
  /// Структурная замена текстового парсинга core-лога. Потребитель — профайлер.
  Stream<List<CcDnsQuery>> get dnsQueries => _dnsQueriesStream;

  // §579 — состояние узлов Tailscale: снапшот списком на каждое обновление.
  late final Stream<List<CcTailscaleStatus>> _tailscaleStream =
      _sharedStream<List<CcTailscaleStatus>>(
        _tailscaleChannel,
        CcTailscaleStatus.listFrom,
      );

  /// §579 — поток ядра `SubscribeTailscaleStatus`: записи endpoint'ов
  /// Tailscale (тег, `BackendState`, `StateText`). Подписку в ядре держат
  /// [startTailscaleStatus]/[stopTailscaleStatus]; слушать до старта.
  Stream<List<CcTailscaleStatus>> get tailscaleStatus => _tailscaleStream;

  // §581 — ответы проверки устройства: по одному событию на ответ. Без кэша
  // последнего значения (новая проверка не должна увидеть ответ прежней);
  // потребитель один — лист проверки.
  late final Stream<CcTailscalePingResult> _tailscalePingStream =
      _tailscalePingChannel.receiveBroadcastStream().map(
            (e) => CcTailscalePingResult.fromMap(_asMap(e)),
          );

  /// §581 — поток ответов [startTailscalePing]. Слушать до старта.
  Stream<CcTailscalePingResult> get tailscalePing => _tailscalePingStream;

  // §707 — входящие Taildrop узла: снапшот на каждое изменение. Без кэша —
  // новая подписка получает свежий снапшот от ядра.
  late final Stream<CcTaildropInbox> _taildropInboxStream =
      _taildropInboxChannel.receiveBroadcastStream().map(
            (e) => CcTaildropInbox.fromMap(_asMap(e)),
          );

  /// §707 — поток входящих узла, поднятого [startTaildropInbox]. Слушать до
  /// старта.
  Stream<CcTaildropInbox> get taildropInbox => _taildropInboxStream;

  // §687 — события теста соединения. Нативная сторона шлёт батчи (список
  // карт), здесь они разворачиваются в одиночные события без кэша.
  late final Stream<ConnectionTestEvent> _connectionTestStream =
      _connectionTestChannel.receiveBroadcastStream().expand(
            (e) => [
              for (final m in e is List ? e : [e])
                if (m is Map) ConnectionTestEvent.fromMap(_asMap(m)),
            ],
          );

  /// §687 — поток событий [startConnectionTest]. Слушать до старта.
  Stream<ConnectionTestEvent> get connectionTest => _connectionTestStream;

  /// §122 — shared-стрим с КЭШЕМ последнего снапшота.
  ///
  /// Два требования, которые наивный `broadcast` ломал → «при старте главный
  /// экран пустой»:
  ///  1. **Постоянный** upstream-listen (НЕ ленивый): EventChannel слушается
  ///     один раз на всю жизнь процесса. Иначе uptream снимался при уходе
  ///     последнего подписчика (rebuild/навигация) и РАЗОВЫЙ снапшот `groups`
  ///     (ядро шлёт его один раз при подключении screenClient) терялся, пока
  ///     никто не слушал.
  ///  2. **Replay последнего значения** новому подписчику: `groups`/`status`
  ///     приходят редко/периодично; подписчик, вставший ПОСЛЕ снапшота, иначе
  ///     ждал бы следующего. Кэшируем last и отдаём его сразу в onListen.
  ///
  /// Native sink (`BoxVpnService.cc*Sink`) держится один раз — несколько
  /// потребителей (главный + Stats + Conns) больше не воюют за него.
  /// Колбэки очистки кэшей `_sharedStream` — зовутся из [resetCaches] на
  /// disconnect, чтобы новый подписчик после reconnect НЕ получил replay'ем
  /// устаревший снапшот прошлой сессии (старые группы/соединения мигнули бы до
  /// прихода свежих).
  final List<void Function()> _cacheResetters = [];

  /// §122 — сбросить replay-кэши групп/нод/соединений. Зовётся из
  /// `_stopCcStreams` (disconnect). `status`-кэш тоже чистится — свежий статус
  /// придёт следующим тиком (1s), а устаревшая скорость мёртвой сессии не нужна.
  void resetCaches() {
    for (final reset in _cacheResetters) {
      reset();
    }
  }

  Stream<T> _sharedStream<T>(EventChannel channel, T Function(Object?) decode) {
    T? last;
    var hasLast = false;
    final controller = StreamController<T>.broadcast(
      onListen: () {}, // upstream уже активен (поднят ниже, постоянно)
    );
    _cacheResetters.add(() {
      last = null;
      hasLast = false;
    });
    // Постоянная подписка на EventChannel — поднимается сразу, не снимается.
    channel.receiveBroadcastStream().listen(
      (e) {
        last = decode(e);
        hasLast = true;
        if (!controller.isClosed) controller.add(last as T);
      },
      onError: (Object err, StackTrace st) {
        if (!controller.isClosed) controller.addError(err, st);
      },
    );
    // Каждому новому подписчику — немедленно последний кэшированный снапшот,
    // затем живой поток из broadcast-контроллера.
    return Stream<T>.multi((sub) {
      if (hasLast) sub.add(last as T);
      final inner = controller.stream.listen(
        sub.add,
        onError: sub.addError,
        onDone: sub.close,
      );
      sub.onCancel = inner.cancel;
    });
  }

  // ─────────────────────── Lifecycle signals ───────────────────────
  // §2.8 — screen/profiler клиенты поднимаются/гасятся по сигналу из Dart.

  /// §185 — cold-start Flutter после swipe-keep (туннель жив, native CC жив,
  /// движок переподнялся). Сбросить протухший native screenRefs + закрыть
  /// осиротевшие screen/profiler-клиенты ПЕРЕД connectScreen — иначе протухший
  /// refcount не даст переподнять screenClient на свежий движок (пустой UI).
  /// Идемпотентно: на штатном старте (refs уже 0) — no-op.
  Future<void> resyncForReopen() => _invoke(_CcMethods.ccResyncForReopen);

  Future<void> connectScreen() => _invoke(_CcMethods.ccConnectScreen);
  Future<void> disconnectScreen() => _invoke(_CcMethods.ccDisconnectScreen);
  Future<void> connectProfiler() => _invoke(_CcMethods.ccConnectProfiler);
  Future<void> disconnectProfiler() => _invoke(_CcMethods.ccDisconnectProfiler);

  // §259 — refcount поверх profilerClient. У profiler-стрима (в т.ч.
  // DNS-журнала §180) теперь ДВА потенциальных держателя: traffic_profiler
  // (recording/live) и dns-direct-детектор (окно после старта). Голый
  // `disconnectProfiler()` одного держателя оборвал бы native-подписку
  // другому. acquire/release ведут счётчик: native connect зовётся на 0→1,
  // native disconnect — на 1→0. Идемпотентно на уровне вызывающих (у каждого
  // своё «взял/отдал»); отрицательный дисбаланс защищён clamp'ом.
  int _profilerRefs = 0;
  Future<void> acquireProfiler() async {
    _profilerRefs++;
    if (_profilerRefs == 1) await connectProfiler();
  }

  Future<void> releaseProfiler() async {
    if (_profilerRefs == 0) return; // защита от лишнего release
    _profilerRefs--;
    if (_profilerRefs == 0) await disconnectProfiler();
  }

  /// §605 — переподнять profilerClient на свежий движок, если его держит хоть
  /// один потребитель. Native `shutdownAll` рвёт клиента на каждой остановке
  /// туннеля, а счётчик в Dart остаётся >0 → без повтора запись «горит» без
  /// событий. Зовётся на каждом `connected`; при 0 держателей — no-op.
  Future<void> restartProfiler() async {
    if (_profilerRefs > 0) await connectProfiler();
  }

  /// §175 — отмена масс-пинга: disconnect отдельного pingClient → ядро рвёт
  /// per-call ctx in-flight URLTest'ов (не дожидаясь TCPTimeout), не задевая
  /// status/screen/profiler-стримы. Следующий urlTestOutbound поднимет свежий.
  Future<void> cancelPing() => _invoke(_CcMethods.ccCancelPing);

  // ─────────────────────── §654 C — OpenConnect ───────────────────────
  // Подписку в ядре держит натив (старт VPN / reload по составу конфига);
  // здесь — поток снапшотов, текущий снапшот и ответы на челлендж.

  late final Stream<CcOpenConnectSnapshot> _openConnectStream =
      _sharedStream<CcOpenConnectSnapshot>(
        _openConnectChannel,
        CcOpenConnectSnapshot.fromObject,
      );

  /// §654 C — состояние endpoint'ов openconnect и слушателя SSO.
  Stream<CcOpenConnectSnapshot> get openConnectStatus => _openConnectStream;

  /// §654 C — текущий снапшот (висящий челлендж при открытии приложения).
  /// `null` — канала нет (VPN выключен, натив недоступен).
  Future<CcOpenConnectSnapshot?> getOpenConnectStatus() async {
    try {
      final r = await _methods.invokeMethod<Object?>(_CcMethods.ccGetOpenConnectStatus);
      return r == null ? null : CcOpenConnectSnapshot.fromObject(r);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// §654 C — тег узла из тапа по уведомлению «Sign-in required»; забирается
  /// один раз.
  Future<String?> takeOpenConnectOpenRequest() async {
    try {
      return await _methods.invokeMethod<String>(_CcMethods.ccTakeOpenConnectOpenRequest);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// §654 C — ответ формой: пары ключ → значение в порядке полей. `null` —
  /// успех, иначе текст ошибки.
  Future<String?> submitOpenConnectForm(
    String tag,
    String challengeId,
    List<MapEntry<String, String>> values,
  ) =>
      _invokeError(_CcMethods.ccSubmitOpenConnectForm, {
        'tag': tag,
        'challenge_id': challengeId,
        'values': [
          for (final v in values) {'key': v.key, 'value': v.value},
        ],
      });

  /// §654 C — отмена челленджа: ядро логинится заново (новый код).
  Future<String?> cancelOpenConnectChallenge(String tag, String challengeId) =>
      _invokeError(_CcMethods.ccCancelOpenConnectChallenge, {
        'tag': tag,
        'challenge_id': challengeId,
      });

  /// §654 C — слушатель SSO на `127.0.0.1:port`; URL редиректа натив сам
  /// отдаёт ядру. `null` — слушает, иначе текст ошибки (порт занят).
  Future<String?> startOpenConnectCallback(
    String tag,
    String challengeId,
    int port,
    List<String> prefixes,
  ) =>
      _invokeError(_CcMethods.ccStartOpenConnectCallback, {
        'tag': tag,
        'challenge_id': challengeId,
        'port': port,
        'prefixes': prefixes,
      });

  Future<void> stopOpenConnectCallback() => _invoke(_CcMethods.ccStopOpenConnectCallback);

  /// §579 — поднять / снять подписку ядра на состояние узлов Tailscale.
  Future<void> startTailscaleStatus() => _invoke(_CcMethods.ccStartTailscaleStatus);
  Future<void> stopTailscaleStatus() => _invoke(_CcMethods.ccStopTailscaleStatus);

  /// §581 — подписку ядра держат несколько потребителей (главный экран для
  /// NETWORKS, вкладка Network узла): поднимается на 0→1, снимается на 1→0.
  int _tailscaleRefs = 0;
  Future<void> acquireTailscaleStatus() async {
    _tailscaleRefs++;
    if (_tailscaleRefs == 1) await startTailscaleStatus();
  }

  Future<void> releaseTailscaleStatus() async {
    if (_tailscaleRefs == 0) return;
    _tailscaleRefs--;
    if (_tailscaleRefs == 0) await stopTailscaleStatus();
  }

  /// Переподнять подписку, если её кто-то держит (reload ядра).
  Future<void> restartTailscaleStatus() async {
    if (_tailscaleRefs > 0) await startTailscaleStatus();
  }

  /// §581 — выбор exit node на ходу (`stableId`; пусто — снять). Тело узла
  /// не меняется. `null` — успех, иначе текст ошибки ядра.
  Future<String?> setTailscaleExitNode(String tag, String stableId) =>
      _invokeError(_CcMethods.ccSetTailscaleExitNode, {
        'tag': tag,
        'stable_id': stableId,
      });

  /// §645 — одиночный `GetTailscaleStatus(tag)` ядра: свежая запись
  /// endpoint'а (путь до устройств — на момент вызова, у потока — на момент
  /// последнего события). Тег не найден, endpoint не запущен, сервис не поднят
  /// — [CcTailscaleStatusPoll.skip]; ядро или native без метода —
  /// [CcTailscaleStatusPoll.notSupported].
  Future<CcTailscaleStatusPoll> getTailscaleStatus(String tag) async {
    try {
      final r = await _methods.invokeMethod<Object?>(_CcMethods.ccGetTailscaleStatus, {
        'tag': tag,
      });
      if (r is! Map) return CcTailscaleStatusPoll.skip;
      final m = _asMap(r);
      if ('${m['tag'] ?? ''}'.isEmpty) m['tag'] = tag;
      return CcTailscaleStatusPoll(status: CcTailscaleStatus.fromMap(m));
    } on PlatformException catch (e) {
      return e.code == 'unimplemented'
          ? CcTailscaleStatusPoll.notSupported
          : CcTailscaleStatusPoll.skip;
    } on MissingPluginException {
      return CcTailscaleStatusPoll.notSupported;
    }
  }

  /// §581 — выход узла из аккаунта. `null` — успех, иначе текст ошибки.
  Future<String?> tailscaleLogout(String tag) =>
      _invokeError(_CcMethods.ccTailscaleLogout, {'tag': tag});

  /// §706 (ядро SPEC 149, lx.30) — вход узла [tag] с новым auth-ключом без
  /// перезапуска VPN. Успех — ядро приняло вызов; отказ ключа виден позже в
  /// `backendState`/health. Отказ ядра — [PlatformException] с кодом
  /// `failed_precondition` (сервис или узел не запущен, узел выключен, уже
  /// вошёл) / `not_found` / `invalid_argument` / `unavailable` / `error`.
  Future<void> tailscaleLogin(String tag, String authKey) =>
      _methods.invokeMethod<void>(_CcMethods.ccTailscaleLogin, {
        'tag': tag,
        'auth_key': authKey,
      });

  /// §581 — проверка устройства: ответы идут в [tailscalePing].
  Future<void> startTailscalePing(String tag, String peerIp) async {
    try {
      await _methods.invokeMethod<void>(_CcMethods.ccStartTailscalePing, {
        'tag': tag,
        'peer_ip': peerIp,
      });
    } on PlatformException {
      // сервис не поднят — ответов не будет
    } on MissingPluginException {
      // юнит-тест / native не готов
    }
  }

  Future<void> stopTailscalePing() => _invoke(_CcMethods.ccStopTailscalePing);

  /// §707 — подписка на входящие Taildrop узла [tag] (одна на приложение).
  Future<void> startTaildropInbox(String tag) async {
    try {
      await _methods.invokeMethod<void>(_CcMethods.ccStartTaildropInbox, {'tag': tag});
    } on PlatformException {
      // сервис не поднят — снапшотов не будет
    } on MissingPluginException {
      // юнит-тест / native не готов
    }
  }

  Future<void> stopTaildropInbox() => _invoke(_CcMethods.ccStopTaildropInbox);

  /// §707 — удалить принятый файл. `null` — успех, иначе текст ошибки.
  Future<String?> taildropDelete(String tag, String name) =>
      _invokeError(_CcMethods.ccTaildropDelete, {'tag': tag, 'name': name});

  /// §707 — прервать приём файла.
  Future<String?> taildropCancelReceiving(
    String tag,
    String senderId,
    String name,
  ) =>
      _invokeError(_CcMethods.ccTaildropCancelReceiving, {
        'tag': tag,
        'sender_id': senderId,
        'name': name,
      });

  /// §707 — входящие узла просмотрены (счётчик непрочитанных ядра).
  Future<String?> taildropMarkRead(String tag) =>
      _invokeError(_CcMethods.ccTaildropMarkRead, {'tag': tag});

  /// §707 — сохранить принятый файл: API 29+ — в Downloads, ниже —
  /// системным «Сохранить как». Сохранённый уходит из входящих.
  /// [downloadsOnly] (итер. 5, Debug API) — ниже API 29 отказ вместо
  /// системного диалога.
  Future<CcTaildropResult> taildropSave(String tag, String name,
          {bool downloadsOnly = false}) =>
      _taildropCall(_CcMethods.ccTaildropSave, {
        'tag': tag,
        'name': name,
        if (downloadsOnly) 'downloads_only': true,
      });

  /// §707 итер. 5 — отправка пиру из байтов ([bytes] с именем [name]) или
  /// заметкой ([text], имя даёт натив) тем же нативным путём, что «Send
  /// file…»; ждёт итога до [wait]. `status` — `sent`, `cancelled`,
  /// `in_progress` (не уложилась в [wait], передача идёт) или `error`;
  /// [CcTaildropResult.name] — имя отправленного файла.
  Future<CcTaildropResult> taildropSendBytes(
    String tag,
    String peerId,
    String peerName, {
    String? name,
    Uint8List? bytes,
    String? text,
    Duration wait = const Duration(seconds: 60),
  }) =>
      _taildropCall(_CcMethods.ccTaildropSendBytes, {
        'tag': tag,
        'peer_id': peerId,
        'peer_name': peerName,
        'name': ?name,
        'bytes': ?bytes,
        'text': ?text,
        'wait_ms': wait.inMilliseconds,
      });

  /// §707 итер. 5 — разовый снимок входящих узла [tag] (форма потока
  /// [taildropInbox]) с `sha256` принятых файлов. `null` — VPN не поднят,
  /// ядро не ответило или канала нет.
  Future<CcTaildropInbox?> taildropInboxSnapshot(String tag) async {
    try {
      final r = await _methods
          .invokeMethod<Object?>(_CcMethods.ccTaildropInboxSnapshot, {'tag': tag});
      if (r is! Map) return null;
      return CcTaildropInbox.fromMap(_asMap(r));
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// §707 итер. 5 — счётчики разбора служебных файлов с начала процесса
  /// (натив, только в памяти). `null` — канала нет.
  Future<Map<String, dynamic>?> taildropServiceStats() async {
    try {
      final r = await _methods.invokeMethod<Object?>(_CcMethods.taildropServiceStats);
      return r is Map ? _asMap(r) : null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// §707 итер. 7 — служебный файл с командами [commands] (SERVICE_FILES
  /// §2–§3) собирает натив — тот же сборщик, что окно «Send clipboard».
  /// `null` — канала нет (тесты, не Android).
  Future<CcServiceFile?> taildropBuildServiceFile(
      List<Object?> commands) async {
    try {
      final r = await _methods.invokeMethod<Object?>(
          _CcMethods.taildropBuildServiceFile, {'commands': commands});
      return r is Map ? CcServiceFile.fromMap(_asMap(r)) : null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// §707 итер. 7 — окно «Send clipboard»: запомненный получатель
  /// (`target`: `tag`, `peer_id`, `name`) и число сообщений лент (`feeds`).
  /// `null` — канала нет.
  Future<Map<String, dynamic>?> taildropClipState() async {
    try {
      final r = await _methods.invokeMethod<Object?>(_CcMethods.taildropClipState);
      return r is Map ? _asMap(r) : null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// §707 — системный выбор файлов и отправка выбранного пиру.
  Future<CcTaildropResult> taildropPickAndSend(
    String tag,
    String peerId,
    String peerName,
  ) =>
      _taildropCall(_CcMethods.ccTaildropPickAndSend, {
        'tag': tag,
        'peer_id': peerId,
        'peer_name': peerName,
      });

  Future<CcTaildropResult> _taildropCall(
    String method,
    Map<String, Object> args,
  ) async {
    try {
      final r = await _methods.invokeMethod<Object?>(method, args);
      return CcTaildropResult.fromMap(_asMap(r));
    } on PlatformException catch (e) {
      return CcTaildropResult(status: 'error', error: e.message ?? e.code);
    } on MissingPluginException {
      return const CcTaildropResult(status: 'error', error: 'not available');
    }
  }

  /// §707 — тег узла из тапа по уведомлению Taildrop; забирается один раз.
  Future<String?> takeTaildropOpenRequest() async {
    try {
      return await _methods.invokeMethod<String>(_CcMethods.ccTakeTaildropOpenRequest);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// §687 — тест соединения через роутер (kernel SPEC 139). События идут в
  /// [connectionTest]. false — сервис не поднят, событий не будет.
  Future<bool> startConnectionTest({
    required String link,
    String packageName = '',
    ConnectionTestDepth depth = ConnectionTestDepth.http,
    bool fresh = false,
  }) async {
    try {
      final ok = await _methods.invokeMethod<bool>(_CcMethods.ccStartConnectionTest, {
        'link': link,
        'package_name': packageName,
        'depth': depth.wire,
        'fresh': fresh,
      });
      return ok == true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> stopConnectionTest() => _invoke(_CcMethods.ccStopConnectionTest);

  Future<String?> _invokeError(String method, Map<String, Object> args) async {
    try {
      return await _methods.invokeMethod<String>(method, args);
    } on PlatformException catch (e) {
      return e.message ?? e.code;
    } on MissingPluginException {
      return 'not available';
    }
  }

  // §164 — энергомодель CC-клиентов.
  /// FAST (0.1с) — Stats открыт (плавность); NORMAL (0.5с) — главный экран.
  /// Пересоздаёт statusClient с новым интервалом (см. feature 123 §3).
  Future<void> setStatusFast(bool fast) async {
    try {
      await _methods.invokeMethod<void>(_CcMethods.ccSetStatusFast, {'fast': fast});
    } catch (_) {
      /* native не готов — игнор, не критично */
    }
  }

  /// Фон (onAppPaused): гасим status+screen клиенты (0 тиков/0 drain).
  /// profilerClient НЕ трогаем — recording живёт в фоне. Выключение VPN ловит
  /// нативный broadcast, не CC (feature 123 §1.1/§4).
  Future<void> pauseClients() => _invoke(_CcMethods.ccPauseClients);

  /// Возврат из фона (onAppResumed): поднимаем status(NORMAL)+screen(если refs>0).
  Future<void> resumeClients() => _invoke(_CcMethods.ccResumeClients);

  // ─────────────────────────── Imperatives ───────────────────────────

  /// §4.6 — per-node delay. Возвращает `(delay, error)`. ИНВАРИАНТ: `error` —
  /// единственный признак провала; `delay==0 && error==''` = успех 0мс.
  /// `timeoutMs` — миллисекунды (0 → дефолт ядра).
  Future<CcDelayResult> urlTestOutbound(
    String tag, {
    String link = '',
    int timeoutMs = 0,
  }) async {
    // §731 — страховочный дедлайн ответа. Таймаут замера держит ЯДРО; если
    // его RPC не вернулся вовсе (жалоба 4PDA #2001: WARP-звено цепочки, строка
    // висит в «PING…», в логе тишина), ни Dart, ни Kotlin вызов не обрывали:
    // одиночный пинг не снимал индикатор, воркер mass ping навсегда занимал
    // слот. Дедлайн = таймаут замера + запас; истёк — узел получает ошибку,
    // а в лог идёт строка. Сам вызов в ядре не трогаем: `cancelPing` рвёт
    // общий pingClient вместе с чужими замерами.
    return _urlTestWithReplyDeadline(
      tag,
      timeoutMs,
      _methods.invokeMethod<Map<dynamic, dynamic>>(
        _CcMethods.ccUrlTestOutbound,
        {'tag': tag, 'link': link, 'timeoutMs': timeoutMs},
      ),
    );
  }

  /// §731 — ждёт ответ замера не дольше «таймаут замера + [urlTestReplyGrace]»
  /// (при `timeoutMs == 0` — [_urlTestCoreDefaultMs] + запас). Общий для
  /// боевого замера и замера probe-сессии.
  Future<CcDelayResult> _urlTestWithReplyDeadline(
    String tag,
    int timeoutMs,
    Future<Map<dynamic, dynamic>?> reply,
  ) async {
    final budget = Duration(
            milliseconds: timeoutMs > 0 ? timeoutMs : _urlTestCoreDefaultMs) +
        urlTestReplyGrace;
    try {
      final r = await reply.timeout(budget);
      return CcDelayResult.fromMap(_asMap(r ?? const {}));
    } on TimeoutException {
      AppLog.I.warning('URLTest $tag: no reply from core in '
          '${budget.inMilliseconds} ms (test timeout $timeoutMs ms)');
      return CcDelayResult(
        delay: 0,
        error: 'no reply from core in ${budget.inMilliseconds} ms',
      );
    }
  }

  /// §731 — запас сверх таймаута замера, после которого ответа ядра на
  /// `urlTestOutbound` больше не ждём.
  @visibleForTesting
  static Duration urlTestReplyGrace = const Duration(seconds: 3);

  /// Бюджет при `timeoutMs == 0` («дефолт ядра»): неизвестен приложению,
  /// берём верхнюю оценку — запасной таймаут пинга (§040).
  static const int _urlTestCoreDefaultMs = 10000;

  /// §308 — групповой URLTest: ядро force-тестит ВСЕХ членов группы её
  /// конфиг-URL'ом (`urltest_url` шаблона, не ping settings) и делает
  /// переселект на живой узел. Fire-and-forget: `true` = команда принята;
  /// результаты приедут стримами (groups → selected, history → делеи).
  Future<bool> urlTestGroup(String tag) async =>
      await _methods.invokeMethod<bool>(_CcMethods.ccUrlTestGroup, {'tag': tag}) ??
      false;

  // ─── §236 — headless probe-сессия (Test servers при выключенном VPN) ───

  /// Стартует probe-инстанс ядра (конфиг БЕЗ tun). [CcProbeStart.error] — ''
  /// при успехе, текст ошибки иначе (в т.ч. «VPN is running…» — тогда caller
  /// уходит на ветку [urlTestOutbound] через боевое ядро).
  ///
  /// §669 — [CcProbeStart.runId] — владелец сессии: остальные probe-вызовы
  /// несут его, а с чужим/устаревшим id ничего не делают ([kProbeStaleRun]).
  /// Новый старт поверх живой сессии её закрывает — старый прогон уже не
  /// может закрыть новую.
  Future<CcProbeStart> probeStart(String config) async {
    final r = await _methods.invokeMethod<Map<dynamic, dynamic>>(_CcMethods.probeStart, {
      'config': config,
    });
    return CcProbeStart.fromMap(_asMap(r ?? const {}));
  }

  /// Тест одной ноды в probe-сессии. Семантика результата как у
  /// [urlTestOutbound] (Variant B: провал — только в `error`).
  Future<CcDelayResult> probeUrlTest(
    String tag, {
    required int runId,
    String link = '',
    int timeoutMs = 0,
  }) {
    // §731 — тот же страховочный дедлайн, что у [urlTestOutbound]: замер с
    // TLS fragment ядро держит, пока узел не подтвердит данные, мимо таймаута
    // замера; без дедлайна такой узел навсегда занимал слот пула пробы, и
    // тест подписки вставал. Вызов в ядре гасит `probeStop` в конце батча.
    return _urlTestWithReplyDeadline(
      tag,
      timeoutMs,
      _methods.invokeMethod<Map<dynamic, dynamic>>(
        _CcMethods.probeUrlTest,
        {'runId': runId, 'tag': tag, 'link': link, 'timeoutMs': timeoutMs},
      ),
    );
  }

  /// §669 — обрыв начатых замеров прогона [runId] (как [cancelPing] §175:
  /// disconnect клиента сессии → ядро отменяет контексты dial'ов). Сессия
  /// остаётся до [probeStop]. Чужой id — no-op.
  Future<void> probeCancel(int runId) =>
      _methods.invokeMethod<void>(_CcMethods.probeCancel, {'runId': runId});

  /// §392 — диагностический GET через узел в probe-сессии (VPN выключен).
  /// Семантика результата — см. [getUrlViaOutbound].
  Future<CcGetUrlResult> probeGetUrl(
    String tag, {
    required int runId,
    required String link,
    int timeoutMs = 0,
    int maxBytes = 0,
    String userAgent = '',
  }) async {
    final r = await _methods.invokeMethod<Map<dynamic, dynamic>>(
      _CcMethods.probeGetUrl,
      {
        'runId': runId,
        'tag': tag,
        'link': link,
        'timeoutMs': timeoutMs,
        'maxBytes': maxBytes,
        'userAgent': userAgent,
      },
    );
    return CcGetUrlResult.fromMap(_asMap(r ?? const {}));
  }

  /// Гасит probe-сессию прогона [runId] (идемпотентно; чужой/устаревший id —
  /// no-op, §669). Kotlin закрывает сервер под потолком 3 с.
  Future<void> probeStop(int runId) =>
      _methods.invokeMethod<void>(_CcMethods.probeStop, {'runId': runId});

  /// §392 — диагностический HTTP GET через узел боевого ядра, адресуемый тегом
  /// (kernel SPEC 058). В отличие от [urlTestOutbound] возвращает ТЕЛО ответа:
  /// отвечает не на «жив ли узел», а на «что видно через него» (exit-IP, гео,
  /// `warp=`). Активный selector не переключается.
  ///
  /// `maxBytes` 0 → дефолт ядра 256 KiB (потолок 1 MiB); `timeoutMs` 0 →
  /// ограничен только вызовом. Реальный трафик через узел — зовётся ТОЛЬКО по
  /// явному действию юзера, фоновые обходы списка запрещены (kernel SPEC 058 §5).
  ///
  /// §659 — `userAgent` пустой → заголовков нет, ядро шлёт `Go-http-client`.
  Future<CcGetUrlResult> getUrlViaOutbound(
    String tag, {
    required String link,
    int timeoutMs = 0,
    int maxBytes = 0,
    String userAgent = '',
  }) async {
    final r = await _methods.invokeMethod<Map<dynamic, dynamic>>(
      _CcMethods.ccGetUrlViaOutbound,
      {
        'tag': tag,
        'link': link,
        'timeoutMs': timeoutMs,
        'maxBytes': maxBytes,
        'userAgent': userAgent,
      },
    );
    return CcGetUrlResult.fromMap(_asMap(r ?? const {}));
  }

  /// §4.7 — снапшот route+DNS правил (диагностика).
  Future<List<CcRule>> getRules() async {
    final r = await _methods.invokeMethod<List<dynamic>>(_CcMethods.ccGetRules);
    return (r ?? const []).map((m) => CcRule.fromMap(_asMap(m))).toList();
  }

  /// §122/SPEC015 — unary pull-снапшот групп. Закрывает дыру pull-vs-push:
  /// если стартовый `SubscribeGroups`-push потерялся (гонка waitForStarted), тут
  /// перечитываем дерево групп синхронно, не пересоздавая screenClient. `null` =
  /// ядро не смогло отдать (не-STARTED/нет клиента) — отличаем от `[]` (групп
  /// нет): на null caller НЕ трогает state, на [] — тоже (пустых при connected
  /// не бывает, см. _onCcGroups). Формат Map идентичен groups-стриму → CcGroup.fromMap.
  Future<List<CcGroup>?> getGroups() async {
    final r = await _methods.invokeMethod<List<dynamic>>(_CcMethods.ccGetGroups);
    if (r == null) return null;
    return r.map((m) => CcGroup.fromMap(_asMap(m))).toList();
  }

  /// §535 (ядро SPEC 097) — unary pull плоского списка outbound'ов и
  /// endpoint'ов. ЕДИНСТВЕННЫЙ источник `endpointState`/`idleSinceSeconds`:
  /// ядро заполняет их только в ответе `GetOutbounds`, поток `outbounds` и
  /// дерево `groups` их не несут. `null` = не смогли прочитать (не-STARTED /
  /// нет клиента), `[]` = список пуст — caller различает, как в [getGroups].
  Future<List<CcOutbound>?> getOutbounds() async {
    final r = await _methods.invokeMethod<List<dynamic>>(_CcMethods.ccGetOutbounds);
    if (r == null) return null;
    return r.map((m) => CcOutbound.fromMap(_asMap(m))).toList();
  }

  /// §311 — unary снапшот конфига РАБОТАЮЩЕГО ядра (kernel SPEC 036
  /// `GetRunningConfig`; javap rc.3: `String getRunningConfig() throws`).
  /// Захвачен ядром один раз на старте, отдача — копия строки.
  ///
  /// КОНТРАКТ (модель §209): `null` = недоступен по ЛЮБОЙ причине — сервис
  /// down, ядро без метода (< rc.3 / без with_lx_command → Unimplemented),
  /// attached-путь (Unavailable), гонка старта (FailedPrecondition), старый
  /// native без handler'а (MissingPlugin). Caller деградирует к saved-файлу.
  /// Пустую строку native не отдаёт (SPEC 036: Unavailable вместо "").
  Future<String?> getRunningConfig() async {
    try {
      final r = await _methods.invokeMethod<String>(_CcMethods.ccGetRunningConfig);
      return (r == null || r.isEmpty) ? null : r;
    } on PlatformException {
      return null; // ядро не STARTED / RPC-ошибка — не фатально
    } on MissingPluginException {
      return null; // юнит-тест / native не готов
    }
  }

  /// §208/§209 — unary снапшот пула round_robin-группы [tag]. Слоты
  /// `[{slot,tag,delay}]` в фиксированном порядке слота. `delay`==0 → мёртвая/не
  /// измерена.
  ///
  /// КОНТРАКТ (§209): `null` = CC-клиент недоступен (сервис down / pingClient не
  /// поднялся) — НЕ путать с пустым пулом. `[]` = пул пуст (группа не
  /// round_robin / нет данных). Идёт через незасыпающий pingClient (native), так
  /// что в фоне отдаёт данные, а не молчит.
  Future<List<CcPoolSlot>?> getPool(String tag) async =>
      (await getPoolState(tag))?.slots;

  /// §759 — тот же снапшот вместе с состоянием самовосстановления группы
  /// (ядро SPEC 138: сдвинутые ключи, «проблемы в адресе», заморозка; у слота
  /// — карантин и счётчики). Контракт `null` / пустой пул — как у [getPool].
  /// Нативная часть на ядре без `GetPoolState` отдаёт список слотов — тогда
  /// состояние нулевое.
  Future<CcPoolState?> getPoolState(String tag) async {
    final r = await _methods.invokeMethod<Object?>(_CcMethods.ccGetPool, {
      'tag': tag,
    });
    if (r == null) return null; // клиент недоступен (§209)
    return CcPoolState.fromWire(r);
  }

  /// §312 — unary снапшот состояния DNS-групп (kernel SPEC 035
  /// `GetDNSGroups`; тип сервера `group`, SPEC 033).
  ///
  /// КОНТРАКТ (модель §209): `null` = недоступен (сервис down / ядро без
  /// метода / attached-путь / Unimplemented) — НЕ путать с `[]` = группы в
  /// конфиге отсутствуют. Через незасыпающий pingClient — отдаёт и в фоне.
  Future<List<CcDnsGroup>?> getDnsGroups() async {
    try {
      final r = await _methods.invokeMethod<List<dynamic>>(_CcMethods.ccGetDnsGroups);
      if (r == null) return null;
      return [
        for (final e in r)
          if (e is Map) CcDnsGroup.fromMap(_asMap(e)),
      ];
    } on PlatformException {
      return null; // RPC-ошибка / не-STARTED — не фатально
    } on MissingPluginException {
      return null; // юнит-тест / native не готов
    }
  }

  Future<bool> selectOutbound(String group, String tag) async =>
      await _methods.invokeMethod<bool>(_CcMethods.ccSelectOutbound, {
        'group': group,
        'tag': tag,
      }) ??
      false;

  /// §557 (ядро SPEC 106) — вкл/выкл WG/AWG-endpoint'а на лету. Возвращает
  /// состояние узла после вызова (строки [CcEndpointState]). Отказ ядра —
  /// [PlatformException] с кодом `not_found` / `invalid_argument` /
  /// `failed_precondition` / `unavailable` / `error`. Ядро выключатель не
  /// сохраняет: reload стартует все узлы включёнными.
  Future<String> setEndpointEnabled(String tag, bool enabled) async =>
      await _methods.invokeMethod<String>(_CcMethods.ccSetEndpointEnabled, {
        'tag': tag,
        'enabled': enabled,
      }) ??
      '';

  /// §613 (ядро SPEC 114, lx.12) — статус WG/AWG-узла и его пиров по тегу.
  /// Только чтение: спящий узел не будится, несобранный не собирается.
  /// Отказ ядра — [PlatformException] с кодом из [CcStatusError].
  Future<CcWireGuardStatus> getWireGuardStatus(String tag) async {
    final r = await _methods.invokeMethod<Map<dynamic, dynamic>>(
        _CcMethods.ccGetWireGuardStatus, {'tag': tag});
    return CcWireGuardStatus.fromMap(_asMap(r));
  }

  Future<bool> closeConnection(String id) async =>
      await _methods.invokeMethod<bool>(_CcMethods.ccCloseConnection, {'id': id}) ??
      false;

  Future<bool> closeConnections() async =>
      await _methods.invokeMethod<bool>(_CcMethods.ccCloseConnections) ?? false;

  Future<void> _invoke(String method) async {
    try {
      await _methods.invokeMethod<void>(method);
    } on PlatformException {
      // Канал недоступен (туннель down / сервис не поднят) — не фатально.
    } on MissingPluginException {
      // Плагин не зарегистрирован (юнит-тест / native не готов) — не фатально.
    }
  }

  static Map<String, dynamic> _asMap(Object? e) {
    if (e is Map) {
      return e.map((k, v) => MapEntry(k.toString(), v));
    }
    return const {};
  }

  static List<dynamic> _asList(Object? e) => e is List ? e : const [];
}

// ═══════════════════════════ Models ═══════════════════════════
