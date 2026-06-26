// §044 — Per-app traffic profiler.
// §048 — Inclusive observer with confidence: каждое событие попадает в UI
// с confidence level'ом, юзер видит всё что произошло на сети.
//
// Singleton ChangeNotifier. Holds текущую recording session + ring-buffer
// последних N завершённых session'ов + **глобальный rolling buffer** всех
// событий (always-running, 60s window) для:
//   - pre-session backfill (юзер ставит recording после того как заметил
//     проблему — теряет первые 60s контекста)
//   - Live system-wide tab — discovery-mode без выбора target заранее
//
// Всё in-memory — на kill app'а всё стирается. Сознательно: упрощает
// model'ку, persist бы добавил schema'ы и migration'ы которые мало что
// дают для diagnostic-only-фичи.
//
// Data sources:
//   1. Sing-box log stream (через ClashLogPump → AppLog → here): ловим
//      ТОЛЬКО package detection (`router: found package name: X`) со связкой
//      `[conn_id Nms]` → `_connIdToMeta` (TCP-атрибуция). §180 — DNS-парсинг из
//      лога ВЫПИЛЕН (см. источник 3).
//   2. §168 — CommandClient `connections` push-стрим (`CcChannel.connections`):
//      tcp/udp open/close + per-app атрибуция (`packageName`/`processPath` из
//      libbox `getProcessInfo()`) + stats (bytes, duration). Подключается через
//      profilerClient (`connectProfiler()`), который §164-энергомодель НЕ паузит
//      в фоне → recording живёт при свёрнутом app. Раньше тут был Clash API
//      `/connections` polling (5s) — выпилен в §122, профайлер остался на
//      пустом fetcher'е (buffer_count=0), §168 перевёл на CommandClient.
//   3. §180 — CommandClient `dnsQueries` стрим (`CcChannel.dnsQueries`, ядро
//      SPEC 018): структурные DNS-события с атрибуцией к процессу ИЗ ЯДРА
//      (processInfo) + cnameChain из answers[] одним событием. Заменил текстовый
//      парсинг лога (regex `_dnsRe`/`_handleDnsLine` + `_DnsAccumulator` по
//      conn_id) — тот сшивал package по connId (хрупко, корень §177-баннера).
//
// Спарка connections — через `metadata.process`; DNS атрибутируется ядром.
//
// **Confidence levels** (§048 Принцип 3):
//   - `verified`     — `router: found package` явный match с targetPackage
//   - `secondary`    — match через `secondaryPackages` (WebView etc)
//   - `inferred`     — match через recent DNS resolved IP (10s window)
//   - `unattributed` — никакая strategy не сработала, но event возможно от target
//
// Connection-issue классификация: 2 типа — `dnsTimeout` (прямо из sing-box
// log stream'а, реальная error-строка) и `tcpReset` (heuristic «conn
// закрылся <1с с 0 bytes»).

import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/debug_entry.dart';
import '../vpn/cc_channel.dart';
import 'app_log.dart';
import 'format_utils.dart'; // §181 — formatDuration в routingLine
import 'settings_storage.dart';

part 'traffic_profiler/models.dart';
part 'traffic_profiler/internal.dart';

// ─────────────────────────────────────────────────────────────────────────
// TrafficProfiler singleton
// ─────────────────────────────────────────────────────────────────────────

class TrafficProfiler extends ChangeNotifier {
  TrafficProfiler._();
  static final TrafficProfiler I = TrafficProfiler._();

  // ─── Config knobs ─────────────────────────────────────────────────────
  static const int _maxCompleted = 5;
  static const int _maxEventsPerSession = 50000;
  static const Duration _slidingWindow = Duration(hours: 3);
  // §048 Принцип 6 — time-bound TTL для conn-id correlation.
  static const Duration _connIdTtl = Duration(seconds: 30);
  // §141 P3.2b — GC-интервал 5s → 15s: TTL=30s, чистить втрое чаще TTL
  // избыточно (entry переживёт максимум +15s до удаления, всё ещё внутри
  // запаса). Втрое меньше пробуждений + разводит фазу с _connPollInterval
  // (5s), которые раньше совпадали каждые 5s как два независимых wakeup'а.
  static const Duration _connIdGcInterval = Duration(seconds: 15);
  static const Duration _processInferenceWindow = Duration(seconds: 10);
  // §048 Принцип 4 — global rolling buffer всегда работает, окно 60s,
  // hard cap 3000 events чтобы memory не убегало на busy device'ах.
  static const Duration _globalRollingWindow = Duration(seconds: 60);
  static const int _globalRollingHardCap = 3000;
  // Banner threshold: >5 unattributed за 30s → user-visible warning.
  static const int _unattributedBannerThreshold = 5;
  static const Duration _unattributedBannerWindow = Duration(seconds: 30);

  // ─── Live wiring (§168) ───────────────────────────────────────────────
  // Источник connection-событий — CommandClient push-стрим. Подписка живёт
  // пока есть active session ИЛИ global recording; снимается когда оба off.
  final CcChannel _cc = CcChannel.instance;
  StreamSubscription<List<CcConnection>>? _ccConnSub;
  StreamSubscription<List<CcDnsQuery>>? _ccDnsSub; // §180 — DNS-журнал из ядра

  // ─── State ────────────────────────────────────────────────────────────
  Session? _active;
  final ListQueue<Session> _completed = ListQueue<Session>();
  String? _verboseSavedLogLevel; // pre-toggle value, чтобы revert на stop

  // SSE listeners — стрим эвентов наружу для Debug API SSE.
  // Per-session stream'ы (исторический endpoint /profiler/stream).
  final List<StreamController<Map<String, Object?>>> _sessionStreamSinks =
      <StreamController<Map<String, Object?>>>[];
  // Global stream'ы (Live tab + /profiler/live/stream).
  final List<StreamController<Map<String, Object?>>> _globalStreamSinks =
      <StreamController<Map<String, Object?>>>[];

  // §048 Принцип 4/7 — глобальный rolling buffer всех events системы.
  // Включается **explicit** через `startGlobalRecording()` (юзер тапнул
  // ▶ START в Live tab); останавливается через `stopGlobalRecording()` или
  // app kill. Без active recording listener detached, buffer не растёт —
  // никаких теневых потребителей.
  //
  // Используется для:
  //   a) Pre-session backfill — на start session backfill события за last
  //      60s которые match'ат target. Работает только если global
  //      recording был включён.
  //   b) Live system-wide tab — discovery без выбора target заранее.
  final ListQueue<TrafficEvent> _globalRollingBuffer =
      ListQueue<TrafficEvent>();

  // §048 — explicit recording state. Independent of UI subscription:
  // recording продолжается когда юзер ушёл с Live tab'а / свернул app.
  bool _globalRecordingActive = false;
  DateTime? _globalRecordingStartedAt;

  // §048 Принцип 1 — отдельный ring-buffer unattributed events (DNS fail
  // без owner / HTTPS / SOA / SVCB) для UI «System-wide events» секции
  // в Per-app Live tab'е. 50 events достаточно чтобы юзер увидел тренд.
  final ListQueue<TrafficEvent> _globalUnattributedEvents =
      ListQueue<TrafficEvent>();
  static const int _globalUnattributedCap = 50;

  // Tracks whether log subscription / GC timers are running. Привязка
  // делается lazily на первый event consumer (start session ИЛИ subscribe
  // на global stream / запрос snapshot'а). Detach — когда нет ни active
  // session'а, ни global subscribers'ов.
  VoidCallback? _appLogListener;
  Timer? _gcTimer;

  // §141 P3.1a — leading-edge throttle для notifyListeners (≤60Hz), эталон
  // AppLog._scheduleNotify. _appendEvent звался на КАЖДОМ traffic-event без
  // троттла → на бёрсте (100+ ev/сек) UI ребилдился каждую мс. Stream-эмит
  // (_emitSessionStream) остаётся per-event — он data-канал, не UI.
  static const _notifyWindow = Duration(milliseconds: 16);
  Timer? _notifyThrottleTimer;
  bool _notifyPending = false;
  // Timestamp последнего обработанного core-log entry. Используется
  // вместо length-diff потому что AppLog имеет ring-buffer cap=500: при
  // overflow length стабилизируется на 500 и length-diff навечно =0,
  // мы бы пропускали всё. Timestamp монотонный и не зависит от cap'а.
  DateTime? _lastSeenLogTs;

  // Conn-id → package map (TTL'нутый, time-based GC).
  final Map<String, _ConnMeta> _connIdToMeta = <String, _ConnMeta>{};

  // §180 — `_dnsByConnId` (per-conn-id DNS accumulator) выпилен: cnameChain
  // теперь приходит целиком в одном CcDnsQuery.answers (ядро SPEC 018), ручная
  // аккумуляция по connId не нужна.

  // Last-known connection state from /connections poll: id → snapshot.
  // Используется для diff (closed connections).
  final Map<String, _ConnSnapshot> _connSnapshots = <String, _ConnSnapshot>{};

  // §176 — id уже-обработанных closed-conn → когда обработан. ЗАЩИТА ОТ ДУБЛЯ:
  // ядро держит closed-conn в FilterState(All) до 5 мин (closedConnectionMaxAge),
  // т.е. один и тот же закрытый conn приходит в снапшоте КАЖДЫЙ тик 5 минут.
  // Без guard'а профайлер на каждом тике повторно эмитил бы open+close → лавина
  // дублей. Сюда кладём id при обработке closed-дельты; повторные пропускаем.
  // Чистится по TTL в _gcStaleConnIds (старше 5 мин — ядро их уже эвиктнуло).
  final Map<String, DateTime> _closedHandled = <String, DateTime>{};

  // ─── Public API ───────────────────────────────────────────────────────

  Session? get active => _active;
  List<Session> get completed => List.unmodifiable(_completed);
  bool get isRecording => _active != null;
  Session? get current => _active;

  /// §048 — публичный getter глобального rolling buffer'а (для Live tab UI).
  List<TrafficEvent> get globalRollingBuffer =>
      List.unmodifiable(_globalRollingBuffer);

  /// §048 — recording state для Live tab. Independent of UI subscriptions.
  bool get isGlobalRecording => _globalRecordingActive;
  DateTime? get globalRecordingStartedAt => _globalRecordingStartedAt;

  /// §048 — explicit START для Live tab. Стартует listener attach + GC.
  /// Recording продолжается когда юзер ушёл с tab'а / свернул app — пока
  /// не вызван `stopGlobalRecording()` или app не убит.
  ///
  /// Идемпотентен: повторный вызов = no-op (recording уже running).
  void startGlobalRecording() {
    if (_globalRecordingActive) return;
    _globalRecordingActive = true;
    _globalRecordingStartedAt = DateTime.now();
    // Чистый старт — buffer чистится чтобы юзер видел только то что было
    // записано в этой recording-сессии. Если хочешь preserve — убери clear.
    _globalRollingBuffer.clear();
    _globalUnattributedEvents.clear();
    _ensureLogListenerAttached();
    _ensureGcTimerStarted();
    // §168 — system-wide recording слушает CommandClient connections-стрим
    // (open/close + per-app). Без этого в Live видны только DNS-строки из
    // core-логов, а tcp/udp open/close приходят только из connections.
    _attachCcConnections();
    AppLog.I.info('TrafficProfiler: global recording started');
    notifyListeners();
  }

  /// §048 — explicit STOP для Live tab. Detaches listener + GC. Buffer
  /// «freezes» (остаётся как был на момент stop), юзер может видеть
  /// последнее состояние пока не нажмёт START снова.
  ///
  /// Идемпотентен: повторный вызов = no-op.
  void stopGlobalRecording() {
    if (!_globalRecordingActive) return;
    _globalRecordingActive = false;
    _globalRecordingStartedAt = null;
    _maybeDetachLogListener();
    _maybeStopGcTimer();
    _maybeDetachCcConnections();
    AppLog.I.info('TrafficProfiler: global recording stopped');
    notifyListeners();
  }

  /// §048 — публичный getter unattributed ring buffer'а (для Per-app Live
  /// «System-wide events» section).
  List<TrafficEvent> get globalUnattributedEvents =>
      List.unmodifiable(_globalUnattributedEvents);

  /// §048 — count unattributed events за last [_unattributedBannerWindow]
  /// (для banner detection в UI: > [_unattributedBannerThreshold] = warning).
  ///
  /// §177-A — в счёт идут ТОЛЬКО признаки сбоя ([_isBannerWorthy]). Успешный
  /// `dnsResolve` без владельца — норма (DNS плохо атрибутируется, §171), не
  /// тревога; раньше он ложно зажигал баннер почти постоянно на busy-устройстве.
  int get recentUnattributedCount {
    final cutoff = DateTime.now().subtract(_unattributedBannerWindow);
    var n = 0;
    for (final e in _globalUnattributedEvents) {
      if (!e.ts.isAfter(cutoff)) continue;
      if (!_isBannerWorthy(e)) continue;
      n++;
    }
    return n;
  }

  /// §177-A — событие достойно баннера (признак сбоя), если это DNS-fail или
  /// TCP/UDP без владельца. Успешный dnsResolve без атрибуции — норма, не в счёт.
  /// Кольцо `_globalUnattributedEvents` НЕ фильтруем — UI-секция и Debug API
  /// показывают всё; меняется только что считать ТРЕВОГОЙ.
  bool _isBannerWorthy(TrafficEvent e) {
    if (e.kind == TrafficEventKind.dnsFail) return true;
    if ((e.kind == TrafficEventKind.tcpOpen ||
            e.kind == TrafficEventKind.udpOpen) &&
        (e.process == null || e.process!.isEmpty)) {
      return true;
    }
    return false;
  }

  bool get unattributedBannerActive =>
      recentUnattributedCount > _unattributedBannerThreshold;

  /// Start session for [targetPackage]. If уже active — finalize старый
  /// и стартуем новый. Если [verbose] = true — sets `log_level=debug`
  /// (caller сам решает делать reload).
  ///
  /// §048 Принцип 4 — на старте делаем backfill из `_globalRollingBuffer`:
  /// все events за last 60s которые match target → попадают в session.events
  /// с флагом `backfilled=true` и оригинальным confidence уровнем.
  Future<Session> start(
    String targetPackage, {
    bool verbose = false,
    Set<String>? secondaryPackages,
  }) async {
    if (_active != null) {
      await stop();
    }
    final session = Session(
      id: _generateId(),
      targetPackage: targetPackage,
      startedAt: DateTime.now(),
      wasVerbose: verbose,
      secondaryPackages: secondaryPackages,
    );
    _active = session;

    if (verbose) {
      _verboseSavedLogLevel = await SettingsStorage.getVar('log_level', '');
      await SettingsStorage.setVar('log_level', 'debug');
    }

    // Подписываемся на logs (no-op если уже подписаны через global).
    _ensureLogListenerAttached();
    // Стартуем GC timer (no-op если уже запущен).
    _ensureGcTimerStarted();
    // §168 — подписка на CommandClient connections (no-op если уже подписаны
    // через global recording).
    _attachCcConnections();

    // §048 Принцип 4 — backfill из global rolling buffer.
    _backfillFromGlobalRollingBuffer(session);

    AppLog.I.info('TrafficProfiler: session started for $targetPackage'
        '${secondaryPackages != null && secondaryPackages.isNotEmpty
            ? " (+secondary: ${secondaryPackages.join(",")})"
            : ""}'
        ' (backfilled ${session.events.length} events)');
    _emitSessionStream({
      'event': 'session_started',
      'data': session.toMetaJson(),
    });
    notifyListeners();
    return session;
  }

  /// Stop active session. Returns session (also added to completed).
  /// Returns null если активной сессии не было.
  Future<Session?> stop() async {
    final s = _active;
    if (s == null) return null;
    s.finishedAt = DateTime.now();

    // Stop session-specific data sources. Log listener / CC connections /
    // GC timer остаются running если есть global recording — иначе detach.
    _maybeDetachCcConnections();
    _maybeDetachLogListener();
    _maybeStopGcTimer();

    // Revert log_level если был toggle.
    if (s.wasVerbose) {
      final prev = _verboseSavedLogLevel ?? '';
      if (prev.isEmpty) {
        await SettingsStorage.removeVar('log_level');
      } else {
        await SettingsStorage.setVar('log_level', prev);
      }
      _verboseSavedLogLevel = null;
    }

    // Push в completed ring-buffer.
    _completed.addLast(s);
    while (_completed.length > _maxCompleted) {
      _completed.removeFirst();
    }
    _active = null;

    // Очищаем session-scoped maps. _globalRollingBuffer не трогаем —
    // он живёт независимо.
    _connSnapshots.clear();
    _closedHandled.clear(); // §176

    AppLog.I.info(
        'TrafficProfiler: session stopped, ${s.events.length} events, '
        '${s.byDomain.length} domains');
    _emitSessionStream({
      'event': 'session_finished',
      'data': s.toMetaJson(),
    });
    notifyListeners();
    return s;
  }

  /// Удалить session из completed.
  bool delete(String sessionId) {
    final before = _completed.length;
    _completed.removeWhere((s) => s.id == sessionId);
    final removed = before != _completed.length;
    if (removed) notifyListeners();
    return removed;
  }

  /// Очистить все completed sessions.
  int clearAll() {
    final n = _completed.length;
    _completed.clear();
    if (n > 0) notifyListeners();
    return n;
  }

  Session? getById(String sessionId) {
    if (_active?.id == sessionId) return _active;
    for (final s in _completed) {
      if (s.id == sessionId) return s;
    }
    return null;
  }

  /// §048 Принцип 3 — изменить set secondary packages для активной session'и.
  /// Эффект применяется к будущим events; уже накопленные events остаются
  /// с старым confidence (юзер видит изменение в `Live` после toggle).
  /// Возвращает `true` если что-то изменилось.
  bool updateSecondaryPackages(Set<String> packages) {
    final s = _active;
    if (s == null) return false;
    final wasSame = s.secondaryPackages.length == packages.length &&
        s.secondaryPackages.containsAll(packages);
    if (wasSame) return false;
    s.secondaryPackages
      ..clear()
      ..addAll(packages);
    s._markDirty();
    notifyListeners();
    return true;
  }

  /// Per-session live stream. Подписаться на events ТОЛЬКО для активной
  /// session'и. Закрывается на session_finished. (Backward-compatible
  /// endpoint для /profiler/stream.)
  Stream<Map<String, Object?>> liveStream() {
    late StreamController<Map<String, Object?>> ctrl;
    ctrl = StreamController<Map<String, Object?>>(
      onCancel: () {
        _sessionStreamSinks.remove(ctrl);
        ctrl.close();
      },
    );
    _sessionStreamSinks.add(ctrl);
    return ctrl.stream;
  }

  /// §048 — Global system-wide live stream. Подписаться на ВСЕ events
  /// (без session filter'а). Используется Live tab'ом UI и
  /// `/profiler/live/stream` SSE endpoint'ом.
  ///
  /// **НЕ** включает recording автоматически. Если `startGlobalRecording()`
  /// не был вызван — events не идут (listener detached). Подписка
  /// безопасна но «пустая» пока recording off.
  Stream<Map<String, Object?>> globalLiveStream() {
    late StreamController<Map<String, Object?>> ctrl;
    ctrl = StreamController<Map<String, Object?>>(
      onCancel: () {
        _globalStreamSinks.remove(ctrl);
        if (!ctrl.isClosed) ctrl.close();
      },
    );
    _globalStreamSinks.add(ctrl);
    return ctrl.stream;
  }

  /// §048 — snapshot последних [seconds] секунд из global rolling buffer'а.
  /// Используется `/profiler/live?seconds=N`.
  List<TrafficEvent> globalSnapshot({int seconds = 60}) {
    final cutoff =
        DateTime.now().subtract(Duration(seconds: seconds.clamp(1, 600)));
    return _globalRollingBuffer
        .where((e) => e.ts.isAfter(cutoff))
        .toList(growable: false);
  }

  void _emitSessionStream(Map<String, Object?> event) {
    if (_sessionStreamSinks.isEmpty) return;
    for (final c in List.of(_sessionStreamSinks)) {
      if (!c.isClosed) c.add(event);
    }
  }

  void _emitGlobalStream(Map<String, Object?> event) {
    if (_globalStreamSinks.isEmpty) return;
    for (final c in List.of(_globalStreamSinks)) {
      if (!c.isClosed) c.add(event);
    }
  }

  // ─── Log subscription (lazy) ──────────────────────────────────────────

  /// Подключиться к AppLog (no-op если уже подключён). Вызывается из:
  ///   - start(): нужен log stream для events session'и
  ///   - globalLiveStream(): нужен log stream даже без active session
  void _ensureLogListenerAttached() {
    if (_appLogListener != null) return;
    final entries = AppLog.I.entriesForSource(DebugSource.core);
    _lastSeenLogTs = entries.isNotEmpty ? entries.first.time : null;
    _appLogListener = () {
      _drainNewLogEntries();
    };
    AppLog.I.addListener(_appLogListener!);
  }

  /// Отключиться от AppLog **только если** нет active session'и
  /// и global recording выключен. Иначе оставляем running.
  /// (UI-subscriptions через `globalLiveStream()` НЕ учитываются — они
  /// passive, не запускают сами по себе recording.)
  void _maybeDetachLogListener() {
    if (_active != null) return;
    if (_globalRecordingActive) return;
    if (_appLogListener == null) return;
    AppLog.I.removeListener(_appLogListener!);
    _appLogListener = null;
    _lastSeenLogTs = null;
  }

  void _ensureGcTimerStarted() {
    _gcTimer ??= Timer.periodic(_connIdGcInterval, (_) => _gcStaleConnIds());
  }

  void _maybeStopGcTimer() {
    if (_active != null) return;
    if (_globalRecordingActive) return;
    _gcTimer?.cancel();
    _gcTimer = null;
  }

  /// §048 Принцип 6 — time-based GC, не count-based. Каждые 5s проходим
  /// и убираем entries старше 30s. Также trim'им `_globalRollingBuffer` по
  /// time window'у. (§180 — `_dnsByConnId` выпилен, чистить нечего.)
  void _gcStaleConnIds() {
    final now = DateTime.now();
    final cutoff = now.subtract(_connIdTtl);
    _connIdToMeta.removeWhere((_, m) => m.firstSeen.isBefore(cutoff));
    // §176 — guard уже-обработанных closed: чистим старше 5 мин (ядро их к
    // этому моменту эвиктнуло из FilterState(All), в снапшоте больше нет).
    final closedCutoff = now.subtract(const Duration(minutes: 5));
    _closedHandled.removeWhere((_, ts) => ts.isBefore(closedCutoff));

    // Trim global rolling buffer по time window'у.
    final globalCutoff = now.subtract(_globalRollingWindow);
    while (_globalRollingBuffer.isNotEmpty &&
        _globalRollingBuffer.first.ts.isBefore(globalCutoff)) {
      _globalRollingBuffer.removeFirst();
    }
    // Trim unattributed ring (тоже time-based, но cap=50 защищает от busy
    // bursts).
    while (_globalUnattributedEvents.isNotEmpty &&
        _globalUnattributedEvents.first.ts.isBefore(globalCutoff)) {
      _globalUnattributedEvents.removeFirst();
    }
  }

  /// AppLog хранит entries newest-first. Идём от индекса 0 (newest) пока
  /// не встретим entry с ts <= last-seen — всё что выше это новое. Сборку
  /// делаем в reverse-order чтобы DNS chain'и собирались хронологически.
  ///
  /// Timestamp-based diff (не length-based): AppLog ring-buffer cap=500,
  /// при overflow length стабилизируется и length-diff никогда не fires.
  void _drainNewLogEntries() {
    final entries = AppLog.I.entriesForSource(DebugSource.core);
    if (entries.isEmpty) return;
    final lastSeen = _lastSeenLogTs;
    // Walk newest-first, collect новые (until we hit ts <= lastSeen).
    // Then process them oldest-first.
    final fresh = <int>[];
    for (var i = 0; i < entries.length; i++) {
      final t = entries[i].time;
      if (lastSeen != null && !t.isAfter(lastSeen)) break;
      fresh.add(i);
    }
    if (fresh.isEmpty) return;
    for (var k = fresh.length - 1; k >= 0; k--) {
      final i = fresh[k];
      _processLogLine(entries[i].message, entries[i].time);
    }
    _lastSeenLogTs = entries.first.time;
  }

  // ─── Log parser (defensive) ───────────────────────────────────────────

  // INFO[NNNN] [<conn_id> <Nms>] router: found package name: <pkg>
  static final _packageRe = RegExp(
      r'(?:\[(\d+)\s+\d+m?s?\]\s+)?router: found package name:\s+(.+?)$');

  // §180 — DNS-regex (_dnsRe/_dnsFailRe) выпилены: DNS идёт структурным стримом
  // (ядро SPEC 018 subscribeDNSQueries → CcChannel.dnsQueries → _ingestDnsQueries),
  // а не парсингом core-лога. Текстовый путь был «обглоданным каналом» (атрибуция
  // по connId-сшивке, regex чинили §141/§171). Структура: processInfo из ядра.

  void _processLogLine(String line, DateTime ts) {
    // 1) Package detection — пишем в conn-id map (всегда, независимо
    //    от active session'и: нужно для global rolling buffer и для
    //    backfill'а в будущую session'ю).
    final pkgM = _packageRe.firstMatch(line);
    if (pkgM != null) {
      final connId = pkgM.group(1);
      final pkg = pkgM.group(2)!.trim();
      if (connId != null && connId.isNotEmpty) {
        _connIdToMeta[connId] = _ConnMeta(pkg, ts);
      }
      return;
    }
    // §180 — DNS-ветки выпилены: DNS идёт структурным стримом
    // (_ingestDnsQueries ← CcChannel.dnsQueries, ядро SPEC 018), НЕ из лога.
    // _processLogLine остаётся ТОЛЬКО ради package detection (_packageRe выше) —
    // это TCP-атрибуция connId→package, не DNS.
  }

  // ─── §180: структурный DNS из ядра (SPEC 018) ────────────────────────

  /// §180 — DNS RR type-код → строка (для `dnsRecordType` в UI). Defensive:
  /// неизвестный код → `TYPE<N>` (как раньше defensive-regex принимал любой тип).
  static String _qtypeToString(int qtype) {
    switch (qtype) {
      case 1:
        return 'A';
      case 28:
        return 'AAAA';
      case 5:
        return 'CNAME';
      case 65:
        return 'HTTPS';
      case 64:
        return 'SVCB';
      case 6:
        return 'SOA';
      case 15:
        return 'MX';
      case 16:
        return 'TXT';
      case 12:
        return 'PTR';
      case 33:
        return 'SRV';
      case 2:
        return 'NS';
      default:
        return 'TYPE$qtype';
    }
  }

  /// §180-fix (device dev.72) — ядро отдаёт `DnsAnswer.rdata` ПОЛНОЙ RR-строкой
  /// "name TTL IN TYPE value" (а не голым значением). Значение записи = последнее
  /// поле: для A/AAAA это IP, для CNAME — target-домен (с trailing dot, срезаем).
  /// Если строка без пробелов (ядро уже дало чистое значение) — отдаём как есть.
  static String _rdataValue(String rdata) {
    final s = rdata.trim();
    if (s.isEmpty) return s;
    final lastSpace = s.lastIndexOf(' ');
    final value = lastSpace >= 0 ? s.substring(lastSpace + 1) : s;
    return value.endsWith('.') ? value.substring(0, value.length - 1) : value;
  }

  /// §180 — батч DNS-событий из ядра (SPEC 018 `subscribeDNSQueries`). Заменяет
  /// текстовый `_handleDnsLine`/`_handleDnsFailLine`. Атрибуция к приложению —
  /// `q.packageName` ИЗ ЯДРА (processInfo), не connId-сшивка (корень §177-баннера).
  void _ingestDnsQueries(List<CcDnsQuery> queries) {
    // Обрабатываем если есть session ИЛИ global recording (как connections).
    if (_active == null && !_globalRecordingActive) return;
    final now = DateTime.now();
    for (final q in queries) {
      _ingestDnsQuery(q, now);
    }
  }

  void _ingestDnsQuery(CcDnsQuery q, DateTime ts) {
    // Атрибуция из ядра: packageName непуст → verified. (Раньше — meta по connId.)
    final attributed = q.packageName.isNotEmpty;
    final process = attributed ? q.packageName : null;
    final recordType = _qtypeToString(q.queryType);

    // Q2 (SPEC 018): провал → dnsFail с issue. `error` — структурная причина
    // (было: reason из regex). rcode==-1 (Q1) = нет ответа (timeout).
    if (q.failed) {
      final reason = q.error.isNotEmpty
          ? q.error
          : (q.noAnswer ? 'no response' : 'rcode ${q.rcode}');
      _routeEvent(TrafficEvent(
        ts: ts,
        kind: TrafficEventKind.dnsFail,
        domain: q.domain.isNotEmpty ? q.domain : null,
        process: process,
        dnsRecordType: recordType,
        confidence:
            attributed ? ConfidenceLevel.verified : ConfidenceLevel.unattributed,
        matchedVia: attributed ? 'dns_stream' : null,
        shownBecause: attributed
            ? null
            : 'system-wide DNS failure (no owner package detected)',
        issues: [
          ConnectionIssue(
              ConnectionIssueKind.dnsTimeout, 'DNS exchange failed: $reason'),
        ],
      ));
      return;
    }

    // Q3 (SPEC 018): cnameChain = CNAME-hops из answers; ip = первый A/AAAA.
    // Аттрибуция на ОРИГИНАЛЬНЫЙ домен (q.domain), не на финальный target —
    // как в текстовом пути (юзер видит что app запрашивал, CNAME chain отдельно).
    // §180-fix (device dev.72): ядро в DnsAnswer.rdata кладёт ПОЛНУЮ RR-строку
    // "name TTL IN TYPE value" (напр. "google.com. 29 IN A 64.233.165.139"),
    // НЕ голое значение → берём последнее поле (_rdataValue).
    final cnameChain = q.answers
        .where((a) => a.isCname)
        .map((a) => _rdataValue(a.rdata))
        .toList();
    final addresses = q.answers
        .where((a) => a.isAddress)
        .map((a) => _rdataValue(a.rdata))
        .toList();
    final ip = addresses.isNotEmpty ? addresses.first : null;

    _routeEvent(TrafficEvent(
      ts: ts,
      kind: TrafficEventKind.dnsResolve,
      domain: q.domain,
      cnameChain: cnameChain,
      ip: ip,
      process: process,
      dnsRecordType: recordType,
      confidence:
          attributed ? ConfidenceLevel.verified : ConfidenceLevel.unattributed,
      matchedVia: attributed ? 'dns_stream' : null,
      // не-адресные типы (HTTPS/SVCB/SOA…): rdata первого answer в extra (было
      // `extra: {'answer': ...}`), чтобы Live показывал что app сделал такой query.
      extra: (ip == null && q.answers.isNotEmpty)
          ? {'answer': _rdataValue(q.answers.first.rdata)}
          : null,
    ));
  }

  // ─── Event routing (global + session) ─────────────────────────────────

  /// §048 — central routing. Каждое event'ое:
  ///   1. Кладётся в `_globalRollingBuffer` (always-running).
  ///   2. Эмитится в global SSE stream.
  ///   3. Если есть active session — applies confidence resolution
  ///      (verified / secondary / inferred / unattributed) и кладётся в
  ///      session.events (даже unattributed, как nearby-event).
  ///   4. Если confidence == unattributed без session — кладётся в
  ///      `_globalUnattributedEvents` ring для banner detection.
  void _routeEvent(TrafficEvent ev) {
    // Step 1: global buffer (всегда).
    _appendToGlobalRollingBuffer(ev);
    // Step 2: global unattributed ring (для banner detection / Per-app
    // Live «System-wide events» section). Заполняется ВСЕГДА для
    // unattributed (независимо от active session): banner должен fire
    // даже во время recording'а — это и есть его смысл.
    if (ev.confidence == ConfidenceLevel.unattributed) {
      _appendToGlobalUnattributed(ev);
    }
    // Step 3: SSE.
    _emitGlobalStream({'event': 'traffic_event', 'data': ev.toJson()});

    // Step 4: session matching.
    final s = _active;
    if (s != null) {
      final resolved = _resolveForSession(ev, s);
      if (resolved != null) {
        _appendEvent(s, resolved);
      }
    }
  }

  /// §048 Принципы 1 и 3 — резолвим event для конкретной session'и:
  /// получаем `verified` / `secondary` / `inferred` / `unattributed`
  /// или `null` (если событие точно не related — например, verified-match
  /// для другого app'а).
  TrafficEvent? _resolveForSession(TrafficEvent ev, Session s) {
    // Strategy 1: direct package match (verified).
    final processNames = _splitPackageNames(ev.process);
    if (processNames.contains(s.targetPackage)) {
      return _withConfidence(ev,
          confidence: ConfidenceLevel.verified, matchedVia: 'router_log');
    }
    // Strategy 2: secondary packages (WebView etc).
    if (s.secondaryPackages.isNotEmpty &&
        processNames.any(s.secondaryPackages.contains)) {
      return _withConfidence(ev,
          confidence: ConfidenceLevel.secondary,
          matchedVia: 'secondary_packages');
    }
    // Strategy 3: UID suffix variants (Gap 5).
    final stripped = processNames.map(_stripUid).toSet();
    if (stripped.contains(s.targetPackage)) {
      return _withConfidence(ev,
          confidence: ConfidenceLevel.verified,
          matchedVia: 'router_log_uid_stripped');
    }
    if (s.secondaryPackages.isNotEmpty &&
        stripped.any(s.secondaryPackages.contains)) {
      return _withConfidence(ev,
          confidence: ConfidenceLevel.secondary,
          matchedVia: 'secondary_packages_uid_stripped');
    }
    // Strategy 4: inferred — recent DNS resolved IP принадлежит target.
    // Применяется только для tcpOpen / udpOpen / tcpClose с known IP.
    if (ev.ip != null && ev.ip!.isNotEmpty &&
        (ev.kind == TrafficEventKind.tcpOpen ||
            ev.kind == TrafficEventKind.udpOpen ||
            ev.kind == TrafficEventKind.tcpClose)) {
      final inferredOwner = _inferProcessByIp(s, ev.ip!, ev.ts);
      if (inferredOwner != null) {
        return _withConfidence(ev,
            confidence: ConfidenceLevel.inferred,
            matchedVia: 'recent_dns_ip',
            process: inferredOwner,
            processInferred: true);
      }
    }
    // Strategy 5: unattributed (`process == null` или process не известный) —
    // показываем в session как nearby event. Если process явно != target
    // и явно НЕ в secondaryPackages — это not-related, drop.
    if (ev.process == null || ev.process!.isEmpty) {
      return _withConfidence(ev,
          confidence: ConfidenceLevel.unattributed,
          shownBecause:
              'system-wide event without owner detection (during active session)');
    }
    // Process известен но это не target и не secondary — ev not related,
    // drop. (Не пихаем чужие apps в session: банально шумно, юзер не
    // ожидает увидеть Telegram трафик в session'е Tinkoff.)
    return null;
  }

  TrafficEvent _withConfidence(TrafficEvent ev,
      {required ConfidenceLevel confidence,
      String? matchedVia,
      String? shownBecause,
      String? process,
      bool? processInferred}) {
    return TrafficEvent(
      ts: ev.ts,
      kind: ev.kind,
      domain: ev.domain,
      cnameChain: ev.cnameChain,
      ip: ev.ip,
      port: ev.port,
      outboundChain: ev.outboundChain,
      detourChain: ev.detourChain, // §181
      upBytes: ev.upBytes,
      downBytes: ev.downBytes,
      duration: ev.duration,
      connId: ev.connId,
      process: process ?? ev.process,
      processInferred: processInferred ?? ev.processInferred,
      network: ev.network,
      rule: ev.rule,
      rulePayload: ev.rulePayload,
      rawLogLine: ev.rawLogLine,
      confidence: confidence,
      matchedVia: matchedVia,
      shownBecause: shownBecause,
      dnsRecordType: ev.dnsRecordType,
      backfilled: ev.backfilled,
      issues: ev.issues,
      extra: ev.extra,
    );
  }

  void _appendToGlobalRollingBuffer(TrafficEvent ev) {
    _globalRollingBuffer.addLast(ev);
    // Soft cap: hard limit на 3000 events чтобы memory не убегало на
    // busy device'ах. Time-based trim — в _gcStaleConnIds (5s tick).
    while (_globalRollingBuffer.length > _globalRollingHardCap) {
      _globalRollingBuffer.removeFirst();
    }
  }

  void _appendToGlobalUnattributed(TrafficEvent ev) {
    _globalUnattributedEvents.addLast(ev);
    while (_globalUnattributedEvents.length > _globalUnattributedCap) {
      _globalUnattributedEvents.removeFirst();
    }
  }

  /// §048 Принцип 4 — backfill events за last 60s которые match new session'е.
  /// Все backfilled events помечаются `backfilled=true` в UI.
  void _backfillFromGlobalRollingBuffer(Session s) {
    if (_globalRollingBuffer.isEmpty) return;
    final cutoff = s.startedAt.subtract(_globalRollingWindow);
    for (final ev in _globalRollingBuffer) {
      if (ev.ts.isBefore(cutoff)) continue;
      final resolved = _resolveForSession(ev, s);
      if (resolved == null) continue;
      // Mark backfilled. Drop unattributed из backfill — они уже в global
      // buffer'е, не нужно дублировать в session.events с прошлым ts.
      if (resolved.confidence == ConfidenceLevel.unattributed) continue;
      final marked = TrafficEvent(
        ts: resolved.ts,
        kind: resolved.kind,
        domain: resolved.domain,
        cnameChain: resolved.cnameChain,
        ip: resolved.ip,
        port: resolved.port,
        outboundChain: resolved.outboundChain,
        detourChain: resolved.detourChain, // §181
        upBytes: resolved.upBytes,
        downBytes: resolved.downBytes,
        duration: resolved.duration,
        connId: resolved.connId,
        process: resolved.process,
        processInferred: resolved.processInferred,
        network: resolved.network,
        rule: resolved.rule,
        rulePayload: resolved.rulePayload,
        rawLogLine: resolved.rawLogLine,
        confidence: resolved.confidence,
        matchedVia: resolved.matchedVia,
        shownBecause: resolved.shownBecause,
        dnsRecordType: resolved.dnsRecordType,
        backfilled: true,
        issues: resolved.issues,
        extra: resolved.extra,
      );
      s.events.add(marked);
    }
    s._markDirty();
  }

  /// Split process строки `"com.x.y, com.x.z (10999)"` на `{com.x.y, com.x.z}`
  /// (UID strip'ается отдельно). §048 Gap 11 — sing-box передаёт через
  /// запятую multiple packages для одного UID.
  Set<String> _splitPackageNames(String? raw) {
    if (raw == null || raw.isEmpty) return const <String>{};
    return raw
        .split(',')
        .map((s) => _stripUid(s.trim()))
        .where((s) => s.isNotEmpty)
        .toSet();
  }

  // ─── CommandClient connections (§168) ────────────────────────────────
  //
  // Источник tcp/udp open/close + per-app атрибуции — push-стрим
  // `CcChannel.connections` через profilerClient. profilerClient §164-
  // энергомодель НЕ паузит в фоне → recording живёт при свёрнутом app.

  /// Подписка на CC connections + подъём profilerClient. Идемпотентна
  /// (active session ИЛИ global recording могут вызвать обе).
  void _attachCcConnections() {
    if (_ccConnSub != null) return;
    // Поднимаем независимый profilerClient (фоновый, §164). Шлёт первый
    // снапшот сразу + далее push'ом — _ingestCcConnections их обработает.
    unawaited(_cc.connectProfiler());
    _ccConnSub = _cc.connections.listen(
      _ingestCcConnections,
      // Ошибка стрима (канал недоступен / native не готов) — не валим
      // recording, следующий снапшот придёт следующим тиком.
      onError: (Object e, StackTrace _) =>
          AppLog.I.warning('TrafficProfiler: cc connections stream error: $e'),
    );
    // §180 — DNS-журнал из ядра (SPEC 018) на том же profilerClient. Батч
    // CcDnsQuery; _ingestDnsQuery эмитит dnsResolve/dnsFail с атрибуцией ИЗ ЯДРА.
    _ccDnsSub = _cc.dnsQueries.listen(
      _ingestDnsQueries,
      onError: (Object e, StackTrace _) =>
          AppLog.I.warning('TrafficProfiler: cc dns stream error: $e'),
    );
  }

  /// Снимает подписку + гасит profilerClient — только если ни active
  /// session, ни global recording. Симметрично `_maybeDetachLogListener`.
  void _maybeDetachCcConnections() {
    if (_active != null) return;
    if (_globalRecordingActive) return;
    _detachCcConnections();
  }

  void _detachCcConnections() {
    _ccConnSub?.cancel();
    _ccConnSub = null;
    _ccDnsSub?.cancel(); // §180
    _ccDnsSub = null;
    unawaited(_cc.disconnectProfiler());
  }

  /// §168 — обработка снапшота CommandClient connections: эмит tcp/udp
  /// open для новых conn'ов, close для исчезнувших (closed-detection через
  /// `_connSnapshots` diff, как раньше делал Clash-poll). Per-app атрибуция
  /// через `CcConnection.packageName/processPath`.
  void _ingestCcConnections(List<CcConnection> conns) {
    final s = _active;
    // Обрабатываем если есть session ИЛИ global recording.
    if (s == null && !_globalRecordingActive) return;
    final now = DateTime.now();

    final seenIds = <String>{};
    for (final c in conns) {
      final id = c.id;
      if (id.isEmpty) continue;
      // §176 — closed-дельта ядра (closedAt>0, теперь приходит из FilterState
      // All). Ядро держит закрытый conn в снапшоте до 5 мин → обрабатываем
      // РОВНО ОДИН раз (guard _closedHandled), иначе лавина дублей.
      if (c.isClosed) {
        if (_closedHandled.containsKey(id)) continue; // уже закрыли — пропуск
        _closedHandled[id] = now;
        // НЕ добавляем в seenIds → diff-блок ниже эмитит tcpClose. open-код
        // НЕ пропускаем: новый conn (snap нет — короткий, open проскочил между
        // тиками) пройдёт open-ветку (emit tcpOpen + snap), затем diff закроет →
        // обе фазы. Если был открыт — обновит байты, diff закроет.
      } else {
        seenIds.add(id);
      }
      // CcConnection несёт packageName (для иконки) + processPath (из
      // libbox getProcessInfo). Для атрибуции берём packageName, иначе путь.
      final process = c.packageName;
      final processPath = c.processPath;
      final rawProcess = process.isNotEmpty ? process : processPath;

      // destination = "host:port" → host-часть + port-часть.
      final host = c.domain;
      final destIp = _ccHostOf(c.destination);
      final destPort = _ccPortOf(c.destination);
      final network = c.network;
      // §174 — реальная outbound-цепочка из ядра (`Connection.chain()`):
      // [node, …selectors]. Fallback на [outbound] для прямых без группы.
      // §181 — chains и detours несём РАЗДЕЛЬНО (не склеиваем как §178): UI
      // строит цепочку решения `[net] proc ⇒ rule ⇒ группы : node → detour →
      // domain` сам, разделяя оси (⇒ внутри / : выход / → снаружи).
      final routeChain = c.chains.isNotEmpty
          ? c.chains
          : (c.outbound.isNotEmpty ? <String>[c.outbound] : <String>[]);
      final detourChain = c.detours; // §181 — detour-ось (транспорт), node→наружу
      final up = c.uplink;
      final down = c.downlink;
      final rule = c.rule;
      // §174 — у ядра нет отдельного rulePayload (в Clash был всегда ""); Rule
      // уже несёт человекочитаемую форму правила целиком — payload не дублируем.
      const rulePayload = '';

      final prev = _connSnapshots[id];
      if (prev == null) {
        // Новая connection — emit tcpOpen / udpOpen.
        // Confidence resolution через _resolveForSession.
        final kind = network == 'udp'
            ? TrafficEventKind.udpOpen
            : TrafficEventKind.tcpOpen;
        final raw = TrafficEvent(
          ts: now,
          kind: kind,
          domain: host.isNotEmpty ? host : null,
          ip: destIp.isNotEmpty ? destIp : null,
          port: destPort > 0 ? destPort : null,
          outboundChain: routeChain,
          detourChain: detourChain,
          upBytes: up,
          downBytes: down,
          process: rawProcess.isNotEmpty ? rawProcess : null,
          network: network,
          rule: rule.isNotEmpty ? rule : null,
          rulePayload: rulePayload.isNotEmpty ? rulePayload : null,
        );
        // Global rolling: всегда добавляем (даже не-target conn'ы, для
        // Live system-wide tab'а) с confidence verified если process
        // известен, иначе unattributed. §084 H6: copyWith вместо ручного
        // копирования 20+ полей.
        final globalEv = raw.copyWith(
          confidence: raw.process == null
              ? ConfidenceLevel.unattributed
              : ConfidenceLevel.verified,
          matchedVia: raw.process == null ? null : 'connections_meta',
        );
        _appendToGlobalRollingBuffer(globalEv);
        _emitGlobalStream(
            {'event': 'traffic_event', 'data': globalEv.toJson()});

        // Snapshot для closed-detection. Нужен и для session, и для
        // global-only режима (чтобы emit'ить tcpClose когда Clash убрал
        // connection из ответа).
        var snapProcess = '';
        var snapConfidence = ConfidenceLevel.unattributed;
        String? snapMatchedVia;
        // §160 — попало ли соединение в session при открытии. Решение
        // фиксируется здесь и наследуется close'ом (см. closed-detection
        // ниже): иначе close чужого conn'а ошибочно писался в session.
        var snapInSession = false;

        if (s != null) {
          // Session resolution.
          final resolved = _resolveForSession(raw, s);
          if (resolved != null) {
            _appendEvent(s, resolved);
            snapProcess = resolved.process ?? '';
            snapConfidence = resolved.confidence;
            snapMatchedVia = resolved.matchedVia;
            snapInSession = true;
          } else {
            // не related к target — в session не пишем, но snapshot
            // нужен для global-only closed detection.
            snapProcess = rawProcess;
            snapConfidence = globalEv.confidence;
            snapMatchedVia = globalEv.matchedVia;
          }
        } else {
          snapProcess = rawProcess;
          snapConfidence = globalEv.confidence;
          snapMatchedVia = globalEv.matchedVia;
        }

        _connSnapshots[id] = _ConnSnapshot(
          id: id,
          host: host,
          ip: destIp,
          port: destPort,
          network: network,
          chains: routeChain,
          detours: detourChain, // §181
          upBytes: up,
          downBytes: down,
          startedAt: now,
          process: snapProcess,
          confidence: snapConfidence,
          matchedVia: snapMatchedVia,
          rule: rule,
          rulePayload: rulePayload,
          inSession: snapInSession,
        );
      } else {
        // Update bytes — снапшот latest values, не emit'им event.
        prev.upBytes = up;
        prev.downBytes = down;
      }
    }

    // Закрытые connections — те что были в _connSnapshots но не пришли в
    // current snapshot.
    final closed =
        _connSnapshots.keys.where((k) => !seenIds.contains(k)).toList();
    for (final id in closed) {
      final snap = _connSnapshots.remove(id);
      if (snap == null) continue;
      final closeEv = TrafficEvent(
        ts: now,
        kind: TrafficEventKind.tcpClose,
        domain: snap.host.isNotEmpty ? snap.host : null,
        ip: snap.ip.isNotEmpty ? snap.ip : null,
        port: snap.port > 0 ? snap.port : null,
        outboundChain: snap.chains,
        detourChain: snap.detours, // §181
        upBytes: snap.upBytes,
        downBytes: snap.downBytes,
        duration: now.difference(snap.startedAt),
        process: snap.process.isEmpty ? null : snap.process,
        processInferred: snap.confidence == ConfidenceLevel.inferred,
        network: snap.network,
        rule: snap.rule.isEmpty ? null : snap.rule,
        rulePayload: snap.rulePayload.isEmpty ? null : snap.rulePayload,
        confidence: snap.confidence,
        matchedVia: snap.matchedVia,
        issues: _classifyConnectionClose(snap, now),
      );
      // §084 H5 — Global stream/buffer всегда, симметрично tcpOpen (который
      // пишется безусловно выше). Раньше под `if (_globalRecordingActive)` —
      // при active session без global recording lifecycle был неполным
      // (open в buffer'е, close — нет). Комментарий «всегда» противоречил
      // коду; теперь поведение соответствует.
      _appendToGlobalRollingBuffer(closeEv);
      _emitGlobalStream({'event': 'traffic_event', 'data': closeEv.toJson()});
      // §160 — Session только если соединение БЫЛО атрибутировано к target
      // при открытии (`snap.inSession`). Раньше close писался безусловно →
      // close чужого conn'а (youtube/imo и т.п.) попадал в session Telegram
      // как verified-чужой, хотя его open был отброшен `_resolveForSession`.
      if (s != null && snap.inSession) {
        _appendEvent(s, closeEv);
      }
    }
  }

  /// §168 — host-часть `destination` ("host:port"). IPv6-safe: режем по
  /// последнему ':'. Без ':' — вся строка.
  static String _ccHostOf(String destination) {
    final i = destination.lastIndexOf(':');
    return i < 0 ? destination : destination.substring(0, i);
  }

  /// §168 — port из `destination` ("host:port") как int (0 если нет).
  static int _ccPortOf(String destination) {
    final i = destination.lastIndexOf(':');
    if (i < 0 || i == destination.length - 1) return 0;
    return int.tryParse(destination.substring(i + 1)) ?? 0;
  }

  /// Поиск process owner'а по recent DNS resolved IP в окне
  /// [_processInferenceWindow]. Идём по `_globalRollingBuffer` (не
  /// session.events: нужно матчить даже до session start'а).
  String? _inferProcessByIp(Session s, String ip, DateTime now) {
    final cutoff = now.subtract(_processInferenceWindow);
    for (var i = _globalRollingBuffer.length - 1; i >= 0; i--) {
      final e = _globalRollingBuffer.elementAt(i);
      if (e.ts.isBefore(cutoff)) break;
      if (e.kind == TrafficEventKind.dnsResolve && e.ip == ip) {
        // Проверяем что resolved DNS принадлежит target (или secondary).
        final processNames = _splitPackageNames(e.process);
        if (processNames.contains(s.targetPackage)) {
          return s.targetPackage;
        }
        if (s.secondaryPackages.isNotEmpty &&
            processNames.any(s.secondaryPackages.contains)) {
          return e.process;
        }
      }
    }
    return null;
  }

  // ─── Connection-issue classifiers ─────────────────────────────────────
  //
  //   - dnsTimeout: прямо из лога sing-box'а (`dns: exchange failed ...`),
  //     не heuristic, а реальный engine-уровневый сигнал. Эмитится в
  //     [_handleDnsFailLine].
  //   - tcpReset: heuristic «conn закрылся <1с с 0 bytes» — высокая
  //     вероятность RST/firewall-blocking, но возможны false positives
  //     (быстрая отмена со стороны app, health-check probe).

  /// Анализ только что закрывшегося conn'а на TCP RST early — heuristic
  /// «закрылся <1с с 0 bytes» = вероятный firewall RST / unreachable.
  List<ConnectionIssue> _classifyConnectionClose(
      _ConnSnapshot snap, DateTime closedAt) {
    final out = <ConnectionIssue>[];
    if (snap.network == 'tcp') {
      final dur = closedAt.difference(snap.startedAt);
      if (dur.inMilliseconds < 1000 &&
          snap.upBytes == 0 &&
          snap.downBytes == 0) {
        out.add(const ConnectionIssue(
          ConnectionIssueKind.tcpReset,
          'Connection closed within 1s without bytes (likely RST / blocked)',
        ));
      }
    }
    return out;
  }

  // ─── Append + pruning ─────────────────────────────────────────────────

  void _appendEvent(Session s, TrafficEvent ev) {
    s.events.add(ev);
    s._markDirty();
    _pruneOld(s);
    _emitSessionStream({
      'event': 'traffic_event',
      'data': ev.toJson(),
    });
    _scheduleNotify(); // §141 P3.1a — throttled вместо прямого notifyListeners
  }

  /// §141 P3.1a — leading-edge 16ms-throttle (эталон AppLog._scheduleNotify):
  /// первый вызов сразу notify, последующие в окне коалесятся в один notify в
  /// конце окна.
  void _scheduleNotify() {
    if (_notifyThrottleTimer != null) {
      _notifyPending = true;
      return;
    }
    notifyListeners();
    _notifyThrottleTimer = Timer(_notifyWindow, () {
      _notifyThrottleTimer = null;
      if (_notifyPending) {
        _notifyPending = false;
        _scheduleNotify();
      }
    });
  }

  void _pruneOld(Session s) {
    // 1) Time-based: drop старее sliding window.
    final cutoff = DateTime.now().subtract(_slidingWindow);
    var firstKeep = 0;
    while (firstKeep < s.events.length &&
        s.events[firstKeep].ts.isBefore(cutoff)) {
      firstKeep++;
    }
    if (firstKeep > 0) {
      s.events.removeRange(0, firstKeep);
      s.eventsDropped += firstKeep;
    }
    // 2) Count-based fallback: если всё ещё > cap.
    if (s.events.length > _maxEventsPerSession) {
      final excess = s.events.length - _maxEventsPerSession;
      s.events.removeRange(0, excess);
      s.eventsDropped += excess;
    }
  }

  // ─── Helpers ──────────────────────────────────────────────────────────

  /// `"ru.tinkoff.investing (10999)"` → `"ru.tinkoff.investing"`. Sing-box
  /// `find_process: true` суффиксует UID в скобках; targetPackage в picker'е
  /// — без UID, поэтому тут strip'аем для матчинга. Также handle'им
  /// формат `pkg/uid` если встретится.
  static String _stripUid(String s) {
    var t = s.trim();
    if (t.isEmpty) return '';
    final paren = t.indexOf(' (');
    if (paren >= 0) t = t.substring(0, paren);
    final slash = t.indexOf('/');
    if (slash >= 0) t = t.substring(0, slash);
    return t.trim();
  }

  static String _generateId() {
    final now = DateTime.now().microsecondsSinceEpoch;
    final rnd = math.Random.secure().nextInt(0x100000000);
    return '${now.toRadixString(16)}-${rnd.toRadixString(16)}';
  }

  // ─── Test-only helpers ────────────────────────────────────────────────

  @visibleForTesting
  void resetForTesting() {
    _active = null;
    _completed.clear();
    _connIdToMeta.clear();
    _connSnapshots.clear();
    _closedHandled.clear(); // §176
    _globalRollingBuffer.clear();
    _globalUnattributedEvents.clear();
    _globalRecordingActive = false;
    _globalRecordingStartedAt = null;
    _ccConnSub?.cancel();
    _ccConnSub = null;
    _ccDnsSub?.cancel(); // §180
    _ccDnsSub = null;
    _gcTimer?.cancel();
    _gcTimer = null;
    if (_appLogListener != null) {
      AppLog.I.removeListener(_appLogListener!);
      _appLogListener = null;
    }
    _lastSeenLogTs = null;
    for (final c in [..._sessionStreamSinks, ..._globalStreamSinks]) {
      if (!c.isClosed) c.close();
    }
    _sessionStreamSinks.clear();
    _globalStreamSinks.clear();
  }

  @visibleForTesting
  void feedLogLineForTest(String line, [DateTime? ts]) {
    _processLogLine(line, ts ?? DateTime.now());
  }

  /// §168 — прогнать снапшот CC connections (заменяет pollOnceForTest).
  @visibleForTesting
  void ingestForTest(List<CcConnection> conns) => _ingestCcConnections(conns);

  /// §180 — прогнать DNS-события из ядра (заменяет feedLogLineForTest для DNS).
  @visibleForTesting
  void ingestDnsForTest(List<CcDnsQuery> queries) => _ingestDnsQueries(queries);

  @visibleForTesting
  void gcOnceForTest() => _gcStaleConnIds();
}
