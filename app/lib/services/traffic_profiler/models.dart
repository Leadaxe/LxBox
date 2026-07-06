part of '../traffic_profiler.dart';

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

  /// §219 — (DORMANT) больше не присваивается: стратегия 4 (inference по
  /// recent-DNS IP в окне `_processInferenceWindow`) выпилена в §044. Значение
  /// оставлено для десериализации старых session JSON. UI marker: `〽 inferred`.
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

/// §160 — чистый аггрегатор событий в `byDomain` / `byIp`. Вынесен из
/// `Session._recompute` чтобы переиспользоваться и для session.events
/// (per-app trace), и для globalRollingBuffer (Stats→Live) одним кодом —
/// без дубля и расхождения логики (TraceExplorer считает агрегаты сам из
/// переданного списка событий, не завязываясь на Session).
///
/// Unattributed-события пропускаются (как и раньше): чтобы «nearby» events
/// без owner'а не пачкали Domains/IPs картинку. В Live-ленте они видны.
({Map<String, DomainStats> byDomain, Map<String, IpStats> byIp})
    computeTraceAggregates(List<TrafficEvent> events) {
  final byDomain = <String, DomainStats>{};
  final byIp = <String, IpStats>{};
  for (final e in events) {
    if (e.confidence == ConfidenceLevel.unattributed) continue;
    if (e.domain != null && e.domain!.isNotEmpty) {
      final d = byDomain.putIfAbsent(e.domain!, () => DomainStats(e.domain!));
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
      final ip = byIp.putIfAbsent(e.ip!, () => IpStats(e.ip!));
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
  return (byDomain: byDomain, byIp: byIp);
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
    this.detourChain = const [],
    this.outboundType,
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

  /// §174/§181 — РОУТИНГ-цепочка от ядра: `[node, …selectors-снизу-вверх]`
  /// (напр. `["[BL]-3", "✨auto", "vpn-1"]`). БЕЗ detour (§181 развернул §178-склейку).
  /// Человекочитаемая «цепочка решения» строится в UI: `rule ⇒ группы ⇒ : node`.
  final List<String> outboundChain;

  /// §181 — DETOUR-ось (транспорт): `[detour, …наружу]` (напр. `["WARP"]`).
  /// Отдельно от outboundChain — это куда физически ныряет пакет ПОСЛЕ выбора
  /// сервера, не часть решения маршрута. Пусто для прямых / без detour.
  final List<String> detourChain;

  /// §204 — тип финального outbound (`CcConnection.outboundType`:
  /// selector/urltest/vless/wireguard/…). Протащен из conn, чтобы detail-секция
  /// Routing была 1:1 с Conns (строка «Outbound type»). null для DNS / если
  /// ядро не отдало.
  final String? outboundType;
  final int? upBytes;
  final int? downBytes;
  final Duration? duration;
  final String? connId;
  final String? process;

  /// §219 — (DORMANT) всегда `false` в текущем коде: эквивалентно
  /// `confidence == inferred`, а стратегия 4 (`_inferProcessByIp`) выпилена в
  /// §044. Поле оставлено для backward-compat со старыми session JSON и
  /// UI/API-consumer'ами, не понимающими `confidence`. НЕ удалять (сломает
  /// десериализацию старых дампов), НЕ пытаться «заполнять».
  final bool processInferred;
  final String? network; // tcp / udp
  final String? rule;
  final String? rulePayload;

  /// §219 — (DORMANT) никогда не заполняется: лог-питатель профайлера снят в
  /// §180 (DNS из структурного стрима, TCP из ядра). Копируется при
  /// трансформациях и сериализуется для backward-compat со старыми session
  /// JSON; UI читает как `?? ''`. НЕ удалять (совместимость дампов).
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

  /// §181 — полная человекочитаемая трассировка пути пакета слева направо:
  /// `[tcp] процесс ⇒ rule ⇒ группа ⇒ …auto… : node → detour → domain`
  /// Разделители кодируют тип перехода: `⇒` внутренние (источник + роутинг),
  /// `:` выход во внешний мир (группа выбрала сервер), `→` снаружи (detour +
  /// назначение). `outboundChain` = `[node, …selectors]` от ядра (§174);
  /// группы разворачиваем reverse, node = `[0]` ставим после `:`.
  String get routingLine => routingLineOf();

  /// [compact] — для live-списка: префикс `[network] process ⇒` опускается,
  /// т.к. дублирует строку процесса + бейдж типа над ней. Строка начинается с
  /// `rule` (`final ⇒ vpn-1 : …`). Detail-sheet зовёт без compact (полная).
  String routingLineOf({bool compact = false}) {
    final sb = StringBuffer();
    if (!compact && network != null && network!.isNotEmpty) {
      sb.write('[$network] ');
    }
    // Внутренняя цепочка (⇒): процесс → rule → группы (сверху вниз).
    final inner = <String>[];
    if (!compact && process != null && process!.isNotEmpty) inner.add(process!);
    inner.add((rule != null && rule!.isNotEmpty) ? rule! : 'final');
    if (outboundChain.length > 1) {
      // selectors = chain[1:] от ВЕРХНЕГО к нижнему (reverse).
      inner.addAll(outboundChain.sublist(1).reversed);
    }
    sb.write(inner.join(' ⇒ '));
    // Выход во внешний мир (:): финальный node = chain[0].
    final node = outboundChain.isNotEmpty ? outboundChain.first : null;
    if (node != null) sb.write(' : $node');
    // Снаружи (→): detour-хвост + назначение. §251 — пара «селектор + его
    // выбор» (detour-канал §248 и кого он выбрал) — одна точка пути, не два
    // хопа: схлопываем в `селектор (выбор)`.
    final outer = <String>[];
    outer.addAll(foldSelectorPairs(detourChain));
    final dest = (domain != null && domain!.isNotEmpty)
        ? domain
        : (ip != null && ip!.isNotEmpty ? ip : null);
    if (dest != null) outer.add(dest);
    if (outer.isNotEmpty) sb.write(' → ${outer.join(' → ')}');
    // §181 — длительность в человеческом формате: <1s → "930ms", иначе "1s"/"1m".
    if (duration != null) sb.write(' · ${_fmtDuration(duration!)}');
    return sb.toString();
  }

  /// §181 — короткая длительность: до секунды в мс (важно для коротких conn),
  /// от секунды — `formatDuration` (1s / 1m / 1h Xm).
  static String _fmtDuration(Duration d) {
    if (d.inMilliseconds < 1000) return '${d.inMilliseconds}ms';
    return formatDuration(d);
  }

  Map<String, Object?> toJson() => {
        'ts': ts.toUtc().toIso8601String(),
        'kind': kind.name,
        if (domain != null) 'domain': domain,
        if (cnameChain.isNotEmpty) 'cname_chain': cnameChain,
        if (ip != null) 'ip': ip,
        if (port != null) 'port': port,
        if (outboundChain.isNotEmpty) 'outbound_chain': outboundChain,
        if (detourChain.isNotEmpty) 'detour_chain': detourChain,
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

  /// §084 H6 — копия с переопределением полей. Используется в
  /// `_pollConnections` чтобы из `raw` (session-snapshot) собрать `globalEv`
  /// (global-buffer вариант с confidence/matchedVia) без ручного копирования
  /// всех 20+ полей (источник дрейфа при добавлении нового поля).
  TrafficEvent copyWith({
    ConfidenceLevel? confidence,
    String? matchedVia,
    bool? backfilled,
    List<ConnectionIssue>? issues,
  }) =>
      TrafficEvent(
        ts: ts,
        kind: kind,
        domain: domain,
        cnameChain: cnameChain,
        ip: ip,
        port: port,
        outboundChain: outboundChain,
        detourChain: detourChain,
        outboundType: outboundType, // §204
        upBytes: upBytes,
        downBytes: downBytes,
        duration: duration,
        connId: connId,
        process: process,
        processInferred: processInferred,
        network: network,
        rule: rule,
        rulePayload: rulePayload,
        rawLogLine: rawLogLine,
        confidence: confidence ?? this.confidence,
        matchedVia: matchedVia ?? this.matchedVia,
        shownBecause: shownBecause,
        dnsRecordType: dnsRecordType,
        backfilled: backfilled ?? this.backfilled,
        issues: issues ?? this.issues,
        extra: extra,
      );
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
    final agg = computeTraceAggregates(events);
    _byDomain = agg.byDomain;
    _byIp = agg.byIp;
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
