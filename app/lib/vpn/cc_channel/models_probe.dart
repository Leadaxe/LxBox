part of '../cc_channel.dart';

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

/// §669 — ответ probe-сессии на вызов с чужим/устаревшим runId: прогон вытеснен
/// новым (`ProbeSession.STALE_RUN` на Kotlin-стороне, сверка дословная).
const kProbeStaleRun = 'stale run';

/// §669 — результат `probeStart`: [error] '' при успехе, иначе текст ошибки;
/// [runId] — владелец поднятой сессии (0 при ошибке). Его несут
/// `probeUrlTest`/`probeGetUrl`/`probeCancel`/`probeStop`.
class CcProbeStart {
  const CcProbeStart({required this.error, required this.runId});

  final String error;
  final int runId;

  bool get ok => error.isEmpty;

  factory CcProbeStart.fromMap(Map<String, dynamic> m) => CcProbeStart(
    error: m['error']?.toString() ?? '',
    runId: _int(m['runId']),
  );
}

/// §392 — результат диагностического GET через узел (kernel SPEC 058).
///
/// ИНВАРИАНТ: `error` — единственный признак несостоявшегося обмена (тег не
/// найден, dial/TLS, таймаут). **Не-2xx статус ошибкой НЕ является**: 403 от
/// Cloudflare или 429 от гео-сервиса — ровно те данные, ради которых проба и
/// существует, они приезжают с `error == ''` и заполненным телом.
///
/// [remoteAddr] — адрес, куда цель отрезолвилась ИЗНУТРИ туннеля, а НЕ exit-IP
/// узла: exit-IP несёт тело ответа (строка `ip=` у cdn-cgi/trace).
///
/// [elapsedMs] — время всего обмена вместе с чтением тела; это не замер
/// задержки, и в историю urltest ядро его не пишет.
class CcGetUrlResult {
  const CcGetUrlResult({
    required this.status,
    required this.content,
    required this.truncated,
    required this.contentType,
    required this.remoteAddr,
    required this.elapsedMs,
    required this.error,
  });

  final int status;
  final String content;
  final bool truncated;
  final String contentType;
  final String remoteAddr;
  final int elapsedMs;
  final String error;

  /// Обмен состоялся (ответ получен, любым статусом).
  bool get ok => error.isEmpty;

  factory CcGetUrlResult.fromMap(Map<String, dynamic> m) => CcGetUrlResult(
    status: _int(m['status']),
    content: m['content']?.toString() ?? '',
    truncated: m['truncated'] == true,
    contentType: m['contentType']?.toString() ?? '',
    remoteAddr: m['remoteAddr']?.toString() ?? '',
    elapsedMs: _int(m['elapsedMs']),
    error: m['error']?.toString() ?? '',
  );
}

/// §208 (SPEC 019 V2) — один слот пула round_robin-группы (`getPool`). Слоты
/// фиксированы по `slot`; нода в слоте может меняться (дотест). `delay`==0 →
/// мёртвая / не измерена (живая всегда ≥1 — ядро клампит на чтении).
class CcPoolSlot {
  const CcPoolSlot({
    required this.slot,
    required this.tag,
    required this.delay,
  });

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

/// §312 — член DNS-группы из `getDNSGroups` (kernel SPEC 035, схема v3).
class CcDnsGroupMember {
  const CcDnsGroupMember({
    required this.tag,
    required this.serverType,
    required this.clean,
    required this.liveErrors,
    required this.lastErrorAgeMs,
    required this.liveWins,
    required this.current,
    required this.lastRttMs,
  });

  final String tag;
  final String serverType;
  final bool clean; // ноль живых ошибок
  final int liveErrors;
  final int lastErrorAgeMs; // возраст последней живой ошибки; -1 = нет
  final int liveWins; // только fastest
  final bool current; // текущая цель группы
  final int lastRttMs; // последняя успешная проба; 0 = не мерялся

  factory CcDnsGroupMember.fromMap(Map<String, dynamic> m) => CcDnsGroupMember(
    tag: m['tag']?.toString() ?? '',
    serverType: m['serverType']?.toString() ?? '',
    clean: m['clean'] == true,
    liveErrors: _int(m['liveErrors']),
    lastErrorAgeMs: _int(m['lastErrorAgeMs'], fallback: -1),
    liveWins: _int(m['liveWins']),
    current: m['current'] == true,
    lastRttMs: _int(m['lastRttMs']),
  );
}

/// §312 — снапшот состояния DNS-группы из `getDNSGroups` (kernel SPEC 035).
class CcDnsGroup {
  const CcDnsGroup({
    required this.tag,
    required this.mode,
    required this.current,
    required this.members,
  });

  final String tag;
  final String mode; // stable | fastest | parallel
  final String current; // '' = ещё не выбиралась / parallel
  final List<CcDnsGroupMember> members;

  factory CcDnsGroup.fromMap(Map<String, dynamic> m) => CcDnsGroup(
    tag: m['tag']?.toString() ?? '',
    mode: m['mode']?.toString() ?? '',
    current: m['current']?.toString() ?? '',
    members: [
      for (final e in (m['members'] as List<dynamic>? ?? const []))
        if (e is Map) CcDnsGroupMember.fromMap(CcChannel._asMap(e)),
    ],
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

int _int(Object? v, {int fallback = 0}) =>
    v is int ? v : (v is num ? v.toInt() : fallback);
