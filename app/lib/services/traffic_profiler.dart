// §044 — Per-app traffic profiler.
//
// Singleton ChangeNotifier. Holds текущую recording session + ring-buffer
// последних N завершённых session'ов. Всё in-memory — на kill app'а всё
// стирается. Сознательно: упрощает model'ку, persist бы добавил schema'ы
// и migration'ы которые мало что дают для diagnostic-only-фичи.
//
// Data sources:
//   1. Sing-box log stream (через ClashLogPump → AppLog → here): ловим
//      DNS resolves (с CNAME chain'ом), package detection (`router: found
//      package name: X`) и связку `[conn_id Nms]`.
//   2. Clash API `/connections` polling 2s: получаем active TCP/UDP
//      connections с metadata.process (= package), bytes, chains, host/IP.
//
// Спарка — через conn_id для DNS, через `metadata.process` для конн'ов.
// DNS resolves строятся в `_DnsAccumulator` по conn_id; closed connections
// финализируются через diff между snapshots.
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
  final bool processInferred;
  final String? network; // tcp / udp
  final String? rule;
  final String? rulePayload;
  final String? rawLogLine;
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
  });

  final String id;
  final String targetPackage;
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
        'started_at': startedAt.toUtc().toIso8601String(),
        if (finishedAt != null)
          'finished_at': finishedAt!.toUtc().toIso8601String(),
        'verbose': wasVerbose,
        'events_count': events.length,
        'events_dropped': eventsDropped,
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
  static const Duration _connPollInterval = Duration(seconds: 2);
  static const Duration _connIdTtl = Duration(seconds: 30);
  static const Duration _processInferenceWindow = Duration(seconds: 10);

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

  // Live SSE listeners — стрим эвентов наружу для Debug API SSE.
  final List<StreamController<Map<String, Object?>>> _streamSinks =
      <StreamController<Map<String, Object?>>>[];

  // Subscriptions — отписываемся в stop().
  VoidCallback? _appLogListener;
  Timer? _connTimer;
  // Timestamp последнего обработанного core-log entry. Используется
  // вместо length-diff потому что AppLog имеет ring-buffer cap=500: при
  // overflow length стабилизируется на 500 и length-diff навечно =0,
  // мы бы пропускали всё. Timestamp монотонный и не зависит от cap'а.
  DateTime? _lastSeenLogTs;

  // Conn-id → package map (TTL'нутый).
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

  /// Start session for [targetPackage]. If уже active — finalize старый
  /// и стартуем новый. Если [verbose] = true — sets `log_level=debug`
  /// (caller сам решает делать reload).
  Future<Session> start(String targetPackage, {bool verbose = false}) async {
    if (_active != null) {
      await stop();
    }
    final session = Session(
      id: _generateId(),
      targetPackage: targetPackage,
      startedAt: DateTime.now(),
      wasVerbose: verbose,
    );
    _active = session;

    if (verbose) {
      _verboseSavedLogLevel = await SettingsStorage.getVar('log_level', '');
      await SettingsStorage.setVar('log_level', 'debug');
    }

    // Подписываемся на logs.
    _attachLogListener();
    // Стартуем connection poll timer.
    _startConnectionPoll();

    AppLog.I.info('TrafficProfiler: session started for $targetPackage');
    _emitStream({
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

    // Detach data sources.
    _detachLogListener();
    _stopConnectionPoll();

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

    // Очищаем maps — следующая session не должна видеть старые conn-id.
    _connIdToMeta.clear();
    _dnsByConnId.clear();
    _connSnapshots.clear();
    _lastSeenLogTs = null;

    AppLog.I.info(
        'TrafficProfiler: session stopped, ${s.events.length} events, '
        '${s.byDomain.length} domains');
    _emitStream({
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

  /// Подписаться на live-stream эвентов (для Debug API SSE).
  Stream<Map<String, Object?>> liveStream() {
    late StreamController<Map<String, Object?>> ctrl;
    ctrl = StreamController<Map<String, Object?>>(
      onListen: () {},
      onCancel: () {
        _streamSinks.remove(ctrl);
        ctrl.close();
      },
    );
    _streamSinks.add(ctrl);
    return ctrl.stream;
  }

  void _emitStream(Map<String, Object?> event) {
    if (_streamSinks.isEmpty) return;
    for (final c in List.of(_streamSinks)) {
      if (!c.isClosed) {
        c.add(event);
      }
    }
  }

  // ─── Log subscription ─────────────────────────────────────────────────

  void _attachLogListener() {
    _detachLogListener();
    final entries = AppLog.I.entriesForSource(DebugSource.core);
    _lastSeenLogTs = entries.isNotEmpty ? entries.first.time : null;
    _appLogListener = () {
      _drainNewLogEntries();
    };
    AppLog.I.addListener(_appLogListener!);
  }

  void _detachLogListener() {
    if (_appLogListener != null) {
      AppLog.I.removeListener(_appLogListener!);
      _appLogListener = null;
    }
    _lastSeenLogTs = null;
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

  // ─── Log parser ───────────────────────────────────────────────────────

  // INFO[NNNN] [<conn_id> <Nms>] router: found package name: <pkg>
  static final _packageRe = RegExp(
      r'(?:\[(\d+)\s+\d+m?s?\]\s+)?router: found package name:\s+(\S+)');
  // INFO[NNNN] [<conn_id> <Nms>] dns: (exchanged|cached) <TYPE> <name>. <ttl> IN <TYPE> <data>
  // Sing-box логирует обе формы: `exchanged` — реальный network query,
  // `cached` — DNS cache hit. Для нашей цели (показать какие DNS resolves
  // случились в session'е) обе одинаково полезны.
  static final _dnsRe = RegExp(
      r'\[(\d+)\s+(\d+)ms\]\s+dns: (?:exchanged|cached)\s+(\S+)\s+(\S+?)\.\s+\d+\s+IN\s+\S+\s+(.+?)$');
  // dns timeout / fail
  static final _dnsFailRe =
      RegExp(r'\[(\d+)\s+(\d+)ms\]\s+dns: exchange failed.*?:\s+(.+?)$');
  // INFO[NNNN] [<conn_id> <Nms>] inbound/tun[tun-in]: inbound packet connection (from|to) <addr>:<port>
  static final _tunPacketRe = RegExp(
      r'\[(\d+)\s+\d+ms\]\s+inbound/tun\[[^\]]+\]: inbound packet connection (from|to)');

  void _processLogLine(String line, DateTime ts) {
    final s = _active;
    if (s == null) return;

    // 1) Package detection — пишем в conn-id map.
    final pkgM = _packageRe.firstMatch(line);
    if (pkgM != null) {
      final connId = pkgM.group(1);
      final pkg = pkgM.group(2)!;
      if (connId != null && connId.isNotEmpty) {
        _connIdToMeta[connId] = _ConnMeta(pkg, ts);
        _gcConnIds(ts);
      }
      // top-level "router: found package name: X" без conn-id — пропускаем,
      // не знаем к какому conn id отнести.
      return;
    }

    // 2) DNS resolve.
    final dnsM = _dnsRe.firstMatch(line);
    if (dnsM != null) {
      _handleDnsLine(line, ts, dnsM, s);
      return;
    }

    // 3) DNS fail.
    final failM = _dnsFailRe.firstMatch(line);
    if (failM != null) {
      _handleDnsFailLine(line, ts, failM, s);
      return;
    }

    // 4) Outbound — связки с пакетом нет, оставляем для issue logic'и
    // через /connections snapshot. Пропускаем здесь.
    // 5) tun packet — для process inference: trigger lookup.
    final tunM = _tunPacketRe.firstMatch(line);
    if (tunM != null) {
      _gcConnIds(ts);
      return;
    }
  }

  void _handleDnsLine(
      String line, DateTime ts, RegExpMatch m, Session s) {
    final connId = m.group(1)!;
    final type = m.group(3)!.toUpperCase();
    final name = m.group(4)!;
    final answer = m.group(5)!.trim();

    // Resolved domain belongs to this session if conn_id mapped to target?
    final meta = _connIdToMeta[connId];
    final targetMatched =
        meta != null && meta.process == s.targetPackage;

    final acc = _dnsByConnId.putIfAbsent(
        connId, () => _DnsAccumulator(domain: name, firstTs: ts));

    if (type == 'CNAME') {
      // CNAME: <name> → <target>. Если accumulator domain == name, это
      // следующий шаг chain'а; иначе — multi-step record (rare in practice).
      final target = answer.replaceAll(RegExp(r'\.$'), '');
      acc.cnameChain.add(target);
      acc.lastTs = ts;
      // Update accumulated 'last name' для матчинга следующих A-записей.
      acc.lastResolvedName = target;
      return;
    }

    if (type == 'A' || type == 'AAAA') {
      // Резолв в IP — IP relevant к last-known-domain.
      final ip = answer.split(RegExp(r'\s+')).first;
      acc.ips.add(ip);
      acc.lastTs = ts;
      // Эмитим только если уже знаем что conn_id принадлежит target package.
      if (targetMatched) {
        // Аттрибутируем event на **оригинальный** queried domain
        // (acc.domain — первое имя что мы увидели), не на финальный
        // CNAME-target. Так в Domains tab юзер видит "api-invest-gw.t-bank-app.ru"
        // (то что app реально запрашивал), а CNAME chain отдельно показывает
        // hops до final IP. Иначе аггрегация дублировала бы запись на финальное
        // имя и теряла связь с тем что app просил.
        _appendEvent(
          s,
          TrafficEvent(
            ts: ts,
            kind: TrafficEventKind.dnsResolve,
            domain: acc.domain,
            cnameChain: List.of(acc.cnameChain),
            ip: ip,
            connId: connId,
            process: meta.process,
            rawLogLine: line,
          ),
        );
      }
    }
  }

  void _handleDnsFailLine(
      String line, DateTime ts, RegExpMatch m, Session s) {
    final connId = m.group(1)!;
    final reason = m.group(3)!;
    final meta = _connIdToMeta[connId];
    if (meta == null || meta.process != s.targetPackage) return;
    _appendEvent(
      s,
      TrafficEvent(
        ts: ts,
        kind: TrafficEventKind.dnsFail,
        connId: connId,
        process: meta.process,
        rawLogLine: line,
        issues: [
          ConnectionIssue(ConnectionIssueKind.dnsTimeout, 'DNS exchange failed: $reason'),
        ],
      ),
    );
  }

  void _gcConnIds(DateTime now) {
    if (_connIdToMeta.length < 256) return;
    final cutoff = now.subtract(_connIdTtl);
    _connIdToMeta.removeWhere((_, m) => m.firstSeen.isBefore(cutoff));
    _dnsByConnId.removeWhere((_, a) => a.lastTs.isBefore(cutoff));
  }

  // ─── Connections poll ─────────────────────────────────────────────────

  void _startConnectionPoll() {
    _stopConnectionPoll();
    _connTimer = Timer.periodic(_connPollInterval, (_) => _pollConnections());
    // Immediate первый прогон чтобы не ждать 2с.
    Future.microtask(_pollConnections);
  }

  void _stopConnectionPoll() {
    _connTimer?.cancel();
    _connTimer = null;
  }

  Future<void> _pollConnections() async {
    final s = _active;
    if (s == null) return;
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
      // `processPath` строки вида `"ru.tinkoff.investing (10999)"` — package
      // name + UID в скобках. Для матчинга с targetPackage снимаем UID.
      final process = _stripUid(meta['process']?.toString() ?? '');
      final processPath = _stripUid(meta['processPath']?.toString() ?? '');
      final rawProcess = process.isNotEmpty ? process : processPath;
      // Process inference: если process пустой, пробуем по conn_id или
      // по prior DNS resolved IPs.
      String? attributedProcess = rawProcess.isNotEmpty ? rawProcess : null;
      var inferred = false;
      if (attributedProcess == null) {
        final destIp = meta['destinationIP']?.toString() ?? '';
        if (destIp.isNotEmpty) {
          final inferredProc = _inferProcessByIp(destIp, now);
          if (inferredProc == s.targetPackage) {
            attributedProcess = inferredProc;
            inferred = true;
          }
        }
      }
      if (attributedProcess != s.targetPackage) continue;

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
        final kind = network == 'udp'
            ? TrafficEventKind.udpOpen
            : TrafficEventKind.tcpOpen;
        final ev = TrafficEvent(
          ts: now,
          kind: kind,
          domain: host.isNotEmpty ? host : null,
          ip: destIp.isNotEmpty ? destIp : null,
          port: destPort > 0 ? destPort : null,
          outboundChain: chains,
          upBytes: up,
          downBytes: down,
          process: attributedProcess,
          processInferred: inferred,
          network: network,
          rule: rule.isNotEmpty ? rule : null,
          rulePayload: rulePayload.isNotEmpty ? rulePayload : null,
        );
        // На open'е issues не вычисляем — оба текущих типа (dnsTimeout /
        // tcpReset) релевантны другим event'ам.
        _appendEvent(s, ev);
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
          process: attributedProcess!,
          inferred: inferred,
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
    final closed = _connSnapshots.keys.where((k) => !seenIds.contains(k)).toList();
    for (final id in closed) {
      final snap = _connSnapshots.remove(id);
      if (snap == null) continue;
      _appendEvent(
        s,
        TrafficEvent(
          ts: now,
          kind: TrafficEventKind.tcpClose,
          domain: snap.host.isNotEmpty ? snap.host : null,
          ip: snap.ip.isNotEmpty ? snap.ip : null,
          port: snap.port > 0 ? snap.port : null,
          outboundChain: snap.chains,
          upBytes: snap.upBytes,
          downBytes: snap.downBytes,
          duration: now.difference(snap.startedAt),
          process: snap.process,
          processInferred: snap.inferred,
          network: snap.network,
          rule: snap.rule.isEmpty ? null : snap.rule,
          rulePayload: snap.rulePayload.isEmpty ? null : snap.rulePayload,
          issues: _classifyConnectionClose(snap, now),
        ),
      );
    }
  }

  String? _inferProcessByIp(String ip, DateTime now) {
    final s = _active;
    if (s == null) return null;
    // Идём с конца events (newest), ищем dnsResolve с ip == [ip]
    // в окне _processInferenceWindow.
    final cutoff = now.subtract(_processInferenceWindow);
    for (var i = s.events.length - 1; i >= 0; i--) {
      final e = s.events[i];
      if (e.ts.isBefore(cutoff)) break;
      if (e.kind == TrafficEventKind.dnsResolve && e.ip == ip) {
        return e.process;
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
    _emitStream({
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
  /// — без UID, поэтому тут strip'аем для матчинга.
  static String _stripUid(String s) {
    final t = s.trim();
    if (t.isEmpty) return '';
    final paren = t.indexOf(' (');
    return paren < 0 ? t : t.substring(0, paren);
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
    _connTimer?.cancel();
    _connTimer = null;
    _detachLogListener();
    _streamSinks.clear();
    _connectionsFetcher = null;
  }

  @visibleForTesting
  void feedLogLineForTest(String line, [DateTime? ts]) {
    _processLogLine(line, ts ?? DateTime.now());
  }

  @visibleForTesting
  Future<void> pollOnceForTest() => _pollConnections();
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
    required this.inferred,
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
  final bool inferred;
  final String rule;
  final String rulePayload;
}
