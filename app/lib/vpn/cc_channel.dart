import 'dart:async';

import 'package:flutter/services.dart';

import '../services/platform_channels.dart';

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

  static const EventChannel _statusChannel =
      EventChannel(PlatformChannels.ccStatus);
  static const EventChannel _outboundsChannel =
      EventChannel(PlatformChannels.ccOutbounds);
  static const EventChannel _groupsChannel =
      EventChannel(PlatformChannels.ccGroups);
  static const EventChannel _connectionsChannel =
      EventChannel(PlatformChannels.ccConnections);

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

  Future<void> connectScreen() => _invoke('ccConnectScreen');
  Future<void> disconnectScreen() => _invoke('ccDisconnectScreen');
  Future<void> connectProfiler() => _invoke('ccConnectProfiler');
  Future<void> disconnectProfiler() => _invoke('ccDisconnectProfiler');

  // §164 — энергомодель CC-клиентов.
  /// FAST (0.1с) — Stats открыт (плавность); NORMAL (0.5с) — главный экран.
  /// Пересоздаёт statusClient с новым интервалом (см. feature 123 §3).
  Future<void> setStatusFast(bool fast) async {
    try {
      await _methods.invokeMethod<void>('ccSetStatusFast', {'fast': fast});
    } catch (_) {/* native не готов — игнор, не критично */}
  }

  /// Фон (onAppPaused): гасим status+screen клиенты (0 тиков/0 drain).
  /// profilerClient НЕ трогаем — recording живёт в фоне. Выключение VPN ловит
  /// нативный broadcast, не CC (feature 123 §1.1/§4).
  Future<void> pauseClients() => _invoke('ccPauseClients');

  /// Возврат из фона (onAppResumed): поднимаем status(NORMAL)+screen(если refs>0).
  Future<void> resumeClients() => _invoke('ccResumeClients');

  // ─────────────────────────── Imperatives ───────────────────────────

  /// §4.6 — per-node delay. Возвращает `(delay, error)`. ИНВАРИАНТ: `error` —
  /// единственный признак провала; `delay==0 && error==''` = успех 0мс.
  /// `timeoutMs` — миллисекунды (0 → дефолт ядра).
  Future<CcDelayResult> urlTestOutbound(
    String tag, {
    String link = '',
    int timeoutMs = 0,
  }) async {
    final r = await _methods.invokeMethod<Map<dynamic, dynamic>>(
      'ccUrlTestOutbound',
      {'tag': tag, 'link': link, 'timeoutMs': timeoutMs},
    );
    return CcDelayResult.fromMap(_asMap(r ?? const {}));
  }

  /// §4.7 — снапшот route+DNS правил (диагностика).
  Future<List<CcRule>> getRules() async {
    final r = await _methods.invokeMethod<List<dynamic>>('ccGetRules');
    return (r ?? const []).map((m) => CcRule.fromMap(_asMap(m))).toList();
  }

  /// §122/SPEC015 — unary pull-снапшот групп. Закрывает дыру pull-vs-push:
  /// если стартовый `SubscribeGroups`-push потерялся (гонка waitForStarted), тут
  /// перечитываем дерево групп синхронно, не пересоздавая screenClient. `null` =
  /// ядро не смогло отдать (не-STARTED/нет клиента) — отличаем от `[]` (групп
  /// нет): на null caller НЕ трогает state, на [] — тоже (пустых при connected
  /// не бывает, см. _onCcGroups). Формат Map идентичен groups-стриму → CcGroup.fromMap.
  Future<List<CcGroup>?> getGroups() async {
    final r = await _methods.invokeMethod<List<dynamic>>('ccGetGroups');
    if (r == null) return null;
    return r.map((m) => CcGroup.fromMap(_asMap(m))).toList();
  }

  Future<bool> selectOutbound(String group, String tag) async =>
      await _methods.invokeMethod<bool>(
          'ccSelectOutbound', {'group': group, 'tag': tag}) ??
      false;

  Future<bool> closeConnection(String id) async =>
      await _methods.invokeMethod<bool>('ccCloseConnection', {'id': id}) ??
      false;

  Future<bool> closeConnections() async =>
      await _methods.invokeMethod<bool>('ccCloseConnections') ?? false;

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

/// §3.1 — статус от `writeStatus`. `uplink`/`downlink` — байтовая дельта за
/// интервал (B/s при interval=1s); `*Total` — накопленный объём.
class CcStatus {
  const CcStatus({
    this.uplink = 0,
    this.downlink = 0,
    this.uplinkTotal = 0,
    this.downlinkTotal = 0,
    this.memory = 0,
    this.goroutines = 0,
    this.connectionsIn = 0,
    this.connectionsOut = 0,
  });

  final int uplink;
  final int downlink;
  final int uplinkTotal;
  final int downlinkTotal;
  final int memory;
  final int goroutines;
  final int connectionsIn;
  final int connectionsOut;

  /// §3.1 — НЕ сумма in+out вслепую (могут двоить); для бейджа активных
  /// предпочтительнее длина connections-снапшота. Здесь — справочно.
  int get connectionsTotal => connectionsIn + connectionsOut;

  factory CcStatus.fromMap(Map<String, dynamic> m) => CcStatus(
        uplink: _int(m['uplink']),
        downlink: _int(m['downlink']),
        uplinkTotal: _int(m['uplinkTotal']),
        downlinkTotal: _int(m['downlinkTotal']),
        memory: _int(m['memory']),
        goroutines: _int(m['goroutines']),
        connectionsIn: _int(m['connectionsIn']),
        connectionsOut: _int(m['connectionsOut']),
      );
}

/// §2.4 — плоский узел из `writeOutbounds` (outbound ИЛИ endpoint).
class CcOutbound {
  const CcOutbound({
    required this.tag,
    required this.type,
    required this.urlTestDelay,
    required this.urlTestTime,
  });

  final String tag;
  final String type;

  /// Задержка в мс. 0 = не тестирован / не ответил — различать по `urlTestTime`.
  final int urlTestDelay;

  /// Unix-время последнего теста (0 = не тестирован).
  final int urlTestTime;

  factory CcOutbound.fromMap(Map<String, dynamic> m) => CcOutbound(
        tag: m['tag']?.toString() ?? '',
        type: m['type']?.toString() ?? '',
        urlTestDelay: _int(m['urlTestDelay']),
        urlTestTime: _int(m['urlTestTime']),
      );
}

/// §2.4 — группа из `writeGroups` (дерево). `selectable` заменяет `type=='Selector'`,
/// `selected` заменяет clash-поле `now`.
class CcGroup {
  const CcGroup({
    required this.tag,
    required this.type,
    required this.selectable,
    required this.selected,
    required this.isExpand,
    required this.items,
  });

  final String tag;
  final String type;
  final bool selectable;
  final String selected;
  final bool isExpand;
  final List<CcOutbound> items;

  factory CcGroup.fromMap(Map<String, dynamic> m) => CcGroup(
        tag: m['tag']?.toString() ?? '',
        type: m['type']?.toString() ?? '',
        selectable: m['selectable'] == true,
        selected: m['selected']?.toString() ?? '',
        isExpand: m['isExpand'] == true,
        items: (m['items'] is List ? m['items'] as List : const [])
            .map((e) => CcOutbound.fromMap(CcChannel._asMap(e)))
            .toList(),
      );
}

/// §3.1/§3.2 — соединение из аккумулятора. `closedAt`>0 = закрытое (closed-история).
///
/// §122 — `uplink`/`downlink` = НАКОПЛЕННЫЙ итог (`getUplinkTotal/DownlinkTotal`),
/// сколько ВСЕГО передано за соединение. `uplinkDelta`/`downlinkDelta` = байт за
/// последний тик статуса (мгновенная скорость; у idle = 0). `outbound`/
/// `outboundType` — нода/тип цепочки (замена Clash `chains`).
class CcConnection {
  const CcConnection({
    required this.id,
    required this.network,
    required this.domain,
    required this.destination,
    required this.rule,
    required this.uplink,
    required this.downlink,
    this.uplinkDelta = 0,
    this.downlinkDelta = 0,
    this.outbound = '',
    this.outboundType = '',
    this.protocol = '',
    this.packageName = '',
    this.processPath = '',
    required this.createdAt,
    required this.closedAt,
  });

  final String id;
  final String network;
  final String domain;
  final String destination;
  final String rule;

  /// Накопленный итог за соединение (всего передано). `getUplinkTotal`.
  final int uplink;
  final int downlink;

  /// Байт за последний тик (мгновенная скорость). `getUplink`. 0 у idle.
  final int uplinkDelta;
  final int downlinkDelta;

  /// Выбранная нода/тип цепочки (libbox `getOutbound`/`getOutboundType`).
  final String outbound;
  final String outboundType;
  final String protocol;

  /// App-attribution из `getProcessInfo()`: package (для иконки) + путь процесса.
  final String packageName;
  final String processPath;

  final int createdAt;
  final int closedAt;

  bool get isClosed => closedAt > 0;

  factory CcConnection.fromMap(Map<String, dynamic> m) => CcConnection(
        id: m['id']?.toString() ?? '',
        network: m['network']?.toString() ?? '',
        domain: m['domain']?.toString() ?? '',
        destination: m['destination']?.toString() ?? '',
        rule: m['rule']?.toString() ?? '',
        uplink: _int(m['uplink']),
        downlink: _int(m['downlink']),
        uplinkDelta: _int(m['uplinkDelta']),
        downlinkDelta: _int(m['downlinkDelta']),
        outbound: m['outbound']?.toString() ?? '',
        outboundType: m['outboundType']?.toString() ?? '',
        protocol: m['protocol']?.toString() ?? '',
        packageName: m['packageName']?.toString() ?? '',
        processPath: m['processPath']?.toString() ?? '',
        createdAt: _int(m['createdAt']),
        closedAt: _int(m['closedAt']),
      );
}

/// §4.6 — результат `urlTestOutbound`. Источник истины провала — `error`.
class CcDelayResult {
  const CcDelayResult({required this.delay, required this.error});

  final int delay;
  final String error;

  bool get ok => error.isEmpty;

  /// Маппинг в UI-контракт `lastDelay` (§4.6): ok → delay (вкл. 0мс); fail → -1.
  int get lastDelayValue => ok ? delay : -1;

  factory CcDelayResult.fromMap(Map<String, dynamic> m) => CcDelayResult(
        delay: _int(m['delay']),
        error: m['error']?.toString() ?? '',
      );
}

/// §4.7 — правило из `getRules` (route+DNS).
class CcRule {
  const CcRule({
    required this.type,
    required this.payload,
    required this.action,
    required this.isDNS,
  });

  final String type;
  final String payload;
  final String action;
  final bool isDNS;

  factory CcRule.fromMap(Map<String, dynamic> m) => CcRule(
        type: m['type']?.toString() ?? '',
        payload: m['payload']?.toString() ?? '',
        action: m['action']?.toString() ?? '',
        isDNS: m['isDNS'] == true,
      );
}

int _int(Object? v) => v is int ? v : (v is num ? v.toInt() : 0);
