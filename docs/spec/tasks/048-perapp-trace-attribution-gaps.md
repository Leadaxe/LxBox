# 048 — Per-app trace: attribution gaps and missing log events

| Поле | Значение |
|------|----------|
| Статус | **Done** (2026-05-09) — `Inclusive observer with confidence` концепт реализован, Live system-wide tab развёрнут, defensive parsing + time-based GC + secondary packages работают, regression tests зелёные (535 tests pass) |
| Дата | 2026-05-09 |
| Связанные spec'ы | [`044 per-app traffic profiler`](../features/044%20per-app%20traffic%20profiler/spec.md) — фича которая дисплеит эти data; [`047 tun TCP deterioration`](./047-tun-tcp-deterioration-diagnosis.md) — sibling task с другой проблемой (race condition) |
| Затронутые файлы | `app/lib/services/traffic_profiler.dart`, `app/lib/services/debug/handlers/profiler.dart`, `app/lib/screens/per_app_trace_tab.dart`, `app/lib/screens/stats_screen.dart`, `app/lib/screens/live_events_tab.dart` (new), `app/test/services/traffic_profiler_test.dart`, `docs/features/per-app-trace.md` |

## Проблема

Per-app trace tab (§044) **теряет события** и **неправильно атрибутирует** часть трафика к target session'у. Юзер видит **пустую** или **неполную** картинку — некоторые TCP-conn'ы / DNS-events / package-events не показываются хотя они **происходят** на устройстве.

Это **отдельная проблема от §047** (race condition в tun). §047 — TCP физически не работает; §048 — TCP работает, но **диагностический tab не показывает** что происходит.

## Известные gaps (live evidence из 2026-05-09 диагностики)

### Gap 1: DNS fail events дропаются полностью

В `traffic_profiler.dart:631-636` (`_handleDnsFailLine`):

```dart
void _handleDnsFailLine(...) {
  final connId = m.group(1)!;
  final meta = _connIdToMeta[connId];
  if (meta == null || meta.process != s.targetPackage) return;   // 🚨
  // ...
}
```

Sing-box логирует failed DNS как `[connId] dns: exchange failed for X. context deadline exceeded` **без** предшествующего `router: found package name`. То есть для conn-id фейлящего DNS — `_connIdToMeta[connId] == null` → event **silently дропается**.

**Live evidence (2026-05-09 08:30:59):**
```
ERROR[16646] [945640198 10.0s] dns: exchange failed for 2ip.io. IN A: context deadline exceeded
```
conn-id `945640198` нигде больше не упомянут — нет `inbound packet connection`, нет `router: found package`. Sing-box просто эмитит error.

**Effect:** При активной session'е target=`com.android.chrome`, юзер открывает 2ip.io, DNS таймаутит — **в Live tab Per-app trace ничего не появляется**. Юзер думает «приложение не делает запросов», хотя на самом деле сделало 16 fail attempts за 1 секунду.

### Gap 2: Process detection misses для коротких/transient TCP

Sing-box определяет owner-package через **callback `findConnectionOwner`** в нашем `PlatformInterfaceWrapper.findConnectionOwner` (через `NetworkStatsManager.queryDetails`). Для **коротких TCP** (< 100ms) и **UDP/QUIC** lookup может **опаздывать** — sing-box завершает routing decision **до** того как мы вернули `ConnectionOwner`. Тогда conn-id попадает в state без `router: found package` line.

Это **upstream sing-box behavior**, но мы можем mitigation'ить.

**Live evidence:** В core_logs мы видим:
- ~85% Chrome TCP-conn'ов имеют `router: found package name: com.android.chrome` ✓
- ~15% Chrome TCP-conn'ов — НЕ имеют такой записи
- DNS-fail events почти **никогда** не имеют package detection

### Gap 3: `〽 inferred` fallback документирован но не работает на 100%

В §044 spec упомянут «process inference fallback» — если sing-box `find_process` мисс'нул, profiler атрибутирует по prior DNS resolved IP в окне 10s post-DNS.

**Проблема:** этот fallback работает только если DNS **успешен**. Когда DNS fail (Gap 1) — `byDomain` не содержит resolved IP → fallback fails → event lost.

Двойной gap: **fail DNS → fail attribution → lost event**.

### Gap 4: WebView / system-process subprocess

Tinkoff / банковские apps часто используют **System WebView** для рендеринга веб-частей. WebView запускается в **isolated process** с UID **отличным от target app's UID**. Package_name = `com.google.android.webview` или подобный.

Profiler matches по `s.targetPackage == 'ru.tinkoff.investing'`, а conn'ы от WebView имеют `process: 'com.google.android.webview'` — не match. Trafic от **встроенного браузера app'а** не виден в session.

**Live evidence (2026-05-08 Tinkoff incident):** Tinkoff CDN (`*.trbcdn.net`) трафик не показывался в session ни разу, хотя app активно использует CDN.

### Gap 5: UID suffix variations

В §044 implementation log #1 уже описано — sing-box возвращает `process: "com.x.app (10364)"` (UID в скобках). Решено через `_stripUid()`. **Но** в некоторых cases (Spotify, Google services) формат другой — нужно проверить все variations.

### Gap 6: Regex не покрывает HTTPS / SVCB record DNS queries

Chrome для **HTTP/3 alt-svc discovery** делает DNS query типа `IN HTTPS`. Live evidence:

```
ERROR[16646] [472318233 10.0s] dns: exchange failed for 2ip.io. IN HTTPS: context deadline exceeded
ERROR[16683] [4178752855 19.74s] dns: exchange failed for static.2ip.io. IN HTTPS: context deadline exceeded
```

`_dnsRe` в `traffic_profiler.dart:524` написана под `A|AAAA|CNAME` record types. **`HTTPS` records regex не матчит** → events дропаются полностью.

### Gap 7: Regex не покрывает SOA records (NXDOMAIN)

Когда DNS возвращает NXDOMAIN, sing-box логирует SOA родительской зоны:

```
INFO[1107] [2591687784 1ms] dns: cached SOA ya.ru. 653 IN SOA ns1.yandex.ru. ...
INFO[1077] [2402429491 0ms] dns: exchanged SOA google.com. 60 IN SOA ns1.google.com. ...
```

Если `_dnsRe` не покрывает SOA — события не парсятся. Не критично (это «not found» сигналы), но потеря diagnostic info.

### Gap 8: Conn-id reuse без явного cleanup

Sing-box может **переиспользовать** conn-id'ы после закрытия предыдущей. Наш `_connIdToMeta` map может содержать **stale entry** от предыдущего conn'а с тем же id → wrong attribution для нового.

`_gcConnIds` (`traffic_profiler.dart:652`) cleanup'ится при `_connIdToMeta.length > 256` через TTL. **Timing-зависимо**: если много conn'ов параллельно (busy traffic) — cleanup отстаёт, race window появляется.

### Gap 9: Polling /connections с интервалом 2s — short-lived TCP пропускаются

`_pollConnections` (`traffic_profiler.dart:673`) делает GET `/connections` каждые **2 секунды**. **Short-lived TCP** (открылся-закрылся за <2s) **не попадают** в `Session.connections` snapshot — connection уже исчез к next poll.

В core_logs мы видим `inbound packet connection` для такого conn'а, но в `Session.byIp` / `Session.connections` ничего нет — поэтому в **Connections tab** пусто, хотя в **Live tab** event прошёл.

### Gap 10: Closed connections rotation в Clash API

Clash API `/connections` показывает только **active** connections. Закрытые исчезают мгновенно. Если Chrome ретранит (open-close-open-close N раз) — мы видим только текущий instant в polling, **history closed** не сохраняется в Clash API.

Compensation: log-stream ловит `outbound/...: connection to X` events, но **не ловит** close events для всех cases. Mixed coverage.

### Gap 11: Multiple package_name на один UID

В живых логах видели:

```
INFO[1019] router: found package name: com.google.android.gms, com.google.android.gsf
```

Один UID = **несколько packages**. Sing-box передаёт через запятую. `meta.process` в нашем cache становится строкой `"com.google.android.gms, com.google.android.gsf"`.

Если target session = `com.google.android.gms`, текущая логика:

```dart
if (meta.process != s.targetPackage) return;
```

`"com.google.android.gms, com.google.android.gsf" != "com.google.android.gms"` — **mismatch** → event drop.

### Gap 12: Pre-session events недоступны

Recording начинается с моментом `▶ START`. Все DNS / TCP events **до старта** недоступны.

Сценарий: юзер открыл Tinkoff app, заметил что приложение не работает (минут через 5), запустил Per-app trace recording. **Все DNS / TCP attempts** за прошедшие 5 минут — **потеряны**. Когда Chrome / app начинает использовать **cached IP** — connection идёт без DNS event в session, юзер не понимает что приложение делает.

### Gap 13: Sandboxed renderer Chrome dying mid-conn

В logcat видели:

```
05-09 11:55:22 ActivityManager: Killing 15986:com.android.chrome:sandboxed_process0 ... isolated not needed
```

Chrome's sandboxed renderer (UID разный от main Chrome) создаёт TCP connection, потом **умирает** до того как `findConnectionOwner` вызывается. UID становится invalid → `getPackagesForUid` возвращает null → событие unattributed. **Не fixable** без deeper Android API access.

---

## Принципы решения (mental models)

Каждый Gap требует не точечного fix'а, а соответствия одному из **общих принципов** для diagnostic UI. Когда решаем — выбираем принцип, имплементация следует.

### Принцип 1: «Show, don't hide» — diagnostic tool никогда не молчит

**Проблема:** сейчас множество event'ов **silently drop'ается** (`return` без побочных действий) когда атрибуция fails. Юзер видит пустой экран и думает «приложение не делает запросов».

**Принцип:** diagnostic tool должен **показывать всё что произошло на сети**, даже если не attributed к target session. Молчание = баг.

**Применение:**
- **Gap 1, 6, 7** (DNS fail / HTTPS / SOA не парсятся) → показывать как **unattributed event** в отдельной секции «System-wide events» в Live tab
- **Gap 9, 10** (polling lag, closed conn rotation) → показывать **count** теряемых events с warning icon
- **Gap 13** (sandboxed dying) → показывать как `〽 attribution lost (process gone)` event

UI pattern: **info banner** + **secondary section** «Events that may be related to this app». Юзер видит цифры, понимает что есть данные за рамками атрибуции.

### Принцип 2: «Defensive parsing» — regex должен принимать unknown variations

**Проблема:** `_dnsRe` хardcoded под `A|AAAA|CNAME`. Любой новый record type (HTTPS, SVCB, SOA, MX, TXT) → silent drop.

**Принцип:** парсеры должны **извлекать максимум** из известного, **не отвергать** unknown. Если базовая структура матчится — событие парсится, специфичные поля могут быть unknown.

**Применение:**
- **Gap 6, 7** → `_dnsRe` принимает любой record type (не whitelist'нуть `A|AAAA|CNAME`, а capture group `(\w+)` + post-processing)
- Парсер **отдельно** распознаёт известные types (для красивой отрисовки), но **не теряет** events с unknown types
- Tests: regression coverage для каждого known type + `unknown_record_type_test`

Code pattern: **fail-open, not fail-closed** — если unsure, пропускаем event с пометкой «unknown record type X», не дропаем.

### Принцип 3: «Multiple matching strategies» — атрибуция по нескольким сигналам

**Проблема:** атрибуция работает строго по `meta.process == targetPackage`. Один сигнал — one match strategy.

**Принцип:** атрибуция должна попытаться **несколько independent strategies** прежде чем сдаться. Каждое event имеет **confidence level**:

```
verified  → router log явно сказал target
inferred  → recent DNS resolved IP / domain pattern match
secondary → WebView/subprocess UID known как paired
unattributed → ни один strategy не сработал, но event возможно от target
```

**Применение:**
- **Gap 4** (WebView) → если target=`ru.tinkoff.investing`, secondary packages = `[com.google.android.webview]` (configurable)
- **Gap 11** (multiple packages 1 UID) → split + contains, не equals
- **Gap 5** (UID suffix variants) → multi-format strip + UID extraction
- **Gap 1, 2** (DNS fail / short TCP без owner) → inference через recent session activity (Gap 3 — текущий fallback ограничен)

UI pattern: **chevron / icon** показывает confidence level каждого event'а. Юзер видит «verified» vs «inferred» vs «system-wide».

### Принцип 4: «Pre-buffer always running» — recording = focus, не activate

**Проблема:** events до `▶ START` recording'а потеряны (Gap 12). Юзер ставит recording **после** того как заметил проблему — теряет контекст.

**Принцип:** TrafficProfiler **всегда** держит rolling buffer недавних events (даже когда нет active session). `▶ START` = **выбираем фокус**, а не запускаем сбор. Backfill из rolling buffer в session при start.

**Применение:**
- **Gap 12** → TrafficProfiler maintains `_globalRollingBuffer` 60 секунд × всех events системы. На `start(targetPackage)` — backfill events для этого package за last 60s в session.events
- Memory cost: ring buffer ~3000 events, ~500KB — приемлемо
- Privacy: rolling buffer **не хранится через app kill** (in-memory only)

### Принцип 5: «Streaming primary, polling supplement» — log stream первичен

**Проблема:** polling `/connections` каждые 2s пропускает short-lived TCP (Gap 9). 

**Принцип:** **log-stream parsing** (через AppLog ChangeNotifier) — primary source events. Polling Clash API — supplement для **stats** (current bytes, duration, active state), не для discovery новых events.

**Применение:**
- **Gap 9, 10** → не зависим от polling discovering new events. Каждый `inbound packet connection` log line **уже** event в session. Polling только enriches (uploadBytes / downloadBytes / state).
- Polling interval можно увеличить до 5s (от 2s) — меньше CPU, не теряем events

### Принцип 6: «Aggressive correlation cleanup» — TTL не bounded by count

**Проблема:** `_gcConnIds` cleanup'ится только при `length > 256`. Race window когда conn-id'ы переиспользуются перед cleanup'ом (Gap 8).

**Принцип:** correlation state имеет **time-bound TTL** (например 30s), не count-bound. GC каждые 5s проходит и убирает stale.

**Применение:**
- **Gap 8** → `_connIdToMeta` entries имеют `firstSeen: DateTime`. GC scheduled `Timer.periodic(5s)` cleanup'ит entries старше 30s.
- TTL короче — меньше race window, но больше attribution misses (event приходит для conn-id'а который уже вычистился). Compromise — 30s.

### Принцип 7: «Live system-wide view» — discovery без выбора app заранее

**Проблема:** Per-app trace требует **сначала** выбрать target app. Юзер не знает заранее какой app виноват, какой делает suspicious traffic, что вообще происходит на устройстве. Без знания target — фича бесполезна.

**Принцип:** добавить **Live system-wide tab** (4-я в Statistics — Overview / Connections / Per-app / **Live**). Показывает **все** events со всех приложений в real-time, без фильтра по target. Использует тот же `_globalRollingBuffer` (Принцип 4) — без дополнительной memory cost.

**Применение:**
- 4-й tab в `StatsScreen` — **в дополнение** к существующим (не replacement)
- Тот же event format что Per-app `Live` sub-tab, но с **колонкой `app`** (package name)
- Filter chips: app multi-select / event type (DNS / TCP / UDP / Failed / Unattributed) / search by domain or IP / time range (Live / Frozen)
- **Privacy**: видны events других apps; OK для diagnostic tool — юзер сам активирует tab. Не персистится через app kill.

**Что закрывает (gap → live tab visibility):**
- Gap 1 (DNS fail без owner) → видны как `〽 unattributed`
- Gap 4 (WebView subprocess) → видим events отдельно, юзер сам решает
- Gap 9 (polling lag) → live feed работает на log-stream, не зависит от polling
- Gap 11 (multi-package UID) → показываем reality (через запятую), без `==` filter
- Gap 12 (pre-session events) → нет «session boundary» вообще
- Gap 13 (sandboxed dying) → видим event с `attribution lost` пометкой

### Сводный концепт: «inclusive observer with confidence»

Все 7 принципов сводятся к одному mental model:

> **TrafficProfiler = inclusive observer**, не exclusive matcher. Каждое событие попадает в UI с **confidence level**. Юзер видит **всё что произошло**, и видит **что точно его app, а что возможно**.

| Confidence | Когда | UI marker |
|---|---|---|
| **`verified`** | `router: found package name: target` явный match | (no marker, default) |
| **`secondary`** | match через `secondaryPackages` (WebView etc) | `🔗 via webview` |
| **`inferred`** | match через recent DNS / domain pattern (10s window) | `〽 inferred from prior DNS` |
| **`unattributed`** | никакая strategy не сработала | `〽 unattributed` |

В per-app session — **показываем все 4 уровня**, не только `verified`. Юзер видит «вот это точно ваш app, а это рядом, без адресата — может быть тоже ваш». Это **честно**.

**API contract** отражает это:

```jsonc
// GET /profiler/session/<id>?include=events
{
  "session_id": "...",
  "target_package": "ru.tinkoff.investing",
  "secondary_packages": ["com.google.android.webview"],   // конфигурируется юзером
  "events": [
    {
      "ts": "...",
      "kind": "dnsResolve",
      "domain": "cdn.t-bank-app.ru",
      "process": "ru.tinkoff.investing",
      "confidence": "verified"
    },
    {
      "ts": "...",
      "kind": "tcpOpen",
      "ip": "193.17.93.194",
      "process": "com.google.android.webview",
      "confidence": "secondary",
      "matched_via": "secondary_packages"
    },
    {
      "ts": "...",
      "kind": "dnsFail",
      "domain": "static.2ip.io",
      "process": null,
      "confidence": "unattributed",
      "shown_because": "system-wide DNS failure during active session"
    }
  ]
}
```

И **новый endpoint** для Live tab:

```jsonc
// GET /profiler/live?seconds=60
// Returns global rolling buffer for system-wide view
{
  "events": [ /* all events с confidence + process */ ]
}

// SSE: GET /profiler/live/stream
// Streaming live feed, аналогично /profiler/stream но без session filter
```

---

## Action items (по принципам, не по Gap'ам)

### A. Implement Принцип 1 (Show, don't hide)

1. Add **`_globalUnattributedEvents`** ring buffer (50 events) в `TrafficProfiler` для DNS fail / HTTPS / SOA events которые не attributable
2. Per-app trace tab: **secondary section** «Recent system-wide events» внизу Live tab — показывает unattributed
3. **Banner** в Per-app tab когда detected gaps (>5 unattributed за 30s)

### B. Implement Принцип 2 (Defensive parsing)

1. Refactor `_dnsRe` чтобы принимать **любой** record type (`(\w+)` capture group вместо whitelist)
2. Refactor `_dnsFailRe` аналогично
3. Tests: regression suite для всех известных DNS types (`A`, `AAAA`, `CNAME`, `HTTPS`, `SVCB`, `SOA`, `MX`, `TXT`)

### C. Implement Принцип 3 (Multiple matching strategies)

1. Replace `meta.process != targetPackage` matching на **`_isMatch(meta, session)`** function:
   ```dart
   bool _isMatch(ConnMeta meta, Session s) {
     final processNames = meta.process.split(',').map((s) => s.trim()).toSet();
     // Strategy 1: direct package match
     if (processNames.contains(s.targetPackage)) return true;
     // Strategy 2: secondary packages (WebView etc)
     if (s.secondaryPackages.any(processNames.contains)) return true;
     // Strategy 3: UID suffix variants
     if (processNames.any((p) => _stripUidVariations(p) == s.targetPackage)) return true;
     return false;
   }
   ```
2. **Add `Session.secondaryPackages: Set<String>`** field
3. UI: при создании session через AppPicker — multi-select для secondary packages
4. **Confidence level** в TrafficEvent — `verified / inferred / secondary / unattributed` enum

### D. Implement Принцип 4 (Pre-buffer always running)

1. **`_globalRollingBuffer: ListQueue<TrafficEvent>`** в TrafficProfiler — always running, ring 60s × все events
2. На `start(targetPackage)` — filter rolling buffer по `_isMatch(event, newSession)` и backfill в session.events с marker `〽 backfilled from pre-recording`
3. Memory cap: ~3000 events / 60s × ~500 bytes/event ≈ 1.5MB

### E. Implement Принцип 5 (Streaming primary)

1. Verify ALL TrafficEvent kinds детектятся через log-stream (не только polling)
2. Document polling responsibility scope (stats only, not discovery)
3. Increase polling interval 2s → 5s (меньше CPU, тот же coverage)

### F. Implement Принцип 6 (Aggressive cleanup)

1. Add `firstSeen: DateTime` в `_ConnMeta`
2. Replace count-based cleanup на time-based: `Timer.periodic(5s, _gcStale)`, drop entries `firstSeen < now - 30s`
3. Ensure DNS accumulator `_dnsByConnId` cleanup'ится тоже

### G. Implement Принцип 7 (Live system-wide tab)

1. **4-й tab `Live` в `StatsScreen`** — после `Per-app`. Не replacement existing tabs, дополнение.
2. **Reuse `_globalRollingBuffer`** из (D) — без дополнительной memory
3. UI: streaming list с **колонкой `app`**, filter chips (app multi-select / event type / domain or IP search / Live vs Frozen toggle)
4. **Pause / resume** button — для frozen view (юзер хочет внимательно прочитать что происходит)
5. **Tap на row** → option «Open in Per-app session» — start session с этим package как target

### H. Implement «inclusive observer with confidence» (cross-cutting)

1. Add **`confidence: ConfidenceLevel`** field в `TrafficEvent`:
   ```dart
   enum ConfidenceLevel { verified, secondary, inferred, unattributed }
   ```
2. Update Per-app session **events list — show all 4 levels**, не только `verified`. UI marker per row (`〽 inferred`, `🔗 via webview`, `〽 unattributed`).
3. **API contract** отражает confidence:
   - `GET /profiler/session/<id>` — events имеют `confidence` field
   - `GET /profiler/live?seconds=60` — **новый endpoint** для Live tab snapshot
   - `GET /profiler/live/stream` — SSE для streaming live feed
4. **`secondary_packages: Set<String>`** в Session model + API. Default `{}`. Configurable через UI / API.
5. Documentation в `docs/features/per-app-trace.md` — section «Confidence levels» + «Live system-wide view».

---

## Acceptance criteria

### Per-app session improvements (Принципы 1-6)

- [ ] Unattributed DNS fail events показываются в Per-app Live sub-tab (Принцип 1) — отдельной section внизу
- [ ] Banner появляется когда detected >5 unattributed events за 30s (Принцип 1)
- [ ] Regex покрывает все известные DNS record types: `A`, `AAAA`, `CNAME`, `HTTPS`, `SVCB`, `SOA`, `MX`, `TXT` + `unknown` fallback (Принцип 2)
- [ ] Multiple matching strategies реализованы: direct match → secondary packages → UID variants → inferred (Принцип 3)
- [ ] `secondary_packages` configurable per session через UI и API (Принцип 3)
- [ ] Pre-session backfill из `_globalRollingBuffer` 60s при `▶ START` (Принцип 4)
- [ ] Polling /connections — только для stats (bytes / duration), не для discovery новых events (Принцип 5)
- [ ] `_connIdToMeta` cleanup time-based 30s TTL + GC каждые 5s (Принцип 6)

### Live tab (Принцип 7)

- [ ] 4-й tab `Live` в `StatsScreen` — system-wide event feed
- [ ] Filter chips: app multi-select / event type / search / Live-Frozen toggle
- [ ] `pause / resume` для статичного просмотра
- [ ] Tap event row → option `Open in Per-app session` — quick discovery flow
- [ ] **`/profiler/live` + `/profiler/live/stream`** Debug API endpoints

### Inclusive observer / confidence (cross-cutting)

- [ ] `TrafficEvent.confidence: ConfidenceLevel` enum
- [ ] UI markers per confidence level (verified default / secondary / inferred / unattributed)
- [ ] API output (session JSON) включает `confidence` + `matched_via` / `shown_because` для не-`verified` cases
- [ ] User guide `docs/features/per-app-trace.md` — section «Confidence levels» + «Live system-wide view»

### Tests

- [ ] DNS-fail без preceding `router: found package` → попадает в session events с `confidence: unattributed` (если timing matches session window)
- [ ] HTTPS / SVCB / SOA record DNS events парсятся (defensive regex)
- [ ] Multi-package UID (`com.x.y, com.x.z`) — match если ANY of them == target
- [ ] WebView subprocess match через `secondaryPackages`
- [ ] Pre-session backfill works — events 30s до `▶ START` появляются в session
- [ ] Live tab streams events для всех apps
- [ ] Confidence levels assigned correctly per matching strategy

## Open questions

1. **Confidence level threshold для unattributed** — показывать ли в Per-app session **все** unattributed (системные), или только те которые **вероятно** target app (через geo-pattern / time-correlation)? Compromise — показывать **все** в отдельной section, чётко помечать.
2. **Memory cost** rolling buffer — 60s × ~50 events/sec на busy device = 3000 events. Каждое ~500B → 1.5MB. Acceptable.
3. **Privacy concern** — Live tab показывает activity других apps. OK для diagnostic tool. Add disclaimer в Help dialog Live tab.
4. **`findConnectionOwner` lookup latency** — можно ли upstream sing-box подождать package detection до routing decision? Это PR в SagerNet/sing-box, не наш fix.
5. **Live tab persistence** — не персистим (in-memory only). Если юзер ждёт ~10 минут чтобы увидеть тренд — buffer sliding только 60s. Compromise: hard limit 60s, но ring растёт до limit'а памяти если запрошено `?seconds=300`.
6. **API authorization** — `/profiler/live*` endpoints через тот же Bearer token что остальные. Нюансов нет.

## Reference

- §044 spec — implementation log пункт #4 (DNS attribution на оригинальный domain)
- §047 sibling task — другая проблема (race condition в tun lifecycle); содержит конкретные log entries из той же диагностической сессии 2026-05-09
- Live evidence repro: `./scripts/lxbox-diag.sh` собирает аналогичный snapshot за 2-3 секунды (см. `docs/DIAGNOSTICS.md`)

---

## Implementation log (2026-05-09)

**TL;DR.** Concept «inclusive observer with confidence» реализован end-to-end. `TrafficProfiler` теперь не drop'ает события — каждое попадает в global rolling buffer (60s × ~3000 events) и в session с одним из 4 уровней confidence (`verified` / `secondary` / `inferred` / `unattributed`). Per-app trace tab показывает System-wide events в Live sub-tab + banner при detected gaps. Добавлен 4-й tab `Live` в Statistics — system-wide feed без выбора target. Debug API расширен `/profiler/live*` endpoint'ами.

### Что сделано (по принципам)

- **Принцип 1 «Show, don't hide».** `_globalUnattributedEvents` ring (50 events) живёт в TrafficProfiler. DNS fail / HTTPS / SVCB / SOA без owner package попадают туда + в global rolling buffer. Per-app Live sub-tab имеет section «System-wide events» (dimmed) + красный banner «N unattributed events / 30s» показывается когда `recentUnattributedCount > 5`.
- **Принцип 2 «Defensive parsing».** `_dnsRe` теперь принимает любой record type (capture group `(\S+)` вместо whitelist'а `A|AAAA|CNAME`). `_dnsFailRe` принимает форматы с/без trailing dot, с/без `IN <TYPE>`, с time в `ms` или `s`. Tests: HTTPS/SVCB/SOA + 10.0s формат + DNS fail без owner.
- **Принцип 3 «Multiple matching strategies».** `_resolveForSession` выполняет цепочку: direct match → secondary packages → UID-stripped variants → recent DNS IP inference (10s). Каждое event получает `confidence` + `matchedVia`. `Session.secondaryPackages: Set<String>` — configurable per session через UI (`Edit secondary` button под header'ом) и API (`POST /profiler/start { secondary_packages: [...] }`, `PATCH /profiler/secondary-packages`). Multi-package UID `com.x.y, com.x.z` — split-and-contains, не equals.
- **Принцип 4 «Pre-buffer always running».** `_globalRollingBuffer: ListQueue<TrafficEvent>` 60s window × hard cap 3000 events. На `start()` events за last 60s резолвятся через `_resolveForSession` и backfill'ятся в session.events с `backfilled=true`. UI показывает marker «〽 backfilled from pre-recording».
- **Принцип 5 «Streaming primary, polling supplement».** Polling interval 2s → 5s. Discovery новых events идёт через log-stream. Polling только enrich'ит open conn'ы (bytes / state) и эмитит close events.
- **Принцип 6 «Aggressive cleanup».** `Timer.periodic(5s, _gcStaleConnIds)` cleanup'ит entries старше 30s в `_connIdToMeta`, `_dnsByConnId`, плюс trim'ит `_globalRollingBuffer` / `_globalUnattributedEvents` по time window'у. Lazy attach: GC и log listener стартуют когда либо session active либо есть global subscriber.
- **Принцип 7 «Live system-wide tab».** `LiveEventsTab` (новый файл `app/lib/screens/live_events_tab.dart`) — 4-й tab в `StatsScreen`. Filter chips: kind (DNS / DNS× / TCP / TCP· / UDP), unattributed-only toggle, app multi-select bottom sheet, search by domain/IP/process. Pause/resume button (frozen view). Long-press на event row → bottom sheet с «Open in Per-app session for <pkg>» — auto-stop active session + start с этим package.

### Что закрывает (gap → реализация)

| Gap | Closed by |
|-----|-----------|
| 1 — DNS fail дроп | Принцип 1 + 2: emit'ится с `confidence: unattributed` (или verified если owner есть), идёт в global ring + Per-app System-wide section |
| 2 — Process detection misses коротких TCP | Принцип 5: log-stream primary; polling только supplement → не зависим от 5s окна |
| 3 — `〽 inferred` не работал на 100% | Принцип 3 strategy 4: `_inferProcessByIp` теперь идёт по `_globalRollingBuffer` (не session.events) — работает даже до session start'а |
| 4 — WebView/system-process subprocess | Принцип 3 strategy 2: `secondaryPackages`. Юзер добавляет `com.google.android.webview` в picker'е → confidence=secondary, попадает в session |
| 5 — UID suffix variations | Принцип 3 strategy 3: `_stripUid` снимает `(UID)` и `/uid` форматы перед matching |
| 6/7 — HTTPS / SOA / SVCB regex | Принцип 2: defensive `_dnsRe` + `dnsRecordType` поле в TrafficEvent |
| 8 — Conn-id reuse | Принцип 6: TTL 30s + GC каждые 5s, race window << reuse window |
| 9 — Polling lag | Принцип 5: discovery в log-stream, polling 5s только для stats |
| 10 — Closed conns rotation | Принцип 5 + 1: log-stream ловит каждый `inbound packet connection`; close event эмитится через snapshot diff (как раньше) — без потерь |
| 11 — Multiple package_name на UID | `_splitPackageNames` split'ит через запятую; `processNames.contains(target)` — match если ANY |
| 12 — Pre-session events потеряны | Принцип 4: backfill из global rolling buffer |
| 13 — Sandboxed renderer dying | Принцип 1: попадает как unattributed через global, видно в System-wide section и Live tab'е |

### API contract (примеры)

```jsonc
// POST /profiler/start
{
  "package": "ru.tinkoff.investing",
  "verbose": false,
  "secondary_packages": ["com.google.android.webview"]
}

// GET /profiler/session/<id>?include=events — каждое event имеет confidence
{
  "session_id": "...",
  "target_package": "ru.tinkoff.investing",
  "secondary_packages": ["com.google.android.webview"],
  "events_count": 47,
  "unattributed_count": 3,
  "events": [
    { "kind": "dnsResolve", "domain": "cdn.t-bank-app.ru", "ip": "193.17.93.194",
      "confidence": "verified" },
    { "kind": "tcpOpen", "ip": "1.2.3.4", "process": "com.google.android.webview",
      "confidence": "secondary", "matched_via": "secondary_packages" },
    { "kind": "dnsFail", "domain": "static.2ip.io", "dns_record_type": "HTTPS",
      "confidence": "unattributed",
      "shown_because": "system-wide event without owner detection (during active session)" }
  ]
}

// GET /profiler/live?seconds=60   — global rolling buffer snapshot
// GET /profiler/live/stream       — SSE feed без session filter'а
// GET /profiler/live/unattributed — recent unattributed + banner state
// PATCH /profiler/secondary-packages { secondary_packages: ["com.x.webview"] }
```

### Tests (added в `app/test/services/traffic_profiler_test.dart`)

- `§048 defensive DNS regex` — HTTPS / SVCB / SOA records, fail без owner, fail с `10.0s` time format
- `§048 multi-package & secondary` — multi-package UID, WebView via secondary, UID-suffixed name `(10999)`, non-target drop, `updateSecondaryPackages` mutation
- `§048 pre-session backfill` — events до start попадают в session.events с `backfilled=true`
- `§048 confidence in JSON` — toJson включает `confidence` + `matched_via` + `shown_because`
- `§048 Live system-wide buffer` — global snapshot для multiple apps, banner threshold trigger
- `§048 time-based GC` — `gcOnceForTest` не падает

Suite: 535 tests pass; `flutter analyze` чистый.

### Что не решает (заведомо out of scope)

- **upstream sing-box `findConnectionOwner` latency** — это PR в SagerNet/sing-box (Open question 4 выше)
- **Persist sessions через kill app'а** — by design, in-memory only (§044 spec'а)
- **Differential capture (session A vs session B)** — пока не делаем
