# 044 — Per-app traffic profiler

> **Канонический термин**: «**Per-app traffic profiler**». Используем его как имя фичи в документации, CHANGELOG'е, спецификах и пользовательских доках. UI tab в `StatsScreen` короткий — «Per-app» (constraint tab-bar'а), но в прозе всегда полное имя.

| Поле | Значение |
|------|----------|
| Статус | **Implemented** (v1.7.0) — backend + UI + Debug API in production |
| Дата | 2026-05-08 |
| Связанные spec'ы | [`043 applog per-source quotas`](../043%20applog%20per-source%20quotas/spec.md) — переиспользует core-log stream; [`030 custom routing rules`](../030%20custom%20routing%20rules/spec.md) — feedback loop "trace → make rule"; [`031 debug api`](../031%20debug%20api/spec.md) — экспонирует API для внешних клиентов; [`040 per-group ping settings`](../../tasks/040-per-group-ping-test-settings.md) — паттерн in-memory state via ChangeNotifier |
| Затронутые файлы | `app/lib/services/traffic_profiler.dart` (новый), `app/lib/screens/per_app_trace_tab.dart` (новый), `app/lib/screens/stats_screen.dart`, `app/lib/screens/home_screen.dart`, `app/lib/services/debug/handlers/profiler.dart` (новый), `app/lib/services/debug/transport/response.dart` (`SseResponse`), `app/lib/services/app_info_cache.dart` (`loadAllApps()` + smart `ensure`), тесты `app/test/services/traffic_profiler_test.dart` |
| Целевой релиз | v1.7.0 (тема: «Observability») |
| User guide | [`docs/features/per-app-trace.md`](../../../features/per-app-trace.md) |

> **Важно**: всё state in-memory, никакого persist. Никакого `App Settings` integration — все controls (verbose toggle / wipe / export) в overflow menu Per-app tab'а. Recording-indicator (⚡) chip в `_buildTrafficBar` на HomeScreen + Per-app tab title.

## Implementation log

Что реально оказалось важным во время имплементации (нашлось через диагностику на живом устройстве, не было предсказуемо из спеки):

### 1. UID suffix в `metadata.process`/`processPath`
Sing-box `find_process: true` возвращает в Clash API `metadata.processPath` (и иногда `metadata.process`) строки вида `"ru.tinkoff.investing (10364)"` — package name + UID в скобках. AppPicker в UI отдаёт чистый package, поэтому без strip'а ни одна conn'ция не атрибутируется к target session'у. Решено: `_stripUid()` snimает суффикс перед сравнением (тот же паттерн, что в `clash_api_client.dart::_extractPackage` для `byApp` агрегации).

В реальных данных `metadata.process` чаще `null` — actual package в `metadata.processPath`. Профайлер пробует оба поля.

### 2. AppLog ring-buffer overflow vs length-diff scan
Изначальный `_drainNewLogEntries()` сравнивал `entries.length` с предыдущим snapshot'ом. AppLog имеет cap=500 для `core` source: когда буфер заполнен, новые entries вытесняют старые, **length стабилизируется на 500**, length-diff навсегда `= 0`. На длинных recording session'ах DNS-строки переставали обрабатываться через 1-2 минуты после старта.

Фикс: timestamp-based diff. Храним `_lastSeenLogTs` (newest entry's ts на момент прошлого drain'а). На каждый `notifyListeners` идём с index 0 (newest) пока `entries[i].time > lastSeen` — это и есть новые. Монотонно работает независимо от cap'а.

### 3. `dns: cached` (не только `dns: exchanged`)
Sing-box логирует две формы DNS-резолва — `exchanged` (реальный network query до upstream'а) и `cached` (cache-hit, без сетевого запроса). У занятых apps большинство резолвов — cached. Изначальная regex-маска покрывала только `exchanged`, поэтому DNS-уровневая видимость была разорванная — TCP-conn'ы шли, а DNS-events нет. Теперь regex `dns: (?:exchanged|cached)` ловит оба.

### 4. DNS event attribution на оригинальный domain (не на финальный CNAME-target)
Sing-box логирует chain последовательно:
```
[id] dns: exchanged CNAME cdn.t-bank-app.ru. → cl-ead2c819.edgecdn.ru.
[id] dns: exchanged A    cl-ead2c819.edgecdn.ru. → 193.17.93.194
```
Изначально `event.domain = name` (из A-записи) → в Domains tab появлялся `cl-ead2c819.edgecdn.ru` (CDN-хост), а изначально-запрошенный `cdn.t-bank-app.ru` исчезал. Aggregation теряла связь с тем что app реально просил.

Фикс: `_DnsAccumulator` per conn-id хранит **первое** имя (`acc.domain` — то что app запросил), CNAME-targets копятся в `cnameChain`. Event эмитится с `domain: acc.domain`, `cnameChain: [...]`, `ip: ...`. Domains tab теперь показывает `cdn.t-bank-app.ru` с раскрытием в `CNAME → cl-ead2c819.edgecdn.ru`, `IPs: 193.17.93.194` — что и нужно для §045-style диагностики.

### 5. Connections click target — только header
Inline-expand на Connections row делал весь tile (включая раскрытую секцию) кликабельным. Тап на кнопку `[View in Domains]` или попытка скопировать текст CNAME схлопывали row. Решено: `InkWell` обёртывает только header (timestamp + host:port + bytes + chevron), expanded section рендерится отдельно ниже.

### 6. ↗ IP-jump иконки везде
Symmetry-ради: каждый IP во всех 4 tab'ах (Live event summaries, Domains expanded `IPs:`, IPs tab title, Connections expanded `All IPs`/`IP`) рендерится через общий helper `_ipChip(context, ip, onTap)`. Тап → `_navigateToDomain(ip)` → переключает на Domains tab + auto-fill search этим IP'ом → видны все домены, что резолвились на него (cross-domain CDN-аудит).

Это folded роль аналогичной симметричной операции с domain'ом: `[View in Domains]` на conn row, `↗` рядом с IP в IPs tab, search-фильтр в Domains tab, который матчит и domain'у, и IP, и CNAME target — три точки входа в одну view.

### 7. Icon cache унификация (мини-рефакторинг по пути)
Custom-Rules picker имел свой собственный `_iconCache` (Map<String, Uint8List?> в module scope). Per-app picker создавал отдельный — иконки грузились дважды на повторных открытиях. Унифицировано через `AppInfoCache.loadAllApps()` (lightweight installed-apps list, populate'ит per-package cache без иконок) + smart `ensure(pkg)` (если в cache есть AppInfo без icon'а, делаем именно `getAppIcon` — лёгче чем полный `getAppInfo`).

## Цель

Дать юзеру inline-инструмент диагностики «куда ходит конкретное приложение и как роутится» — без ручных curl/jq, packet capture или внешних tools.

Решает класс задач:

1. **«X не открывается через VPN»** (повторяющиеся live-инциденты типа Tinkoff CDN на `.trbcdn.net`, см. `/tmp/lxbox-debug-2026-05-08-tinkoff/`). Сейчас диагностика занимает 30+ минут ручной работы со снапшотами `/state` / `/connections` / `/logs` + кросс-референс по conn-id. С §044 — 30 секунд: pick app, see routing, fix.
2. **Privacy audit**: «куда стучит этот фитнес-трекер?» — список доменов наглядно, сразу можно блокировать.
3. **VPN debug**: понять почему один сервис тормозит — увидеть через какой outbound и какую ноду VLESS он реально идёт.
4. **Catalog для preset'ов**: собранная session по «Сбер» / «ВТБ» / «Госуслуги» — основа для расширения `ru-direct` / новых RU-banks preset'ов.
5. **Dogfooding**: разработка L×Box ускоряется — этот tool заменяет наш текущий manual flow.

## Differentiator

Никто на mobile рынке не показывает **routing chain per-app** одновременно с domain/IP-уровнем:

| Tool | Per-app | Routing chain (outbound) | DNS resolves | CNAME tracking |
|---|---|---|---|---|
| PCAPDroid | ✓ | ✗ | ✗ (hex only) | ✗ |
| NetGuard | ✓ (block/allow) | ✗ | ✗ | ✗ |
| AdGuard Pro | iOS only | ✗ | ✓ DNS-side only | ✗ |
| Wireshark / desktop | ✗ (нужен PC) | ✗ | ✓ | ✓ |
| **L×Box §044** | ✓ | ✓ | ✓ | ✓ |

Sing-box-router внутри даёт нам уникальный data-source — outbound chain виден изнутри.

## UX flow

### Где живёт

Третий tab в **`StatsScreen`** (рядом с Overview / Connections). Имя: **«Per-app»** или **«App trace»**.

### Главный экран — idle (не выбран app)

```
┌─ Per-app trace ─────────────────────────────┐
│                                              │
│  Pick an app to start tracing its            │
│  network activity.                           │
│                                              │
│  [ Select app ▼ ]                            │
│                                              │
│  Saved sessions:                             │
│    • ru.tinkoff.investing — 02:34, 47 doms  │
│    • org.telegram.messenger — 00:48, 12 doms│
│    [Open] [Delete]                           │
└──────────────────────────────────────────────┘
```

«Saved sessions» — последние N (default 5) finished session'ов в memory ring-buffer. **In-memory only** — на kill app'а / force-stop стираются. Никакого persist'а через restart.

### Recording

```
┌─ Per-app trace ─────────────────────────────┐
│  Target: [ru.tinkoff.investing ▼]   [⏹ STOP]│
│                                              │
│  ⚠ Verbose logs disabled — capturing basic  │  ← если `log_level != debug`
│     info only. [Enable in Settings →]        │
│                                              │
│  ⏺ Recording · 02:34 · 47 doms · 53 conn    │
│                                              │
│  [Live] [Domains] [IPs] [Connections]        │
│                                              │
│  ─── Live (newest first) ───                 │
│  10:42:15  DNS  cdn.t-bank-app.ru            │
│            → CNAME edgecdn.ru                │
│            → A 193.17.93.194 (16ms)         │
│  10:42:15  TCP  193.17.93.194:443            │
│            via direct-out  ↓2.1KB ↑458B      │
│  10:42:14  DNS  certs.t-bank-app.ru          │
│            → CNAME trbcdn.net                │
│            → A 81.222.127.186 (20ms)        │
│  10:42:14  TCP  81.222.127.186:443     ⚠     │
│            via 🇫🇮Финляндия (vpn-1)           │
│            ⚠ unexpected: domain looks RU     │
│  ...                                          │
└──────────────────────────────────────────────┘
```

⚠ icon — visual cue для connection issues (DNS timeout от sing-box'а, TCP RST early). См. секцию «Connection issues» ниже.

**Кнопки в header**:
- **Target** — AppPicker, тап → выбор app (как в Custom Rules)
- **Recording control button**:
  - Idle: **[▶ START]** — primary green, начинает session
  - Recording: **[⏹ STOP]** — primary red, останавливает
  
  Phrasing явный (не «pause/play»), чтобы юзер не путался.

### Verbose toggle (в overflow menu Per-app tab'а)

Никаких изменений в App Settings. Все controls локально в overflow menu (⋮) Per-app tab'а:

```
┌─ Per-app trace ──────────────────────⋮──┐
                                       │
              На тап ⋮ открывается:    │
                                       ▼
          ┌────────────────────────────────┐
          │ ☐ Verbose core logs (debug)    │
          │      Higher CPU/battery        │
          ├────────────────────────────────┤
          │ 📋 Export active session       │
          │ 📤 Share active session        │
          ├────────────────────────────────┤
          │ 🗑 Clear all sessions          │
          ├────────────────────────────────┤
          │ ❓ Help                         │
          └────────────────────────────────┘
```

**In-tab banner** когда verbose ON (только в Per-app tab'е, не глобально):

```
┌─ Per-app trace ──────────────────────⋮──┐
│ ⚡ Verbose core logs active — battery/    │
│   CPU impact                       [✕]  │
│                                          │
│  Target: [...] [⏹ STOP]                 │
```

Toggle ON action:
1. Save current `log_level` value (для revert на toggle OFF)
2. `PUT /settings/vars/log_level` → `"debug"` (через internal Debug API call)
3. `POST /action/reload` (light reload, без TUN teardown)
4. In-tab banner shows
5. `TrafficProfiler` начинает capture'ить debug-уровень events

Toggle OFF: revert log_level → saved previous value → reload → banner hides.

### Indicator на HomeScreen — chip в `_buildTrafficBar`

Существующий `_buildTrafficBar(state)` widget в `home_screen.dart` показывает `↑ ↓ 🔗 conns + uptime`. Когда session active — добавляется четвёртый chip с ⚡ + short package name. Tap всей строки уже navigates в StatsScreen — теперь с `initialTab: perApp` если recording active.

```
Idle (no recording):
  ↑ 0.2 KB/s    ↓ 1.4 KB/s    🔗 23                    1h 12m

Recording:
  ↑ 0.2 KB/s    ↓ 1.4 KB/s    🔗 23    ⚡ ru.tinkoff   1h 12m
                                         ↑
                              new chip — short package name
                              tap всей bar → StatsScreen.perApp
```

`_shortPkg("ru.tinkoff.investing")` = `"ru.tinkoff"` (первые два компонента).

### Indicator на Per-app tab title

```
TabBar [ Overview · Connections · Per-app ]            ← idle
TabBar [ Overview · Connections · Per-app ⚡ ]          ← recording
```

Один универсальный `⚡` для любого active session (verbose / non-verbose не различаем).

### Sub-tabs

| Tab | Содержимое |
|---|---|
| **Live** | streaming list событий newest-first. Каждый event: timestamp, type (DNS / TCP / UDP), summary (domain → IP, или host:port via outbound), bytes, ⚠ icons (connection issues). Auto-scroll опционально. |
| **Domains** | Aggregated unique domains. Cols: domain, count, total bytes ↑↓, last seen, outbound chain, status (resolved / failed / cached). Sortable. Tap row → drill-down: full DNS chain (с CNAME), connection list для этого domain. |
| **IPs** | Aggregated unique destination IPs. Cols: IP, port(s), count, bytes, AS info (если local geoip-cache есть), outbound, first/last seen. |
| **Connections** | Timeline of all connections (live + closed). Cols: timestamp, domain (sniffed/resolved), IP:port, protocol, outbound chain, bytes, status, duration. Tap → JSON dump полного meta. |

### Bonus actions (post-MVP, optional)

После Stop'а на Domains/IPs/Connections tabs:
- **[Add to ru-direct]** — выбранные domain → suffix-list существующего `ru-direct` preset'а через Custom Rules editor
- **[Block selected]** — выбранные domain → новое inline rule с `domain_suffix` + `package_name` + `action: reject`
- **[Make new preset]** — bundle of selected → новый user preset (или suggest template change)
- **[Copy as JSON]** — share session payload (для report'а / community)

В MVP — только **[Copy as JSON]** + **[Share]**, остальные — на v1.7.x cycles.

### Connection issues (⚠ маркеры)

Не статистические аномалии — конкретные diagnostic-сигналы. Помечаются ⚠ в Live, Domains expanded, Connections expanded. В JSON: `events[i].issues: [{kind, description}]` + `by_domain[i].issues`.

Реализованные 2 типа (locale-агностичные):

| Issue | Условие |
|---|---|
| `dnsTimeout` | sing-box лог `dns: exchange failed for <host>: <reason>` — прямой engine-сигнал |
| `tcpReset` | TCP conn closed в течение 1с, ↑0 ↓0 байт — heuristic «firewall RST / unreachable» |

Отвергнуто (см. Implementation log #8 / Habr):
- ~~`geoMismatch`~~ — RU-bias через парсинг эмодзи в outbound name; правильная реализация требует user-config home-locale + geoip-lookup, отложено на post-MVP.
- ~~`unusualPort`~~ — arbitrary port whitelist, шум для apps с custom-протоколами (BitTorrent / Steam / corp services); порт сам по себе не диагностирует роутинг.
- ~~`badLatency`~~ — был в enum, никогда не emit'ился; dead code.

Public API:
```dart
enum ConnectionIssueKind { dnsTimeout, tcpReset }

class ConnectionIssue {
  const ConnectionIssue(this.kind, this.description);
  final ConnectionIssueKind kind;
  final String description;
}

class TrafficEvent {
  // ...
  final List<ConnectionIssue> issues;
}
```

Issue logic — в `TrafficProfiler._classifyConnectionClose()` (для tcpReset) и `_handleDnsFailLine()` (для dnsTimeout). На `tcpOpen` событиях issues не вычисляем (оба текущих типа релевантны другим event'ам).

## Архитектура

### Сервис `TrafficProfiler` (новый)

`app/lib/services/traffic_profiler.dart` — singleton ChangeNotifier.

```dart
class TrafficProfiler extends ChangeNotifier {
  static final TrafficProfiler I = TrafficProfiler._();

  // ─── State ─────────────────────────────────────
  Session? _active;                // текущая recording, null = idle
  final List<Session> _completed;  // ring-buffer last 5

  // ─── Public API ────────────────────────────────
  Session? get active;
  List<Session> get completed;

  /// Начать session для targetPackage. Если уже active —
  /// finalize старую (move to _completed) и стартует новую.
  Future<Session> start(String targetPackage);

  /// Stop active. Returns finalized session (also added к completed).
  Future<Session?> stop();

  /// Удалить session из completed по id.
  void delete(String sessionId);

  /// Очистить все completed sessions.
  void clearAll();

  // ─── Internal: log/connections subscription ────
  // На start подписываемся на ClashLogPump.stream + Clash API
  // /connections polling 1s. Filter events по targetPackage
  // через conn-id ↔ package map (заполняется на 'router: found
  // package name: <X>' events).
  // Аккумулируем в Session.events / aggregates.
}
```

### Data model

```dart
/// Одна recording session.
class Session {
  final String id;                    // uuid
  final String targetPackage;         // ru.tinkoff.investing
  final DateTime startedAt;
  DateTime? finishedAt;               // null если active
  final bool wasVerbose;              // log_level=debug на момент старта
  final List<TrafficEvent> events;    // ring-buffer 10000

  // Aggregated views (computed on-demand, cached):
  Map<String, DomainStats> get byDomain;
  Map<String, IpStats> get byIp;
  List<ConnectionRecord> get connections;
}

class TrafficEvent {
  final DateTime ts;
  final TrafficEventKind kind;        // dns / tcp / udp / quic / dns-fail / closed
  final String? domain;               // sniffed/resolved
  final List<String> cnameChain;      // [t-bank-app.ru, edgecdn.ru, ...]
  final String? ip;
  final int? port;
  final List<String> outboundChain;   // [vpn-1, 🇫🇮Финляндия, vless-server]
  final int? upBytes;
  final int? downBytes;
  final Duration? duration;
  final String? rawLogLine;           // для debug
  final List<ConnectionIssue> issues;
}

enum TrafficEventKind { dnsResolve, dnsFail, tcpOpen, tcpClose, udpOpen, quicOpen }

class DomainStats {
  final String domain;
  int connections;
  int upBytes, downBytes;
  DateTime firstSeen, lastSeen;
  Set<String> ips;                    // resolved to
  Set<String> outbounds;              // через какие
  List<ConnectionIssue> issues;
}

class ConnectionIssue {
  final ConnectionIssueKind kind;
  final String description;
}
enum ConnectionIssueKind { dnsTimeout, tcpReset }
```

### Storage

**In-memory only** — никакого persist'а. Никаких новых полей в `lxbox_settings.json`. На app kill / force-stop / device reboot — все sessions стираются.

`TrafficProfiler` сам holds:
- `Session? _active` — текущая recording (или null)
- `ListQueue<Session> _completed` — ring-buffer max 5 завершённых sessions
- ChangeNotifier signals UI на изменения

Никакого `SettingsStorage` integration. STORAGE.md не апдейтится этой фичей.

### Verbose toggle integration

`SettingsStorage.setVar('log_level', 'debug')` → reload sing-box. In-tab banner подписан на `vars.log_level` через `SettingsStorage` listener — показывает себя пока == debug. Banner живёт только в Per-app tab content tree, НЕ глобально.

### UI компоненты

Новые widget'ы:
- `PerAppTraceTab` — главный tab (`stats_screen.dart`)
- `_TraceLiveView` — streaming list events
- `_TraceDomainsView` / `_TraceIpsView` / `_TraceConnectionsView` — aggregated tables
- `_IssueChip` — ⚠ visual marker
- `_VerboseLogsBanner` — banner внутри Per-app tab content (НЕ глобальный)
- `_PerAppOverflowMenu` — overflow menu (⋮) с verbose toggle / export / wipe / help

Изменения в существующих widget'ах:
- `_buildTrafficBar` (`home_screen.dart`) — добавить ⚡ chip + plumbing `StatsScreen(initialTab: perApp)`
- `StatsScreen` — `initialTab` constructor parameter (`StatsTab.overview` / `connections` / `perApp`)

`AppPicker` — переиспользован из Custom Rules.

## Debug API (через §031)

Все endpoints доступны через `localhost:9270` с Bearer-token authentication.

### Start session

```
POST /profiler/start
Content-Type: application/json
{
  "package": "ru.tinkoff.investing",
  "verbose": false               // опционально, default false; true → set log_level=debug
}

Response 200:
{
  "session_id": "<uuid>",
  "target_package": "ru.tinkoff.investing",
  "started_at": "2026-05-08T10:42:00Z",
  "verbose": false
}

Response 409: { "error": "already_active", "active_session_id": "<uuid>" }
Response 400: { "error": "invalid_package" }
```

Если verbose=true:
- saves current `log_level` (для revert на stop)
- `setVar('log_level', 'debug')` + reload sing-box
- profiler.session.wasVerbose = true

### Stop session

```
POST /profiler/stop

Response 200:
{
  "session_id": "<uuid>",
  "target_package": "ru.tinkoff.investing",
  "started_at": "2026-05-08T10:42:00Z",
  "finished_at": "2026-05-08T10:44:34Z",
  "events_count": 287,
  "domains_count": 47,
  "ips_count": 53,
  "connections_count": 122
}

Response 404: { "error": "no_active_session" }
```

Если session.wasVerbose: revert log_level → previous value + reload.

### Get active session

```
GET /profiler/active

Response 200:
{
  "session_id": "<uuid>",
  "target_package": "ru.tinkoff.investing",
  "started_at": "...",
  "duration_ms": 154321,
  "verbose": false,
  "events_count": 287,
  "domains_count": 47,
  "ips_count": 53
}

Response 404: { "error": "no_active_session" }
```

### Get session details

```
GET /profiler/session/<id>?include=events,domains,ips,connections,raw

Response 200:
{
  "session_id": "...",
  "target_package": "...",
  "started_at": "...", "finished_at": "...",
  "events": [ ... ],            // если ?include=events
  "by_domain": [                 // если ?include=domains
    {
      "domain": "cdn.t-bank-app.ru",
      "cname_chain": ["edgecdn.ru"],
      "ips": ["193.17.93.194"],
      "connections": 3,
      "up_bytes": 2058,
      "down_bytes": 8492,
      "first_seen": "...", "last_seen": "...",
      "outbounds": ["direct-out"],
      "issues": []
    },
    ...
  ],
  "by_ip": [ ... ],              // если ?include=ips
  "connections": [ ... ],         // если ?include=connections
  "raw_log_lines": [ ... ]       // если ?include=raw (только если wasVerbose)
}
```

### List completed sessions

```
GET /profiler/sessions

Response 200:
{
  "sessions": [
    { "session_id": "...", "target_package": "...", "started_at": "...", "finished_at": "...", "events_count": 287, "domains_count": 47 },
    ...
  ]
}
```

### Delete session

```
DELETE /profiler/session/<id>

Response 200: { "ok": true }
Response 404: { "error": "not_found" }
```

### Clear all sessions

```
DELETE /profiler/sessions

Response 200: { "ok": true, "deleted": 5 }
```

### Stream events (SSE для UI)

Fire-and-forget — без `Last-Event-ID` reconnect-mechanism (overkill для in-app UI single-user use case). На disconnect клиент просто переподключается и подхватывает с нового момента.

```
GET /profiler/stream  (Server-Sent Events)
Accept: text/event-stream

→ event: session_started
  data: {...}

→ event: traffic_event
  data: { kind, domain, ip, ... }
  
→ event: session_finished
  data: {...}
```

## Edge cases

| Сценарий | Поведение |
|---|---|
| `find_process: false` в config'е | Profiler не сможет фильтровать по package. Show error в Per-app tab: «Process detection disabled in template — recording unavailable». Юзеру нужно поправить template / vars (off-feature flow). |
| Process detection misses (как с Tinkoff webview) | Bonus inference: если в session уже видели domain X, и пришёл TCP к одному из его resolved IP без package_name → атрибутировать к session («inferred from prior DNS»). Помечается visual cue: 〽 inferred. |
| Verbose toggle включён, sing-box reload — connections рвутся | UI warning при toggle: «Sing-box reload — active connections will reset». Юзеру решать. |
| Session-events overflow (3h sliding window + 50k count fallback) | Drop oldest first. Counter `events_dropped` в Session metadata, виден в UI footer. |
| Memory pressure (несколько больших sessions) | 5-completed ring + 1 active = max 6 sessions concurrent. Old completed evict'ятся автоматически на add нового. |
| Юзер unpick'ает app в picker'е во время recording | Stop session (как ⏹ STOP), keep в `_completed`. |
| Re-pick того же package во время recording (no stop) | Existing session продолжает (ничего не делаем). |
| App force-stop / kill на устройстве | All in-memory sessions стираются. Это OK: persist не предусмотрен, юзер должен экспортировать заранее. |
| Sing-box reload mid-session | Auto-finalize partial DNS chains как `interrupted: true`. Session continues с новым conn-id space. In-tab notification «Sing-box reloaded — recording continues». |

## Acceptance criteria

- [ ] Spec written и approved (этот файл).
- [ ] `TrafficProfiler` service: start / stop / get / completed list / clear работают, тесты `traffic_profiler_test.dart` покрывают session lifecycle, log-stream parsing, connection-issue detection. **In-memory only, никакого persist.**
- [ ] Stats tab "Per-app" с AppPicker + ⏹/▶ button + 4 sub-tabs (Live / Domains / IPs / Connections) + overflow menu (verbose toggle / export / wipe / help).
- [ ] In-tab banner показывает что verbose ON, с кнопкой [✕] для disable.
- [ ] HomeScreen `_buildTrafficBar` показывает ⚡ chip + short package name когда session active. Tap всей строки → `StatsScreen(initialTab: perApp)`.
- [ ] StatsScreen TabBar показывает ⚡ возле "Per-app" tab title когда session active.
- [ ] Debug API endpoints (start / stop / active / session / sessions / delete / clear / stream) implemented через §031 framework, тесты в `debug/handlers/profiler_test.dart`. **Никаких schema_version / Last-Event-ID — fire-and-forget.**
- [ ] Connection-issue detection покрывает 2 типа (dnsTimeout, tcpReset). Тесты в `traffic_profiler_test.dart`.
- [ ] Process-inference fallback (если `find_process` мисс'нул конкретный TCP — атрибутировать через prior DNS, 10s window).
- [ ] `flutter analyze` чистый, `flutter test` зелёный.
- [ ] Smoke-тест: записать session «Tinkoff» — увидеть `*.trbcdn.net` через vpn-1 ⚠.
- [ ] Documentation: `docs/api/debug-api-reference.md` обновлён с `/profiler/*` endpoints.

## План имплементации

1. Эта спека (✓)
2. **Phase 1 — Backend** (~3 дня):
   - `TrafficProfiler` service + tests
   - Log-stream subscription + conn-id ↔ package map
   - Aggregation logic (3h sliding window + 50k count cap)
   - DNS chain reconstruction (CNAME tracking) с regex parser'ом
3. **Phase 2 — UI** (~2 дня):
   - `PerAppTraceTab` + 4 sub-tabs (Live / Domains / IPs / Connections)
   - AppPicker integration
   - ⏹/▶ button
   - Overflow menu (⋮) с verbose toggle / export / wipe / help
   - In-tab banner для verbose-active state
   - HomeScreen `_buildTrafficBar` ⚡ chip + `StatsScreen.initialTab` plumbing
   - Per-app tab title ⚡ indicator
4. **Phase 3 — Debug API** (~1 день):
   - HTTP handlers (start / stop / active / session / sessions / delete / clear / stream)
   - SSE stream (fire-and-forget, без Last-Event-ID)
   - Documentation (`docs/api/debug-api-reference.md`)
5. **Phase 4 — Connection-issue detection + bonus** (~1 день):
   - Connection-issue classifier (2 типа: dnsTimeout, tcpReset)
   - Process-inference fallback (10s post-DNS window)
   - Export to JSON / Share через `share_plus`
6. **Phase 5 — Polish** (~0.5 день):
   - Banner UX, loading states, edge case handling
   - Smoke-тест на реальном Tinkoff incident'е
7. **Release**: v1.7.0 (тема: «Observability»). CHANGELOG / RELEASE_NOTES / docs/releases/v1.7.0.md.

## Final decisions

Полный список design decisions, согласованных перед имплементацией:

| # | Вопрос | Decision |
|---|---|---|
| 1 | Multi-session | Single only — max 1 active session за раз |
| 2 | Multi-app pick | Single only — один package за раз |
| 3 | Live drill-down | Inline expandable panel (DNS chain + outbound chain + TLS + bytes timeline + issues + actions) |
| 4 | Recording duration | 3h sliding window — events старше auto-pruned, aggregates переcчитываются |
| 5 | Polling vs log-stream | Log-stream primary; `/connections` poll 2s **только когда** active session |
| 6 | Issue classification | Lazy + cached на event-уровне |
| 7 | Memory cap | 3h time + 50k events count fallback (drop oldest first) |
| 8 | Privacy: state/storage | Profiler sessions **исключены** из `/state/storage` allow-list |
| 9 | Wipe button | Yes, в overflow menu Per-app tab'а («Clear all sessions») |
| 10 | Schema version в JSON | **Не нужен** — in-memory only, no import path |
| 11 | SSE `Last-Event-ID` reconnect | **Не нужен** — fire-and-forget, in-app UI single-user |
| 12 | REST `/active` + SSE `/stream` | Both — разные use cases (snapshot vs live push) |
| 13 | Package vs UID keying | Package-keyed; UID — implementation detail, app reinstall не теряет history |
| 14 | Process inference window | 10s post-DNS resolve, IP must be в resolved-set, marker 〽 inferred |
| 15 | Sing-box reload mid-session | Auto-finalize partial chains как `interrupted: true`, session continues с новым conn-id space |
| 16 | Verbose toggle mid-session | Allowed, but warning dialog: «Reload reset connections — recommend stop first» |
| 17 | HTTP-level extensibility | `extra: Map<String,dynamic>?` поле в `TrafficEvent` для будущих kinds |
| 18 | Persist sessions across restarts | **Не нужен** — in-memory only, app kill = stop |
| 19 | Verbose toggle location | **Overflow menu** Per-app tab'а (НЕ App Settings → Diagnostics) |
| 20 | Verbose-active banner scope | **In-tab only** (Per-app tab content), не глобальный |
| 21 | Recording indicator в Stats TabBar | ⚡ возле «Per-app» tab title когда session active |
| 22 | Recording indicator на HomeScreen | ⚡ chip в `_buildTrafficBar` + short package name; tap всей строки → `StatsScreen(initialTab: perApp)` |

---

## Сравнение с альтернативами на mobile

| Tool | Per-app traffic | Routing chain | DNS chain | Block in 1 click | Open-source |
|---|---|---|---|---|---|
| **PCAPDroid** | ✓ (hex) | ✗ | ✗ | ✗ | ✓ |
| **NetGuard** | ✓ (block/allow log) | ✗ | ✗ | ✓ block-only | ✓ |
| **AdGuard Pro** | iOS-only | ✗ | DNS-side | ✓ DNS-side | ✗ |
| **Glasswire** | ✓ (per-app graph) | ✗ | ✗ | ✗ | ✗ |
| **L×Box §044** | ✓ structured | ✓ outbound | ✓ CNAME | ✓ direct/block/preset | ✓ |

Differentiator: **routing chain** + структурированный **CNAME tracking** — никто на mobile этого не делает, потому что у них нет своего routing engine. У L×Box есть (sing-box) — пользуемся.

## Marketing pitch (на v1.7.0 release notes)

> **L×Box now lets you trace any app's network activity in real-time**: pick an app, hit ⏺ Record, and see every domain, IP, and routing decision — including which CDN your bank uses, where it gets routed, and whether it's leaking through the wrong VPN node.
>
> Works without root. Built-in connection-issue detection flags DNS timeouts and likely-blocked TCP connections. One-tap export to JSON. Available in Stats → Per-app tab.

## Future extensions (post-v1.7.0)

- **Community sessions library**: published JSON dumps как preset-source. «Tinkoff routing snapshot» / «Sber CDN domains» — community contributes, мы import'им как preset suggestions.
- **Differential mode**: capture session N1 (vpn-1) и session N2 (direct), сравнить — какие домены работают только через one of outbound'ов.
- **HTTP-level inspection**: если sing-box добавит API для HTTP request capture (URL/method/headers), интегрируем. Сейчас на L4 — hostname + port.
- **TLS fingerprinting**: показывать JA3/JA4 fingerprint (sing-box capability в `outbound/uTLS`). Полезно для debug DPI обхода.
