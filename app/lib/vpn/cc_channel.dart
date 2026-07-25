import 'dart:async';

import 'package:flutter/services.dart';

import '../services/platform_channels.dart';
import '../services/selector_info.dart'; // §251 — fold «селектор (выбор)»

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
  static const EventChannel _dnsChannel =
      EventChannel(PlatformChannels.ccDns); // §180

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
  Future<void> resyncForReopen() => _invoke('ccResyncForReopen');

  Future<void> connectScreen() => _invoke('ccConnectScreen');
  Future<void> disconnectScreen() => _invoke('ccDisconnectScreen');
  Future<void> connectProfiler() => _invoke('ccConnectProfiler');
  Future<void> disconnectProfiler() => _invoke('ccDisconnectProfiler');

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

  /// §175 — отмена масс-пинга: disconnect отдельного pingClient → ядро рвёт
  /// per-call ctx in-flight URLTest'ов (не дожидаясь TCPTimeout), не задевая
  /// status/screen/profiler-стримы. Следующий urlTestOutbound поднимет свежий.
  Future<void> cancelPing() => _invoke('ccCancelPing');

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

  /// §308 — групповой URLTest: ядро force-тестит ВСЕХ членов группы её
  /// конфиг-URL'ом (`urltest_url` шаблона, не ping settings) и делает
  /// переселект на живой узел. Fire-and-forget: `true` = команда принята;
  /// результаты приедут стримами (groups → selected, history → делеи).
  Future<bool> urlTestGroup(String tag) async =>
      await _methods.invokeMethod<bool>('ccUrlTestGroup', {'tag': tag}) ??
      false;

  // ─── §236 — headless probe-сессия (Test servers при выключенном VPN) ───

  /// Стартует probe-инстанс ядра (конфиг БЕЗ tun). Возвращает '' при успехе,
  /// текст ошибки иначе (в т.ч. «VPN is running…» — тогда caller уходит на
  /// ветку [urlTestOutbound] через боевое ядро).
  Future<String> probeStart(String config) async {
    final r = await _methods
        .invokeMethod<String>('probeStart', {'config': config});
    return r ?? '';
  }

  /// Тест одной ноды в probe-сессии. Семантика результата как у
  /// [urlTestOutbound] (Variant B: провал — только в `error`).
  Future<CcDelayResult> probeUrlTest(
    String tag, {
    String link = '',
    int timeoutMs = 0,
  }) async {
    final r = await _methods.invokeMethod<Map<dynamic, dynamic>>(
      'probeUrlTest',
      {'tag': tag, 'link': link, 'timeoutMs': timeoutMs},
    );
    return CcDelayResult.fromMap(_asMap(r ?? const {}));
  }

  /// Гасит probe-сессию (идемпотентно).
  Future<void> probeStop() => _methods.invokeMethod<void>('probeStop');

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

  /// §208/§209 — unary снапшот пула round_robin-группы [tag]. Слоты
  /// `[{slot,tag,delay}]` в фиксированном порядке слота. `delay`==0 → мёртвая/не
  /// измерена.
  ///
  /// КОНТРАКТ (§209): `null` = CC-клиент недоступен (сервис down / pingClient не
  /// поднялся) — НЕ путать с пустым пулом. `[]` = пул пуст (группа не
  /// round_robin / нет данных). Идёт через незасыпающий pingClient (native), так
  /// что в фоне отдаёт данные, а не молчит.
  Future<List<CcPoolSlot>?> getPool(String tag) async {
    final r = await _methods
        .invokeMethod<List<dynamic>>('ccGetPool', {'tag': tag});
    if (r == null) return null; // клиент недоступен (§209)
    return r.map((m) => CcPoolSlot.fromMap(_asMap(m))).toList();
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
/// `outboundType` — выбранная нода/тип; `chains` — полная outbound-цепочка
/// (Clash `chains`, §174: ядро отдаёт через `Connection.chain()`-итератор).
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
    this.chains = const [],
    this.detours = const [],
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

  /// Выбранная нода/тип (libbox `getOutbound`/`getOutboundType`).
  final String outbound;
  final String outboundType;
  final String protocol;

  /// §174 — полная outbound-цепочка (Clash `chains`): selector→urltest→node.
  /// Из `Connection.chain()`-итератора ядра. Пусто для прямого outbound.
  final List<String> chains;

  /// §178 — detour-хвост финального outbound (ядро SPEC 017, `Connection.detour()`).
  /// Транспортная ось (куда физически ныряет пакет: `node → WARP`), порядок
  /// node→наружу. Пусто: прямой outbound / block / dns / ядро без поля 23.
  /// НЕ дублирует `chains` — node там, detour-теги тут.
  final List<String> detours;

  /// App-attribution из `getProcessInfo()`: package (для иконки) + путь процесса.
  final String packageName;
  final String processPath;

  final int createdAt;
  final int closedAt;

  bool get isClosed => closedAt > 0;

  /// §204 — routing-строка в нотации §252 (эволюция §181), идентичная
  /// `TrafficEvent.routingLineOf`: `[net] rule ⇒ группы : транспорт-вход → …
  /// → выход (селектор (выбор)) → dest` — справа от `:` физический путь
  /// пакета (вход первым, выход перед целью).
  /// `chains`/`detours` приходят из ТОГО ЖЕ источника ядра, что
  /// `TrafficEvent.outboundChain`/`detourChain` (`Connection.chain()`/`.detour()`),
  /// порядок идентичен (`[node, …selectors]` / `[node→наружу]`) — поэтому логика
  /// копируется 1:1.
  ///
  /// Отличия от TrafficEvent (намеренно): process НЕ включаем (у ряда Conns своя
  /// app-строка); duration НЕ дописываем (§204 D — таймер рендерится отдельным
  /// виджетом справа в ряду / секцией Timing в detail, не внутри строки).
  ///
  /// [compact] — для ряда: опускает префикс `[net]` (дублирует бейдж/иконку),
  /// строка начинается с `rule`.
  /// [ruleLabel] — резолвленное человекочитаемое имя правила (UI-слой
  /// `RuleNameResolver`); если передано — используется вместо сырого `rule`
  /// (модель vpn не знает про резолвер). Пусто → берётся `rule` или `final`.
  String routingLineOf({bool compact = false, String? ruleLabel}) {
    final sb = StringBuffer();
    // Ось решения (⇒): [net] rule → селекторы (сверху вниз = chains[1:].reversed).
    final inner = <String>[];
    final ruleText = (ruleLabel != null && ruleLabel.isNotEmpty)
        ? ruleLabel
        : (rule.isNotEmpty ? rule : 'final');
    inner.add(!compact && network.isNotEmpty ? '[$network] $ruleText' : ruleText);
    if (chains.length > 1) inner.addAll(chains.sublist(1).reversed);
    sb.write(inner.join(' ⇒ '));
    // §252 — физический путь (→ по ходу пакета): транспорт изнутри наружу
    // (detour-ось развёрнута: вход первым) → выход ОДНИМ элементом
    // `селектор (…вложенно… (node))` (свёртка ПО СТРУКТУРЕ chains
    // `[node, …selectors]`, не через SelectorInfo; пустые chains —
    // outbound-fallback) → назначение.
    final phys = <String>[...foldSelectorPairs(detours).reversed];
    final exitChain =
        chains.isNotEmpty ? chains : (outbound.isNotEmpty ? [outbound] : null);
    if (exitChain != null) {
      var exit = exitChain.first;
      for (final sel in exitChain.skip(1)) {
        exit = '$sel ($exit)';
      }
      phys.add(exit);
    }
    final dest = domain.isNotEmpty ? domain : _hostOfDestination;
    if (dest.isNotEmpty) phys.add(dest);
    if (phys.isNotEmpty) sb.write(' : ${phys.join(' → ')}');
    return sb.toString();
  }

  /// Host из `destination` (`host:port` → `host`); IPv6 в `[..]:port` сохраняем.
  String get _hostOfDestination {
    final d = destination;
    if (d.isEmpty) return '';
    if (d.startsWith('[')) {
      final end = d.indexOf(']');
      return end > 0 ? d.substring(0, end + 1) : d;
    }
    final colon = d.lastIndexOf(':');
    return colon > 0 ? d.substring(0, colon) : d;
  }

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
        chains: (m['chains'] as List?)?.map((e) => e.toString()).toList() ??
            const [],
        detours: (m['detours'] as List?)?.map((e) => e.toString()).toList() ??
            const [],
        packageName: m['packageName']?.toString() ?? '',
        processPath: m['processPath']?.toString() ?? '',
        createdAt: _int(m['createdAt']),
        closedAt: _int(m['closedAt']),
      );
}

/// §180 — структурное DNS-событие из ядра (SPEC 018 v2, §261: команда
/// `CommandDNS` в мультиплексе profilerClient, приходит через `writeDNSQuery`).
/// Заменяет текстовый парсинг core-лога: атрибуция к приложению (`packageName`)
/// приходит ИЗ ЯДРА (processInfo), не сшивается по connId.
class CcDnsQuery {
  const CcDnsQuery({
    required this.domain,
    required this.queryType,
    required this.rcode,
    this.ttl = 0,
    this.source = '',
    this.failed = false,
    this.error = '',
    this.packageName = '',
    this.processPath = '',
    this.dnsServer = '',
    this.dnsServerType = '',
    this.outbound = const [],
    this.answers = const [],
  });

  /// Запрошенный домен (оригинал, не финальный CNAME-target).
  final String domain;

  /// qtype: 1=A, 28=AAAA, 5=CNAME, 65=HTTPS, 33=SRV, … (DNS RR type).
  final int queryType;

  /// Q1 (SPEC 018): `-1` = НЕТ ОТВЕТА (timeout), физически ≠ 65535. Иначе —
  /// реальный response.Rcode (0=NOERROR, 3=NXDOMAIN…). НЕ кастить в unsigned:
  /// ядро отдаёт signed, `_int` знак сохраняет.
  final int rcode;

  final int ttl;

  /// exchanged/cached/optimistic/refreshed/rejected/failed (источник ответа).
  final String source;

  /// Q2 (SPEC 018): true на провале (timeout/SERVFAIL/rejected/loopback).
  /// failed-событие → профайлер делает `dnsFail`.
  final bool failed;

  /// Причина провала ("timeout"/"loopback"/"rejected"…); "" на успехе.
  final String error;

  /// Атрибуция к приложению ИЗ ЯДРА (processInfo). Часто непуст — в отличие от
  /// connId-сшивки текстового пути (корень §177-баннера).
  final String packageName;
  final String processPath;

  /// rc.10 (SPEC 018+) — какой DNS-сервер резолвил запрос (на всех путях, вкл.
  /// провалы). Пусто на старом ядре / если ядро не отдало.
  final String dnsServer;

  /// rc.10 — тип DNS-сервера (udp/tcp/tls/https/quic/…).
  final String dnsServerType;

  /// rc.10 — outbound-канал DNS-сервера (селектор развёрнут в активный узел
  /// через Now() server-side), список как chain/detour. ПУСТО на cached
  /// (cache-hit без сетевого пути).
  final List<String> outbound;

  /// Q3 (SPEC 018): ВЕСЬ response.Answer (CNAME-hops + финальные A/AAAA) в
  /// исходном порядке. Пусто если подписка без includeAnswers. cnameChain
  /// собирается из элементов с type==CNAME(5).
  final List<CcDnsAnswer> answers;

  /// Q1-helper: ответа от сервера не было (timeout).
  bool get noAnswer => rcode == -1;

  factory CcDnsQuery.fromMap(Map<String, dynamic> m) => CcDnsQuery(
        domain: m['domain']?.toString() ?? '',
        queryType: _int(m['queryType']),
        rcode: _int(m['rcode']), // знак сохраняется → -1 остаётся -1 (Q1)
        ttl: _int(m['ttl']),
        source: m['source']?.toString() ?? '',
        failed: m['failed'] == true,
        error: m['error']?.toString() ?? '',
        packageName: m['packageName']?.toString() ?? '',
        processPath: m['processPath']?.toString() ?? '',
        dnsServer: m['dnsServer']?.toString() ?? '',
        dnsServerType: m['dnsServerType']?.toString() ?? '',
        outbound: (m['outbound'] as List?)
                ?.map((e) => e.toString())
                .where((s) => s.isNotEmpty)
                .toList() ??
            const [],
        answers: (m['answers'] as List?)
                ?.map((a) => CcDnsAnswer.fromMap(
                    (a as Map).map((k, v) => MapEntry(k.toString(), v))))
                .toList() ??
            const [],
      );
}

/// §180 — одна DNS-запись ответа (RR). Часть `CcDnsQuery.answers`.
class CcDnsAnswer {
  const CcDnsAnswer({
    required this.name,
    required this.type,
    required this.rdata,
    this.ttl = 0,
  });

  final String name;
  final int type; // RR type (5=CNAME, 1=A, 28=AAAA…)
  final String rdata; // значение записи (target для CNAME, IP для A/AAAA)
  final int ttl;

  bool get isCname => type == 5;
  bool get isAddress => type == 1 || type == 28; // A / AAAA

  factory CcDnsAnswer.fromMap(Map<String, dynamic> m) => CcDnsAnswer(
        name: m['name']?.toString() ?? '',
        type: _int(m['type']),
        rdata: m['rdata']?.toString() ?? '',
        ttl: _int(m['ttl']),
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

/// §208 (SPEC 019 V2) — один слот пула round_robin-группы (`getPool`). Слоты
/// фиксированы по `slot`; нода в слоте может меняться (дотест). `delay`==0 →
/// мёртвая / не измерена (живая всегда ≥1 — ядро клампит на чтении).
class CcPoolSlot {
  const CcPoolSlot({required this.slot, required this.tag, required this.delay});

  final int slot;
  final String tag;
  final int delay; // мс, 0 = мёртвая/не измерена

  /// true → нода в слоте жива (есть замер). false → мёртвая/не измерена.
  bool get alive => delay > 0;

  factory CcPoolSlot.fromMap(Map<String, dynamic> m) => CcPoolSlot(
        slot: _int(m['slot']),
        tag: m['tag']?.toString() ?? '',
        delay: _int(m['delay']),
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
