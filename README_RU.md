# L×Box

[![GitHub](https://img.shields.io/badge/GitHub-Leadaxe%2FLxBox-blue)](https://github.com/Leadaxe/LxBox)
[![License](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Version](https://img.shields.io/github/v/release/Leadaxe/LxBox?label=version)](https://github.com/Leadaxe/LxBox/releases)
[![Dart](https://img.shields.io/badge/Dart-3.11%2B-blue)](https://dart.dev/)

Android-клиент на ядре [sing-box-lx](https://github.com/Leadaxe/sing-box-lx) — форке [sing-box](https://sing-box.sagernet.org/) с AmneziaWG 2.0 и нативным XHTTP — для гибкой маршрутизации сетевого трафика, предназначенный для сетевых специалистов различного уровня подготовки. Мульти-подписки, умные правила, встроенный тест скорости.

**[Скачать последний релиз](https://github.com/Leadaxe/LxBox/releases/latest)** | **[English README](README.md)**

---

## Скриншоты







---

## Возможности

**Серверы и подписки** — управление источниками прокси

Добавляйте серверы по URL подписки, прямой ссылке, WireGuard URI/INI, Amnezia `vpn://`-ссылке или raw sing-box JSON outbound. Умный диалог вставки определяет формат автоматически и показывает превью. Включение/отключение подписок без удаления. Офлайн-rehydrate — ноды восстанавливаются из кеша тела при старте app. Per-subscription настройки detour серверов.

- **10 протоколов**: VLESS, VMess, Trojan, Shadowsocks, Hysteria2, **TUIC v5**, **NaïveProxy**, SSH, SOCKS, WireGuard (вкл. **AmneziaWG / AWG 2.0** — `awg://` URI, AmneziaWG `.conf`, **Amnezia `vpn://`-ссылки** (v2.0.3), JSON)
- Форматы: Base64, Xray JSON Array (chained proxy), plain text, raw sing-box JSON
- Per-subscription picker **Update interval** (1/3/6/12/24/48/72/168h), учитывает заголовок `profile-update-interval`
- Subtitle в строке подписки: `124 nodes · 🔄 24h · 🕐 3h ago · (2 fails)`
- Fallback имени из `Content-Disposition: filename=...` (RFC 5987)
- Быстрый старт с комьюнити-курируемой подборкой тестовых серверов
- **Get WARP** — Cloudflare WARP в один тап: регистрирует устройство в Cloudflare и добавляет готовый WireGuard-узел

**Get WARP** — Cloudflare WARP в один тап, ключи генерятся на устройстве

Пункт **Get WARP** в overflow-меню Servers → регистрируется WireGuard-туннель к Cloudflare и добавляется как узел. Без копипасты конфигов с чужих сайтов-генераторов.

- **Регистрация на устройстве**: приватный X25519-ключ генерится на телефоне и НЕ покидает его — в Cloudflare (`api.cloudflareclient.com`) уходит только публичный ключ. Не используем чужие воркеры-генераторы (они отдают приватник, сгенерированный на их сервере).
- **WARP+** (опционально): вставьте license key под *Advanced* для привязки WARP+ (Argo Smart Routing). Пусто = free WARP.
- **Идемпотентность**: повторный тап переиспользует закешированный аккаунт, а не плодит регистрации; *Re-register* создаёт новый.
- Кастомный endpoint под *Advanced* (рабочий `IP:port`, если дефолтный заблокирован).
- См. [спека 025](docs/spec/features/025%20warp%20integration/spec.md)

**Автообновление подписок** — 4 триггера, жёсткие гейты против спама

Подписки обновляются в фоне без спама провайдерам. Каждый запрос зажат в рамки, процессов в свободном полёте нет.

- **Триггеры**: запуск app · через 2 мин после активации туннеля · раз в час · сразу по остановке туннеля · manual ⟳ (force)
- **Gates**: `minRetryInterval=15min` (persisted через `lastUpdateAttempt`), `maxFailsPerSession=5` (in-memory, размораживается на рестарт app), `10s ± 2s` между подписками, `_running`/`_inFlight` dedup-флаги, `inProgress` guard от двойных кликов
- Crash-safe init sweep: зависший `inProgress` на диске сбрасывается в `failed`
- Rebuild config **никогда** не триггерит HTTP — только локальная сборка из загруженных nodes
- См. [спека 027](docs/spec/features/027%20subscription%20auto%20update/spec.md)

**Главный экран** — подключение и управление нодами

Запуск/остановка туннеля одним нажатием с анимированным статусом. Выбор группы прокси, сортировка нод по пингу/имени/вручную, массовый пинг. Панель трафика с реалтайм скоростью, соединениями и аптаймом.

- **Разметка строки ноды** (v1.3.1+): `[ACTIVE зелёная] ПРОТОКОЛ · · · 50MS →` — лейбл протокола (VLESS/Hy2/WG/TUIC/SS) из типа outbound'а, ping справа с цветом по latency
- **Подзаголовок ноды `ПРОТОКОЛ · транспорт · security`** (v2.0.0): `VLESS·xhttp·TLS`, `VLESS·tcp·Reality+Vision`, `WG·awg2` — видно, что внутри ноды, не открывая JSON
- **Filter workspace** (v2.0.0): фильтр-панель с табами **Regex · Protocol · Subscribes · Settings** + сводка активных фильтров чипами; у каждой категории своя `!`-инверсия (NOT); строка чипов по транспорту/безопасности (`tcp`/`ws`/`grpc`/`h2`/`httpupgrade`/`quic`/`xhttp` + `TLS`/`Reality`/`+Vision`/`awg`/`awg2`); фильтры запоминаются per-channel
- **Detour-фильтр — tri-state** (v2.0.0): показать всё / скрыть detour / **только detour** (чистый список релеев для диагностики)
- **Персистентная сортировка Custom** (v2.0.0): ручной порядок выбирается из меню сортировок и tap-карусели (Default → Ping → A-Z → Custom), переживает рестарт; подписки перетаскиваются за grab-strip
- Группы прокси: `auto-proxy-out`, VPN ①/②/③
- Фильтр нод: выбор участников автоподбора
- Sticky restart warning под Stop — не пропадает при отмене Stop-диалога
- Long-press: Ping · Use this node · View JSON · **Copy URI** (vless://, awg://, …) — действия Copy-JSON живут внутри диалога View JSON (Copy server / Copy detour / Copy server + detours(N))

**Quick Connect** — toggle VPN без открытия app'а (v1.5.0)

Два пути включить/выключить VPN не открывая приложение:

- **Плитка в шторке** — потяни статус-бар → редактирование → перетащи **L×Box**. Тап = on/off, плитка показывает live-статус (`Connected` / `Disconnected` / `Connecting…` / `Stopping…`). Добавить через App Settings → General → Quick connect → `Add` (на Android 13+ системный prompt, на старых — текстовая инструкция).
- **Long-press на иконку app'а** на хоум-скрине → пункт **Toggle VPN**.
- Первый раз tile/shortcut коротко открывает приложение ради системного VPN consent-диалога (`VpnService.prepare(...)` — Activity-only API). Toast объясняет почему. После consent activity закрывается сама — обычный flow без UI-вспышки.
- Tile переживает OOM-kill сервиса: `currentStatus` сбрасывается в `onDestroy` чтобы не показывать «Connected» когда сервиса больше нет.

**Маршрутизация** — единая модель правил (v1.4.0)

Блокировка рекламы, прямая маршрутизация для .ru доменов, BitTorrent через прокси, per-app, матчинг приватных IP. Все пользовательские правила — единый `CustomRule` со всеми match-полями параллельно (OR внутри категории, AND между — per sing-box default rule formula).

- **3 вкладки**: Channels (proxy groups) · Presets (read-only каталог → Copy to Rules) · Rules (твой реестр)
- **Match-поля**: domain, domain_suffix, domain_keyword, ip_cidr, port, port_range, packages (per-app), protocols (tls/quic/bittorrent/…), ip_is_private, remote .srs rule-set
- **SRS только локально** — никаких авто-обновлений, ручное скачивание через ☁, правило заблокировано пока нет кэша
- **Drag-reorder** + **long-press → Delete с подтверждением**
- **Params / View табы** в редакторе — View показывает готовый sing-box-фрагмент конфига
- **Dirty-aware save** — back с несохранёнными → диалог "Discard changes?"
- Fallback для нераспознанного трафика (`route.final`)
- См. [спека 030](docs/spec/features/030%20custom%20routing%20rules/spec.md), [спека 011](docs/spec/features/011%20local%20ruleset%20cache/spec.md)

**Балансировка нагрузки** — раскидать трафик по пулу серверов (v2.7.0)

Auto-группа канала умеет не только выбирать один быстрейший узел, но и **раскидывать соединения по пулу** из N серверов (round-robin), сохраняя при этом липкость сессий — TLS/авторизация не прыгают между IP.

- **Два режима** в редакторе канала → *Include auto*:
  - **Fastest** (`least_test`) — один лучший узел по latency, весь трафик через него (классика)
  - **Load balance** (`round_robin`) — соединения ротируются по пулу фиксированного размера из живых узлов
- **Pool size** — сколько узлов в пуле одновременно; **Pool tolerance** — `0` держать пул живых (скорость неважна), `>0` вытеснять медленные в пользу быстрых
- **Sticky session by** — ряд чипов (`process` / `domain` / `source ip` / `dest ip` / `dest port`); ключ вроде `process + domain` сажает все соединения одного приложения к одному сайту на **тот же** сервер пула (ноль реконнектов пока узел жив). Снять все чипы → чистая ротация без липкости
- **View pool** — long-press по auto-ноде → попап с живым пулом: фиксированные `слот · узел · delay`, видно какие именно N серверов сейчас тянут трафик
- На базе sing-box-lx **SPEC 019** (фиксированные слоты, ленивый health-check, slot-hash липкость — без per-connection состояния). Билдер пишет блок `balancer{}` только под round_robin; Fastest остаётся бит-в-бит апстримом
- См. [§208 spec](docs/spec/tasks/208-urltest-balancer-round-robin.md)

**Detour серверы** — цепочки прокси для приватности

Multi-hop цепочки: трафик идёт через промежуточный сервер перед финальным прокси. Полезно при работе в сетях с гео-ограничениями на уровне провайдера или локали: поставьте домашний WireGuard как detour → заграничный мобильный интернет превращается в тоннель к дому.

- Добавил свой сервер (paste URI / paste JSON / WG INI) — он становится кандидатом для detour
- **Mark as detour server** switch в Node Settings — добавляет префикс `⚙` 
- **Override detour** per-subscription: маршрутизирует все её ноды через ваш сервер
- Register / Use toggles для detour-серверов из подписок
- Detour dropdown в Node Settings persist'ит через `overrideDetour` (без JSON roundtrip drift'а)

**Настройки DNS** — полный контроль резолвинга

16 пресетов DNS (Cloudflare, Google, Yandex, Quad9, AdGuard) с UDP/DoT/DoH вариантами. Кастомные серверы через JSON. Стратегия, кэш, правила.

- Включение/отключение серверов переключателями
- Стратегия DNS: prefer_ipv4 / prefer_ipv6 / ipv4_only / ipv6_only
- Редактор правил DNS, DNS Final, Default Domain Resolver
- Bundle-пресет "Russian domains direct" (spec 033) — self-contained правило `.ru/.su/.рф/.рус/.москва/.moscow/.tatar/.дети/.онлайн/.сайт/.орг/.ком` + свои Yandex DNS-серверы + переменные `@out`/`@dns_server`

**Устойчивость соединений** — совместимость с packet inspection

Три ортогональных параметра тюнинга TLS-handshake — комбинируются на одном outbound.

- **TLS Fragment** — разбивает ClientHello по TCP-сегментам
- **TLS Record Fragment** — разбивает handshake на несколько TLS-записей
- **Mixed-case SNI** (v1.3.0+) — рандомизирует регистр `server_name` (`WwW.gOoGle.CoM`). Повышает совместимость с системами инспекции пакетов, использующими exact-match по SNI. По RFC 6066 поле case-insensitive — сервер обрабатывает любой регистр без изменения поведения. Менее эффективно против систем с нормализацией.
- Все параметры применяются только к первому хопу (внутренние хопы идут внутри туннеля и не требуют дополнительной обработки).

**Haptic feedback** — вибро на события туннеля

Короткая вибрация на состояниях туннеля, ошибках и тапах. Респектит системную настройку Android Touch feedback.

- Tap Start/Stop → лёгкий tick
- Туннель активирован → средний impact; user disconnect → лёгкий
- Revoked / heartbeat fail (только **первый**, не на каждый tick) → тяжёлый
- Manual subscription fetch success/fail → лёгкий/средний
- Авто-триггеры не вибрируют; throttle 100 мс защищает от спама
- Toggle в App Settings → Feedback (default **on**)
- См. [спека 029](docs/spec/features/029%20haptic%20feedback/spec.md)

**Тест скорости** — измерение соединения

Встроенный тест скорости с 10 серверами по всему миру. Per-server пинг к конкретному серверу скачивания. Параллельные потоки, upload тест, история за сессию.

- Серверы: Cloudflare, Hostkey (5 городов), Selectel, Tele2, OVH, ThinkBroadband
- Настраиваемые потоки (1/4/10), upload method per server
- История с именем сервера

**Статистика и соединения** — что происходит

Реалтайм трафик по outbound с раскрывающимися карточками. Каждое соединение: хост, протокол, правило, трафик, длительность, цепочка прокси, имя приложения. Закрытие отдельных соединений.



**Per-app traffic profiler** — трассировка сети любого приложения в реальном времени (v1.7.0)

Выбираете app, тапаете ▶ Record — видите все домены, IP и решения роутинга: какой CDN использует ваш банк, через какую ноду уходит, не утекает ли трафик через «не тот» VPN. Встроенный anomaly-detection помечает подозрительные geo-mismatch'ы.

- **Stats → Per-app tab**: app picker, [▶ START] / [⏹ STOP], строка статуса `Recording 02:34 · 47 doms · 53 ips · 287 ev`
- **4 sub-tab'а**:
  - **Live** — newest events first (DNS resolves с CNAME chain'ом · TCP/UDP open/close), monospace IP `↗` chip переходит на Domains
  - **Domains** — aggregated unique domains, sortable; expanded view = CNAME targets, all resolved IPs, outbounds, anomalies. Search-поле матчит по `domain` || `ip` || `cname target` (cross-domain CDN-аудит)
  - **IPs** — aggregated по destination IP (порты, conn count, bytes, outbound). Каждая строка с `↗` для перехода в Domains с фильтром по этому IP
  - **Connections** — per-connection timeline. Тап по header → inline-expand: CNAME chain, all IPs, rule, anomalies, кнопка `[View in Domains →]` фокусит соответствующую aggregated row
- **Connection-issue detection (2 locale-агностичных типа)**: `dnsTimeout` (sing-box `dns: exchange failed` log — прямой engine-сигнал, не heuristic), `tcpReset` (TCP closed в течение 1s с 0 bytes — firewall RST / unreachable). ⚠ icon на Live row + Domain expanded view с описанием
- **Process inference** — когда sing-box `find_process` мисс'нул (rare, для WebView/system processes), profiler attribut'ит conn по resolved IP в окне 10s post-DNS; rows помечены `〽 inferred from prior DNS`
- **Recording indicators**:
  - HomeScreen `_buildTrafficBar` chip `⚡ <pkg>` рядом с traffic stats; тап по строке → `StatsScreen(initialTab: perApp)`
  - В StatsScreen у `Per-app` tab title красная иконка `⚡` пока идёт запись
- **Overflow menu (⋮)** в Per-app tab'е: Verbose core logs (debug-level, применяется на следующей session), Copy session JSON, Share, Clear all sessions, Help
- **In-memory only** — последние 5 finished sessions + 1 active. 3h sliding window на session + 50k events fallback cap. `force-stop` / kill app'а стирает всё (persist'а нет by design — diagnostic-only)
- **Debug API** (Bearer-auth, порт 9269): `POST /profiler/start {package, verbose?}` · `POST /profiler/stop` · `GET /profiler/active` · `GET /profiler/sessions` · `GET /profiler/session/<id>?include=events,domains,ips` · `DELETE /profiler/session/<id>` · `DELETE /profiler/sessions` · `GET /profiler/stream` (SSE, fire-and-forget)
- **Документация**: [user guide с use cases и curl-рецептами](docs/features/per-app-trace.md) · [§044 spec](docs/spec/features/044%20per-app%20traffic%20profiler/spec.md)



**Профилирование ядра (pprof)** — ловить нагрев CPU и утечки памяти (v2.7.0)

Когда ядро греется или течёт по памяти, снимите настоящий Go-**pprof** слепок прямо с устройства — без десктопа и пересборки. **App Settings → Diagnostics → Profiling**: каждая кнопка тянет профиль с живого ядра sing-box и открывает системный Share.

| Профиль | Что ловит |
|---|---|
| **CPU profile (10s)** | нагрев / 100 % CPU — busy-spin в tight-loop |
| **Heap (inuse_space)** | что реально держит память сейчас (GC форсится перед снимком → только живые объекты) |
| **Allocations** | что аллоцирует память (источник давления на GC) |
| **Goroutines** (summary / full stacks) | счётчик и полные стеки горутин — утечки горутин |

- `.pb`-файлы открываются `go tool pprof` (CPU/heap/allocs); `goroutine?debug=*` — текст. Heap inuse: `go tool pprof -inuse_space heap.pb`
- Реализовано целиком на стороне оболочки через встроенный в libbox `PProfServer` (Go `net/http/pprof`) — **ядро не правилось**. Сервер поднимается на loopback-порту по тапу, отдаёт один GET и гасится в `finally` (в проде listener не висит)
- Также через Debug API: `GET /diag/pprof?profile=heap|profile|allocs|goroutine&query=...` (нужен поднятый туннель)
- См. [§207 spec](docs/spec/tasks/207-goroutine-cpu-dump.md)



**Настройки ядра** — конфигурация маршрутизации

Организованы по секциям: General, Network, Include Auto, DNS, TUN, Connection Resilience. URLTest параметры для авто-подбора прокси. Все изменения автосохраняются.



**Редактор конфига** — для продвинутых

Просмотр и редактирование raw JSON конфига sing-box. Форматированное отображение с кнопкой копирования. Сохранение, вставка, загрузка, шаринг.



**Настройки приложения**

- Тема: Системная / Светлая / Тёмная
- Автозапуск туннеля при загрузке
- Туннель остаётся при закрытии приложения
- Авто-пересборка конфига при изменениях
- **Battery optimization** tile — статус + shortcut в системный whitelist (v1.4.0)
- **App info (OEM power settings)** с hint-диалогом для Autostart / Background activity (v1.4.0)
- **Auto-ping after connect** — пинг активной группы через 5s после подключения VPN (по умолчанию ON, v1.4.0)
- Haptic feedback toggle
- См. [спека 022](docs/spec/features/022%20app%20settings/spec.md)

---

## Поддерживаемые протоколы


| Протокол    | URI-схема                          | Транспорт                                      |
| ----------- | ---------------------------------- | ---------------------------------------------- |
| VLESS       | `vless://`                         | TCP, WebSocket, gRPC, H2, HTTPUpgrade, **XHTTP**, REALITY |
| VMess       | `vmess://` (v2rayN base64)         | TCP, WebSocket, gRPC, H2, HTTPUpgrade, **XHTTP** |
| Trojan      | `trojan://`                        | TCP, WebSocket, gRPC                           |
| Shadowsocks | `ss://` (SIP002 + legacy + SS2022) | TCP, UDP, SIP003-плагины                       |
| Hysteria2   | `hy2://` / `hysteria2://`          | QUIC, Salamander obfs                          |
| **TUIC v5** | `tuic://`                          | QUIC, BBR/CUBIC/NewReno, zero-RTT              |
| **NaïveProxy** | `naive+https://`                | Настоящий Chrome TLS через cronet, `extra-headers` |
| SSH         | `ssh://`                           | TCP, host key / password / private key         |
| SOCKS       | `socks://` / `socks5://`           | TCP, auth                                      |
| WireGuard / **AmneziaWG** | `wireguard://`, `awg://`, INI / `.conf`, **Amnezia `vpn://`** | UDP, multi-peer, **обфускация AWG 1.x/2.0** (jc/jmin/jmax, s1–s4, h1–h4 вкл. **диапазоны `N-M`**, i1–i5), авто-MTU 1280 |


**XHTTP** — нативный транспорт с v2.0.0 (Xray splithttp: `mode` auto/packet-up/stream-up/stream-one). С **v2.8.0** парсер ссылок поддерживает **полный клиентский набор полей**: настраиваемые placement'ы session/seq/uplink (path/query/header/cookie), ключи, метод upload, **X-Padding obfs-режим** (`repeat-x`/`tokenish`) и packet-up tuning — читаются из плоских query-параметров и из параметра `extra` (URL-encoded JSON). Работает с TLS и Reality, несовместим с XTLS-Vision (ограничение протокола).

Подробная документация: [docs/PROTOCOLS.md](docs/PROTOCOLS.md)

---

## Архитектура

L×Box построен вокруг **3-слойного parser/builder pipeline** (спека 026, v1.3.0+):

```
UI / Controller
  │
  ▼
parseFromSource(source)  ← HTTP fetch + body_decoder + типизированный parser
  │                         returns: List<NodeSpec>, meta, rawBody
  ▼
ServerList (sealed)      ← SubscriptionServers | UserServer
  │ .build(ctx)            применяет tagPrefix, detour policy, allocateTag
  ▼
buildConfig(lists, settings)  ← template + post-steps (resilience, DNS, rules)
  │                              returns: BuildResult{ config, validation, warnings }
  ▼
sing-box JSON
```

- **Bundled-ядро** (v2.0.0) — [sing-box-lx](https://github.com/Leadaxe/sing-box-lx) **`v1.14.0-lx.1-rc.16`**: форк sing-box 1.14, собранный с тегами `with_awg` / `with_xhttp` / `with_lx_command`; управляющий канал — libbox `CommandClient` (без Clash API). Добавлен round-robin **балансировщик** (SPEC 019) + RPC `GetPool`, и полный клиентский набор полей XHTTP (SPEC 002 v2, rc.16). Версия пинится в `app/android/libbox.version`, AAR скачивается из GitHub Releases форка скриптом `scripts/fetch-libbox.sh` с проверкой SHA256
- **Sealed `NodeSpec`** — 9 протоколов, полиморфный `emit(vars)` / `toUri()` (round-trip инвариант)
- `**EmitContext**` — пробрасывает шаблонные vars в per-node emit
- `**NodeEntries{main, detours[]}**` — именованный struct для chain-результатов
- `**ValidationResult**` — типизированные issues: dangling refs, empty urltest, invalid selector default

Полная картина: [Архитектура](docs/ARCHITECTURE.md).

---

## Разработка

Spec-driven development — 30 спецификаций фич в [docs/spec/features/](docs/spec/features/).


| Документ                                     | Описание                                                  |
| -------------------------------------------- | --------------------------------------------------------- |
| [Безопасность](docs/SECURITY.md)             | Модель угроз — защита от утечек (Unknown traffic / kill-switch), локальная поверхность атаки, секреты на устройстве |
| [Документация протоколов](docs/PROTOCOLS.md) | URI форматы, параметры, маппинг в sing-box                |
| [Архитектура](docs/ARCHITECTURE.md)          | 3-слойный pipeline, потоки данных, нативный bridge        |
| [Сборка](docs/BUILD.md)                      | Инструкции по сборке, CI, подпись APK, local-build marker |
| [Руководство](docs/DEVELOPMENT_GUIDE.md)     | Принципы, тестирование (167 тестов), организация спек     |
| [Список изменений](CHANGELOG.md)             | История релизов                                           |
| [Release notes](docs/releases/)              | Подробные заметки per-версия (EN + RU)                    |


### Локальная сборка

```bash
./scripts/build-local-apk.sh
```

Скрипт оборачивает `flutter build apk --release` с `--dart-define`'ами, которые подмешивают git describe. About screen показывает розовую плашку **🧪 LOCAL BUILD · N commits since vX.Y.Z** — чтобы отличать от CI-билдов.

---

## Безопасность

- **Только TUN inbound** — нет SOCKS5/HTTP прокси на localhost (защита от утечки IP)
- **Управляющий канал** — libbox `CommandClient` внутри процесса (без сетевого Clash API, без открытого порта/секрета)
- **VPN Service** не экспортирован (`android:exported="false"`)
- **Геомаршрутизация**: российские домены → direct (не через прокси)

---

## Лицензия

L×Box распространяется на условиях [GNU General Public License v3.0](LICENSE).

Коммерческая лицензия от Leadaxe возможна **только на собственный код Leadaxe в L×Box**. L×Box линкуется с [`libbox`](https://github.com/SagerNet/sing-box) (sing-box, GPLv3), поэтому собранный L×Box в любом случае остаётся под GPLv3 — коммерческая лицензия только от Leadaxe не делает L×Box пригодным для проприетарного продукта. Область применения и ограничения: [LICENSING.md](LICENSING.md). Запросы: [ledaxe@gmail.com](mailto:ledaxe@gmail.com).