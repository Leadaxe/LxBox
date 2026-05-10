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
//      DNS resolves (с CNAME chain'ом), package detection (`router: found
//      package name: X`) и связку `[conn_id Nms]`. **Primary source** —
//      каждый `inbound packet connection` log line == event в session'е.
//   2. Clash API `/connections` polling (5s): supplement для **stats**
//      (current bytes, duration, active state). Не для discovery новых
//      events — это закрывает Gap 9 (short-lived TCP).
//
// Спарка — через conn_id для DNS, через `metadata.process` для конн'ов.
// DNS resolves строятся в `_DnsAccumulator` по conn_id.
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
import 'app_log.dart';
import 'settings_storage.dart';

// ─────────────────────────────────────────────────────────────────────────
// Public types
// ─────────────────────────────────────────────────────────────────────────

enum TrafficEventKind { dnsResolve, dnsFail, tcpOpen, tcpClose, udpOpen }

/// §048 Принцип 3 — атрибуция как **continuous signal**, а не binary
/// match-or-drop. Каждое event в session/global buffer'е помечено уровнем
/// уверенности; UI показывает все 4, но визуально различает.
enum ConfidenceLevel {
  /// `router: found package name: target` — sing-box явно сказал что this
  /// is target. Default visual (no marker).
  verified,

  /// `meta.process` ∈ session.secondaryPackages — WebView / paired UID.
  /// UI marker: `🔗 via <pkg>`.
  secondary,

  /// `meta.process` пустой/null, но recent DNS resolved IP принадлежит
  /// target в окне `_processInferenceWindow`. UI marker: `〽 inferred`.
  inferred,

  /// Никакая strategy не сработала. Событие показывается в Live tab'е
  /// или в Per-app session как `unattributed nearby` секция. UI marker:
  /// `〽 unattributed`.
  unattributed,
}

/// Маркеры **проблем сетевого соединения**, которые показываются как ⚠
/// в UI и попадают в session JSON. Это **не статистические аномалии** —
/// это конкретные diagnostic-сигналы (engine error / heuristic для RST).
///
/// Locale-агностичные:
/// - `dnsTimeout` — sing-box залогировал `dns: exchange failed ...`.
///   Прямой engine-сигнал, не heuristic.
/// - `tcpReset` — conn закрылся в течение 1с без bytes, вероятный
///   firewall RST / unreachable. Heuristic, возможны false positives.
enum ConnectionIssueKind { dnsTimeout, tcpReset }

class ConnectionIssue {
  const ConnectionIssue(this.kind, this.description);
  final ConnectionIssueKind kind;
  final String description;

  Map<String, Object?> toJson() => {
        'kind': kind.name,
        'description': description,
      };
}

class TrafficEvent {
  TrafficEvent({
    required this.ts,
    required this.kind,
    this.domain,
    this.cnameChain = const [],
    this.ip,
    this.port,
    this.outboundChain = const [],
    this.upBytes,
    this.downBytes,
    this.duration,
    this.connId,
    this.process,
    this.processInferred = false,
    this.network,
    this.rule,
    this.rulePayload,
    this.rawLogLine,
    this.confidence = ConfidenceLevel.verified,
    this.matchedVia,
    this.shownBecause,
    this.dnsRecordType,
    this.backfilled = false,
    List<ConnectionIssue>? issues,
    this.extra,
  }) : issues = issues ?? <ConnectionIssue>[];

  final DateTime ts;
  final TrafficEventKind kind;
  final String? domain;
  final List<String> cnameChain;
  final String? ip;
  final int? port;
  final List<String> outboundChain;
  final int? upBytes;
  final int? downBytes;
  final Duration? duration;
  final String? connId;
  final String? process;

  /// Legacy флаг для обратной совместимости с UI-кодом и API consumers'ами,
  /// которые ещё не понимают `confidence`. Эквивалентно
  /// `confidence == inferred`.
  final bool processInferred;
  final String? network; // tcp / udp
  final String? rule;
  final String? rulePayload;
  final String? rawLogLine;

  /// §048 Принцип 3 — confidence в attribution event'а к target session'у.
  /// Для events в `_globalRollingBuffer` (без active session) — всегда
  /// `verified` если процесс известен, иначе `unattributed`.
  final ConfidenceLevel confidence;

  /// Какая strategy сработала: `router_log`, `secondary_packages`,
  /// `recent_dns_ip`, `system_wide_correlation`, etc. Заполняется только
  /// для не-`verified` уровней.
  final String? matchedVia;

  /// Объяснение почему unattributed event попал в session events
  /// (e.g. «system-wide DNS failure during active session»).
  final String? shownBecause;

  /// DNS record type (A / AAAA / CNAME / HTTPS / SVCB / SOA / MX / TXT /
  /// unknown). Заполняется для `dnsResolve` / `dnsFail`. Defensive parsing
  /// (§048 Принцип 2): принимаем любой record type, не теряем events.
  final String? dnsRecordType;

  /// `true` если event попал в session.events через pre-session backfill
  /// из `_globalRollingBuffer` (§048 Принцип 4). UI marker:
  /// `〽 backfilled from pre-recording`.
  final bool backfilled;

  final List<ConnectionIssue> issues;
  final Map<String, Object?>? extra;

  Map<String, Object?> toJson() => {
        'ts': ts.toUtc().toIso8601String(),
        'kind': kind.name,
        if (domain != null) 'domain': domain,
        if (cnameChain.isNotEmpty) 'cname_chain': cnameChain,
        if (ip != null) 'ip': ip,
        if (port != null) 'port': port,
        if (outboundChain.isNotEmpty) 'outbound_chain': outboundChain,
        if (upBytes != null) 'up_bytes': upBytes,
        if (downBytes != null) 'down_bytes': downBytes,
        if (duration != null) 'duration_ms': duration!.inMilliseconds,
        if (connId != null) 'conn_id': connId,
        if (process != null) 'process': process,
        if (processInferred) 'process_inferred': true,
        if (network != null) 'network': network,
        if (rule != null) 'rule': rule,
        if (rulePayload != null) 'rule_payload': rulePayload,
        // §048 — confidence всегда отражается, даже для verified
        // (consumers могут отличать «default» от опущенного поля).
        'confidence': confidence.name,
        if (matchedVia != null) 'matched_via': matchedVia,
        if (shownBecause != null) 'shown_because': shownBecause,
        if (dnsRecordType != null) 'dns_record_type': dnsRecordType,
        if (backfilled) 'backfilled': true,
        if (issues.isNotEmpty)
          'issues': issues.map((a) => a.toJson()).toList(),
      };
}

class DomainStats {
  DomainStats(this.domain);
  final String domain;
  int connections = 0;
  int upBytes = 0;
  int downBytes = 0;
  DateTime? firstSeen;
  DateTime? lastSeen;
  final Set<String> ips = <String>{};
  final Set<String> cnameTargets = <String>{};
  final Set<String> outbounds = <String>{};
  final List<ConnectionIssue> issues = <ConnectionIssue>[];

  Map<String, Object?> toJson() => {
        'domain': domain,
        'connections': connections,
        'up_bytes': upBytes,
        'down_bytes': downBytes,
        'first_seen': firstSeen?.toUtc().toIso8601String(),
        'last_seen': lastSeen?.toUtc().toIso8601String(),
        'ips': ips.toList(),
        'cname_targets': cnameTargets.toList(),
        'outbounds': outbounds.toList(),
        if (issues.isNotEmpty)
          'issues': issues.map((a) => a.toJson()).toList(),
      };
}

class IpStats {
  IpStats(this.ip);
  final String ip;
  final Set<int> ports = <int>{};
  int connections = 0;
  int upBytes = 0;
  int downBytes = 0;
  DateTime? firstSeen;
  DateTime? lastSeen;
  final Set<String> outbounds = <String>{};

  Map<String, Object?> toJson() => {
        'ip': ip,
        'ports': ports.toList()..sort(),
        'connections': connections,
        'up_bytes': upBytes,
        'down_bytes': downBytes,
        'first_seen': firstSeen?.toUtc().toIso8601String(),
        'last_seen': lastSeen?.toUtc().toIso8601String(),
        'outbounds': outbounds.toList(),
      };
}

class Session {
  Session({
    required this.id,
    required this.targetPackage,
    required this.startedAt,
    this.wasVerbose = false,
    Set<String>? secondaryPackages,
  }) : secondaryPackages = secondaryPackages ?? <String>{};

  final String id;
  final String targetPackage;

  /// §048 Принцип 3 — additional package names which should be considered
  /// part of the target app's traffic. Configurable per session через UI
  /// и API. Default `{}`. Typical values: `com.google.android.webview`,
  /// `com.android.chrome` (если target — Chrome-derived app).
  final Set<String> secondaryPackages;

  final DateTime startedAt;
  DateTime? finishedAt;
  bool wasVerbose;
  int eventsDropped = 0;

  /// Newest-last (append-only). Pruning см. в `_pruneOld`.
  final List<TrafficEvent> events = <TrafficEvent>[];

  /// Aggregates — рассчитываются on-demand на view request.
  Map<String, DomainStats> _byDomain = {};
  Map<String, IpStats> _byIp = {};
  bool _aggregatesDirty = true;

  void _markDirty() => _aggregatesDirty = true;

  void _recompute() {
    _byDomain = <String, DomainStats>{};
    _byIp = <String, IpStats>{};
    for (final e in events) {
      // Aggregates считаются только по verified+secondary+inferred — чтобы
      // unattributed «nearby» events не пачкали Domains/IPs картинку.
      // В Live секции они всё равно видны.
      if (e.confidence == ConfidenceLevel.unattributed) continue;
      if (e.domain != null && e.domain!.isNotEmpty) {
        final d = _byDomain.putIfAbsent(e.domain!, () => DomainStats(e.domain!));
        d.firstSeen ??= e.ts;
        d.lastSeen = e.ts;
        if (e.ip != null) d.ips.add(e.ip!);
        for (final c in e.cnameChain) {
          d.cnameTargets.add(c);
        }
        for (final o in e.outboundChain) {
          d.outbounds.add(o);
        }
        if (e.kind == TrafficEventKind.tcpOpen ||
            e.kind == TrafficEventKind.udpOpen) {
          d.connections++;
        }
        if (e.upBytes != null) d.upBytes += e.upBytes!;
        if (e.downBytes != null) d.downBytes += e.downBytes!;
        for (final a in e.issues) {
          if (!d.issues.any((x) => x.kind == a.kind)) d.issues.add(a);
        }
      }
      if (e.ip != null && e.ip!.isNotEmpty) {
        final ip = _byIp.putIfAbsent(e.ip!, () => IpStats(e.ip!));
        ip.firstSeen ??= e.ts;
        ip.lastSeen = e.ts;
        if (e.port != null) ip.ports.add(e.port!);
        for (final o in e.outboundChain) {
          ip.outbounds.add(o);
        }
        if (e.kind == TrafficEventKind.tcpOpen ||
            e.kind == TrafficEventKind.udpOpen) {
          ip.connections++;
        }
        if (e.upBytes != null) ip.upBytes += e.upBytes!;
        if (e.downBytes != null) ip.downBytes += e.downBytes!;
      }
    }
    _aggregatesDirty = false;
  }

  Map<String, DomainStats> get byDomain {
    if (_aggregatesDirty) _recompute();
    return _byDomain;
  }

  Map<String, IpStats> get byIp {
    if (_aggregatesDirty) _recompute();
    return _byIp;
  }

  Map<String, Object?> toMetaJson() => {
        'session_id': id,
        'target_package': targetPackage,
        'secondary_packages': secondaryPackages.toList(),
        'started_at': startedAt.toUtc().toIso8601String(),
        if (finishedAt != null)
          'finished_at': finishedAt!.toUtc().toIso8601String(),
        'verbose': wasVerbose,
        'events_count': events.length,
        'events_dropped': eventsDropped,
        'unattributed_count': events
            .where((e) => e.confidence == ConfidenceLevel.unattributed)
            .length,
        'domains_count': byDomain.length,
        'ips_count': byIp.length,
        if (finishedAt == null)
          'duration_ms':
              DateTime.now().difference(startedAt).inMilliseconds
        else
          'duration_ms':
              finishedAt!.difference(startedAt).inMilliseconds,
      };
}

// ─────────────────────────────────────────────────────────────────────────
// TrafficProfiler singleton
// ─────────────────────────────────────────────────────────────────────────

typedef ConnectionsFetcher = Future<Map<String, dynamic>> Function();

class TrafficProfiler extends ChangeNotifier {
  TrafficProfiler._();
  static final TrafficProfiler I = TrafficProfiler._();

  // ─── Config knobs ─────────────────────────────────────────────────────
  static const int _maxCompleted = 5;
  static const int _maxEventsPerSession = 50000;
  static const Duration _slidingWindow = Duration(hours: 3);
  // §048 Принцип 5 — polling supplement, не discovery. 2s → 5s: меньше
  // CPU, log-stream всё равно ловит каждый conn.
  static const Duration _connPollInterval = Duration(seconds: 5);
  // §048 Принцип 6 — time-bound TTL для conn-id correlation, GC каждые 5s.
  static const Duration _connIdTtl = Duration(seconds: 30);
  static const Duration _connIdGcInterval = Duration(seconds: 5);
  static const Duration _processInferenceWindow = Duration(seconds: 10);
  // §048 Принцип 4 — global rolling buffer всегда работает, окно 60s,
  // hard cap 3000 events чтобы memory не убегало на busy device'ах.
  static const Duration _globalRollingWindow = Duration(seconds: 60);
  static const int _globalRollingHardCap = 3000;
  // Banner threshold: >5 unattributed за 30s → user-visible warning.
  static const int _unattributedBannerThreshold = 5;
  static const Duration _unattributedBannerWindow = Duration(seconds: 30);

  // ─── Live wiring ──────────────────────────────────────────────────────
  ConnectionsFetcher? _connectionsFetcher;

  /// Bind the runtime data sources. Should be called once during app
  /// bootstrap (HomeScreen init) so the profiler знает откуда брать
  /// /connections snapshot. Без этого `start()` работает но connections
  /// не собираются (только DNS из логов).
  void bindRuntime({required ConnectionsFetcher connections}) {
    _connectionsFetcher = connections;
  }

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
  Timer? _connTimer;
  Timer? _gcTimer;
  // Timestamp последнего обработанного core-log entry. Используется
  // вместо length-diff потому что AppLog имеет ring-buffer cap=500: при
  // overflow length стабилизируется на 500 и length-diff навечно =0,
  // мы бы пропускали всё. Timestamp монотонный и не зависит от cap'а.
  DateTime? _lastSeenLogTs;

  // Conn-id → package map (TTL'нутый, time-based GC).
  final Map<String, _ConnMeta> _connIdToMeta = <String, _ConnMeta>{};

  // Per-conn-id DNS accumulator: собираем CNAME chain + IP до next event.
  final Map<String, _DnsAccumulator> _dnsByConnId =
      <String, _DnsAccumulator>{};

  // Last-known connection state from /connections poll: id → snapshot.
  // Используется для diff (closed connections).
  final Map<String, _ConnSnapshot> _connSnapshots = <String, _ConnSnapshot>{};

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
    // System-wide recording тоже опрашивает Clash /connections — без этого
    // в Live видны только DNS lines из core logs, а TCP/UDP open/close
    // приходят только через connection poll.
    _startConnectionPoll();
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
    _maybeStopConnectionPoll();
    AppLog.I.info('TrafficProfiler: global recording stopped');
    notifyListeners();
  }

  /// §048 — публичный getter unattributed ring buffer'а (для Per-app Live
  /// «System-wide events» section).
  List<TrafficEvent> get globalUnattributedEvents =>
      List.unmodifiable(_globalUnattributedEvents);

  /// §048 — count unattributed events за last [_unattributedBannerWindow]
  /// (для banner detection в UI: > [_unattributedBannerThreshold] = warning).
  int get recentUnattributedCount {
    final cutoff = DateTime.now().subtract(_unattributedBannerWindow);
    var n = 0;
    for (final e in _globalUnattributedEvents) {
      if (e.ts.isAfter(cutoff)) n++;
    }
    return n;
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
    // Стартуем connection poll timer.
    _startConnectionPoll();

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

    // Stop session-specific data sources. Log listener / connection poll /
    // GC timer остаются running если есть global recording — иначе detach.
    _maybeStopConnectionPoll();
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
  /// и убираем entries старше 30s. Также чистим `_dnsByConnId` и trim'им
  /// `_globalRollingBuffer` по time window'у.
  void _gcStaleConnIds() {
    final now = DateTime.now();
    final cutoff = now.subtract(_connIdTtl);
    _connIdToMeta.removeWhere((_, m) => m.firstSeen.isBefore(cutoff));
    _dnsByConnId.removeWhere((_, a) => a.lastTs.isBefore(cutoff));

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

  // §048 Принцип 2 — defensive DNS regex. Принимаем любой record type
  // (`(\S+)` capture group вместо `A|AAAA|CNAME` whitelist).
  // Sing-box логирует обе формы: `exchanged` — реальный network query,
  // `cached` — DNS cache hit. Для нашей цели обе одинаково полезны.
  // Time field — `\S+` чтобы принимать `5ms`, `10.0s`, `1m23s`, etc.
  // Capture groups: connId, recordType, name, answer.
  static final _dnsRe = RegExp(
      r'\[(\d+)\s+\S+\]\s+dns: (?:exchanged|cached)\s+(\S+)\s+(\S+?)\.\s+\d+\s+IN\s+\S+\s+(.+?)$');

  // §048 Принцип 2 — defensive DNS-fail regex. Принимает форматы:
  //   `dns: exchange failed for X. IN HTTPS: context deadline exceeded`
  //   `dns: exchange failed for X.: timeout`
  //   `dns: exchange failed for some.host: context deadline exceeded` (без trailing dot)
  //   `dns: exchange failed: <reason>` (без `for <name>` совсем)
  // Trailing dot после name — optional. Time field — `\S+` (ms / s / unknown).
  // Capture groups: connId, queriedName (optional), recordType (optional), reason.
  static final _dnsFailRe = RegExp(
      r'\[(\d+)\s+\S+\]\s+dns: exchange failed(?: for (\S+?)\.?(?: IN (\S+))?)?:\s*(.+?)$');

  // INFO[NNNN] [<conn_id> <Nms>] inbound/tun[tun-in]: inbound packet connection (from|to) <addr>:<port>
  static final _tunPacketRe = RegExp(
      r'\[(\d+)\s+\d+ms\]\s+inbound/tun\[[^\]]+\]: inbound packet connection (from|to)');

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

    // 2) DNS resolve (defensive — любой record type).
    final dnsM = _dnsRe.firstMatch(line);
    if (dnsM != null) {
      _handleDnsLine(line, ts, dnsM);
      return;
    }

    // 3) DNS fail (defensive — extract domain + record type если есть).
    final failM = _dnsFailRe.firstMatch(line);
    if (failM != null) {
      _handleDnsFailLine(line, ts, failM);
      return;
    }

    // 4) tun packet — для process inference (no-op, оставляем для будущего).
    final tunM = _tunPacketRe.firstMatch(line);
    if (tunM != null) {
      // no-op — обработка в /connections polling.
      return;
    }
  }

  void _handleDnsLine(String line, DateTime ts, RegExpMatch m) {
    final connId = m.group(1)!;
    final type = m.group(2)!.toUpperCase();
    final name = m.group(3)!;
    final answer = m.group(4)!.trim();

    final meta = _connIdToMeta[connId];

    final acc = _dnsByConnId.putIfAbsent(
        connId, () => _DnsAccumulator(domain: name, firstTs: ts));

    if (type == 'CNAME') {
      // CNAME: <name> → <target>. Если accumulator domain == name, это
      // следующий шаг chain'а; иначе — multi-step record (rare in practice).
      final target = answer.replaceAll(RegExp(r'\.$'), '');
      acc.cnameChain.add(target);
      acc.lastTs = ts;
      acc.lastResolvedName = target;
      // CNAME hops сами по себе не emit'ятся как отдельные events —
      // они аккумулируются в acc.cnameChain и появляются как поле в
      // финальном dnsResolve event'е (когда A/AAAA придёт).
      return;
    }

    if (type == 'A' || type == 'AAAA') {
      final ip = answer.split(RegExp(r'\s+')).first;
      acc.ips.add(ip);
      acc.lastTs = ts;
      // Аттрибутируем event на **оригинальный** queried domain
      // (acc.domain), не на финальный CNAME-target. Так в Domains tab
      // юзер видит "api-invest-gw.t-bank-app.ru" (то что app реально
      // запрашивал), а CNAME chain отдельно показывает hops до final IP.
      final ev = TrafficEvent(
        ts: ts,
        kind: TrafficEventKind.dnsResolve,
        domain: acc.domain,
        cnameChain: List.of(acc.cnameChain),
        ip: ip,
        connId: connId,
        process: meta?.process,
        rawLogLine: line,
        dnsRecordType: type,
        confidence: meta == null
            ? ConfidenceLevel.unattributed
            : ConfidenceLevel.verified,
        matchedVia: meta == null ? null : 'router_log',
      );
      _routeEvent(ev);
      return;
    }

    // §048 Принцип 2 — другие record types (HTTPS / SVCB / SOA / MX / TXT
    // / unknown): defensive — emit'им event с record type, чтобы юзер
    // видел в Live что app сделал такой query.
    final ev = TrafficEvent(
      ts: ts,
      kind: TrafficEventKind.dnsResolve,
      domain: acc.domain,
      cnameChain: List.of(acc.cnameChain),
      // Для HTTPS / SVCB / SOA / MX / TXT etc — answer обычно не IP,
      // оставляем `extra` для raw payload'а, в `ip` ничего.
      connId: connId,
      process: meta?.process,
      rawLogLine: line,
      dnsRecordType: type,
      confidence: meta == null
          ? ConfidenceLevel.unattributed
          : ConfidenceLevel.verified,
      matchedVia: meta == null ? null : 'router_log',
      extra: {'answer': answer},
    );
    _routeEvent(ev);
  }

  void _handleDnsFailLine(String line, DateTime ts, RegExpMatch m) {
    final connId = m.group(1)!;
    final domain = m.group(2); // optional — extract'ится не из всех формат
    final recordType = m.group(3); // optional — IN <TYPE>
    final reason = m.group(4)!.trim();
    final meta = _connIdToMeta[connId];

    // §048 Принцип 1 — DNS fail без owner НЕ дропается. Эмитим как
    // unattributed event в global ring + (если есть match) в session.
    final ev = TrafficEvent(
      ts: ts,
      kind: TrafficEventKind.dnsFail,
      domain: domain,
      connId: connId,
      process: meta?.process,
      rawLogLine: line,
      dnsRecordType: recordType?.toUpperCase(),
      confidence: meta == null
          ? ConfidenceLevel.unattributed
          : ConfidenceLevel.verified,
      matchedVia: meta == null ? null : 'router_log',
      shownBecause: meta == null
          ? 'system-wide DNS failure (no owner package detected)'
          : null,
      issues: [
        ConnectionIssue(ConnectionIssueKind.dnsTimeout,
            'DNS exchange failed: $reason'),
      ],
    );
    _routeEvent(ev);
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

  // ─── Connections poll (supplement, not discovery) ────────────────────

  void _startConnectionPoll() {
    _stopConnectionPoll();
    _connTimer = Timer.periodic(_connPollInterval, (_) => _pollConnections());
    // Immediate первый прогон чтобы не ждать 5с.
    Future.microtask(_pollConnections);
  }

  void _stopConnectionPoll() {
    _connTimer?.cancel();
    _connTimer = null;
  }

  /// Останавливает poll только если ни active session, ни global recording
  /// — иначе оставляем running. Симметрично `_maybeDetachLogListener`.
  void _maybeStopConnectionPoll() {
    if (_active != null) return;
    if (_globalRecordingActive) return;
    _stopConnectionPoll();
  }

  Future<void> _pollConnections() async {
    final s = _active;
    // Poll работает если есть session ИЛИ global recording. Без обоих
    // не зачем дёргать Clash API.
    if (s == null && !_globalRecordingActive) return;
    final fetcher = _connectionsFetcher;
    if (fetcher == null) return;
    Map<String, dynamic> data;
    try {
      data = await fetcher();
    } catch (_) {
      return; // не падаем — следующий tick попробует снова
    }
    final now = DateTime.now();
    final conns = (data['connections'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>();

    final seenIds = <String>{};
    for (final c in conns) {
      final id = c['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      seenIds.add(id);
      final meta = c['metadata'] as Map<String, dynamic>? ?? {};
      // Sing-box `find_process: true` возвращает в `metadata.process`/
      // `processPath` строки вида `"ru.tinkoff.investing (10999)"`.
      final process = meta['process']?.toString() ?? '';
      final processPath = meta['processPath']?.toString() ?? '';
      final rawProcess = process.isNotEmpty ? process : processPath;

      final host = meta['host']?.toString() ?? '';
      final destIp = meta['destinationIP']?.toString() ?? '';
      final destPort =
          int.tryParse(meta['destinationPort']?.toString() ?? '') ?? 0;
      final network = meta['network']?.toString() ?? '';
      final chains = (c['chains'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [];
      final up = (c['upload'] as num?)?.toInt() ?? 0;
      final down = (c['download'] as num?)?.toInt() ?? 0;
      final rule = c['rule']?.toString() ?? '';
      final rulePayload = c['rulePayload']?.toString() ?? '';

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
          outboundChain: chains,
          upBytes: up,
          downBytes: down,
          process: rawProcess.isNotEmpty ? rawProcess : null,
          network: network,
          rule: rule.isNotEmpty ? rule : null,
          rulePayload: rulePayload.isNotEmpty ? rulePayload : null,
        );
        // Global rolling: всегда добавляем (даже не-target conn'ы, для
        // Live system-wide tab'а) с confidence verified если process
        // известен, иначе unattributed.
        final globalEv = TrafficEvent(
          ts: raw.ts,
          kind: raw.kind,
          domain: raw.domain,
          cnameChain: raw.cnameChain,
          ip: raw.ip,
          port: raw.port,
          outboundChain: raw.outboundChain,
          upBytes: raw.upBytes,
          downBytes: raw.downBytes,
          duration: raw.duration,
          connId: raw.connId,
          process: raw.process,
          processInferred: raw.processInferred,
          network: raw.network,
          rule: raw.rule,
          rulePayload: raw.rulePayload,
          rawLogLine: raw.rawLogLine,
          confidence: raw.process == null
              ? ConfidenceLevel.unattributed
              : ConfidenceLevel.verified,
          matchedVia: raw.process == null ? null : 'connections_meta',
          dnsRecordType: raw.dnsRecordType,
          issues: raw.issues,
          extra: raw.extra,
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

        if (s != null) {
          // Session resolution.
          final resolved = _resolveForSession(raw, s);
          if (resolved != null) {
            _appendEvent(s, resolved);
            snapProcess = resolved.process ?? '';
            snapConfidence = resolved.confidence;
            snapMatchedVia = resolved.matchedVia;
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
          chains: chains,
          upBytes: up,
          downBytes: down,
          startedAt: now,
          process: snapProcess,
          confidence: snapConfidence,
          matchedVia: snapMatchedVia,
          rule: rule,
          rulePayload: rulePayload,
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
      // Global stream/buffer — всегда (для Live system-wide tab).
      if (_globalRecordingActive) {
        _appendToGlobalRollingBuffer(closeEv);
        _emitGlobalStream(
            {'event': 'traffic_event', 'data': closeEv.toJson()});
      }
      // Session — только если active.
      if (s != null) {
        _appendEvent(s, closeEv);
      }
    }
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
    notifyListeners();
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
    _dnsByConnId.clear();
    _connSnapshots.clear();
    _globalRollingBuffer.clear();
    _globalUnattributedEvents.clear();
    _globalRecordingActive = false;
    _globalRecordingStartedAt = null;
    _connTimer?.cancel();
    _connTimer = null;
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
    _connectionsFetcher = null;
  }

  @visibleForTesting
  void feedLogLineForTest(String line, [DateTime? ts]) {
    _processLogLine(line, ts ?? DateTime.now());
  }

  @visibleForTesting
  Future<void> pollOnceForTest() => _pollConnections();

  @visibleForTesting
  void gcOnceForTest() => _gcStaleConnIds();
}

// ─────────────────────────────────────────────────────────────────────────
// Internal helpers
// ─────────────────────────────────────────────────────────────────────────

class _ConnMeta {
  _ConnMeta(this.process, this.firstSeen);
  final String process;
  final DateTime firstSeen;
}

class _DnsAccumulator {
  _DnsAccumulator({required this.domain, required this.firstTs})
      : lastTs = firstTs,
        lastResolvedName = domain;
  final String domain;
  String lastResolvedName;
  final List<String> cnameChain = <String>[];
  final Set<String> ips = <String>{};
  DateTime firstTs;
  DateTime lastTs;
}

class _ConnSnapshot {
  _ConnSnapshot({
    required this.id,
    required this.host,
    required this.ip,
    required this.port,
    required this.network,
    required this.chains,
    required this.upBytes,
    required this.downBytes,
    required this.startedAt,
    required this.process,
    required this.confidence,
    required this.matchedVia,
    required this.rule,
    required this.rulePayload,
  });
  final String id;
  final String host;
  final String ip;
  final int port;
  final String network;
  final List<String> chains;
  int upBytes;
  int downBytes;
  final DateTime startedAt;
  final String process;
  final ConfidenceLevel confidence;
  final String? matchedVia;
  final String rule;
  final String rulePayload;
}
