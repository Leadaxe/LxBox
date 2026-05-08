# Per-app traffic profiler

Инструмент диагностики «куда конкретное приложение ходит и как роутится». Решает задачи вида: «X не открывается через VPN», «куда стучит этот фитнес-трекер», «через какой outbound реально идёт трафик банка». Без packet capture, без root, без ручного matching'а conn_id'ов между логами.

| | |
|---|---|
| Где живёт | `Statistics → Per-app` (третий tab) |
| Spec | [`docs/spec/features/044 per-app traffic profiler/spec.md`](../spec/features/044%20per-app%20traffic%20profiler/spec.md) |
| Реализация в | v1.7.0 |
| State | In-memory only (на kill app'а / force-stop sessions стираются) |
| Battery cost | Низкий в normal mode; средний при включённом verbose toggle |

## TL;DR — basic flow

1. Открыть `Statistics → Per-app` (или с HomeScreen tap по traffic bar'у когда recording active)
2. **Pick app** → выбрать приложение из picker'а
3. **▶ START** — recording пошёл
4. Походить по приложению, дать трафик пройти
5. **⏹ STOP** — финализирует session (сохраняется в ring-buffer'е последних 5)
6. Смотреть: **Live** (стрим events), **Domains** (агрегаты по домену), **IPs**, **Connections** (timeline)
7. ⚠ icon отмечает connection issues (DNS timeout, TCP RST early)

## UI tour

### Header

```
┌─ Per-app traffic profiler ──────────────────⋮──┐
│ ⚡ Verbose core logs active — battery/CPU       │  ← banner если verbose ON
│   impact while session runs                    │
│                                                 │
│  Target: [ru.tinkoff.investing ▼]   [⏹ STOP]   │
│  ⏺ Recording · 02:34 · 47 doms · 53 ips · 287 ev│
└─────────────────────────────────────────────────┘
```

- **Target dropdown** — открывает single-pick app picker. Заблокирован пока recording active (юзер не может сменить target mid-session — нужно сначала STOP).
- **▶ START / ⏹ STOP** — primary green / red button. Нет «pause» — phrasing явный, чтобы юзер не путался.
- **⋮ Overflow menu** — Verbose toggle, Copy session JSON, Share session, Clear all sessions, Help.

### Verbose toggle

Включает sing-box `log_level=debug` через `setVar('log_level', 'debug') + reload`. На stop'е — revert к предыдущему значению. Banner внутри tab'а напоминает что verbose ON; глобального banner'а нет.

**Когда нужен**: для глубокой диагностики DNS-уровня — без debug'а sing-box не пишет некоторые подробности типа cache state или router's внутренние решения. Для типичного «X не работает» — обычно не нужен. Battery/CPU impact ощутимый при busy traffic.

### Sub-tabs

#### Live

Streaming list events newest-first. Каждый event — одна строка:

```
10:42:15  DNS  cdn.t-bank-app.ru → 193.17.93.194 ↗
              ↳ CNAME cl-ead2c819.edgecdn.ru
10:42:15  TCP  cdn.t-bank-app.ru:443
              ↳ via direct-out
10:42:14  DNS  certs.t-bank-app.ru → 81.222.127.186 ↗      ⚠
              ↳ CNAME eq09pc7nbi.a.trbcdn.net
10:42:14  TCP  certs.t-bank-app.ru:443                      ⚠
              ↳ via vpn-1 → 🇫🇮Финляндия
```

- **Цветные kind-метки**: `DNS` (tertiary), `DNS×` (error — fail), `TCP` (primary), `TCP·` (closed, dimmed), `UDP` (secondary)
- **`↳ CNAME chain`** — промежуточные CNAME-таргеты (если резолв шёл через CNAME-цепочку)
- **`↳ via outbound`** — какой outbound выбрал router
- **⚠** — connection issue mark, hover/tap → tooltip с описанием
- **↗** — рядом с IP — переход на Domains tab с автоподстановкой этого IP в search

Если выводить много данных — auto-scroll работает natively (newest-first, добавляются в начало). Manual scroll вверх не сбивает.

#### Domains

Aggregated unique domains, sorted by total bytes (top apps). Search-поле сверху матчит:
- по domain name (`tbank` → все `*.tbank.ru` и `*.tbank-app.ru`)
- по IP (`193.17` → все домены, что резолвились на `193.17.x.x`)
- по CNAME target (`trbcdn` → все домены, чей CNAME лидит на `*.trbcdn.net`)

Это **cross-domain IP-аудит** — folded роль из IPs tab'а: имея подозрительный IP, видишь сразу полный список доменов, которые на него резолвились.

```
▼ cdn.t-bank-app.ru                  1 conn  ↑458B  ↓2.1KB
    CNAME    cl-ead2c819.edgecdn.ru
    IPs      193.17.93.194 ↗
    Outbound direct-out
    First    10:42:14
    Last     10:42:14
▼ certs.t-bank-app.ru               1 conn  ↑458B  ↓2.1KB  ⚠
    CNAME    eq09pc7nbi.a.trbcdn.net
    IPs      81.222.127.186 ↗
    Outbound vpn-1 / 🇫🇮Финляндия (vpn-1)
    ⚠ Russian domain routed via foreign outbound (vpn-1 → 🇫🇮Финляндия)
```

Тап на row — раскрывает. ↗ рядом с IP — переход на тот же tab с подстановкой IP в search (см. cross-domain выше).

#### IPs

Симметричный Domains tab взгляд — aggregated unique destination IPs sorted by bytes. Полезен для:
- **Hostless conn'ов** — TCP без SNI sniffing (e.g. raw protocol, не HTTPS); они не появляются в Domains tab'е, но видны в IPs
- **Glance view** — топ-N куда ушло больше трафика
- **Suspect IP debugging** — пришёл IP из threat-feed / провайдерских логов, надо понять, ходит ли туда наш app

Каждая строка — `IP ↗`, ports, conns count, bytes, outbound. ↗ переходит на Domains с подстановкой IP (показывает, какие домены этот IP «обслуживал»).

#### Connections

Per-connection timeline (TCP/UDP open/close events). Tap на row — inline expand:

```
10:42:15  certs.t-bank-app.ru:443  ↑458B  ↓2.1KB  ⚠  ▽
              via vpn-1 → 🇫🇮Финляндия
              duration 3247ms
              ─────────────────────────────
              CNAME    eq09pc7nbi.a.trbcdn.net
              All IPs  81.222.127.186 ↗
              Rule     domain_suffix (t-bank-app.ru)
              ⚠ Russian domain routed via foreign outbound
              [↗ View in Domains]
```

- **Click target — только header** (timestamp + host:port + bytes + chevron). Развёрнутая секция не схлопывается на тап — можно жать кнопку View in Domains, копировать текст CNAME без потери expand-state.
- **All IPs** — все IP, в которые резолвился этот domain (не только destinationIP конкретного conn'а)
- **[View in Domains]** — переключает на Domains tab + autofill search этим domain'ом + auto-expand row
- **Hostless conn** (нет SNI) — отображается как `[<ip>]:port`. Кнопка View in Domains скрыта (нет domain'а для перехода).

### Connection issues (⚠ маркеры)

Не статистические аномалии, а конкретные diagnostic-сигналы — два locale-агностичных типа:

| Issue | Условие | Use case |
|---|---|---|
| **DNS timeout** | sing-box лог `dns: exchange failed ...` (context deadline exceeded и пр.) — прямой engine-сигнал, не heuristic | Network-уровневая проблема, DNS server недоступен |
| **TCP RST early** | conn closed в течение 1с, ↑0 ↓0 байт — heuristic | Block / RST injection / TLS handshake fail / firewall reject |

В JSON session'а лежат как `events[i].issues: [{kind, description}]` и `by_domain[i].issues: [...]`. В UI отрисовываются как ⚠ icon на event row + tooltip с описанием.

Раньше были ещё типы (`geoMismatch`, `unusualPort`, `badLatency`) — выпилил, оба давали locale-bias / шум. Locale-агностичная geo-mismatch через user-config home-locale + geoip-lookup — на post-MVP.

### Saved sessions

Когда session active нет — в нижней части показываются последние 5 завершённых sessions:
- Tap → открыть session в read-only режиме (sub-tab'ы те же)
- Иконка share — экспорт session JSON через `share_plus` (отправить себе в Telegram, сохранить в файл итд)
- Иконка delete — удалить session

После 5 sessions старые автоматически evict'ятся (FIFO). Force-stop приложения = все sessions стираются (in-memory only).

## Recording indicators

```
HomeScreen (idle):
  ↑ 0.2 KB/s   ↓ 1.4 KB/s   🔗 23                 1h 12m

HomeScreen (recording):
  ↑ 0.2 KB/s   ↓ 1.4 KB/s   🔗 23   ⚡ ru.tinkoff  1h 12m
                                       ↑
                            новый chip — short pkg name
                            tap всей строки → Stats.perApp

Stats TabBar (idle):
  [ Overview · Connections · Per-app ]

Stats TabBar (recording):
  [ Overview · Connections · Per-app ⚡ ]
```

Recording **продолжается независимо от UI**: можно уйти на HomeScreen, в другие настройки, свернуть приложение — singleton service пишет события дальше. Останавливается только:
- Manual ⏹ STOP
- Force-stop приложения (Android Settings)
- Device reboot
- Старт новой session (старая finalize'ится в completed ring-buffer)

## Use cases

### 1. «Tinkoff не открывается через VPN» (§045 incident)

1. Tinkoff → Per-app traffic profiler → ru.tinkoff.investing → ▶
2. Открыть Tinkoff Investments, дать ему сделать запросы
3. ⏹ STOP
4. **Domains** tab → видим список `*.t-bank-app.ru`
5. Строки с ⚠ → раскрыть → видим: domain `certs.t-bank-app.ru`, CNAME `*.trbcdn.net`, outbound `vpn-1 → 🇫🇮Финляндия`
6. Корень: CNAME-target на `.net` TLD не попадает в `ru-domains` rule_set, sing-box роутит через bypass-VPN
7. Решение: добавить `*.trbcdn.net` в `ru-direct` preset (или включить geoip-fallback из §045)

Раньше тот же flow занимал 30+ минут ручной работы со снапшотами `/state` / `/connections` / `/logs` + cross-reference по conn_id. С §044 — 30 секунд.

### 2. Privacy audit фитнес-трекера

1. Открыть фитнес-трекер → Per-app traffic profiler → выбрать его → ▶
2. Походить по экранам где собираются данные (workout, профиль)
3. ⏹ STOP
4. **Domains** tab — список доменов, отсортированный по объёму трафика
5. Заметили что-то незнакомое типа `analytics.tracker.com`? Skim'ните CNAME chain + outbound — куда это ушло?
6. Если решили блокировать — кнопка `[Add domain rule]` (post-MVP) → создаст inline rule с `domain_suffix + package_name + action: reject`

### 3. Debug медленного приложения

1. Per-app trace → app → ▶
2. Воспроизвести «медленный» сценарий
3. ⏹ STOP
4. **Domains** sorted by bytes — топ потребителей трафика
5. **IPs** — какие IP отвечают; ↗ → Domains → cross-reference с CDN
6. Anomalies (⚠ DNS timeout / RST early) — network-уровневые проблемы

### 4. Catalog для preset'ов RU-сервисов

Записать сессии «Сбер», «ВТБ», «Госуслуги», экспортировать каждый в JSON через Share. Из набора доменов в Domains tab → составить расширенный preset для ru-direct или новый bank-specific preset.

### 5. Dogfooding разработки L×Box

Когда сам L×Box себя ведёт странно — Per-app traffic profiler на `com.leadaxe.lxbox`. Видим, какие подписки fetch'аются, через какой outbound, есть ли DNS retry'и. Ускоряет TDD на VPN-flow'ах.

## Debug API

Все controls UI доступны через HTTP API (Bearer-token authenticated). Полная reference: [`docs/api/debug-api-reference.md`](../api/debug-api-reference.md).

```bash
TOKEN=357f5aacdf154419d2787ec61e3ad9f2
H="Authorization: Bearer $TOKEN"

# Start session
curl -s -H "$H" -H "Content-Type: application/json" \
  -d '{"package":"ru.tinkoff.investing","verbose":false}' \
  http://127.0.0.1:9270/profiler/start

# Active session meta (counts, duration)
curl -s -H "$H" http://127.0.0.1:9270/profiler/active

# Full session с domains+ips+events
curl -s -H "$H" "http://127.0.0.1:9270/profiler/session/<id>?include=domains,ips,events"

# List finished sessions
curl -s -H "$H" http://127.0.0.1:9270/profiler/sessions

# Stop
curl -s -X POST -H "$H" http://127.0.0.1:9270/profiler/stop

# Live SSE stream (для скриптов / external dashboards)
curl -s -N -H "$H" -H "Accept: text/event-stream" \
  http://127.0.0.1:9270/profiler/stream
```

SSE формат: `event: traffic_event\ndata: {...}\n\n`. Fire-and-forget — без `Last-Event-ID` reconnect mechanism (overkill для in-app single-user use case'а).

## Edge cases & limits

| Случай | Поведение |
|---|---|
| `find_process: false` в config'е | UI показывает «Process detection disabled in template». Юзеру нужно поправить `template`/`vars`. |
| Process detection миссит (webview/system process) | Profiler пытается inferred-attribution через prior DNS resolved IPs (10s window). Помечается `〽 inferred from prior DNS` в Live и Connections expanded. |
| Verbose toggle включается / выключается mid-session | Sing-box reload, active connections рвутся. UI warning при toggle — юзер решает. |
| Session events overflow (>50000 ev или >3h) | Drop oldest, counter `events_dropped` в meta JSON виден в UI footer (`· N dropped`). |
| Memory pressure | Max 6 sessions concurrent (1 active + 5 completed). Old auto-evict'ятся. |
| Sing-box reload mid-session | Auto-finalize partial DNS chains, session continues с новым conn-id space. |
| App force-stop / device reboot | Все in-memory sessions стираются. Persist принципиально не делается — экспортируйте через Share/Copy если нужно сохранить. |

## Что **не** делает (текущая версия)

- Не умеет inline создавать routing rules «Add to ru-direct» / «Block this domain» (запланировано на v1.7.x cycle, см. spec § Bonus actions).
- Не показывает HTTP-уровневые headers / URL'ы — только L4 (hostname:port). Это limitation sing-box'а — он работает на уровне SOCKS/TUN, не HTTP.
- Не делает differential capture (compare session A vs session B) — на будущих циклах.
- Не считает per-domain latency / RTT — только bytes & connection counts.
- TLS fingerprinting (JA3/JA4) — пока не интегрирован, sing-box capability в `outbound/uTLS` ещё не expose'ится.
