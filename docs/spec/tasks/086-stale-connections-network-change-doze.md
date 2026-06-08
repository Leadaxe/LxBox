# 086 — Stale connections после смены сети / Doze (исследование)

| Поле | Значение |
|------|----------|
| Статус | Research — зафиксированы результаты изысканий; реализация **вне** этой таски |
| Дата | 2026-06-08 |
| Тип | investigation / root-cause |
| Метод | 2 multi-agent research-workflow (connection-level: 6 агентов; Doze/watchdog: 5 агентов). Факты верифицированы против нашего кода + sing-box source/docs + industry (SFA/SFI, NekoBox, Clash Meta, v2rayNG, Hiddify, shadowsocks-android, rethink, Tailscale). |
| Связанные | `DefaultNetworkMonitor.kt`, `BoxService.kt`, `box_vpn_client.dart::resetNetwork`, `clash_api_client.dart` (DELETE /connections), `wizard_template.json` (selector/urltest), §042 health watchdog. |

> **Назначение документа:** зафиксировать **только результаты исследования** —
> симптомы, root-cause, что есть в коде, варианты лечения с тем что они
> чинят/не чинят. Это не implementation-план; конкретная реализация —
> отдельной задачей.

## Симптомы (наблюдения юзера)

1. **Смена сети (WiFi↔LTE)** — соединения рвутся, страницы не грузятся; ручной
   пинг ноды частично оживляет (новое грузится, старое висит).
2. **После ночи / долгого простоя (deep Doze)** — «самое мерзкое»: пока не
   сделаешь полный **reset VPN**, ничего не грузит. Пинг — **рандом** (иногда
   оживляет, иногда нет).
3. Браузер «пробует засунуть пакеты в старое соединение» — висит до таймаута.

Это **два независимых failure mode**, симптом их смешивает.

---

## Failure mode 1 — Network-path staleness (смена сети). КОРЕНЬ НАЙДЕН

### Как должно работать (sing-box core)
В `route/network.go` ядро регистрирует `notifyInterfaceUpdate` → при смене
default-интерфейса вызывает `ResetNetwork()` → `connectionManager.CloseAll()`
— ядро **само** force-закрывает все живые соединения. На Android GUI-клиенте
platform interface monitor зарегистрирован всегда.

### Что делает наш native (gap)
`DefaultNetworkMonitor.kt` ловит смену сети (ConnectivityManager callback)
и вызывает `updateDefaultInterface(ifName, idx, false, false)` — **PASSIVE**
уведомление. libbox узнаёт про новый интерфейс, но **`resetNetwork()` НЕ
вызывается** → мёртвые сокеты не закрываются. Браузер ретрансмитит в них.

```
смена WiFi/LTE
  → DefaultNetworkMonitor ловит ✅
  → updateDefaultInterface(...) — passive
  → sing-box знает про новый интерфейс…
  → resetNetwork() / CloseAll() НЕ дёргается ❌  ← gap
```

### Что УЖЕ есть в коде (лечение написано, но не вызывается авто)
- **`resetNetwork()`** реализован: native (`BoxService` ACTION_RESET_NETWORK →
  `commandServer.resetNetwork()`) + Dart (`BoxVpnClient.resetNetwork()`).
  Делает «light recovery»: **closeAll connections + flush DNS + reset
  DoH/DoT/UDP transports + rebind**. Вызывается **только вручную** из Dart,
  не на смену сети.
- **Clash API `DELETE /connections`** полностью реализован:
  `ClashApiClient.closeAllConnections()` (DELETE /) + `closeConnection(id)`
  (DELETE /:id). Закрытие сокета → app получает RST → **мгновенно
  пересоздаёт**. (Внутри ядра DELETE / тоже зовёт ResetNetwork.)

### Почему ручной пинг — только наполовину (подтверждено source)
`clash.delay(tag)` (GET /proxies/:tag/delay) открывает **новое** тестовое
соединение → прогревает путь → **новый** трафик грузится. Но **существующие**
app-сессии висят на мёртвых сокетах до TCP-таймаута. `closeAll`/`resetNetwork`
шлёт сокетам Close → RST → пересоздание сразу. **Пинг = re-dial новых;
reset = убить старые.** Отсюда «новое грузится, старое висит».

### Почему `interrupt_exist_connections` не спасал
`interrupt_exist_connections: true` стоит на всех 4 группах
(`wizard_template.json:64,74,86,97`) — но per sing-box source он срабатывает
**только на смену ВЫБОРА outbound** (selector/urltest переключил ноду), **не
на смену сети**. Настроен правильно, но не про этот баг.

### Состояние конфига (факты)
- `interrupt_exist_connections: true` — все группы (для selection-change, ОК).
- `auto_detect_interface: true` (default) — outbound'ы ребиндятся на живой NIC
  (первая линия защиты; `default_interface` не пиннится — корректно, Android
  переименовывает `rmnet_data0→1`).
- **НЕТ** TCP keepalive / connect_timeout / idle-timeout нигде — sing-box
  defaults (`tcp_keep_alive` default 5m). Нет idle/dead-connection sweeper'а
  в sing-box вообще (только keepalive dial-поля).
- **НЕТ** `default_interface`/`default_mark` в route — sing-box инферит
  динамически.

---

## Failure mode 2 — Doze freeze (после ночи). КОРЕНЬ НАЙДЕН

### Почему «рандом» (root cause — два разных state, один симптом)
- **STATE A — outbound/NAT staleness** (лёгкий). Carrier-NAT истёк за ночь,
  sing-box держит zombie-TCP в трекере (до 16+ мин пока TCP keep-alive не
  сработает). TUN/CommandServer/box runtime **живы** — стейл только сокеты +
  DNS/transport. Тут `resetNetwork()` (или органический re-dial от пинга)
  оживляет → **«пинг помог»**.
- **STATE B — whole-stack timer freeze от Doze** (тяжёлый). Go-runtime
  меряет время по `CLOCK_MONOTONIC`, который **не идёт пока устройство
  suspended** → **ВСЕ** sing-box таймеры (urltest interval, keepalive,
  reconnect backoff) замерзают и не оживают сами → нужен reload/restart →
  **«пинг не помог»**.

Один фиксированный action (ручной пинг) срабатывает только когда живой state
случайно совпал с тем что пинг чинит. Отсюда рандом.

### Doze — подтверждённые факты
- Doze **не освобождает** сеть/wake-locks даже для foreground/VpnService: в
  deep Doze OS «suspends network access» + «ignores wake locks».
- **ROOT CAUSE #1** (глубочайший): `CLOCK_MONOTONIC` freeze → все Go-таймеры
  стоят. Нет libbox-команды «тихо reconnect через Doze» — таймеры, которые
  гнали бы reconnect, **сами заморожены**; нужен OS-wake.
- **ROOT CAUSE #2**: на pause/wake libbox зовёт `Router().ResetNetwork()`
  (with_conntrack) → закрывает ВСЕ TCP. Double-edged (регрессия #3400 —
  убивал TCP на каждый screen-off через 2-5 мин).
- **Background mode = NEVER (default)**: `BootReceiver` —
  `BG_MODE_NEVER`/`LAZY`/`ALWAYS`. Только LAZY/ALWAYS регистрируют
  `ACTION_SCREEN_OFF/ON` + `ACTION_DEVICE_IDLE_MODE_CHANGED` →
  `commandServer.pause()`/`.wake()`. При NEVER sing-box не получает pause/wake.
- **Doze whitelist** (battery exempt, `ACTION_REQUEST_IGNORE_BATTERY_
  OPTIMIZATIONS`) — необходим, но **НЕ достаточен** (partial exemption).
- `tcp_keep_alive` / `network_strategy` / urltest tuning — ограниченно и
  частично контрпродуктивно на mobile.

### §042 health watchdog — это DRAFT, НЕ построен
- §042 spec (2026-05-05) — детальный дизайн (HeartbeatHealth collector +
  HealthWatchdog reactor), но **код не написан**: нет `services/health/`,
  нет `/state/health` endpoint, нет интеграции.
- Текущий `_checkHeartbeat` (home_controller.dart:242-281) — **cosmetic**:
  каждые 20с fetch Clash traffic; на 2 фейла подряд → `_onTunnelDead()` →
  `TunnelStatus.revoked` (**full-stop cliff, не recovery**).
- НЕ детектит «tunnel up but dead» (zero-traffic + active connections).
- НЕ работает в фоне (только foreground/on-resume).
- **Нет эскалации** — single action (cliff).
- §042 планировал watchdog → `resetNetwork()` при 4 условиях, но тоже single
  action, только на `resumed`.

---

## Recovery-примитивы (всё УЖЕ callable из Dart — `box_vpn_client.dart`)

| Примитив | Cost | Что делает | Сохраняет |
|---|---|---|---|
| **`resetNetwork()`** (line 430) | SEMI-HOT <1s | CloseAll connections + DNS/transport rebind, **без** recycle runtime; tunnel status не меняется | tun, runtime, permission |
| **`reloadVPN()`** (line 415) | HOT ~3s | `startOrReloadService` — пересоздаёт box runtime (re-read config, rebuild DNS/routes) | Android Service, CommandServer, **tun fd**, VPN permission |
| **`stopVPN()`+`startVPN()`** | DISRUPTIVE 5-10s | destroy+recreate Service/CommandServer/tun/runtime; permission flicker | — |

`reloadVPN` — ровно та ступень, что чинит STATE B (замёрзший runtime) **без**
видимого юзеру teardown. Config не hot-reload'ится сам — читается заново на
каждый `startOrReloadService`.

## Industry self-heal (consensus, факты)
- **Liveness**: sing-box-клиенты (SFA/NekoBox/Hiddify/CMFA) **не пишут свой
  ping-loop** — переиспользуют core `urltest` outbound (generate_204).
- **Network-change trigger**: gold-standard — `DefaultNetworkListener` +
  `setUnderlyingNetworks` (shadowsocks-android lineage). Этот callback
  **сам срабатывает на Doze-exit и re-acquisition радио** → почему он
  предпочтительный wake-trigger.
- **Escalation ladder** (не прыгают сразу в restart): rebind sockets →
  re-discover/interrupt → re-handshake → restart (last resort).
- **Zombie tunnel** (design-against edge): handshake/liveness OK ≠ рабочий
  data-path (rethink #2602, sing-box #1415). → **re-check gate должен быть
  РЕАЛЬНЫЙ запрос через туннель**, не статус-флаг.

---

## Предложенная эскалация (из синтеза research — для будущей реализации)

**Ladder из 4 ступеней, дешёвая→дорогая, с RE-CHECK GATE между каждой.**

- **GATE** (перед rung 1 и после каждой): один urltest/HTTP-204 **через
  туннель** (тот же Clash delay endpoint что `pingNode`). Success (204,
  delay≥0) ⇒ healed, STOP. Fail ⇒ следующая ступень. **Реальный запрос, не
  флаг** (защита от zombie-tunnel).
- **ENTRY-условие** (не начинать ladder без деградации): §042 dual-signal —
  `urltest-not-confirming` AND `no-traffic-streak ≥5min` (+ `connectionsCount
  > 0` фильтр, чтобы idle не триггерил). Гистерезис против flapping.
- **Rung 0** — DETECT (always-on, дёшево): §042 `HeartbeatHealth` passive
  collector — копит zero-traffic-with-connections streak.
- **Rung 1** — `resetNetwork()` (лечит STATE A).
- **Rung 2** — `reloadVPN()` (лечит STATE B — замёрзший runtime).
- **Rung 3** — full `stop/start` (last resort; сегодня это **единственное**
  что есть — cliff).

### Триггеры (event-driven предпочтительнее polling)
1. **Смена сети** (симптом #1): `DefaultNetworkListener`/`DefaultNetworkMonitor`
   **уже есть**. Сейчас зовёт только `updateDefaultInterface` (passive). →
   на `onAvailable`/`onCapabilitiesChanged` дёргать **Rung 1 (resetNetwork)
   нативно, в фоне, debounced**. Не эскалировать дальше на bare смену сети.
   Работает **без Dart** (фон) — потому и лечит «рвётся на switch» даже когда
   app не на переднем плане.
2. **Wake** (симптом #2): `SCREEN_ON`/`commandServer.wake()` +
   `DEVICE_IDLE_MODE_CHANGED` (BoxService уже их ловит при BG_MODE_ALWAYS) →
   probe + ladder.
3. **Periodic** (когда foreground): heartbeat → gate → ladder при деградации.

## Minimal-viable (из research — наименьшее что реально помогает)

- **MV-1 — эскалация вместо обрыва.** Сегодня единственное восстановление —
  full-restart cliff в `_onTunnelDead` (home_controller.dart:283 → revoked).
  Вставить ступени **перед** ним: на деградации → `resetNetwork()` → re-probe
  (Clash delay) → если мёртв `reloadVPN()` → re-probe → только тогда full
  restart. Конвертирует «рандом, иногда только full reset» в «пробует дешёвое,
  restart только когда надо». Покрывает STATE A и B **существующими**
  примитивами. Без новых сервисов — небольшой escalation-helper из
  `onAppResumed` + heartbeat-fail.
- **MV-2 — native resetNetwork на смену сети.** В
  `DefaultNetworkMonitor.checkUpdate` (или callback), после
  `updateDefaultInterface`, слать существующий `ACTION_RESET_NETWORK`
  (debounced). Чистый native, лечит симптом #1 в фоне.
  **→ РЕАЛИЗОВАНО в [§087](087-network-change-force-reset.md)** (genuine
  interface-change detect + debounce 1.5s → `resetNetwork()`).

---

## Варианты лечения (failure mode 1, из синтеза research)

| # | Вариант | Чинит | НЕ чинит | Стоимость |
|---|---|---|---|---|
| **C** | **Native force-reset на реальную смену интерфейса** — `DefaultNetworkMonitor` дёргает существующий `resetNetwork()` | Закрывает стейл-сокеты в корне, минимальная latency (native callback раньше Dart). Совпадает с SFA/SFI event-driven дизайном. | Не про Doze-freeze (mode 2). | Только проводка триггера — `resetNetwork()` уже есть. Дисциплина: дёргать **только** на genuine interface change (не на каждый capability-update). |
| **B** | **Clash API `DELETE /connections` на Dart-детект смены сети** (`connectivity_plus`) | Тот же эффект (closeAll → RST), + чистит Connections UI. | Чуть выше latency (Dart-сигнал позже native). Не про Doze. | Zero new code (endpoint реализован). |
| **D** | **Dart auto-ping** (delay/groupDelay на foreground/таймер) | Re-dial свежих над текущим интерфейсом → новый трафик сам восстанавливается без ручного открытия app. | **Не закрывает** стейл-сокеты — старые сессии висят (= то что юзер видит). | Дёшево. |
| **A** | `interrupt_exist_connections` (уже `true`) | Чисто дропает потоки при смене **выбора ноды**. | **Ничего** для этого бага (не про смену сети). | Уже включено. |

**Из research (recommendation):** proper fix = **C** (native resetNetwork на
смену сети); **B** — low-risk quick win; компонуются; **A** уже на месте; **D**
(пинг) — только частично, как и наблюдает юзер.

## Industry consensus (факты)
- Ядро sing-box (SFA/SFI/NekoBox/Hiddify) полагается на авто-`ResetNetwork()`
  на network transition (через Pause/Wake + interface change).
- `DELETE /connections` — кросс-клиентская идиома «согнать app'ы со стейл-
  сокетов» (Clash Meta, Clash-for-Windows surface это как кнопку).
- v2rayNG (#2758) — фичу «force reset connections» просили, мейнтейнеры
  закрыли «not planned».
- Hiddify — тот же класс бага (туннель залипает после WiFi reconnect, иногда
  виснет на «disconnecting»); митигация — app-level auto-reconnect.
- «Пинг/urltest чтобы оживить» (#1494/#1385/#934/#1095) — **user workaround**,
  не мейнтейнер-фикс; proper = interface rebinding + event-driven reset.

## Ключевые выводы (одной строкой)
1. **Смена сети** — корень: native ловит, но не дёргает готовый
   `resetNetwork()`. Fix почти бесплатный (MV-2).
2. **После ночи** — два state (NAT-stale vs Doze timer-freeze) → нужна
   **эскалация** `resetNetwork → reloadVPN → restart` с реальным re-check
   gate (MV-1). Все примитивы уже есть.
3. **§042 watchdog — только spec, не построен**; текущий heartbeat = cliff
   без эскалации. Foundation (примитивы + триггеры) на месте.
4. Пинг — user-workaround, не fix (re-dial новых, стейл висит). Industry
   consensus: event-driven reset + ladder, gate = реальный запрос (не флаг).

## Статус реализации
- **MV-2** (mode 1 — смена сети) — ✅ [§087](087-network-change-force-reset.md).
- **MV-1** (mode 2 — Doze escalation ladder `resetNetwork → reloadVPN →
  restart` с re-check gate) — ⏳ не реализовано; следующая задача.
- **§042 watchdog** (HeartbeatHealth/HealthWatchdog) — ⏳ только spec (DRAFT).

## Не в скопе (этой таски)
- Реализация (MV-1, эскалация, конфиг, тесты) — отдельная задача. Эта таска —
  **только результаты изысканий** (MV-2 вынесено в §087).
- Реализация §042 watchdog (HeartbeatHealth/HealthWatchdog) — связанная,
  но отдельная.

## Файлы / источники
- `docs/spec/tasks/086-stale-connections-network-change-doze.md` (этот файл).
- `docs/spec/features/042 health watchdog/spec.md` (DRAFT, не построен).
- Код: `DefaultNetworkMonitor.kt`, `BoxService.kt`,
  `box_vpn_client.dart` (`resetNetwork`/`reloadVPN`/`startVPN`),
  `clash_api_client.dart` (`closeAllConnections`/`delay`),
  `home_controller.dart` (`_checkHeartbeat`/`_onTunnelDead`),
  `wizard_template.json` (`interrupt_exist_connections`/`auto_detect_interface`).
- Research: workflow `stale-connection-research` (run `wf_3dad08c9-32d`, 6 агентов),
  `doze-watchdog-research` (run `wf_c3db7f6b-e01`, 5 агентов).
