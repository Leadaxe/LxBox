# Diagnostics Playbook

Документ — справочник всех средств диагностики L×Box на тестовом устройстве + порядок работы при «X не работает» жалобе.

> **Дисциплина перед всем остальным:** прежде чем триггерить любую destructive op (`POST /action/reset-network`, reload, VPN restart, `PUT /config`, изменения storage) — **сохрани snapshot**. После reset state RAM-only потерян, и понять что именно деградировало уже нельзя. См. [`scripts/lxbox-diag.sh`](../scripts/lxbox-diag.sh) — one-command сборщик. Триггерить destructive только после **явного подтверждения** юзера.

---

## Quick start

```bash
# 1. Поднять wifi-adb (или USB)
./scripts/ensure-wifi-adb.sh

# 2. Снять полный snapshot — параллельно через все API + adb
./scripts/lxbox-diag.sh

# Сохраняет в /tmp/lxbox-debug-<datetime>/:
#   state.json / storage.json / config.json
#   core_logs.json / app_logs.json
#   profiler_live.json          (system-wide TCP/UDP/DNS events за окно)
#   device_ss_tcp.txt / device_ss_udp.txt
#   device_routes_main.txt / device_routes_all.txt / device_ip_rule.txt
#   device_addrs.txt / device_props.txt
#   device_logcat.txt
```

> ⚠️ §122 — **Clash API больше нет** (полный отказ, см. ниже). Соединения / группы / DNS теперь
> снимаются через профайлер (`/profiler/live`), а не через Clash `/connections`.

Читать в порядке:
1. `state.json` — что юзер видит (selected_group / active_in_group / last_error)
2. `profiler_live.json` — **где идёт трафик прямо сейчас**: TCP/UDP open/close + DNS resolve/fail
   по всем package'ам, с routing-цепочкой (`routingLine` / `outboundChain` / `detourChain`) per event
3. `core_logs.json` (отфильтровать `level: error|warning`) — что фейлит
4. `device_ss_tcp.txt` (state counts) — здоровье TCP-стека
5. `config.json` (route.rules + route.final + dns.rules) — как должно роутиться

---

## Endpoints — где что брать

### LxBox Debug API (`http://<phone>:9269`, adb-forward)

Дефолт — форвард 1:1: `adb forward tcp:9269 tcp:9269` (как в `scripts/lxbox-diag.sh` и
[debug-api-reference.md](api/debug-api-reference.md)). `scripts/install-apk.sh` форвардит на
хост-порт **9270** (чтобы не толкаться с singbox-launcher) — тогда `lxbox-diag.sh` надо звать с
`--port 9270`.

Auth: `Authorization: Bearer $TOKEN` (token в `vars.debug_token`, dev-token см. `project_dev_endpoints.md` memory).

| Endpoint | Когда использовать |
|---|---|
| `GET /ping` | sanity-check без auth |
| `GET /state` | Снимок HomeState: tunnel/group/active_node/traffic/last_delay/last_error |
| `GET /state/storage` | Полный `lxbox_settings.json` (sensitive scrubbed) — vars / server_lists / custom_rules / dns_options / ping_options |
| `GET /state/subs` | Подписки (с `?reveal=true` — clear URLs) |
| `GET /state/rules` | Custom rules + `srs_cached`/`srs_mtime` flags |
| `GET /state/vpn` | auto_start / keep_on_exit / battery-opt status |
| `GET /state/config_locked` | §037 — заперт ли auto-rebuild |
| `GET /device` | Android version / model / ABI / app version + build / core version (libbox / sing-box-lx) / VPN perm / uptime |
| `GET /config` | **Сохранённый** sing-box JSON (файл; §311 — при живом туннеле может ОПЕРЕЖАТЬ ядро: пересборка до рестарта) |
| `GET /config/pretty` | То же с indent:2 |
| `GET /config/running` | §311 — снапшот конфига **работающего ядра** (kernel SPEC 036, захват на старте). Re-marshal — сравнивать с `/config` только семантически. `409` = туннель down / ядро < lx.16-rc.3 / ещё не подтянут. Расхождение running↔saved видно по `running_config_length` vs `config_length` в `/state` |
| `GET /pool?tag=vpn-1-auto` | §208 — снапшот пула round_robin-группы: `{tag, count, slots:[{slot, tag, delay, alive}]}`. Какие N серверов в слотах сейчас + их пинг. Не-round_robin → `200 slots:[]`; туннель down → `409` (не пустой ответ — §209) |
| `GET /logs?source=core&limit=500` | Sing-box internal logs (требует `core_logs_enabled=true`) |
| `GET /logs?source=app&limit=300` | App-side warn/error |
| `GET /logs?source=core&q=tinkoff&level=error,warning` | Фильтрация по substring + level |
| `GET /diag/*` | §038 диагностика runtime'а (см. api/debug-api-reference.md) |
| `GET /diag/pprof?profile=P` | §207 — pprof-слепок живого ядра. `P` = `heap` (что держит память, `?query=gc=1` форсит GC) \| `allocs` \| `profile` (CPU, `?query=seconds=10`) \| `goroutine` (`?query=debug=2` — полные стеки). Туннель up. `.pb` → `go tool pprof`; `goroutine?debug=*` → текст |
| `POST /profiler/live/start` | Включить system-wide rolling-buffer (или тап START в Profiler tab) |
| `POST /profiler/live/stop` | Выключить |
| `GET /profiler/live?seconds=N` | §048 — **где идёт трафик сейчас**: system-wide events за окно N сек (TCP/UDP open/close + DNS resolve/fail всех packages, с routing-цепочкой per event). Требует предшествующий `live/start` |
| `GET /profiler/live/stream` | SSE stream system-wide events (live push) |
| `GET /profiler/live/unattributed` | §177 — недавние unattributed события (DNS fail без owner-UID и т.п.) |
| `GET /profiler/live/state` | `{recording, started_at, buffer_count, unattributed_count, banner_active}`. `buffer_count=0` при `recording=true` — события не приходят (профайлер пишет, но пусто) |

**Read-only safe.** Все остальные endpoints (`POST /action/*`, `PUT /config`, `PUT /settings/*`) — destructive, см. ниже.

### ~~Clash API~~ — УДАЛЁН (§122)

> **Clash API больше нет.** §122 — полный отказ от Clash HTTP: UI и диагностика ходят через libbox
> CommandClient (push-стримы из ядра), Clash-порт (`63130`/`9091`) больше **не открывается**.
> `ClashApiClient` выпилен из кода. Не пытайся форвардить/curl'ить Clash — канала нет.

**Чем заменено — таблица соответствия:**

| Было (Clash) | Стало |
|---|---|
| `GET /connections` (chains + rule per conn) | **Профайлер**: `GET /profiler/live?seconds=N` или вкладка **Conns** / **Live** в Stats. Каждое событие несёт `routingLine` (§181), `outboundChain` (`[rule, группа, …auto…, node]`) и `detourChain` (транспорт-хвост, напр. `["WARP"]`) |
| `GET /proxies` (`now` + per-node `history`) | CommandClient `groups`-стрим → `/state` (`active_node` / `last_delay`) и UI группы |
| `GET /proxies/<tag>/delay?url=` (ping) | `POST /action/urltest` (Debug API) или тап ping в UI |
| `GET /rules` (live-resolved) | `GET /config` → `route.rules` (как реально собрано ядром) |
| `GET /traffic` (SSE up/down) | CommandClient `status`-стрим → `/state` (traffic) |
| `GET /logs?level=info` (SSE) | `GET /logs?source=core` (Debug API) |

> **«Куда идёт TCP-трафик сейчас» теперь смотрится в профайлере** — он показывает то, чего нет в
> info-level sing-box логах (см. ниже про невидимый `direct-out`): routing-цепочку per соединение.

### ADB device-side

```bash
adb shell ss -tnp                    # TCP sockets с PID/UID
adb shell ss -unp                    # UDP sockets
adb shell ip route                   # main routing table
adb shell ip route show table all    # ВСЕ таблицы (sing-box auto_route ставит default в свою таблицу)
adb shell ip rule                    # policy-based routing rules
adb shell ip -4 addr                 # interfaces (wlan0/ccmni*/tun*)
adb shell getprop | grep dns         # Android system DNS settings
adb logcat -d -t 500                 # last 500 logcat lines (system-wide)
adb shell pm list packages           # installed packages (для package_name match validation)
adb shell dumpsys connectivity       # Network stack overall
adb shell dumpsys netstats --uid-detail   # Per-UID byte counters
adb shell dumpsys package <pkg> | grep -E "userId|uid"  # UID owner процесса (для package match debug)
```

### sing-box conn_id correlation

Sing-box логи имеют префикс `[<conn_id> <elapsed_ms>]`. Каждый сокет — свой `conn_id`. **DNS-запрос и TCP-соединение к тому же IP — РАЗНЫЕ conn_id** (DNS — один, TCP — другой).

Чтобы проследить жизненный цикл одного сокета:

```python
import json
es = json.load(open('core_logs.json'))
es = es if isinstance(es, list) else es.get('entries', [])
target = '<conn_id from interesting log line>'
for e in sorted(es, key=lambda x: x['ts']):
    if f'[{target} ' in e['message']:
        print(e['ts'][11:23], e['level'], e['message'])
```

Что внутри типичного TCP-сокета (info-level):
1. `inbound/tun[tun-in]: inbound packet connection from <client>` — пакет в tun
2. `inbound/tun[tun-in]: inbound packet connection to <dst>` — destination
3. `router: route ... → <outbound>` — routing decision (только если debug-level включён)
4. `outbound/<type>[<tag>]: outbound connection to <dst>` — outbound dial (только для НЕ direct-out)

⚠️ **`outbound/direct-out` info-уровень НЕ ПЕЧАТАЕТ** — direct connections в логах невидимы.
Чтобы увидеть direct-out (и любую) routing-цепочку — смотри **профайлер** (`/profiler/live` →
`outboundChain` / `routingLine`, или вкладка **Conns**), где для прямого соединения цепочка
заканчивается на `direct`.

> **§180/§044 — DNS и package-detection больше НЕ парсятся из core-лога.** Профайлер выпилил
> лог-листенер: DNS-резолвы приходят структурным стримом из ядра (`CcChannel.dnsQueries`), а не
> regex'ом по строкам `dns: exchanged …` / `router: found package name …`. Здоровье DNS смотрится
> в профайлере (события `dnsResolve` / `dnsFail` с доменом, dns-сервером (rc.10) и latency), не в
> логах. Строки `dns: exchanged` / `found package name` в core-логе могут ещё мелькать, но это
> **не** источник истины для диагностики.

---

## Анализ — что значит что

### TCP socket states (`ss -tnp`)

| State | Что означает | Что подсказывает |
|---|---|---|
| `ESTABLISHED` | Активный обмен | Здоровое соединение |
| `SYN-SENT` (висит) | Отправили SYN, нет SYN-ACK | Remote unreachable / DPI блок / firewall drop |
| `SYN-RECV` | Получили SYN, ждём ACK | Норма, transient |
| `FIN-WAIT-1` (много) | Мы отправили FIN, ждём ACK | Если **массово >100** — connections не закрываются нормально, peer не отвечает |
| `FIN-WAIT-2` | Получили ACK на наш FIN, ждём FIN от peer | Норма |
| `CLOSE-WAIT` | Peer закрыл, мы ещё не | Может быть application leak |
| `LAST-ACK` | Мы закрыли в ответ, ждём ACK на наш FIN+payload | Если **send-q > 0** — наш payload не подтверждён, **peer закрыл соединение до того как ack'нул payload** (typical TLS reject by remote) |
| `TIME-WAIT` | После закрытия, 2*MSL pause | Норма |

**Health-check counts:** `awk '{print $1}' device_ss_tcp.txt | sort | uniq -c`. Норма: ESTAB > 30, FIN-WAIT < 30, SYN-SENT < 5. Если ESTAB ≈ 3 + FIN-WAIT > 100 + SYN-SENT > 10 — серьёзная сетевая деградация (DPI / RST flood / VPN-нода умерла).

### DNS-резолвы (профайлер, §180)

DNS теперь смотрится в профайлере (`/profiler/live` или вкладка **Live**/**Conns** в Stats), а не
в логах: событие `dnsResolve` (успех) или `dnsFail` (провал) с доменом, dns-сервером (rc.10) и
latency. На сбойные резолвы без owner-UID — баннер unattributed (§177) + `/profiler/live/unattributed`.

| Событие / симптом | Причина |
|---|---|
| `dnsFail`, долгий wait (10-20s) до отказа | DNS-сервер не ответил (context deadline). Server unreachable, blocked, или маршрут к серверу мёртвый. Смотри `dnsServer` события и куда он detour'ится |
| `dnsFail` мгновенный, домен «нет адреса» | Negative DNS response от server'а; домен реально не существует или сервер цензурит |
| `dnsResolve`, latency 16-50ms | Здоровый резолв |
| `dnsResolve`, latency >500ms | Server overloaded / далеко по сети / частичные drops |

### App-logs warnings (`/logs?source=app`)

| Pattern | Источник | Что говорит |
|---|---|---|
| `errno=113 No route to host` | Dart httpClient / UpdateChecker | Outbound маршрут к remote сломан. Если на public-internet IP — VPN-выход не работает |
| `errno=111 Connection refused` | То же | TCP RST от peer, или promediator (DPI) |
| `urltest <outbound> → timeout/err` | CommandClient urltest (ping) | Outbound не отвечает на ping URL — кандидат «эта нода умерла» |
| `[debug-api] ... → 4xx/5xx` | Internal Debug API call | API ошибка приложения; смотреть на endpoint |

### Sing-box routing decision (если debug-логи)

Если `core_logs_enabled=true` и в template `log.level: debug` (или DebugScreen toggle) — sing-box печатает каждое routing decision: `router: route ... matched ... → <outbound>`. Без debug — только `info`-уровень: `outbound: ...` (для НЕ-direct). Для итоговой routing-цепочки per соединение лучше профайлер (`routingLine` / `outboundChain`), он не зависит от log-level.

Чтобы временно включить — App Settings → Diagnostics → `Forward sing-box logs` (требует force-stop приложения).

### Routing rule precedence

Sing-box matches **первым попавшимся правилом** (top-down):

```
[0] resolve  (action — DNS resolve config для tun)
[1] sniff    (action — извлечение SNI/HTTP host)
[2] hijack-dns (DNS пакеты в DNS pipeline)
[3..N] custom rules (по rule_set / domain / process / package / port / ip_is_private / protocol)
[final] default outbound для unmatched
```

⚠️ **Sniff race:** правила с `domain_suffix`/`domain_keyword` зависят от sniffed SNI/HTTP host. `sniff timeout: 1s`. Если соединение установилось но ClientHello не пришёл за 1s → sniffed_domain пустой → правило промахивается → fall through.

⚠️ **Package detection race (Android):** правила с `package_name` требуют owner-UID detection через `NetworkStatsManager.queryDetailsForUidTagState()` или `/proc/net/tcp6`. На Android 12+ есть restrictions. Для коротких/transient TCP-сокетов lookup может опаздывать → правило silently skip → fall through.

⚠️ **Lesson learned (2026-05-08):** ru.tinkoff.investing trafic к `*.t-bank-app.ru` мог попадать в `final` (vpn-1 = Польша) если **оба** sniff и package detection провалились. `Ru Apps` rule с package_name не гарантирован для всех TCP-сокетов. **Mitigation:** лучше всегда добавлять явные `domain_suffix` в `ru-direct` preset для критичных доменов.

---

## Common diagnostic flows

### «X сайт/приложение не открывается»

1. `/state` — что тоннель up? Active node живой (`last_delay[<active_in_group>] != -1`)?
2. `/profiler/live` (или вкладка **Conns**) — есть ли active connection для домена X? Через какой `outboundChain`?
3. Если **нет соединения** к ожидаемому IP → значит до TCP не дошло:
   - DNS fail? В `/profiler/live` ищи событие `dnsFail` по домену X (vs `dnsResolve`)
   - Если DNS ok → значит app не делает TCP — возможно сидит в очередях, ждёт другой backend
4. Если **есть, но `outboundChain` неожиданный** (например через bypass-VPN вместо `direct`) → routing match не тот:
   - `config.route.rules` — какое правило должно матчить?
   - Sniff race / package race / domain не в rule_set → fall to final
5. Если соединение **в LAST-ACK / FIN-WAIT с send-q > 0** → backend rejected (TLS/GeoIP/firewall) — fix routing
6. Если массово SYN-SENT застряли → outbound нода мертва или DPI блокирует — переключить selector

### «Долгий idle → DNS не работает / соединения висят»

1. Снять snapshot **сразу**, до любых reset/reload — сначала `./scripts/lxbox-diag.sh`, destructive-op только после явного подтверждения (см. секцию «Что **НЕ делать**» ниже)
2. `/profiler/live` — какие домены дают `dnsFail` (и через какой `dnsServer`)? Плюс `core_logs?level=error,warning` для контекста
3. `config.dns.servers` — какой server обслуживает эти домены (по `dns.rules`)?
4. Этот server — UDP или DoH/DoT?
   - **DoH/DoT** — есть persistent TLS-pool, может «слипнуться» после long idle. `POST /action/reset-network` его лечит (предложить юзеру).
   - **UDP** — stateless, pool ломаться нечему. Симптом другой:
     - **DNS-cache stuck** (negative cache) — reset тоже лечит
     - **In-flight deadline lock** — sing-box state issue, reset помогает
     - **Real network block** — reset не поможет, надо менять server / detour

### «Какой-то selector переключился сам / not matching expected»

1. `/state` (`active_node` per group) — какая нода выбрана в каждом selector'е?
2. `POST /action/urltest` (group или node) — реально работает?
3. `state.last_delay` history — был ли auto-test?
4. `/state/storage` `vars.dns_final` / `route_final` — что в storage'е выбрано?
5. Если group-default `✨auto` (URLTest) — он сам выбирает по ping; смотри historical delays per-node

### «Нода живая, а пинг −1» — методика замера живости (§305)

Замер врёт чаще, чем узел умирает. В §305 вывод «MASQUE h3 мёртв — 1 живая из 62»
оказался артефактом измерения: после корректного прогона h3 отвечает на всех 7
портах. **Прежде чем объявлять ноду мёртвой — проверь, чем её мерили.**

| Способ | Годен | Почему |
|---|---|---|
| `POST /folders/{id}/probe` при **остановленном** VPN (headless §236) | только TCP | headless probe-сессия **не поднимает QUIC** → все h3/QUIC-ноды дают 0 живых (ложь). h2/TCP при этом меряется нормально |
| `POST /folders/{id}/probe` при **запущенном** VPN | нет | отказывает: `probe failed to start: __vpn_running__` (два CommandServer на процесс невозможны) |
| `rebuild-config` + `urltest` **без reconnect** | нет | ядро продолжает работать на старой сессии → живые ноды дают `-1` |
| `rebuild-config` → **`/action/reconnect`** → `urltest` **по одной** | **да** | единственный достоверный путь |

Порядок для честного замера:

```bash
# 1. ноды уже в папке → вложить в боевой конфиг
curl -X POST -H "$HDR" "$BASE/action/rebuild-config"
# 2. ОБЯЗАТЕЛЬНО: ядро должно перечитать конфиг
curl -X POST -H "$HDR" "$BASE/action/reconnect"
# 3. пинговать ПО ОДНОЙ (mass-ping даёт ложные -1 у QUIC: хендшейки конкурируют)
curl -X POST -H "$HDR" "$BASE/action/urltest?tag=$(enc '<тег ноды>')"
sleep 6
curl -s -H "$HDR" "$BASE/state" | jq '.last_delay["<тег ноды>"]'
```

Живая карта MASQUE-эндпоинтов (какие IP/порты вообще должны отвечать) —
в [spec/tasks/305](spec/tasks/305-masque-endpoint-h2-pool-and-override.md).

### «Load balance: трафик идёт не туда / перекос в один сервер» (§208)

1. `/config` → `balancer` у `<tag>-auto`: `mode=round_robin`? `pool`/`pool_tolerance`/`sticky_hash` те, что ожидаешь?
2. `/pool?tag=<tag>-auto` → состав слотов сейчас: 4 разных живых узла или дубли/мёртвые (`delay:0`)? Сними несколько раз — слоты держат номера, узлы меняются только при замене.
3. Включи `/profiler/live/start`, нагенери трафик, `/profiler/live?seconds=120` → посчитай `outbound_chain[0]` по узлам: должно быть ~равномерно по слотам (с дефолтным sticky `process+domain` один домен держится на одном узле).
4. Перекос «всё в один узел» был багом ядра rc.14 (пустой sticky `domain`) — фикшен в rc.15. С `dest_ip` в sticky-ключе домен с round-robin DNS (CDN) законно размазывается по узлам — это не баг.
5. `pool_tolerance>0` агрессивно переселяет слоты при колебаниях delay → ключи слота легально переезжают на новый узел (SPEC «реконнект для слота, чей жилец сменился»). Для чистого теста липкости — `pool_tolerance=0` (пул не вытесняет живых).

### «VPN не запускается, status сразу Stopped с alert»

§050 — sing-box не стартует когда config содержит `wifi_ssid:`/`wifi_bssid:` правила, но Android permissions не выданы.

1. `/state` → `last_error` начинается с `Stopped: alert:permission_location:` — это structured alert от `BoxService.startSingbox` (port из reference SagerNet).
2. После двоеточия — comma-list missing permissions, типичный набор:
   - `android.permission.ACCESS_BACKGROUND_LOCATION` — runtime grant **только через Settings** на API 30+ (не runtime prompt)
   - `android.permission.NEARBY_WIFI_DEVICES` — API 33+; **обязательный** для real SSID когда `targetSdk≥33`. Без него `WifiInfo.ssid` = `"<unknown ssid>"` → wifi rules не матчатся silently
3. Проверка current state:
   ```bash
   adb shell dumpsys package com.leadaxe.lxbox | grep -E "granted=" | grep -iE "location|nearby"
   ```
4. Lечение: либо grant через Flutter dialog (есть кнопка `Allow Wi-Fi info` для NEARBY one-tap + `Open Settings` для BACKGROUND_LOCATION), либо `adb shell pm grant com.leadaxe.lxbox android.permission.NEARBY_WIFI_DEVICES` для quick test
5. Альтернативно — убрать wifi rules из config'а. Если `cs.needWIFIState() == false`, permission-check skip.

**Диагностический флаг**: в logcat при successful startup увидишь `BoxService: [vpn] sing-box uses WIFI state, all permissions granted: [...]`. При failure — `BoxService: [vpn] config requires WIFI state but missing: [...]`.

### «`<unknown ssid>` в wifi rules»

Если в logcat видишь `PIW: readWIFIState: <unknown ssid>` (debug log из [PlatformInterfaceWrapper](../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/PlatformInterfaceWrapper.kt:139)) — значит permission grants есть (нет SecurityException), но `WifiInfo.ssid` вернул `"<unknown ssid>"`. На Android 13+ это означает **отсутствие `NEARBY_WIFI_DEVICES`** даже если ACCESS_FINE_LOCATION granted (Google разделил wi-fi info и location в API 33). Действие: добавить `NEARBY_WIFI_DEVICES` в Manifest + grant через runtime prompt.

### «VPN сам отваливается / "Another VPN app took the system VPN slot"»

Android держит **ОДИН** VPN-слот. Этот текст (§224/§276) = системный `VpnService.onRevoke()`, а его Android адресует **только** когда слот перехватил другой `VpnService`. Саморевок исключён (§224: один `ServiceRecord` без `android:process`; fd закрывается синхронно до разблокировки Dart). Смерть процесса по LMK даёт `SIGKILL` — Java-код не исполняется, broadcast не уходит, `START_NOT_STICKY` не рестартит → туннель пропал бы **молча, без этой строки**. Раз строка есть — перехватчик реален, ищем его.

1. **Кто владеет слотом прямо сейчас** — единственный надёжный источник:
   ```bash
   adb shell dumpsys vpn_management | grep -iE "Active package|VpnTransportInfo|session"
   ```
   `getOwnerUid()` из приложения недостижим (`@hide`, privacy by design) — поэтому в UI имя не показываем, а даём кнопку «VPN settings» (§241): на системном экране активный VPN помечен как Connected.
2. **Хронология захвата** (кто и когда поднялся):
   ```bash
   adb shell dumpsys usagestats | grep -iE "FOREGROUND_SERVICE_START|DEVICE_STARTUP|USER_UNLOCKED"
   ```
3. **Типичные перехватчики:**
   - второй VPN-клиент с **Always-on / kill-switch** — переустанавливает туннель по таймеру/смене сети → выглядит как «падает раз в N минут»;
   - **автозапуск при загрузке** у чужого VPN. Грабля (кейс v2rayNG, §241): BOOT_COMPLETED откладывается Direct Boot'ом до USER_UNLOCKED, захват приходит через ~1-2 мин после разблокировки → читается как «VPN сам упал спустя минуту», а не как boot-гонка. Настройка называется не «автозагрузка», а «Автоподключение при запуске» (`pref_is_booted`);
   - **Samsung Secure Wi-Fi** (`com.samsung.android.fast`) — встроенный VpnService, умеет включаться сам на Wi-Fi;
   - на слабых устройствах LMK убивает **чужой** VPN, тот рестартует по своему auto-start и забирает слот — LMK тут триггер, но ревокер всё равно чужое приложение.
4. Наш pre-check `isForeignVpnActive()` (§211) ловит только занятый слот **перед** ручным стартом — перехват в уже работающей сессии он не видит по определению.

### Workflow при незнакомом баге

1. `./scripts/lxbox-diag.sh` (или вручную параллельно)
2. Юзеру: «снимок сделан, можешь продолжать пользоваться. Что именно не работает — название домена / приложения / времени когда сломалось?»
3. Анализ snapshot'а (без trigger'ов на устройстве)
4. Если 1 цикла мало — попросить юзера ещё раз воспроизвести, снять второй snapshot, **diff'ить**

---

## Что **НЕ делать** в диагностике

> Все эти операции уничтожают runtime evidence. После выполнения root cause часто становится непостижим.

| Op | Что портит | Когда можно |
|---|---|---|
| `POST /action/reset-network` | DNS cache, active connections, transport state | После snapshot'а + явного «делай» от юзера |
| `POST /action/rebuild-config` | active connections (close), routing decisions | По требованию юзера |
| Reload via UI button | Same as reset-network | По требованию юзера |
| `POST /action/stop-vpn` / start-vpn | tun teardown, RAM state | По требованию юзера |
| `PUT /config` | Live config заменяется, не gracefully | Только в эксперименте, заранее `config_locked=true` |
| `PUT /settings/*` | Меняет storage в рантайме → может triger rebuild | Если меняем для теста — заранее `config_locked` |
| `adb shell am force-stop com.leadaxe.lxbox` | Полный wipe RAM | После snapshot'а |

**Auto-rebuild safety:** если хочешь экспериментировать с config через `PUT /config` — сначала `PUT /settings/config_locked {"locked": true}`. Тогда любые UI-trigger'ы rebuild'а silently no-op'нутся (§037), и твой custom config не будет перетёрт.

---

## Расширения (when you need more)

- **tcpdump / packet capture** — если нужно видеть TLS ClientHello, RST'ы, MTU issues. Требует root (или редкие debug-builds Android'а).
- **Sing-box debug-level** — `vars.log_level = debug` + force-stop. Печатает каждое routing decision и dial event. Сильно увеличивает log volume.
- **Per-app routing testing** — `adb shell am start -n <activity>` запустить целевое приложение по щелчку, в момент запуска снимать ss + `/profiler/live`.
- **`adb shell ping`** — обычно blocked без рута. Используй `POST /action/urltest` (urltest нод/групп через ядро) вместо.
- **pprof — нагрев CPU / утечки памяти ядра (§207)** — для deep-диагностики runtime'а sing-box. Туннель должен быть up.
  ```bash
  TOKEN=...   # forward 9269 на телефон
  H="Authorization: Bearer $TOKEN"
  # CPU-профиль (10с) — busy-spin / 100% CPU
  curl -s -H "$H" "http://127.0.0.1:9269/diag/pprof?profile=profile&query=seconds=10" -o cpu.pb
  go tool pprof -top cpu.pb
  # Heap (что держит память сейчас, gc=1 форсит GC)
  curl -s -H "$H" "http://127.0.0.1:9269/diag/pprof?profile=heap&query=gc=1" -o heap.pb
  go tool pprof -inuse_space -top heap.pb
  # Goroutine-стеки (утечка горутин) — отдаёт текст, не .pb
  curl -s -H "$H" "http://127.0.0.1:9269/diag/pprof?profile=goroutine&query=debug=2"
  ```
  Или из UI: App Settings → Diagnostics → Profiling (кнопки + системный Share).

---

## Reference

- [Debug API reference](api/debug-api-reference.md) — полный список endpoints (вкл. destructive)
- [STORAGE.md](STORAGE.md) — что внутри `state/storage` snapshot'а
- [TEMPLATE.md](TEMPLATE.md) — как читать `wizard_template.json` для понимания где какие vars / preset / DNS-server'а определены
- [spec/tasks/305 — MASQUE endpoint](spec/tasks/305-masque-endpoint-h2-pool-and-override.md) — device-verified карта живых WARP-MASQUE IP/портов (h3 против h2) + таблица «чем мерить живость нод»
- [scripts/lxbox-diag.sh](../scripts/lxbox-diag.sh) — автоматический сборщик snapshot'а
- [scripts/ensure-wifi-adb.sh](../scripts/ensure-wifi-adb.sh) — поднять wifi-adb (USB → tcpip 5555)
- [scripts/install-apk.sh](../scripts/install-apk.sh) — install + auto-forward Debug API
