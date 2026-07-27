// §044 — System-wide traffic profiler.
// §048 — Inclusive observer with confidence: каждое событие попадает в UI
// с confidence level'ом, юзер видит всё что произошло на сети.
// §288 — per-app session-путь удалён; остался ТОЛЬКО system-wide profiler
// (global recording, live-поток по всем приложениям).
//
// Singleton ChangeNotifier. Holds **глобальный rolling buffer** всех
// событий (окно настраивается юзером) для Live system-wide tab —
// discovery-mode по всем приложениям без выбора target заранее.
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
// **Confidence levels** (§048 Принцип 3) в global buffer'е:
//   - `verified`     — процесс известен ядром (packageName)
//   - `unattributed` — процесс не определён (DNS fail без owner / TCP без атрибуции)
//
// Connection-issue классификация: 2 типа — `dnsTimeout` (прямо из sing-box
// log stream'а, реальная error-строка) и `tcpReset` (heuristic «conn
// закрылся <1с с 0 bytes»).

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../vpn/cc_channel.dart';
import 'app_log.dart';
import 'dns_health_detector.dart'; // §262 — детектор здоровья DNS
import 'format_utils.dart'; // §181 — formatDuration в routingLine
import 'selector_info.dart'; // §251 — fold «селектор (выбор)» в routingLine
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
  // §141 P3.2b — GC-интервал 15s: GC чистит rolling buffer'ы по retention-окну
  // + closed-guard. (§044 — _connIdTtl выпилен вместе с conn-id-мапой.)
  static const Duration _connIdGcInterval = Duration(seconds: 15);
  // §048 / §044-new-profiler — global rolling buffer всегда работает. Окно
  // НАСТРАИВАЕМО (юзер выбирает 1/10/60 мин в фильтр-окне профайлера) — было
  // жёстко 60s. Default 10 мин (600s). Грузится из SettingsStorage через
  // [loadRetention]; меняется на лету через [setRetention]. Hard cap поднят
  // (на 60-мин окне событий заметно больше) — защита памяти на busy device'ах.
  Duration _globalRollingWindow =
      Duration(seconds: SettingsStorage.profilerRetentionDefaultSec);
  static const int _globalRollingHardCap = 20000;

  /// Текущее окно хранения Live-журнала (для UI: показать выбранное).
  Duration get retention => _globalRollingWindow;

  /// §044/new-profiler — загрузить окно хранения из настроек (вызывать при
  /// открытии профайлера). Идемпотентно.
  Future<void> loadRetention() async {
    final sec = await SettingsStorage.getProfilerRetentionSec();
    _globalRollingWindow = Duration(seconds: sec);
  }

  /// §044/new-profiler — сменить окно хранения на лету + персист. Немедленно
  /// влияет на следующий GC-проход (старые события подрежутся/доживут).
  Future<void> setRetention(Duration window) async {
    if (window == _globalRollingWindow) return;
    _globalRollingWindow = window;
    await SettingsStorage.setProfilerRetentionSec(window.inSeconds);
    notifyListeners();
  }
  // Banner threshold: >5 unattributed за 30s → user-visible warning.
  static const int _unattributedBannerThreshold = 5;
  static const Duration _unattributedBannerWindow = Duration(seconds: 30);

  // ─── Live wiring (§168) ───────────────────────────────────────────────
  // Источник connection-событий — CommandClient push-стрим. Подписка живёт
  // пока идёт global recording; снимается когда recording off.
  final CcChannel _cc = CcChannel.instance;
  StreamSubscription<List<CcConnection>>? _ccConnSub;
  StreamSubscription<List<CcDnsQuery>>? _ccDnsSub; // §180 — DNS-журнал из ядра

  // ─── State ────────────────────────────────────────────────────────────

  // SSE listeners — стрим эвентов наружу для Debug API SSE.
  // Global stream'ы (Live tab + /profiler/live/stream).
  final List<StreamController<Map<String, Object?>>> _globalStreamSinks =
      <StreamController<Map<String, Object?>>>[];

  // §048 Принцип 4/7 — глобальный rolling buffer всех events системы.
  // Включается **explicit** через `startGlobalRecording()` (юзер тапнул
  // ▶ START в Live tab); останавливается через `stopGlobalRecording()` или
  // app kill. Без active recording listener detached, buffer не растёт —
  // никаких теневых потребителей.
  //
  // Используется Live system-wide tab'ом — discovery по всем приложениям
  // без выбора target заранее.
  final ListQueue<TrafficEvent> _globalRollingBuffer =
      ListQueue<TrafficEvent>();

  // §048 — explicit recording state. Independent of UI subscription:
  // recording продолжается когда юзер ушёл с Live tab'а / свернул app.
  bool _globalRecordingActive = false;
  DateTime? _globalRecordingStartedAt;

  // §048 Принцип 1 — отдельный ring-buffer unattributed events (DNS fail
  // без owner / HTTPS / SOA / SVCB) для UI «System-wide events» секции
  // в Live tab'е. 50 events достаточно чтобы юзер увидел тренд.
  final ListQueue<TrafficEvent> _globalUnattributedEvents =
      ListQueue<TrafficEvent>();
  static const int _globalUnattributedCap = 50;

  // §044 — §180-cleanup: _appLogListener / _lastSeenLogTs / _connIdToMeta
  // выпилены вместе с лог-питателем (§219 — GC-таймер см. _ensureGcTimerStarted
  // ниже). GC-таймер остаётся — чистит rolling buffer'ы по retention-окну, не
  // conn-id-мапу.
  Timer? _gcTimer;

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

  // ─────────────────────── §262 — детектор здоровья DNS ───────────────────────
  // Скользящее окно [kDnsHealthWindow] по _globalRollingBuffer. Вердикт
  // unhealthy = fail-доля ≥20% + ≥3 fail + есть conn-активность (связь жива).
  // Драйвит баннер в Live-профайлере (live_events_tab) + попап 3 решений.

  DnsHealthStats _computeDnsHealth() {
    final now = DateTime.now();
    final stats = DnsHealthStats();
    for (final e in _globalRollingBuffer) {
      final ageMs = now.difference(e.ts).inMilliseconds;
      if (ageMs > kDnsHealthWindow.inMilliseconds) continue;
      final kind = switch (e.kind) {
        TrafficEventKind.dnsResolve => DnsHealthEventKind.dnsResolve,
        TrafficEventKind.dnsFail => DnsHealthEventKind.dnsFail,
        TrafficEventKind.tcpOpen ||
        TrafficEventKind.udpOpen ||
        TrafficEventKind.tcpClose =>
          DnsHealthEventKind.connActivity,
      };
      stats.add(DnsHealthSample(kind: kind, ageMs: ageMs));
    }
    return stats;
  }

  /// §262 — вердикт детектора (для баннера). true = DNS деградировал при живой
  /// связи.
  bool get dnsHealthUnhealthy => _computeDnsHealth().unhealthy;

  /// §262 — доля fail за окно (для текста баннера «N% queries failing»).
  int get dnsHealthFailPercent => (_computeDnsHealth().failRatio * 100).round();

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

  void _emitGlobalStream(Map<String, Object?> event) {
    if (_globalStreamSinks.isEmpty) return;
    for (final c in List.of(_globalStreamSinks)) {
      if (!c.isClosed) c.add(event);
    }
  }

  // §044 — §180-cleanup: лог-листенер (_ensureLogListenerAttached/
  // _maybeDetachLogListener/_drainNewLogEntries/_processLogLine) ВЫПИЛЕН. Он
  // питал только write-only `_connIdToMeta` (TCP-атрибуция из router-лога),
  // которая после §168 не читается — TCP-owner идёт из ядра
  // (CcConnection.packageName), DNS — из стрима SPEC 018. Core-лог больше не
  // парсится профайлером.

  void _ensureGcTimerStarted() {
    _gcTimer ??= Timer.periodic(_connIdGcInterval, (_) => _gcStaleConnIds());
  }

  void _maybeStopGcTimer() {
    if (_globalRecordingActive) return;
    _gcTimer?.cancel();
    _gcTimer = null;
  }

  /// §048 Принцип 6 — time-based GC, не count-based. §219 — тик каждые
  /// `_connIdGcInterval` (15s); trim'им `_globalRollingBuffer` по динамическому
  /// `_globalRollingWindow`. (§180 — `_dnsByConnId` выпилен, чистить нечего.)
  void _gcStaleConnIds() {
    final now = DateTime.now();
    // §176 — guard уже-обработанных closed: чистим старше 5 мин (ядро их к
    // этому моменту эвиктнуло из FilterState(All), в снапшоте больше нет).
    final closedCutoff = now.subtract(const Duration(minutes: 5));
    _closedHandled.removeWhere((_, ts) => ts.isBefore(closedCutoff));

    // Trim global rolling buffer по time window'у.
    final globalCutoff = now.subtract(_globalRollingWindow);
    var trimmed = false;
    while (_globalRollingBuffer.isNotEmpty &&
        _globalRollingBuffer.first.ts.isBefore(globalCutoff)) {
      _globalRollingBuffer.removeFirst();
      trimmed = true;
    }
    // Trim unattributed ring (тоже time-based, но cap=50 защищает от busy
    // bursts).
    while (_globalUnattributedEvents.isNotEmpty &&
        _globalUnattributedEvents.first.ts.isBefore(globalCutoff)) {
      _globalUnattributedEvents.removeFirst();
      trimmed = true;
    }

    // §262 — тримминг мог погасить вердикт детектора здоровья DNS
    // (dnsHealthUnhealthy) или unattributed-баннера: события «остыли» и
    // выпали из окна, но без нового event'а UI об этом не узнает (SSE-фид
    // молчит). Нотифицируем listeners, чтобы баннеры пересчитались. Только
    // при реальном тримминге — на idle-тике зря не будим UI.
    if (trimmed) notifyListeners();
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

  /// §180 — батч DNS-событий из ядра (SPEC 018 v2, §261: `CommandDNS`-команда
  /// мультиплекса). Заменяет текстовый `_handleDnsLine`/`_handleDnsFailLine`.
  /// Атрибуция к приложению —
  /// `q.packageName` ИЗ ЯДРА (processInfo), не connId-сшивка (корень §177-баннера).
  void _ingestDnsQueries(List<CcDnsQuery> queries) {
    // Обрабатываем только при global recording.
    if (!_globalRecordingActive) return;
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
      // rc.10 — dnsServer заполнен и на провалах (какой сервер не ответил).
      final failExtra = <String, Object?>{};
      if (q.dnsServer.isNotEmpty) failExtra['dns_server'] = q.dnsServer;
      if (q.dnsServerType.isNotEmpty) {
        failExtra['dns_server_type'] = q.dnsServerType;
      }
      if (q.source.isNotEmpty) failExtra['source'] = q.source;
      // §315 — трасса группы: на провале она важнее всего (видно, кто из
      // членов сбоил и добил ли веер).
      _addDnsGroupTrace(failExtra, q);
      _routeEvent(TrafficEvent(
        ts: ts,
        kind: TrafficEventKind.dnsFail,
        domain: q.domain.isNotEmpty ? q.domain : null,
        process: process,
        outboundChain: q.outbound, // rc.10 — канал (может быть пуст на провале)
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
        extra: failExtra.isEmpty ? null : failExtra,
      ));
      return;
    }

    // Q3 (SPEC 018): cnameChain = CNAME-hops из answers; ip = первый A/AAAA.
    // Аттрибуция на ОРИГИНАЛЬНЫЙ домен (q.domain), не на финальный target —
    // как в текстовом пути (юзер видит что app запрашивал, CNAME chain отдельно).
    // §180-fix (device dev.72): ядро в DnsAnswer.rdata кладёт ПОЛНУЮ RR-строку
    // "name TTL IN TYPE value" (напр. "google.com. 29 IN A 64.233.165.139"),
    // НЕ голое значение → берём последнее поле (_rdataValue).
    // §219 — один проход по q.answers (было два раздельных .where).
    final cnameChain = <String>[];
    final addresses = <String>[];
    for (final a in q.answers) {
      if (a.isCname) {
        cnameChain.add(_rdataValue(a.rdata));
      } else if (a.isAddress) {
        addresses.add(_rdataValue(a.rdata));
      }
    }
    final ip = addresses.isNotEmpty ? addresses.first : null;

    // rc.10 — outbound-канал DNS-сервера (узел/селектор→узел), список как
    // chain. Кладём в outboundChain → routingLine покажет «через какой сервер
    // пошёл DNS». Пусто на cached (cache-hit без сетевого пути).
    final outboundChain = q.outbound;

    // rc.10 — dnsServer/тип в extra (для detail-sheet). + answer для не-адресных.
    // source (exchanged/cached/optimistic/refreshed) → detail-sheet + cached-бейдж.
    final extra = <String, Object?>{};
    if (q.dnsServer.isNotEmpty) extra['dns_server'] = q.dnsServer;
    if (q.dnsServerType.isNotEmpty) extra['dns_server_type'] = q.dnsServerType;
    if (q.source.isNotEmpty) extra['source'] = q.source;
    if (ip == null && q.answers.isNotEmpty) {
      extra['answer'] = _rdataValue(q.answers.first.rdata);
    }
    _addDnsGroupTrace(extra, q); // §315

    _routeEvent(TrafficEvent(
      ts: ts,
      kind: TrafficEventKind.dnsResolve,
      domain: q.domain,
      cnameChain: cnameChain,
      ip: ip,
      process: process,
      outboundChain: outboundChain,
      dnsRecordType: recordType,
      confidence:
          attributed ? ConfidenceLevel.verified : ConfidenceLevel.unattributed,
      matchedVia: attributed ? 'dns_stream' : null,
      extra: extra.isEmpty ? null : extra,
    ));
  }

  /// §315 (kernel SPEC 035) — трасса DNS-группы в `extra` события.
  ///
  /// Групповое живёт в `extra`, а не полями `TrafficEvent`: модель события
  /// общая для TCP/UDP/DNS, и не-DNS события таскали бы мёртвые поля.
  /// `attempts` схлопывается в плоскую строку — `extra` типизирован как
  /// `Map<String, Object?>` и рендерится copy-строкой; структурный список
  /// потребовал бы своего виджета, что избыточно для диагностики.
  ///
  /// Флаги пишутся ТОЛЬКО когда true — иначе `extra` мусорился бы `false`
  /// на каждом обычном запросе (99% трафика идёт мимо групп).
  static void _addDnsGroupTrace(Map<String, Object?> extra, CcDnsQuery q) {
    if (q.groupPath.isNotEmpty) {
      extra['dns_group_path'] = q.groupPath.join(' → ');
    }
    if (q.attempts.isNotEmpty) {
      extra['dns_attempts'] = [
        for (final a in q.attempts)
          '${a.server} ${a.outcome}${a.rttMs > 0 ? ' ${a.rttMs}ms' : ''}',
      ].join(' · ');
    }
    if (q.fanned) extra['dns_fanned'] = 'true';
    if (q.survival) extra['dns_survival'] = 'true';
  }

  // ─── Event routing (global) ───────────────────────────────────────────

  /// §048 — central routing. Каждое event'ое:
  ///   1. Кладётся в `_globalRollingBuffer` (always-running при recording).
  ///   2. Если confidence == unattributed — в `_globalUnattributedEvents`
  ///      ring для banner detection.
  ///   3. Эмитится в global SSE stream.
  void _routeEvent(TrafficEvent ev) {
    // Step 1: global buffer (всегда).
    _appendToGlobalRollingBuffer(ev);
    // Step 2: global unattributed ring (для banner detection / Live
    // «System-wide events» section).
    if (ev.confidence == ConfidenceLevel.unattributed) {
      _appendToGlobalUnattributed(ev);
    }
    // Step 3: SSE.
    _emitGlobalStream({'event': 'traffic_event', 'data': ev.toJson()});
  }

  void _appendToGlobalRollingBuffer(TrafficEvent ev) {
    _globalRollingBuffer.addLast(ev);
    // §219 — hard cap `_globalRollingHardCap` (20000) чтобы память не убегала
    // на busy device'ах. Time-based trim — в GC-тике (_connIdGcInterval = 15s).
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

  // ─── CommandClient connections (§168) ────────────────────────────────
  //
  // Источник tcp/udp open/close + per-app атрибуции — push-стрим
  // `CcChannel.connections` через profilerClient. profilerClient §164-
  // энергомодель НЕ паузит в фоне → recording живёт при свёрнутом app.

  /// Подписка на CC connections + подъём profilerClient. Идемпотентна
  /// (вызывается из startGlobalRecording).
  void _attachCcConnections() {
    if (_ccConnSub != null) return;
    // Поднимаем независимый profilerClient (фоновый, §164). Шлёт первый
    // снапшот сразу + далее push'ом — _ingestCcConnections их обработает.
    // §259 — через refcount (второй держатель — dns-direct-детектор).
    unawaited(_cc.acquireProfiler());
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

  /// Снимает подписку + гасит profilerClient — только если global recording
  /// off.
  void _maybeDetachCcConnections() {
    if (_globalRecordingActive) return;
    _detachCcConnections();
  }

  void _detachCcConnections() {
    _ccConnSub?.cancel();
    _ccConnSub = null;
    _ccDnsSub?.cancel(); // §180
    _ccDnsSub = null;
    unawaited(_cc.releaseProfiler()); // §259 — refcount
  }

  /// §168 — обработка снапшота CommandClient connections: эмит tcp/udp
  /// open для новых conn'ов, close для исчезнувших (closed-detection через
  /// `_connSnapshots` diff, как раньше делал Clash-poll). Атрибуция
  /// через `CcConnection.packageName/processPath`.
  void _ingestCcConnections(List<CcConnection> conns) {
    // Обрабатываем только при global recording.
    if (!_globalRecordingActive) return;
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
      // §181/§252 — chains и detours несём РАЗДЕЛЬНО (не склеиваем как §178):
      // UI строит строку `proc ⇒ [net] rule ⇒ группы : физический путь →
      // domain` сам, разделяя оси (⇒ решение / → путь пакета).
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
        // Новая connection — emit tcpOpen / udpOpen в global buffer.
        final kind = network == 'udp'
            ? TrafficEventKind.udpOpen
            : TrafficEventKind.tcpOpen;
        // confidence verified если process известен ядром, иначе unattributed.
        final hasProcess = rawProcess.isNotEmpty;
        final globalEv = TrafficEvent(
          ts: now,
          kind: kind,
          domain: host.isNotEmpty ? host : null,
          ip: destIp.isNotEmpty ? destIp : null,
          port: destPort > 0 ? destPort : null,
          outboundChain: routeChain,
          detourChain: detourChain,
          outboundType: c.outboundType.isNotEmpty ? c.outboundType : null, // §204
          upBytes: up,
          downBytes: down,
          process: hasProcess ? rawProcess : null,
          network: network,
          rule: rule.isNotEmpty ? rule : null,
          rulePayload: rulePayload.isNotEmpty ? rulePayload : null,
          confidence: hasProcess
              ? ConfidenceLevel.verified
              : ConfidenceLevel.unattributed,
          matchedVia: hasProcess ? 'connections_meta' : null,
        );
        _appendToGlobalRollingBuffer(globalEv);
        _emitGlobalStream(
            {'event': 'traffic_event', 'data': globalEv.toJson()});

        // Snapshot для closed-detection (emit'им tcpClose когда ядро убрало
        // connection из снапшота).
        _connSnapshots[id] = _ConnSnapshot(
          id: id,
          host: host,
          ip: destIp,
          port: destPort,
          network: network,
          chains: routeChain,
          detours: detourChain, // §181
          outboundType: c.outboundType.isNotEmpty ? c.outboundType : null, // §204
          upBytes: up,
          downBytes: down,
          startedAt: now,
          process: globalEv.process ?? '',
          confidence: globalEv.confidence,
          matchedVia: globalEv.matchedVia,
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
        detourChain: snap.detours, // §181
        outboundType: snap.outboundType, // §204
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
      // §084 H5 — Global stream/buffer, симметрично tcpOpen (который пишется
      // выше). Lifecycle open/close полный в global buffer'е.
      _appendToGlobalRollingBuffer(closeEv);
      _emitGlobalStream({'event': 'traffic_event', 'data': closeEv.toJson()});
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

  // §044 — _inferProcessByIp (Strategy 4 inferred-эвристика) ВЫПИЛЕН вместе с
  // _processInferenceWindow. Атрибуция TCP/DNS теперь из ядра (§168/§180).

  // ─── Connection-issue classifiers ─────────────────────────────────────
  //
  //   - dnsTimeout: структурный DNS-fail из ядра (SPEC 018, `q.failed`),
  //     не heuristic, а реальный engine-уровневый сигнал. Эмитится в
  //     [_ingestDnsQuery] (§180 — заменил текстовый _handleDnsFailLine).
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

  // ─── Test-only helpers ────────────────────────────────────────────────

  @visibleForTesting
  void resetForTesting() {
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
    for (final c in _globalStreamSinks) {
      if (!c.isClosed) c.close();
    }
    _globalStreamSinks.clear();
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
