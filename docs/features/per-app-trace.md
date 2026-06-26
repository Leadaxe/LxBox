# Per-app traffic profiler

Инструмент диагностики «куда конкретное приложение ходит и как роутится». Решает задачи вида: «X не открывается через VPN», «куда стучит этот фитнес-трекер», «через какой outbound реально идёт трафик банка». Без packet capture, без root, без ручного matching'а conn_id'ов между логами.

**Inclusive observer with confidence** (§048): profiler не drop'ает события, каждое попадает в UI с уровнем уверенности (`verified` / `secondary` / `unattributed`). Юзер видит **всё что произошло**, и видит **что точно его app, а что возможно**.

Атрибуция приходит **готовой из ядра** (§168/§180, sing-box-lx): TCP/UDP-владелец — `CcConnection.packageName` из libbox `getProcessInfo()`, DNS-владелец — структурный DNS-стрим (`CcChannel.dnsQueries`, SPEC 018). Профайлер больше **не парсит core-логи** regex'ами и не сшивает события по conn_id.

| | |
|---|---|
| Где живёт | `Statistics → App` (3-я вкладка, per-app trace) и `Statistics → Profiler` (4-я вкладка, system-wide). Обе используют общий движок `TraceExplorer`. |
| Spec | [`docs/spec/features/044 per-app traffic profiler/spec.md`](../spec/features/044%20per-app%20traffic%20profiler/spec.md) + [`docs/spec/tasks/048-perapp-trace-attribution-gaps.md`](../spec/tasks/048-perapp-trace-attribution-gaps.md) |
| Реализация в | v1.7.0 (базовая фича); §048 inclusive observer + Profiler-вкладка; §160 единый `TraceExplorer` (Live / Aggregated); §180 структурный DNS-стрим из ядра. Текущее поведение — v2.5.0. |
| State | In-memory only (на kill app'а / force-stop sessions стираются) |
| Battery cost | Низкий в normal mode; средний при включённом verbose toggle |

## TL;DR — basic flow

1. Открыть `Statistics → App` (или с HomeScreen tap по traffic bar'у когда recording active)
2. **Pick app** → выбрать приложение из picker'а
3. **▶ START** — recording пошёл
4. Походить по приложению, дать трафик пройти
5. **⏹ STOP** — финализирует session (сохраняется в ring-buffer'е последних 5)
6. Смотреть через тогл группировки: **Event stream** (поток событий newest-first) или **Aggregated** (свод **by Domain** / **by IP**)
7. ⚠ icon отмечает connection issues (DNS timeout, TCP RST early); тап по строке → детали события (route, DNS-сервер, app)

## UI tour

`App`-вкладка = заголовок сессии (picker + START/STOP + overflow) над общим движком `TraceExplorer` (control-строка + список). `TraceExplorer` тот же, что в `Profiler`-вкладке (system-wide) — отличие в источнике событий (события сессии vs глобальный буфер) и в том, что в `App`-вкладке target фиксирован сессией, поэтому app-ось фильтра скрыта.

### Header (App-вкладка)

```
┌─ App ───────────────────────────────────────⋮──┐
│ ⚡ Verbose core logs active — battery/CPU       │  ← banner если verbose ON
│   impact while session runs                    │
│                                                 │
│  Target: [ru.tinkoff.investing ▼]   [⏹ STOP]   │
│  ⏺ Recording · 02:34 · 47 doms · 53 ips · 287 ev│
│  🔗 No secondary packages      [+ Edit secondary]│
└─────────────────────────────────────────────────┘
```

- **Target dropdown** — открывает single-pick app picker. Заблокирован пока recording active (юзер не может сменить target mid-session — нужно сначала STOP).
- **▶ START / ⏹ STOP** — primary green / red button. Нет «pause»-записи — phrasing явный, чтобы юзер не путался (пауза есть, но только для *отображения* Live-списка, не для записи — см. control-строку).
- **⋮ Overflow menu** — Verbose toggle, Copy session JSON, Share session, Clear all sessions, Help.

### Control-строка (TraceExplorer)

Под заголовком — одна строка управления просмотром:

- **⏸ Pause / ▶ Resume** (только в режиме Event stream) — замораживает *отображение* списка для вдумчивого чтения. Запись продолжается в фоне, на resume — свежее состояние.
- **Grouping-меню** — переключает режим: **Event stream** (поток newest-first) / **Group by Domain** / **Group by IP** (последние два = Aggregated).
- **Filter** — открывает фильтр-окно (см. ниже). Жёлтая точка + счётчик `(N)` показывают сколько фильтров активно.
- **Retention** (окно хранения Live, `1m / 10m / 1h`) — присутствует только в `Profiler`-вкладке; в `App`-вкладке журнал = события сессии, окно не настраивается.

### Verbose toggle

Включает sing-box `log_level=debug` через `setVar('log_level', 'debug') + reload`. На stop'е — revert к предыдущему значению. Banner внутри tab'а напоминает что verbose ON; глобального banner'а нет.

**Когда нужен**: для глубокой диагностики на уровне core-логов (cache state, внутренние решения router'а) — это пишется в общий журнал приложения, не в профайлер (профайлер берёт DNS из структурного стрима независимо от log_level). Для типичного «X не работает» — обычно не нужен. Battery/CPU impact ощутимый при busy traffic.

### Режимы просмотра: Event stream / Aggregated

`TraceExplorer` показывает события одним из двух режимов (переключается Grouping-меню). Раньше это были четыре отдельных саб-таба (Live / Domains / IPs / Connections); §160 свернул их в один движок: Domains+IPs стали осями Aggregated, а Connections растворился в Event stream (та же лента + чип TCP/UDP + детали по тапу).

#### Event stream (Live)

Streaming list events newest-first. Каждый event — одна строка:

```
10:42:15  DNS  cdn.t-bank-app.ru → 193.17.93.194
              ↳ CNAME cl-ead2c819.edgecdn.ru
10:42:15  TCP  cdn.t-bank-app.ru:443
              final ⇒ direct-out
10:42:14  DNS  certs.t-bank-app.ru → 81.222.127.186      ⚠
              ↳ CNAME eq09pc7nbi.a.trbcdn.net      cached
10:42:14  TCP  certs.t-bank-app.ru:443                    ⚠
              final ⇒ vpn-1 : 🇫🇮fi-node → WARP
```

- **Цветные kind-метки**: `DNS` (tertiary), `DNS×` (error — fail), `TCP` (primary), `TCP·` (closed, dimmed), `UDP` (secondary)
- **`↳ CNAME chain`** — промежуточные CNAME-таргеты (приходят целиком в одном DNS-событии из ядра)
- **routingLine** — читаемая трассировка маршрута (см. ниже): `процесс ⇒ rule ⇒ группа : нода → detour → домен`
- **cached-бейдж** — когда DNS-ответ пришёл из кэша ядра (без сетевого запроса)
- **⚠** — connection issue mark, tap по строке → детали с описанием
- **тап по строке** → bottom-sheet с деталями события (route, DNS-сервер, app, IP/CNAME, issues)

Newest-first, новые добавляются в начало. **⏸ Pause** замораживает отображение (запись идёт дальше).

#### Aggregated (by Domain / by IP)

Свод уникальных доменов или IP, отсортированный по объёму. Ось переключается в Grouping-меню (`Group by Domain` / `Group by IP`). Search-поле фильтра матчит по domain / IP / process.

- **by Domain** — каждая строка = домен (conns, ↑/↓ bytes, outbound). Тап → свод + список соединений → тап по соединению → детали события.
- **by IP** — симметричный взгляд: уникальные destination-IP. Полезен для **hostless conn'ов** (TCP без SNI — нет домена, но есть IP), **glance view** топ-потребителей и **suspect IP debugging** (пришёл IP из threat-feed — ходит ли туда app).

```
▼ certs.t-bank-app.ru               1 conn  ↑458B  ↓2.1KB  ⚠
    CNAME    eq09pc7nbi.a.trbcdn.net
    IPs      81.222.127.186
    Outbound vpn-1 / 🇫🇮Финляндия
    First    10:42:14
    Last     10:42:14
```

Из деталей агрегата есть `View in Aggregated` — переключает на ось by Domain + автоподстановка ключа в search (cross-domain IP-аудит: по подозрительному IP сразу видно полный список доменов, которые на него резолвились).

### routingLine — трассировка маршрута (§181)

В деталях каждого conn/DNS-события строка **Route** показывает полный путь пакета слева направо. Разделители кодируют тип перехода:

```
[tcp] ru.tinkoff.investing ⇒ final ⇒ vpn-1 : fi-node → WARP → certs.t-bank-app.ru
       └─ процесс          └ rule  └ группа └ нода  └ detour └ домен
```

- **`⇒`** — внутренние переходы (источник + роутинг: процесс → rule → группы-селекторы)
- **`:`** — выход во внешний мир (группа выбрала конкретный сервер/ноду)
- **`→`** — снаружи (detour-цепочка транспорта + конечный домен)

В live-списке показывается компактная форма (без префикса `[network] процесс ⇒`); полная — в detail-sheet.

### Детали DNS-события (rc.10, §180)

Для DNS-событий bottom-sheet показывает дополнительно:
- **DNS server** — какой сервер ответил (`+ тип`: udp/tls/https/…). На проксированном DNS-пути.
- **Source** — `exchanged` (сетевой запрос), `cached` (из кэша), `optimistic`, `refreshed`.
- **App** — иконка + человекочитаемое имя приложения + package (атрибуция из ядра).
- **Route** — routingLine (через какой outbound пошёл DNS).

### Confidence levels (§048)

Каждое event имеет confidence — насколько точно мы уверены что это traffic нашего target app'а. Атрибуция приходит из ядра (§168/§180), поэтому фактические уровни:

| Уровень | UI marker | Когда |
|---|---|---|
| `verified` | (no marker, default) | владелец из ядра совпал с target (`CcConnection.packageName` / DNS-стрим) |
| `secondary` | 🔗 sec | match через `secondary packages` (WebView etc) |
| `unattributed` | ? (red) | ядро не определило владельца — событие показано как nearby/system-wide |

Tooltip над badge'ом показывает `matched_via` (как сработала атрибуция) и `shown_because` (для unattributed — почему всё-таки показано).

> Уровень `inferred` (process-inference по recent DNS-IP, маркер 〽) **выпилен** в §044: после §168/§180 владелец TCP/DNS приходит готовым из ядра, эвристика «безымянный TCP принадлежит target по DNS-IP» больше не нужна. Безымянный TCP теперь → `unattributed` (деградация точности, не поломка). Значение `inferred` осталось в enum dormant для совместимости старых session-JSON, но не выставляется.

### Secondary packages

Под header'ом session'и есть chip-row «🔗 No secondary packages» + кнопка `[Edit secondary]`. Это ответ на Tinkoff / WebView сценарий: банковское app может рендерить web-части в `com.google.android.webview` (отдельный UID), и его traffic не попадает в session под target = `ru.tinkoff.investing`. Решение — добавить `com.google.android.webview` в secondary через multi-select picker. Live mutation: можно менять во время recording'а.

### System-wide events section

В `App`-вкладке внизу Live-режима появляется секция «System-wide events (no owner detected) — N» когда есть unattributed events (e.g. DNS fail без определённого ядром владельца). Они dimmed, помечены `?`-badge'ом, видны в JSON session'и с `confidence: unattributed` + `shown_because`.

Если detected >5 событий-сбоев за 30s — вверху появляется красный banner «N unattributed events / 30s — attribution gaps detected». В счёт идут **только признаки сбоя** (§177-A): DNS-fail и безымянный TCP/UDP open. Успешный DNS без владельца — норма (DNS плохо атрибутируется), не тревога. Этот же banner подсвечивает иконку на самой вкладке `Profiler`.

### Pre-session backfill

`TrafficProfiler` держит global rolling buffer (окно настраивается: 1/10/60 мин, default 10 мин) всех событий всех apps. На `▶ START` — события за окно, которые match target / secondary, попадают в session.events с marker `backfilled from pre-recording`. Решает «юзер ставит recording после того как заметил проблему — теряет первый контекст». Работает только если global recording (`Profiler`-вкладка) был включён.

### Connection issues (⚠ маркеры)

Не статистические аномалии, а конкретные diagnostic-сигналы — два locale-агностичных типа:

| Issue | Условие | Use case |
|---|---|---|
| **DNS timeout** | структурный DNS-fail из ядра (SPEC 018, `q.failed`) — прямой engine-сигнал с причиной (rcode / no response / error), не heuristic | Network-уровневая проблема, DNS server недоступен |
| **TCP RST early** | conn closed в течение 1с, ↑0 ↓0 байт — heuristic | Block / RST injection / TLS handshake fail / firewall reject |

В JSON session'а лежат как `events[i].issues: [{kind, description}]` и `by_domain[i].issues: [...]`. В UI отрисовываются как ⚠ icon на event row + tooltip с описанием.

Раньше были ещё типы (`geoMismatch`, `unusualPort`, `badLatency`) — выпилил, оба давали locale-bias / шум. Locale-агностичная geo-mismatch через user-config home-locale + geoip-lookup — на post-MVP.

### Saved sessions

Когда session active нет — в нижней части показываются последние 5 завершённых sessions:
- Tap → открыть session в read-only режиме (тот же `TraceExplorer`: Event stream / Aggregated)
- Иконка share — экспорт session JSON через `share_plus` (отправить себе в Telegram, сохранить в файл итд)
- Иконка delete — удалить session

После 5 sessions старые автоматически evict'ятся (FIFO). Force-stop приложения = все sessions стираются (in-memory only).

## Profiler system-wide tab (§048)

Параллельная вкладка `Statistics → Profiler` (4-я). Discovery-mode без выбора target заранее: видно все apps' DNS / TCP / UDP события системы в real-time. Использует тот же `TraceExplorer`, что и `App`-вкладка, плюс свою специфику: большая START/STOP-кнопка записи (`globalRecording`) + export в хедере, retention-меню в control-строке, app-ось фильтра (в per-app trace процесс один, тут — все).

```
┌─ Profiler ────────────────── [⏹ STOP] [⇪ Export] ─┐
│ ⏸  10m ▾   Stream ▾                    Filter (3) ●│  ← control-строка
│ ─────────────────────────────────────────────── │
│ 12:34:01 DNS  cdn.example.com → 1.2.3.4          │
│           com.android.chrome                      │
│ 12:34:01 DNS× ?  example.invalid                  │
│           ?                  record: HTTPS        │
│ 12:34:00 TCP  api.tinkoff.ru:443                  │
│           ru.tinkoff.investing                    │
│ ...                                               │
└──────────────────────────────────────────────────┘
```

**Фильтр-окно (§044/§177)** — bottom-sheet с двумя независимыми осями:
- **Protocol** — DNS / TCP / UDP (по семейству, один чип ловит обе фазы: dnsResolve+dnsFail, tcpOpen+tcpClose).
- **App** — мульти-выбор замеченных в feed'е приложений + пункт «потеряшки» (unattributed/no-owner). App-ось работает в OR: событие проходит, если process ∈ выбранных ЛИБО это потеряшка и потеряшки включены.
- Плюс кросс-осевой **Search** — substring match по domain / IP / process.

Активные фильтры отмечены счётчиком `(N)` + жёлтой точкой на кнопке Filter.

**Retention** (`1m / 10m / 1h`) — окно хранения global rolling buffer'а, меняется на лету (старые события подрежутся следующим GC-проходом). Только в этой вкладке.

**Pause / resume** — статичный snapshot для вдумчивого чтения. Запись продолжается в background, на resume — fresh state.

**Banner** наверху появляется когда счёт событий-сбоев за 30s превышает порог — то же что в `App`-вкладке.

## Recording indicators

```
HomeScreen (idle):
  ↑ 0.2 KB/s   ↓ 1.4 KB/s   🔗 23                 1h 12m

HomeScreen (recording):
  ↑ 0.2 KB/s   ↓ 1.4 KB/s   🔗 23   ⚡ ru.tinkoff  1h 12m
                                       ↑
                            новый chip — short pkg name
                            tap всей строки → Stats → App

Stats TabBar (idle):
  [ Stats · Conns · App · Profiler ]

Stats TabBar (recording):
  [ Stats · Conns · App ⚡ · Profiler ]
                       ↑ recording-болт на App; ⚠ на Profiler = unattributed banner
```

Recording **продолжается независимо от UI**: можно уйти на HomeScreen, в другие настройки, свернуть приложение — singleton service пишет события дальше. Останавливается только:
- Manual ⏹ STOP
- Force-stop приложения (Android Settings)
- Device reboot
- Старт новой session (старая finalize'ится в completed ring-buffer)

## Use cases

### 1. «Tinkoff не открывается через VPN» (§045 incident)

1. `Stats → App` → ru.tinkoff.investing → ▶
2. Открыть Tinkoff Investments, дать ему сделать запросы
3. ⏹ STOP
4. Grouping → **by Domain** → видим список `*.t-bank-app.ru`
5. Строки с ⚠ → раскрыть → видим: domain `certs.t-bank-app.ru`, CNAME `*.trbcdn.net`, routingLine `… ⇒ vpn-1 : 🇫🇮fi-node`
6. Корень: CNAME-target на `.net` TLD не попадает в `ru-domains` rule_set, sing-box роутит через bypass-VPN
7. Решение: добавить `*.trbcdn.net` в `ru-direct` preset (или включить geoip-fallback из §045)

Раньше тот же flow занимал 30+ минут ручной работы со снапшотами `/state` / `/connections` / `/logs` + cross-reference по conn_id. С §044 — 30 секунд.

### 2. Privacy audit фитнес-трекера

1. Открыть фитнес-трекер → `Stats → App` → выбрать его → ▶
2. Походить по экранам где собираются данные (workout, профиль)
3. ⏹ STOP
4. Grouping → **by Domain** — список доменов, отсортированный по объёму трафика
5. Заметили что-то незнакомое типа `analytics.tracker.com`? Тап → детали: CNAME chain + routingLine — куда это ушло?
6. Если решили блокировать — `[Add domain rule]` (post-MVP) → создаст inline rule с `domain_suffix + package_name + action: reject`

### 3. Debug медленного приложения

1. `Stats → App` → app → ▶
2. Воспроизвести «медленный» сценарий
3. ⏹ STOP
4. Grouping → **by Domain** (sorted by bytes) — топ потребителей трафика
5. Grouping → **by IP** — какие IP отвечают; `View in Aggregated` → cross-reference с CDN
6. Anomalies (⚠ DNS timeout / RST early) — network-уровневые проблемы

### 4. Catalog для preset'ов RU-сервисов

Записать сессии «Сбер», «ВТБ», «Госуслуги», экспортировать каждый в JSON через Share. Из набора доменов в Aggregated (by Domain) → составить расширенный preset для ru-direct или новый bank-specific preset.

### 5. Dogfooding разработки L×Box

Когда сам L×Box себя ведёт странно — `Stats → App` на `com.leadaxe.lxbox`. Видим, какие подписки fetch'аются, через какой outbound, есть ли DNS retry'и. Ускоряет TDD на VPN-flow'ах.

## Debug API

Все controls UI доступны через HTTP API (Bearer-token authenticated). Полная reference: [`docs/api/debug-api-reference.md`](../api/debug-api-reference.md).

```bash
TOKEN=357f5aacdf154419d2787ec61e3ad9f2
H="Authorization: Bearer $TOKEN"

# Start session (с secondary packages — §048)
curl -s -H "$H" -H "Content-Type: application/json" \
  -d '{"package":"ru.tinkoff.investing","verbose":false,
       "secondary_packages":["com.google.android.webview"]}' \
  http://127.0.0.1:9270/profiler/start

# Mutate secondary packages live (§048)
curl -s -X PATCH -H "$H" -H "Content-Type: application/json" \
  -d '{"secondary_packages":["com.google.android.webview","com.android.webview"]}' \
  http://127.0.0.1:9270/profiler/secondary-packages

# Active session meta (counts, duration, unattributed_count)
curl -s -H "$H" http://127.0.0.1:9270/profiler/active

# Full session с domains+ips+events (events содержат confidence + matched_via)
curl -s -H "$H" "http://127.0.0.1:9270/profiler/session/<id>?include=domains,ips,events"

# List finished sessions
curl -s -H "$H" http://127.0.0.1:9270/profiler/sessions

# Stop
curl -s -X POST -H "$H" http://127.0.0.1:9270/profiler/stop

# Per-session SSE stream
curl -s -N -H "$H" -H "Accept: text/event-stream" \
  http://127.0.0.1:9270/profiler/stream

# §048 — Global system-wide snapshot (last N seconds)
curl -s -H "$H" "http://127.0.0.1:9270/profiler/live?seconds=60"

# §048 — Global SSE stream без session filter'а
curl -s -N -H "$H" -H "Accept: text/event-stream" \
  http://127.0.0.1:9270/profiler/live/stream

# §048 — Recent unattributed events + banner state
curl -s -H "$H" http://127.0.0.1:9270/profiler/live/unattributed
```

SSE формат: `event: traffic_event\ndata: {...}\n\n`. Fire-and-forget — без `Last-Event-ID` reconnect mechanism (overkill для in-app single-user use case'а).

## Edge cases & limits

| Случай | Поведение |
|---|---|
| `find_process: false` в config'е | UI показывает «Process detection disabled in template». Юзеру нужно поправить `template`/`vars`. |
| Process detection миссит (webview/system process) | Ядро не вернуло владельца → событие → `unattributed` (показано как nearby/system-wide). Для WebView-сценария — добавить subprocess в secondary packages. |
| Verbose toggle включается / выключается mid-session | Sing-box reload, active connections рвутся. UI warning при toggle — юзер решает. |
| Session events overflow (>50000 ev или >3h) | Drop oldest, counter `events_dropped` в meta JSON виден в UI footer (`· N dropped`). |
| Memory pressure | Max 6 sessions concurrent (1 active + 5 completed). Old auto-evict'ятся. |
| App force-stop / device reboot | Все in-memory sessions стираются. Persist принципиально не делается — экспортируйте через Share/Copy если нужно сохранить. |

## Что **не** делает (текущая версия)

- Не умеет inline создавать routing rules «Add to ru-direct» / «Block this domain» (запланировано на v1.7.x cycle, см. spec § Bonus actions).
- Не показывает HTTP-уровневые headers / URL'ы — только L4 (hostname:port). Это limitation sing-box'а — он работает на уровне SOCKS/TUN, не HTTP.
- Не делает differential capture (compare session A vs session B) — на будущих циклах.
- Не считает per-domain latency / RTT — только bytes & connection counts.
- TLS fingerprinting (JA3/JA4) — пока не интегрирован, sing-box capability в `outbound/uTLS` ещё не expose'ится.
