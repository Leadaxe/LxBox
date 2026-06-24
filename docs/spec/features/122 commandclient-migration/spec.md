# §122 — Переход на libbox CommandClient (отказ от Clash API)

| Поле | Значение |
|---|---|
| **Статус** | Approved with required edits (прошла ролевую экспертизу: ядро/код/UX/архитектор; P0+P1 внесены; железные Q5–Q9 — на устройстве) |
| **Дата** | 2026-06-24 |
| **Целевое ядро** | sing-box-lx `v1.14.0-lx.1-rc.2` (мажор-связка `v1.14.0-lx.1`; base sing-box v1.13.13 + `with_awg`/`with_xhttp`/`with_lx_command`). Релиз: [github.com/Leadaxe/sing-box-lx/releases/tag/v1.14.0-lx.1-rc.2](https://github.com/Leadaxe/sing-box-lx/releases/tag/v1.14.0-lx.1-rc.2). **Два AAR:** `libbox-1.14.0-lx.1-rc.2.aar` (основной, **SDK23+**) и `libbox-legacy-1.14.0-lx.1-rc.2.aar` (**SDK21**). `Libbox.version()` → `1.14.0-lx.1`. Тег `-rc` — пререлиз, НЕ device-verified по §010; для command-API (client-only, data-path не затронут) — не помеха. SPEC 014: статус A (реализовано). |
| **Ядровая спека** | SPEC 014 — `sing-box-lx/SPECS/014-LIBBOX_COMMAND_URLTEST_RULES/SPEC.md` (закреплена за тегом rc.2, парная, обязательна к согласованию) |
| **Интеграция (Фаза 0)** | Обновить `libbox.version` → `1.14.0-lx.1-rc.2`, подложить оба AAR (SDK23 + legacy SDK21). Новые методы: `URLTestOutbound(tag, link, timeout int32)→*URLTestOutboundResult{Delay int32, Error string}` (Вариант B: истина в `Error`; Go-error = только транспортный сбой); `GetRules()→RuleIterator` (`Rule{Type,Payload,Action,IsDNS}`). Масс-пинг — worker-pool в клиенте, отмена = реконнект conn. |
| **Связанные спеки** | §012 (native vpn service), §121 (libbox-1.14-adoption — родитель), §016 (stats), §040 (per-group ping), §044 (profiler), §048 (node-filters), §042 (health watchdog — data-source переезжает), §030 (custom-rules Debug API), §031 (debug api), §043/§010 (core-log — НЕ затрагивается), §159 (import allowlist), §143 (interrupt-on-switch) |
| **Память** | `[[project_122_commandclient_migration]]`, `[[project_libbox_114_migration_api_breaks]]`, `[[project_jni_callbacks_must_not_throw]]`, `[[project_dns_routing_king]]`, `[[feedback_no_destructive_diagnostics]]` |
| **Затронутые файлы** | `clash_api_client.dart`, `clash_endpoint.dart`, `build_config.dart`, `home_controller.dart`, `home_state.dart`, `node_filter.dart`, `node_row.dart`, `node_list*.dart`, `ping_orchestration.dart`, `stats_screen`, `connections_screen`, `error_format.dart`, `wizard_template.json`; native: `BoxService.kt`, `BoxVpnService.kt`, `VpnPlugin.kt`, новый `BoxCommandClient.kt`; диагностика: `scripts/lxbox-diag.sh`, Debug API `/clash/*`; тест-фикстуры (`build_config_test`, `clash_endpoint_test`, `config_dirty_flag_test`, `pipeline_e2e_test`, `detour_append_replace_test`) |

---

## §0. Главный тезис

**§122 меняет КОНТРАКТ ДАННЫХ, а не транспорт.** Это не «тот же Clash API по другому проводу» — модель взаимодействия инвертируется на трёх осях, и непонимание этого — первейший источник ошибок реализации (см. риски: BLOCKER «концептуальная путаница `CommandServer` ⟂ `ClashAPI`»).

| Ось | Clash API (было) | libbox CommandClient (станет) |
|---|---|---|
| **Поток** | pull-снапшоты — UI опрашивает HTTP по таймеру, ядро отвечает полным состоянием на каждый запрос | push-дельты — ядро само пушит по server-stream при изменении; UI подписывается один раз |
| **Поля** | Clash-метадата (`metadata.*`, `proxies`, `connections[]` JSON) | поля libbox — иные имена и форма (`Connection.getProcessInfo()`, `getUplinkDelta`, `getClosedAt`, `StatusMessage.getUplink` = байтовая дельта за интервал статуса (B/s при interval=1s)) |
| **Отмена** | отсутствует как механизм — каждый poll независим, отменять нечего | единый механизм на двух концах: разрыв/закрытие conn ⇒ серверный `ctx.Done()` ⇒ in-flight операции падают (бывший `cancelDelays` = `server.Context().Done()`) |

Транспорт под обоими — это уже `CommandServer` внутри нашего же процесса (мы и сегодня держим `CommandServer` in-process, но потребляем его через HTTP-петлю Clash). §122 убирает петлю и потребляет `CommandServer` штатным фасадом `CommandClient`. Поэтому планировать миграцию как «замену URL-ов на вызовы метода» — неверно: переписываются модели данных (`TrafficSnapshot`/`AppStat` наполняются из `StatusMessage`/`Connection`, не из `connections.json`), модель потока (3 `Timer.periodic` + heartbeat → один server-stream push + watchdog) и семантика отмены (§143 interrupt-on-switch получает реальный серверный механизм вместо «бросить poll»).

---

## §1. Мотивация

Четыре независимых довода. Доводы 2–4 не зависят от состава `.so`; довод 1 — conditional на нём (см. §1a).

**1. Безопасность и гигиена конфига.** Пока проектный `.so` линкует Clash API server, блок `experimental.clash_api` открывает живой TCP-порт на `127.0.0.1`, доступный любому приложению на устройстве; единственная защита — `secret`. Это attack surface. После rc.1 (server вырезан, см. §1a) инъекция деградирует до мёртвой опции-no-op — порт не откроется, но опция остаётся бессмысленным мусором в конфиге, который ядро всё равно парсит. В обоих состояниях `.so` инъекция `clash_api` нежелательна: либо дыра, либо мёртвый груз. Отказ от неё закрывает оба случая.

**2. Нативность.** `CommandClient` — это штатный канал libbox для GUI; так устроены эталонные SagerNet/SFA и SFI. Мы держим `CommandServer` в процессе, но сейчас потребляем его через HTTP-петлю Clash — нештатно. Миграция возвращает нас на каноническую поверхность libbox и не зависит от состава `.so`.

**3. Потенциал.** Через `CommandClient` доступно то, чего Clash API в принципе не отдавал: `writeStatus` с готовой байтовой дельтой за интервал (`getUplink`=`UplinkTotal−uploadTotal` тика; при interval=1s численно равна B/s) — апгрейд над нашим ручным расчётом дельты; `getDeprecatedNotes` (предупреждения о deprecated-опциях конфига); `ConnectionEvent`-дельты (New/Update/Closed) вместо периодических снапшотов; closed-история соединений; NQ/STUN. Недостижимо через Clash. Не зависит от `.so`.

**4. Детерминизм control-channel.** Вскрыто декомпиляцией (§1a): сегодня поведение канала недетерминировано — открыт ли Clash-порт, зависит от того, слинкован ли server в конкретном `.so`, а это расходится между проектным AAR и rc.1. Миграция делает канал единственным и независимым от состава `.so`: `CommandClient` работает поверх `command.sock` всегда, потому что `CommandServer` мы поднимаем сами в процессе. Не зависит от `.so`.

### §1a. Дрейф сборок (проектный AAR vs rc.1)

Канал управления сегодня недетерминирован из-за расхождения двух сборок ядра, вскрытого декомпиляцией:

| Сборка | Clash-парсер `*option.ClashAPIOptions` | Clash-server `clashapi.NewServer`/`(*Server).Start`/`setupMetaAPI` | Порт на `127.0.0.1` |
|---|---|---|---|
| Проектный AAR (`app/android/app/libs/libbox.aar`) | есть | **линкуется** — рантайм-символы в `.so` | **реально открывается** |
| Релизный `v1.14.0-lx.1-rc.1` | есть | **отсутствует** (`with_clash_api` dropped) | не открывается |

**Парсер ≠ server.** `*option.ClashAPIOptions` присутствует в обоих бинарях ВСЕГДА — ядро обязано уметь читать поле `clash_api` в чужих импортируемых конфигах, иначе парсинг падает. Наличие парсера НЕ доказывает, что server слинкован. Server доказывается ТОЛЬКО присутствием рантайм-символов `(*Server).Start` / `setupMetaAPI` / `clashapi.NewServer` в `.so`. В проектном AAR они есть; в rc.1 — нет.

**Следствие для §122.** Перед/в рамках миграции проектный AAR синхронизировать с rc.1 (server-less). Это обязательный сопутствующий шаг, но не блокер: довод мотивации №1 остаётся в силе в обоих состояниях `.so` (дыра ⇒ no-op-мусор), а §122 в любом случае перестаёт зависеть от того, какая из двух сборок подложена.

---

## §2. Архитектура

### §2.1. Процессная модель

Приложение **одно-процессное**: `BoxVpnService` объявлен без `android:process`, поэтому VPN-сервис, foreground `BoxService`, Flutter-engine и Go-ядро живут в одном процессе `com.leadaxe.lxbox`. Это — фундамент всей миграции: command-сокет, его сервер и его клиент находятся в одной памяти, разделены только границей JNI.

Четыре актора в этом процессе:

- **Go-ядро** (sing-box-lx) — держит in-process `CommandServer` (gRPC-сервис `StartedService` поверх unix-сокета).
- **`BoxService`** (foreground) — хост нативной обвязки: `CommandServer` (CSH-сторона) и новый **`BoxCommandClient`** (клиент). `CommandServer` стартует в `BoxService.kt:179` (`startCommandServer()`) сразу после `BoxApplication.libboxReady.await()`.
- **`BoxVpnService`** — реализует `PlatformInterface`, владеет статическими sink'ами Flutter-каналов (`coreLogSink` и новый эмиттер).
- **Flutter-engine** (`VpnPlugin`) — потребитель: `EventChannel`-стримы и `MethodChannel`-команды.

Сокет: `command.sock` в `filesDir` = `/data/data/com.leadaxe.lxbox/files/command.sock`.

```
   ┌──────────────────────── процесс com.leadaxe.lxbox ─────────────────────────┐
   │                                                                            │
   │   ┌─── Go-ядро (sing-box-lx) ───┐                                          │
   │   │  CommandServer              │                                          │
   │   │  gRPC StartedService        │                                          │
   │   └─────────────┬───────────────┘                                          │
   │                 │  command.sock (unix, filesDir)                           │
   │                 │  gomobile-фасад libbox                                   │
   │   ┌─────────────┴───────────────── BoxService (foreground) ───────────┐   │
   │   │  CommandServer (CSH)  ◄──── BoxService.kt:179 startCommandServer() │   │
   │   │                                                                    │   │
   │   │  BoxCommandClient (НОВЫЙ) — ТРИ клиента (§2.8):                    │   │
   │   │    statusClient   : Status(1)+interval 1s   [always-on]           │   │
   │   │    screenClient   : Outbounds(5)+Group(2)+Conn(4) [по экрану]     │   │
   │   │    profilerClient : Conn(4)                 [по recording]        │   │
   │   │    колбэки try/catch fail-safe; Conn-аккумулятор (refcount)       │   │
   │   │    lifecycle connect/disconnect + backoff                          │   │
   │   └───────────────┬────────────────────────────────────────────────────┘  │
   │                   │  статические sink'и в BoxVpnService                   │
   │   ┌───────────────┴── BoxVpnService (PlatformInterface) ──────────────┐    │
   │   │  coreLogSink   |   statusSink/outboundsSink/groupsSink/connSink    │    │
   │   └───────────────┬────────────────────────────────────────────────────┘  │
   │                   │  EventChannel (push) / MethodChannel (команды)         │
   │   ┌───────────────┴── Flutter-engine (VpnPlugin) ────────────────────┐     │
   │   │  StreamBuilder ← stats/connections/profiler ; watchdog ← status   │     │
   │   └────────────────────────────────────────────────────────────────────┘  │
   └────────────────────────────────────────────────────────────────────────────┘
```

**Размещение клиента — решение.** `BoxCommandClient` поднимается в Kotlin (рядом с `CommandServer` в `BoxService`), а эмиттер в Dart идёт через `EventChannel`-sink, который **обязан** жить во Flutter-процессе — по образцу `coreLogSink` (`BoxVpnService.coreLogSink`, дренаж `BoxService.kt:676`).

**Инвариант (BLOCKER).** Если `BoxVpnService` когда-либо уедет в `:bg` (отдельный процесс), `EventChannel` порвётся — sink'и из чужого процесса недоступны. Запрет на декларацию `android:process` зафиксировать комментарием в коде и тестом. Это та же причина, по которой клиент коннектится только **после** старта сервера (сокет существует лишь после `startCommandServer()`), и только на статус `Starting`/`Started`.

### §2.2. Инверсия push vs poll

Старый Clash-канал был **pull** по HTTP: четыре независимых поллера опрашивали `127.0.0.1`. Новый канал — **push**: ядро через server-stream само эмитит изменения, клиент подписывается один раз.

| Было (Clash HTTP pull) | Стало (CommandClient push) |
|---|---|
| `stats_screen` `Timer.periodic` 3с | `SubscribeStatus` (cmd 1) + `setStatusInterval ≈ 1s` → `StreamBuilder` |
| `connections_screen` `Timer.periodic` 2с | `SubscribeConnections` (cmd 4) → дельты → аккумулятор → `StreamBuilder` |
| `profiler` `Timer.periodic` 1-2с, `_pollConnections` diff | `Stream<ConnectionEvent>` (cmd 4), нативные `New`/`Closed`-дельты вместо diff |
| `HomeController` heartbeat 20с (pull HTTP) | **watchdog**: dead-tunnel при `disconnected` ИЛИ нет `StatusMessage` дольше **8–10с** (≥5–6 пропущенных тиков по 1с — запас на радио-джиттер РФ-LTE/хэндовер БС, чтобы не давать ложных «соединение потеряно»). Сохранить «один haptic на серию» (`_heartbeatFailNotified`) |

`HomeController.heartbeat` перестаёт быть поллером и становится сторожем живости стрима: dead-tunnel диагностируется по отсутствию `StatusMessage` дольше таймаута, а не по неудаче HTTP-запроса. `TrafficProfiler.bindRuntime(connections-fetcher callback)` переходит с pull-diff на подписку `Stream<ConnectionEvent>`: ему нужны именно дельты open/close, поэтому ему эмитятся события `ConnectionEventNew`/`Closed`, а не снапшоты.

**Backpressure.** Server-push снимает дросселирование на клиенте, но переносит риск на native-границу. Снапшот connections дросселируется в Kotlin по образцу coreLog-дренера (`BoxService.kt:676`, `LOG_QUEUE_MAX = 4096` :658, `DRAIN_BATCH_MAX = 200` :662): батч-эмиссия, re-post с yield.

### §2.3. Три слоя протокола

Command-канал в 1.13+ — это **gRPC** (`StartedService` поверх `command.sock`). AAR libbox оборачивает gRPC в **gomobile-фасад** `CommandClient`. Kotlin-обвязка работает с фасадом и **никогда не пишет gRPC напрямую**. Три уровня семантики не путать:

| Слой | Семантика | Go-сторона | gomobile-фасад | Command-константа |
|---|---|---|---|---|
| **1. unary-read** | снапшот «сейчас» | `GetVersion`, `GetStartedAt`, `URLTestOutbound`*, `GetRules`* | прямые методы `CommandClient` (`getDeprecatedNotes()`, обёртки `urlTestOutbound()`/`rules()`) | **НЕТ** |
| **2. server-stream** | живое состояние, ядро пушит при изменении | `SubscribeLog`/`Status`/`Groups`/`ClashMode`/`Connections`/`Outbounds` | `CommandClientOptions.addCommand(int)` + `setStatusInterval` → колбэки `handler.writeLogs`/`writeStatus`/`writeGroups`/`writeOutbounds`/`writeConnectionEvents` | **0-5** (`Log=0`,`Status=1`,`Group=2`,`ClashMode=3`,`Connections=4`,`Outbounds=5`) |
| **3. императив** | действие | `selectOutbound`/`closeConnection`/`urlTest`/`setGroupExpand`/`setClashMode` | прямые методы фасада | — |

\* `URLTestOutbound`/`GetRules` — новые unary-RPC из ядровой SPEC 014; обе **без** `Command*`-константы, Dart-обёртки `urlTestOutbound()`/`rules()` без `Command`-префикса.

**Единый механизм отмены.** `server.Send()` в цикле = вызов соответствующего `write*`-колбэка. `server.Context().Done()` (клиент отвалился) = `disconnect()`/разрыв conn = бывший `cancelDelays` Clash-канала. Отмена — **один** механизм на двух концах (детально по масс-пингу — §4.3).

**Тонкость единиц (MED).** `setStatusInterval` принимает Go `Duration` на gomobile-уровне — это **наносекунды**, тогда как `URLTestOutbound.timeout` — **миллисекунды** (нормативно — §4.6). Не перепутать.

**Нормативные требования к реализации handler'а (консультация команды ядра, rc.2):**
- **Не хардкодить числа `addCommand(5)` — использовать именованные константы `Libbox.CommandOutbounds`/`CommandStatus`/`CommandGroup`/`CommandConnections`.** Если upstream вставит команду в середину iota-блока на ребейзе, числа поедут, имена — нет.
- **Типы итераторов в колбэках РАЗНЫЕ, легко спутать:** `writeGroups(OutboundGroupIterator)` (дерево групп) vs `writeOutbounds(OutboundGroupItemIterator)` (плоский список). Это разные типы — `OutboundGroup` (с `getItems()`) против `OutboundGroupItem` (лист).
- **Цепочка на Go-стороне (для понимания):** `addCommand(CommandOutbounds)` → `dispatchCommands` → `handleOutboundsStream()` → gRPC `client.SubscribeOutbounds(...)` → на каждый `stream.Recv()` дёргает `handler.WriteOutbounds(...)`. То есть колбэк `writeOutbounds` = «пришёл апдейт `SubscribeOutbounds`-стрима».
- **delay endpoint'ов (WG/AWG) виден ТОЛЬКО через `CommandOutbounds`→`writeOutbounds`** — `writeGroups` итерирует лишь членов `OutboundGroup` и endpoint'ы не покажет (§4.3, SPEC 014 §3.2).
- **`setStatusInterval` — период ТОЛЬКО для `CommandStatus`**; стримы групп/outbounds пушатся по событию `urlTestObserver`, не по таймеру → интервал на них не влияет, ставить только на `statusClient` (§2.8).

### §2.4. Два стрима узлов

Узлы приходят **двумя** разными стримами; их нельзя смешивать.

| Стрим | Колбэк / итератор | Форма | Поля узла | Потребитель |
|---|---|---|---|---|
| `SubscribeOutbounds` (cmd 5) | `writeOutbounds(OutboundGroupItemIterator)` | **плоский** список ВСЕХ outbound+endpoint | `getTag`, `getType`, `getURLTestTime`, `getURLTestDelay` | **node-list** (`node_list.dart`, `node_list_presenter.dart`) + **масс-пинг** |
| `SubscribeGroups` (cmd 2) | `writeGroups(OutboundGroupIterator)` | **дерево** группа→items | `OutboundGroup`: `getTag`/`getType`/`getSelectable`/`getSelected`/`getIsExpand`/`getItems` | экран групп, selector-UI |

Замена Clash-семантики групп: `getSelectable()` заменяет проверку `type == 'Selector'`; `getSelected()` заменяет поле `now`. Источник `selectorGroupTags` для UI — `getSelectable()` стрима групп, а не разбор конфига.

### §2.5. Карта каналов по экранам UI

| Экран / контроллер | Источник (стрим / unary) | Команды (императив) |
|---|---|---|
| Home — список узлов | `writeOutbounds` (cmd 5): tag/type/delay per-node | `selectOutbound`, `URLTestOutbound` (single + масс-пинг) |
| Home — группы/селекторы | `writeGroups` (cmd 2): дерево, `getSelectable`/`getSelected` | `selectOutbound`, `setGroupExpand`, `setClashMode` |
| Home — скорость/heartbeat | `writeStatus` (cmd 1): `getUplink`/`getDownlink` (дельта/интервал, B/s при 1s) | — (watchdog по таймауту статуса) |
| Stats (`stats_screen`) | `writeStatus` (cmd 1) → `StreamBuilder` | — |
| Connections (`connections_screen`) | `writeConnectionEvents` (cmd 4) → native-аккумулятор → `StreamBuilder` | `closeConnection` |
| Profiler (`TrafficProfiler`, §044) | `writeConnectionEvents` (cmd 4) → `Stream<ConnectionEvent>` (дельты open/close) | — |
| §048 ping-фильтр | `writeOutbounds` (cmd 5): `getURLTestDelay` → per-node delay | `URLTestOutbound` (масс-пинг) |

### §2.6. Таблица соответствия Clash → CommandClient

Каждый Clash-вызов клиента и его эквивалент. Удаляемый код — в `clash_api_client.dart` (целиком `ClashApiClient`), `clash_endpoint.dart`, `home_controller.dart`, `build_config.dart`, `wizard_template.json`, `error_format.dart`, `scripts/lxbox-diag.sh`.

| Clash API (что вызывали) | Канон: файл:строка | CommandClient-эквивалент | Слой |
|---|---|---|---|
| `GET /traffic` (up/down скорость) | `ClashApiClient` (`clash_api_client.dart`) | `writeStatus.getUplink/getDownlink` (дельта/интервал; B/s при interval=1s) | server-stream cmd 1 |
| `GET /connections` (снапшот) | `clash_api_client.dart`; поллер `connections_screen` 2с | `writeConnectionEvents` дельты → native-аккумулятор → снапшот | server-stream cmd 4 |
| `GET /proxies` (узлы + delay) | `clash_api_client.dart` | `writeOutbounds` (плоский) + `writeGroups` (дерево) | server-stream cmd 5 / cmd 2 |
| `PUT /proxies/{group}` (выбор) | `static proxyEntry` (`clash_api_client.dart`) | `selectOutbound(group, tag)` | императив |
| `GET /proxies/{name}/delay` (ping) | `static urltestNow` (`clash_api_client.dart`) | `URLTestOutbound(tag, link, timeoutMs)` — **unary**; `urlTest(groupTag)` (групповой) — **императив** | unary (SPEC 014) / императив |
| `GET /rules` | `lxbox-diag.sh:108`; `state/rules` :95 | `GetRules()` → `RuleIterator` (route+DNS, элемент `Rule{Type,Payload,Action,IsDNS}`) | unary (SPEC 014) |
| `GET /version` | `lxbox-diag.sh:109` | `Libbox.version()` | нативный вызов (не command-канал) |
| `route.final` чтение | `ClashEndpoint.routeFinalTag` (`clash_endpoint.dart:36`); вызовы `home_controller.dart:374,557` | **перенести** в адаптер (читает конфиг, не Clash-канал) | — (не канал) |
| endpoint-парсинг конфига | `ClashEndpoint.fromConfigJson` (`clash_endpoint.dart:13`); `_rebuildClashEndpoint`/`_clash`/`clashClient` (`home_controller.dart`) | **удалить** (канал на сокете, не на URI) | — |
| ping-фильтр delay-источник (§048) | `node_filter.dart:124-128`; sort `home_state.dart:161-171`; label `node_row.dart:42-56` | `writeOutbounds.getURLTestDelay` + `URLTestOutbound` (масс-пинг) | server-stream cmd 5 / unary |
| `experimental.clash_api` в конфиге | блок `wizard_template.json:602-605`, vars `:236,244`; `_ensureClashApiDefaults` `build_config.dart:471`, вызов `:116` | **удалить** + вырезать при импорте (§6.1) | — |
| `ClashHttpException` гуманизация | `error_format.dart:41` | `PlatformException`-ветка | — |
| диагностика `clash_connections/proxies/rules/version` | `lxbox-diag.sh:106-109` | Debug API `/clash/*` переписан поверх CommandClient; `version`→`Libbox.version()` | — |

Удаляется клиент `ClashApiClient` (`clash_api_client.dart`), но модели `TrafficSnapshot`/`AppStat` **сохраняются** — их наполняют из `StatusMessage`/`Connection`. `static urltestNow`/`proxyEntry`/`connectionIdsInChain` переносятся в адаптеры. `_ensureClashApiDefaults` рандомизировал порт `49152..65534` (`build_config.dart:471-487`) — теперь не нужен: HTTP-порт не открывается вовсе.

### §2.7. Связка масс-пинга (обзор)

Масс-пинг — контур, где **клиент** держит worker-pool=10 (`ping_orchestration.dart:142`, `_pingConcurrency`), а **ядро** меряет один узел синхронно и stateless. Синхронный `{delay, error}`-ответ `URLTestOutbound` даёт немедленный per-node feedback (`pingBusy`→ms), а `SubscribeOutbounds`-стрим (cmd 5, `getURLTestDelay`) — source of truth. Детальный контур (диаграмма, инварианты, отмена) — **§4.3/§4.6**. Существующий **групповой** `urlTest(groupTag)` — **не трогаем** (нулевой дифф в ядре).

### §2.8. Lifecycle подписок: ТРИ `CommandClient`'а, не один

В gomobile-фасаде подписки конфигурируются через `CommandClientOptions.addCommand(int)` + колбэки `handler.write*` (НЕ прямые `subscribe*`-методы — их в AAR нет, см. §2.3). Один `CommandClient` = одно соединение с фиксированным набором команд, поднятым на `connect()`. Чтобы lifecycle подписок совпадал с реальными потребностями (разведано по коду — что работает в фоне, что гасится с экраном), заводим **три отдельных клиента** с разными жизненными циклами:

| Клиент | Команды (`addCommand`) | Lifecycle | Потребитель | Обоснование |
|---|---|---|---|---|
| **`statusClient`** | `addCommand(Libbox.CommandStatus)` + `setStatusInterval(1s)` | **always-on** пока туннель up | dead-tunnel watchdog (§2.2) + скорость на главном (`traffic_bar`) | Лёгкий (1 msg/s). Watchdog обязан жить в фоне — ловит обрыв. Апгрейд: push-1s вместо poll-20s. **Единственный клиент с `setStatusInterval`** — на остальных бессмысленно (стримы пушатся по `urlTestObserver`, не по таймеру, §2.3). |
| **`screenClient`** | `addCommand(Libbox.CommandOutbounds)` + `addCommand(Libbox.CommandGroup)` + `addCommand(Libbox.CommandConnections)` | поднимается при открытии экрана узлов/stats/connections, `disconnect` при уходе (`didChangeAppLifecycleState` paused/hidden) | node-list, группы, таблица соединений | Сейчас эти поллеры **гасятся в фоне** (heartbeat §141 P0.2, stats/connections `_stopTimer`). Сохраняем 1:1 — никакого нового resident-drain. Без `setStatusInterval`. |
| **`profilerClient`** | `addCommand(Libbox.CommandConnections)` | поднимается при `startGlobalRecording`, `disconnect` при `stopGlobalRecording` (`traffic_profiler.dart`) | TrafficProfiler §048 (per-app live) | Recording — **opt-in пользователем** (нажал START), может жить в фоне. НЕ always-on по умолчанию. Отдельный клиент — чтобы recording не зависел от того, открыт ли экран. |

**Почему не один always-on клиент со всеми командами:** `Connections`/`Outbounds`-стримы тяжёлые (все соединения/узлы); держать их always-on = лить в фоне впустую = тот самый resident-drain, который §141 P0.2 вычищал. Разведка кода подтвердила: в фоне нужен **только** `Status` (для watchdog), остальное гасится с экраном. Нотификация/tile статичны (up/down + нода, не скорость); automation §047 — событийная (broadcast, без статистики трафика) — фоновых стримов не требуют.

**Native-аккумулятор `Connections`** живёт под `screenClient`+`profilerClient` (оба на cmd 4). Если оба активны одновременно (экран connections открыт И recording on) — **один** аккумулятор, refcount: первый потребитель поднимает клиента, последний гасит. closed-история (`filterState`) — только пока есть подписчик, с TTL/cap (§3.3).

**Синхронизация при re-connect (НЕТ рассинхрона — гарантия ядра).** Пока клиент подключён, рассинхрона нет: ядро пушит `write*` на каждое изменение (лучше поллинга — нет stale-окна между тиками). При re-connect (вернулись из фона, в фоне состояние изменилось) **ядро на первом `Recv()` шлёт полный reset-снапшот**, не дельту: `writeConnectionEvents` с `getReset()=true` (полный список), `writeOutbounds`/`writeGroups` — текущее состояние целиком. UI синхронизируется автоматически. **Нормативные требования к реализации, чтобы reset работал как reset:**
- При `getReset()=true` аккумулятор/state-слой **очищается и заполняется заново** (replace, НЕ merge поверх старого) — иначе призраки из прошлой сессии.
- **Generation-гейт против гонки connect/disconnect** (как §141 P1.2): каждый `connect()` инкрементит `clientGeneration`; снапшот/события из устаревшего поколения игнорируются. Защищает от быстрого фон→foreground→фон, где disconnect-в-полёте и новый connect перетёрли бы друг друга.
- Окно от `connect()` до первого снапшота (мс на localhost-сокете) — допустимо; опц. пометить state `stale` при `disconnect`, чтобы не мигнуть старым.

---

## §3. Модель данных

CommandClient заменяет **контракт данных**, а не транспорт: вместо JSON Clash-API приходят типизированные gomobile-структуры. Принцип — **один адаптер на структуру**, переписать на него все места парсинга. Модели `TrafficSnapshot`/`AppStat` сохраняются (см. §5), но наполняются из `StatusMessage`/`Connection`, а не из `connections.json`.

### §3.1. Маппинг AAR-структур на Dart-модели

**`StatusMessage` → `TrafficSnapshot`** (модель в `clash_api_client.dart:223`, сам клиент удаляется — §5). Источник — server-stream `writeStatus` (§2.4), `setStatusInterval≈1s`:

| Dart-поле | Источник (libbox) | Примечание |
|---|---|---|
| `uploadTotal` / `downloadTotal` | `getUplinkTotal()` / `getDownlinkTotal()` (long) | объём за сессию; раньше агрегировался из `/connections` |
| `uploadSpeed` / `downloadSpeed` *(новое)* | `getUplink()` / `getDownlink()` (long, байт за интервал статуса) | **B/s при interval=1s**; при ином интервале клиент делит на интервал. Заменяет наш ручной `(total−prev)/Δt` ТОЛЬКО при жёстко зафиксированном 1s |
| `memory` | `getMemory()` (long) | раньше из топа `/connections` |
| `goroutines` *(опц.)* | `getGoroutines()` (int) | диагностика |
| `activeConnections` | `len` аккумулятора после `filterState(Active)` | **НЕ суммировать `getConnectionsIn+getConnectionsOut` вслепую** — это два разных счётчика (conn-manager vs traffic-tracker), могут двоить. Source of truth активных = размер аккумулятора |

При жёстко зафиксированном `StatusInterval=1s` ядровая дельта (`getUplink`/`getDownlink`) численно = B/s и читается напрямую, отменяя клиентский `(total−prev)/Δt` в `heartbeat.dart`. **Если интервал меняется — клиент обязан делить дельту на фактический интервал** (ядро отдаёт байты-за-тик, не нормированную скорость).

**`OutboundGroup` / `OutboundGroupItem` → группа / узел.** Два разных стрима, не путать (см. §2.4):

- **`SubscribeOutbounds` → `writeOutbounds(OutboundGroupItemIterator)`** — **плоский** список **всех** outbound+endpoint. Per-node: `getTag()`, `getType()`, `getURLTestTime()` (long), `getURLTestDelay()` (int, ms). **Сюда садится node-list (`node_list*.dart`) и масс-пинг.** `getURLTestDelay()` → `state.lastDelay[tag]` (§048).
- **`SubscribeGroups` → `writeGroups(OutboundGroupIterator)`** — **дерево** группа→items. `OutboundGroup`: `getTag()`, `getType()`, `getSelectable()` (→ замена строковой проверки `type=='Selector'` в `clash_api_client.dart:59`; `home_controller.dart:551` — лишь call-site `selectorGroupTags`), `getSelected()` (→ замена парсинга `now`), `getIsExpand()`, `getItems()→OutboundGroupItemIterator`.

`state.proxiesJson` (сырой JSON из `/proxies`) **исчезает** → типизированная модель из `writeGroups`/`writeOutbounds`. `urltestNow` (static, `node_list_presenter.dart:62,74`, `node_list.dart:228`) и `proxyEntry()` (`home_controller.dart:590`) переписываются на `OutboundGroup.getSelected()`+`getItems()`.

**`Connection` (libbox) → единый адаптер → `AppConnection`.** Ввести **один** адаптер `Connection → AppConnection`, переписать на него все 4 места парсинга: `connections_screen.dart:271-306` (per-connection парсинг `metadata.*`, `rulePayload` на :305; строки :130-162 — это diff/accumulate-цикл, не парсинг полей), `stats_screen.dart:131-173`, `traffic_profiler._pollConnections`, `TrafficSnapshot.fromConnectionsJson` (`clash_api_client.dart:256`). Имена полей libbox отличаются от Clash `metadata.*`:

| Старое (Clash `metadata.*`) | Новое (libbox `Connection`) | Тип |
|---|---|---|
| `id` | `getID()` | string |
| `metadata.processPath` | `getProcessInfo().getProcessPath()` | string |
| `metadata.process` / packageNames | `getProcessInfo().packageNames()` (StringIterator), `getUserName()`, `getUserID()` | — |
| `metadata.host` | `getDomain()` | string |
| `metadata.destinationIP`/`Port` | `getDestination()` / `displayDestination()` | string |
| `metadata.network` | `getNetwork()` | string |
| `chains` | `chain()` (StringIterator) | — |
| `rule` | `getRule()` | string |
| `rulePayload` | **отдельного поля НЕТ** — проверить на железе (Q1), склеен ли payload в `getRule()` | — |
| `upload` / `download` | `getUplink()` / `getDownlink()` (long) | — |
| `start` | `getCreatedAt()` (long) | — |
| — (нет в Clash) | `getClosedAt()` (long) | closed-история (§3.3) |

**`rulePayload`-нюанс (HIGH).** В Clash `rule` и `rulePayload` — два поля (`rule="DOMAIN-SUFFIX"`, `rulePayload="google.com"`); by-rule агрегация в Stats (`stats_screen.dart` `byRule`) опиралась на оба. У libbox `Connection` — только `getRule()`. **Проверить на железе (Q1):** склеена ли в неё payload (`"DOMAIN-SUFFIX google.com"`). Если да — адаптер сплитит по первому пробелу; если нет — by-rule теряет payload-гранулярность (агрегация только по типу правила). Не блокер: by-rule в Stats остаётся per-connection и к `GetRules` (§4.7) не привязан.

**`DeprecatedNote`** *(новое, опц., фаза 2)*: `getName()`/`message()`/`messageWithLink()`/`impending()` через unary `getDeprecatedNotes()` → UI-нотис о deprecated-опциях конфига после `serviceReload`. Недостижимо через Clash API.

### §3.2. Connections — дельты, не снапшот *(BLOCKER)*

Принципиальное отличие от Clash: **нет `writeConnections`/нет pull-снапшота**. Handler получает поток событий `writeConnectionEvents(ConnectionEvents)`:

- `ConnectionEvents.getReset()` (boolean) — полный начальный снапшот / сброс состояния;
- `ConnectionEventIterator` — список дельт.

Каждый `ConnectionEvent`: `getType()` (`ConnectionEventNew=0` / `Update=1` / `Closed=2`), `getID()`, `getConnection()` (для `Closed` может быть частичным/неполным), `getUplinkDelta()` / `getDownlinkDelta()` (long), `getClosedAt()` (long).

**Решение — native-аккумулятор `Connections` (есть в нашем AAR).** Методы: `applyEvents(ConnectionEvents)`, `filterState(int)`, `sortByDate/sortByTraffic`, `iterator()`. Аккумулятор держится **в Kotlin** (проще сериализовать для Dart), а не реконструируется в Dart из событий. В Dart эмитится **полный снапшот** (сериализованный) на каждое изменение, **дросселированно** (backpressure — §2.2: батч + cap по образцу `coreLog`-drainer, `BoxService.kt:676`, `LOG_QUEUE_MAX=4096`, `DRAIN_BATCH_MAX=200`).

**Исключение — `traffic_profiler`** (§044): ему нужны именно **дельты** open/close, а не агрегированный снапшот. Для него EventChannel эмитит **события** (`ConnectionEventNew`/`Closed`), Dart не diff'ит снапшоты — это снимает ~1000 строк pull-diff-логики `_pollConnections`.

### §3.3. Closed-история *(наш AAR её уже даёт)*

Подтверждено декомпиляцией AAR: `Connection.getClosedAt()`, `ConnectionEvent.getClosedAt()`, `ConnectionEventClosed=2`, `ConnectionStateClosed=2`, `Connections.filterState/applyEvents`. Версионного разрыва нет — фаза 2 на том же ядре.

- **Апсайд:** показ закрытых соединений в Stats/Connections (новая фича, без апгрейда AAR) — точные `close`-события вместо «исчезло из снапшота» (чинит accumulate-баг профайлера).
- **Риск — рост памяти** (§10 MED): аккумулятор по умолчанию `filterState(ConnectionStateActive=1)`; closed копит **только когда соответствующий экран открыт**, с TTL/cap. closed-таб за фича-флагом (фаза 2).

---

## §4. URLTest / ping и контракт SPEC 014

«URLTest» в LxBox — это **четыре разные операции**; переход на CommandClient бьёт по ним по-разному, поэтому вынесено в отдельный раздел. Парный ядровой контракт — `URLTestOutbound` и `GetRules` из **SPEC 014** (`sing-box-lx/SPECS/014-LIBBOX_COMMAND_URLTEST_RULES`, build-tag `with_lx_command`); реализуется в форке ядра, не в этом репо.

### §4.1. Матрица операций

| Операция | Файл:строка | Сейчас (Clash) | На CommandClient | Объём |
|---|---|---|---|---|
| **Group URLTest** (`runGroupUrltest`) | `ping_orchestration.dart:169` | `GET /group/{tag}/delay` → `groupDelay()` (`clash_api_client.dart:143`) | штатный `urlTest(groupTag)` (императив); результат для членов группы через `writeGroups`, для node-list — через `writeOutbounds` (плоский, §4.3) | паритет 1:1 (нулевой дифф в ядре — не трогать) |
| **Auto-urltest группа** (`auto`) | `wizard_template.json:156-169` (`type:urltest`) | ядро пингует по `interval`, app read-only | то же — ядро делает само | не трогаем |
| **Single-node ping** (тап «Ping» на узле) | `runNodeUrltest` `ping_orchestration.dart:21`; UI `node_list.dart:272` | `GET /proxies/{tag}/delay` → `delay(tag)` (`clash_api_client.dart:117`) | **`URLTestOutbound(tag, link, timeout)`** (SPEC 014) — outbound ИЛИ endpoint | перенос на unary-команду (§4.4) |
| **Mass-ping** (кнопка Ping, concurrency=10) | `runMassUrltest` `ping_orchestration.dart:198`; авто-пинг `:149` | параллельные `delay(tag)`; отмена через отдельный `_delayHttp`-клиент (`clash_api_client.dart:20`, разрыв в `cancelDelays()` :218-219), точка входа `cancelMassPing()` (`ping_orchestration.dart:~291`) | worker-pool в **клиенте**, цикл `URLTestOutbound(tag)` concurrency=10; отмена клиентская | перепроектирование оркестрации (§4.5) |

### §4.2. Что НЕ меняется (структуры состояния)

`lastDelay: Map<tag,ms>` (`home_state.dart:85`), `pingBusy: Map<tag,str>` (`:86`), `pingBatchGen` (`:99`), per-group `url`/`timeout` (`ping_options.groups` в Storage) — **остаются как есть**, меняется только источник, который их наполняет. Читатели delay не трогаем: node_row ms-label/цвет (`node_row.dart:42-56`), §048-фильтр `maxPingMs` (`node_filter.dart:84,124`), latency-sort `_compareLatency` (`home_state.dart:161-171`).

### §4.3. Главный паттерн масс-пинга: команда триггерит, стрим — source of truth

worker-pool=10 живёт **в клиенте** (`ping_orchestration.dart:142`, `_pingConcurrency`); ядро меряет **один узел синхронно и stateless** (SPEC 014). Двойной путь данных:

```
                         клиент (Flutter)                          ядро (sing-box-lx)
  worker-pool=10  ──URLTestOutbound(tag, link, timeout)──►  меряет 1 узел синхронно
       │                                                         │  StoreURLTestHistory
       │   ◄────────── {delay, error} (unary-ответ) ────────────┘  (HistoryStorage)
       │        немедленный per-node feedback: pingBusy→ms              │
       │                                                               │ push при изменении
       └─── lastDelay[tag] синхронизируется ◄── writeOutbounds-стрим ──┘
              SOURCE OF TRUTH (getURLTestDelay/getURLTestTime per-node)
```

- **Worker-pool=10** — на клиенте (`ping_orchestration.dart:142`, `_pingConcurrency`). Ядро параллелизмом не управляет.
- **Синхронный `{delay,error}`-ответ** = немедленный per-node feedback (`pingBusy`→ms на `node_row.dart:42-56`), пока стрим не доехал.
- **`SubscribeOutbounds`-стрим = source of truth:** после замера ядро делает `StoreURLTestHistory`, стрим пушит обновлённый `getURLTestDelay()` → `lastDelay` синхронизируется. Так delay переживает и узлы, померенные **не нами** (групповой `urlTest`, авто-urltest группы).
- **Отдельный history-RPC НЕ нужен:** история delay живёт в ядре (`HistoryStorage`/`LoadURLTestHistory`), `StoreURLTestHistory` будит общий `urlTestObserver` → оба групповых стрима. **Карта каналов (SPEC 014 §3.2, проверено `started_service.go:1028-1084`):**
  - **Синхронный ответ RPC** — delay **любого** узла (outbound И endpoint), немедленно. Для ручного пинга одного узла — брать отсюда, не ждать стрим.
  - **`SubscribeOutbounds`** — все outbound'ы (`outboundManager.Outbounds()`) **И все endpoint'ы** (`endpointManager.Endpoints()`, WG/AWG/Tailscale), плоско. **Единственный стрим, где delay endpoint'а вообще появляется.** Живой node-list подписывается СЮДА.
  - **`SubscribeGroups`** — **только** узлы внутри `OutboundGroup`. Одиночные outbound вне групп и **любые endpoint'ы сюда НЕ попадают** — для них стрим групп бесполезен. Обновляется сам для членов групп, отдельной синхронизации не нужно.
- **Отмена масс-пинга** = клиентский флаг в worker-pool ИЛИ `disconnect`/реконнект conn → серверный `ctx.Done()` → in-flight замеры падают (единый механизм §2.3).

### §4.4. Single-node ping — перенос на `URLTestOutbound`

`runNodeUrltest` (`ping_orchestration.dart:21`) меняет `clash.delay(tag,…)` на `URLTestOutbound(tag, link, timeout)`. Команда резолвит тег в **обоих** менеджерах (`outboundManager.Outbound` → fallback `endpointManager.Get`), поэтому покрывает и WG/AWG/Tailscale-**endpoint**'ы, не только outbound. Логика UI (`pingBusy`/ms-label) не трогается. Это паритет со старым Clash `delay(tag)` без расточительного «пинговать всю группу ради одного узла».

### §4.5. Mass-ping — синхронный per-node, отмена клиентская

Тот же worker-pool **остаётся в клиенте**: цикл `await URLTestOutbound(tag)` по узлам, concurrency=10, порядок = display-list (`node_list_presenter.dart:174`). Авто-пинг (`_scheduleAutoPing`, Timer(5s) после connect, `:149`) → тот же mass-`URLTestOutbound`.

**Отмена — чисто клиентская:** флаг отмены в Dart-воркере; между итерациями перестаём слать следующие замеры, текущий in-flight (≤timeout) досинхронно завершается. `_delayHttp`-клиент (`clash_api_client.dart:20`) и его разрыв (`cancelDelays()` :218-219) **удаляются** вместе с `ClashApiClient` — синхронная команда на сокете их не требует. Жёсткая отмена in-flight (если потребуется) = `disconnect()`/разрыв conn → серверный `ctx.Done()` (один механизм на двух концах, §2.3).

### §4.6. Контракт `URLTestOutbound` (SPEC 014 §3.2)

unary-read RPC, реализуется ядром. Здесь — для клиентского маппинга; источник истины proto — SPEC 014.

```proto
// lx:begin lx_command
rpc URLTestOutbound(URLTestOutboundRequest) returns (URLTestOutboundResponse) {}
message URLTestOutboundRequest {
  string outboundTag = 1;   // тег outbound ИЛИ endpoint (НЕ группы)
  string link        = 2;   // пусто → https://www.gstatic.com/generate_204
  uint32 timeout     = 3;   // 0 → дефолт ядра; иначе МИЛЛИСЕКУНДЫ (не наносекунды)
}
message URLTestOutboundResponse {
  uint32 delay = 1;         // латентность, мс (движок uint16 → uint32)
  string error = 2;         // "" = ок; иначе причина (not-found/timeout/dial/bad-status)
}
// lx:end lx_command
```

**Клиентская gomobile-обёртка (SPEC 014 §3.2 — НЕ дословно из proto):** gomobile не биндит ни три возврата, ни `uint16`/`uint32`, поэтому AAR отдаёт struct-обёртку с геттерами (как `SystemProxyStatus`):
```go
URLTestOutbound(outboundTag, link string, timeout int32) (*URLTestOutboundResult, error)
type URLTestOutboundResult struct { Delay int32; Error string }  // геттеры getDelay()/getError() в Kotlin
```
Go-`error` возврата = **только транспортный сбой** (соединение/gRPC); прикладной исход — в `Result.Error` (Вариант B). `timeout` — `int32`, мс (0→дефолт). На Kotlin: `result.delay` (int), `result.error` (String).
```

**ИНВАРИАНТ КЛИЕНТА (критично):** источник истины провала — поле `error`, **не** `delay`. `delay` валиден ⟺ `error == ""`. Случай `delay==0 && error==""` = **успех 0 мс** (целочисленное `time.Since/time.Millisecond` для ответа <1мс, `urltest.go:133`), **не** ошибка. Клиент **не должен** трактовать `delay==0` как фейл — иначе ложный ERR на быстром узле. Все ошибки приходят в payload, `status.Error` не используется; not-found → `error="outbound or endpoint not found"`.

**Клиентский маппинг** (`ping_orchestration.dart`) — **двойной путь** (см. §4.3):
- **Синхронный ответ:** `error==""` → `lastDelay[tag]=delay` (включая 0мс); `error!=""` → `lastDelay[tag]=-1` (UI-контракт ERR/<0, `node_row.dart:42-56`) + текст `error` в debug-лог (замена `_formatProbeError`).
- **Анти-мигание (P1):** синхронный ответ — **якорь** на короткое окно (debounce ~N сек по образцу `pingBatchGen`-freeze, `home_state.dart:94`). В течение окна `SubscribeOutbounds`-стрим **не перезатирает** только что показанное per-node значение, лишь **дополняет** непомеренные узлы — иначе пользователь увидит «прыжок» (сначала из ответа, потом из стрима). После окна стрим — единственный source of truth.
- **`SubscribeOutbounds`-стрим:** дотягивает `getURLTestDelay()`/`getURLTestTime()` per-node как source of truth.

Per-group `link`/`timeout` (§040: `pingUrlFor`/`pingTimeoutFor`, `ping_options.groups`) шлются в команду без изменений resolve-chain. **Внимание на единицы:** `timeout` здесь — **миллисекунды** (в отличие от `setStatusInterval`, который на gomobile-уровне принимает **наносекунды** Go-`Duration`).

### §4.7. Контракт `GetRules` (SPEC 014 §3.3) — только диагностика

unary-read RPC, второй в SPEC 014:

```proto
rpc GetRules(Empty) returns (RuleList) {}        // proto: RuleList{repeated Rule}; клиент-обёртка: RuleIterator
message Rule { string type; string payload; string action; bool isDNS; }
```

Снапшот **route + DNS** правил из рантайм-роутера (`router.Rules()` + новый DNS-геттер `adapter.DNSRouter.Rules()` за `// lx:`). **Богаче Clash** — Clash DNS-правила не отдавал. Клиент использует `GetRules` **узко**: только для диагностики (`lxbox-diag.sh` / Debug API `/clash/rules`-over-CommandClient, см. §7) — **UI-экран «Rules» в §122 OUT OF SCOPE.** by-rule агрегация в Stats остаётся **per-connection** (`Connection.getRule()`, §3.1), к `GetRules` не привязана.

### §4.8. Конвенция: unary-read без `Command*`-константы

`URLTestOutbound` и `GetRules` — **unary-read** RPC (request→response), **не** подписки. Им **не заводится `Command*`-константа** (подписки конфигурируются полем `CommandClientOptions.StatusInterval` (int64, **наносекунды** — Go `Duration`) + `addCommand(int32)` — только для стримовых `CommandStatus`/`CommandConnections`/…). Это прямые методы `CommandClient`, как штатные `getDeprecatedNotes()`/`getSystemProxyStatus()`/`selectOutbound()`. Dart/gomobile-обёртки — `urlTestOutbound(...)→*URLTestOutboundResult{Delay int32, Error string}` (на gomobile-границе `delay` — `int32`/Kotlin `int`, не uint), `rules()→RuleIterator`; **без `Command`-префикса**. «Команды 0–5» (счётчик стримовых подписок, §2.4) **не меняется** — эти два RPC в него не входят.

### §4.9. §048 ping-фильтр — РЕШЕНО командой `URLTestOutbound`

§048-фильтр визуальный (`node_filter.dart:124-128`, fail-open: `delay==null` проходят, opacity 0.4 для non-match, locked decision #11) — он **не гейтит маршрутизацию**. `lastDelay` читают: node_row ms-label/цвет (`node_row.dart:42-56`), §048-фильтр `maxPingMs`, latency-sort `_compareLatency` (`home_state.dart:161-171`). Восстановление per-node delay на CommandClient — **решено** командой `URLTestOutbound` (§4.4/§4.6): точный per-node delay по тегу восстановлен, зависимость от штатного `urlTest`-на-селекторе снята. §048-фильтр и latency-sort работают как раньше, источник = `URLTestOutbound` вместо Clash `delay(tag)`.

### §4.10. Коллизия ключа `lastDelay` между группами — базовый фикс в §122, полное решение спин-офф

`lastDelay: Map<tag,ms>` ключуется **только тегом узла** (`home_state.dart:85`), без группы. Но узел входит **во все** selector-группы (`build_config.dart:416-444` суёт `selectorTags` в каждый selector), а группы имеют **разные** per-group ping-настройки (§040: G1→`ya.ru`, G2→`gstatic`). Замер из G2 затирает `lastDelay[node]` → UI в G1 показывает число, померенное чужим endpoint'ом; фильтр §048 и latency-sort в G1 работают по G2-числам. `setSelectedGroup` (`home_controller.dart:675`) `lastDelay` не сбрасывает; composite-ключа нет.

**Баг существует уже на Clash API** — миграция его не создаёт, но `URLTestOutbound` делает его **систематическим и воспроизводимым** (per-group `link`/`timeout` теперь шлём мы → расхождение замеров между группами перестаёт быть случайным).

**Обязательный минимум §122 (P1):** в `setSelectedGroup` (`home_controller.dart:675`, рядом с бампом `pingBatchGen`) **сбрасывать `lastDelay` при смене группы** — одна строка, убирает «соврало между группами» для пользователя сразу. Узлы перепингуются в контексте новой группы.

**Полное решение (out of scope §122)** — composite-ключ `group:node` (или per-group cache), чтобы delay не терялся при переключении туда-обратно — выносится в **отдельную таску** `docs/spec/tasks/NNN`. Базовый сброс (выше) — в §122; composite — в спин-офф.

---

## §5. Что удаляется (клиент)

Удаление выполняется в Фазе 1 (§8), за фича-флагом сосуществования. Поимённо — три категории: код контракта Clash, инъекция `clash_api` в конфиг, тестовые фикстуры.

### §5.1. Код контракта Clash

| Символ | Канон (файл:строка) | Действие |
|---|---|---|
| `ClashApiClient` | `clash_api_client.dart` | Удалить класс целиком |
| `TrafficSnapshot.fromConnectionsJson` | `clash_api_client.dart:256` | Удалить конструктор (JSON-парсинг исчезает) |
| `ClashHttpException` | `clash_api_client.dart` | Удалить тип |
| `ClashHttpException`-ветка | `error_format.dart:41` | Удалить ветку гуманизации (см. §10 MED — переезжает на `PlatformException`) |
| `ClashEndpoint.fromConfigJson` | `clash_endpoint.dart:13` | Удалить — больше не читаем `experimental.clash_api` |
| `_rebuildClashEndpoint` / `_clash` / `clashClient` | `home_controller.dart` | Удалить поля и метод сборки HTTP-клиента |
| `PerAppTraceTab.clash` | **живой потребитель** (рендерится `stats_screen.dart:286`, `.clash` читается на каждом poll `per_app_trace_tab.dart:58`) | **МИГРИРОВАТЬ** на `writeConnectionEvents`/аккумулятор — НЕ удалять |

**СОХРАНИТЬ** (доменные модели — наполняются из libbox, не Clash):
- `TrafficSnapshot`, `AppStat` — остаются, источник данных меняется на `StatusMessage`/`Connection` (см. §3.1, §3.2).
- `static urltestNow` / `proxyEntry` / `connectionIdsInChain` — **перенести** в новые адаптеры (`writeOutbounds`/`writeGroups`/аккумулятор `Connections`), не удалять логику.

### §5.2. routeFinalTag — ПЕРЕНЕСТИ, не удалять

`ClashEndpoint.routeFinalTag` (`clash_endpoint.dart:36`, читает `route.final` из конфига) — **не зависит от Clash API**, это парсер итогового outbound. Используется в `home_controller.dart:374` и `home_controller.dart:557`. При удалении `clash_endpoint.dart` функцию перенести в нейтральный модуль (например `config_inspect.dart` рядом с другими read-only парсерами конфига). Зависимость остаётся живой — это блокер удаления файла, а не самостоятельный риск (§10 LOW).

### §5.3. Инъекция clash_api в конфиг (builder/template)

| Что | Канон (файл:строка) | Действие |
|---|---|---|
| Блок `experimental.clash_api` в шаблоне | `wizard_template.json:602-605` | Удалить блок |
| UI-vars `clash_api` / `clash_secret` | `wizard_template.json:236,244` | Удалить var-объявления |
| `_ensureClashApiDefaults` + вызов | `build_config.dart:471-489` (метод), `build_config.dart:116` (вызов) | Удалить метод и его вызов из pipeline |

После выпила builder **никогда** не пишет `experimental.clash_api`. `generatedVars` осиротеет на ключах `clash_api`/`clash_secret` — допустимо, молча игнорируются (§10 LOW).

### §5.4. Тесты-фикстуры

Снять зависимость от `clash_api` в фикстурах и ассертах:
- `build_config_test` — убрать ожидание блока `clash_api` в выходе.
- `clash_endpoint_test` — переписать на тест `routeFinalTag` (после переноса), удалить кейсы `fromConfigJson`.
- `config_dirty_flag_test:95` — снять `clash_api`-завязку.
- `pipeline_e2e_test` — обновить эталон выходного конфига (нет `clash_api`).
- `detour_append_replace_test` — обновить, если эталон содержал `clash_api`.

---

## §6. Обратная совместимость подписок и бэкапов

### §6.1. Импорт чужого конфига — вырезать clash_api

Пользователь импортирует sing-box-конфиг (подписка / ручной JSON), где `experimental.clash_api` **уже присутствует**. Недостаточно «не добавлять свой» — builder/validator **ОБЯЗАН активно вырезать** блок при импорте.

Мотив (см. §1a): пока проектный `.so` линкует Clash server, чужой `clash_api` в импортированном конфиге **откроет живой TCP-порт** на 127.0.0.1 (наша гигиена обнулится через чужой конфиг). После rc.1 (server вырезан) — деградирует до мёртвой no-op опции, но всё равно нежелательна (ядро парсит мёртвое поле). Вырезание — в импорт-пайплайне, согласовано с §159 (import allowlist).

### §6.2. Старые бэкапы — clash_api/secret в vars

Бэкапы, сделанные до §122, несут `clash_api`/`clash_secret` в `vars`. После удаления var-объявлений (§5.3) §159 default-deny **молча отбросит** эти ключи при восстановлении — поломки нет, значения просто исчезают. Задокументировать в migration notes (§13) и покрыть тестом (§11).

### §6.3. Матрица совместимости

| Сценарий | Поведение после §122 |
|---|---|
| Импорт подписки с `clash_api` | Блок вырезан на импорте, порт не открыт |
| Восстановление бэкапа с `clash_api`/`secret` в vars | Ключи молча отброшены §159, восстановление успешно |
| Экспорт конфига после §122 | `clash_api` отсутствует в выходе |
| Внешний Clash-подписчик к нашему порту | Невозможен — порт не открывается ни в release, ни в debug |

---

## §7. Диагностика — полный отказ от Clash HTTP

`lxbox-diag.sh` снимал четыре артефакта curl'ом к Clash-порту (`scripts/lxbox-diag.sh:106-109`): `clash_connections.json`, `clash_proxies.json`, `clash_rules.json`, `clash_version.json` (за флагом `SKIP_CLASH`). После §122 Clash-порт не существует — все четыре переезжают **без единого Clash HTTP-запроса**.

| Артефакт (был) | Источник (стало) | Слой |
|---|---|---|
| `clash_connections.json` | Debug API `/clash/connections`, переписанный поверх `CommandClient` (аккумулятор `Connections`) | server-stream (cmd 4) |
| `clash_proxies.json` | Debug API `/clash/proxies` поверх `CommandClient` (`writeGroups`/`writeOutbounds`) | server-stream (cmd 2/5) |
| `clash_rules.json` | `GetRules()` (SPEC 014, unary) | unary-read |
| `clash_version.json` | `Libbox.version()` | нативный вызов |

Уточнения:
- `/clash/*` в `debug/` — это **НАШ Debug API** (CRUD кастом-правил §030/§031), а не Clash-core. Имя пути историческое; за ним теперь стоит `CommandClient`, не HTTP-петля к ядру.
- `/state/clash` поле `api_ok` переопределяется: было «Clash HTTP отвечает» → стало **«CommandClient connected: bool»**.
- `GetRules()` богаче Clash (отдаёт DNS-правила, которых Clash не давал) — **только для диагностики**, UI-экрана Rules в §122 нет (OUT OF SCOPE).
- Инвариант: после §122 grep по `lxbox-diag.sh` и Debug API на `CLASH_BASE`/HTTP-`:9090` даёт ноль попаданий.

**§7.1. Независимая наблюдаемость канала (P1).** Диагностика не должна зависеть от того же `CommandClient`, который диагностирует — если клиент не подключился, `GetRules`/connections-снапшот мёртвы вместе с ним, а `api_ok=connected` лишь скажет «нет». Нужен **независимый сигнал здоровья мимо CommandClient**, через Debug API: счётчик пропущенных `StatusMessage`, время с последнего push, состояние backoff/реконнекта. Позволяет дебажить «канал не поднялся» в проде, не имея самого канала.

**§7.2. Поведение клиента на ядре без `with_lx_command` (стык §122↔SPEC 014, P1).** SPEC 014 гарантирует `codes.Unimplemented` для `URLTestOutbound`/`GetRules`, если ядро собрано без тега (usbip-stub-паттерн). Клиент обязан **graceful degrade**: single-ping ловит `Unimplemented` → fallback на групповой `urlTest` ИЛИ баннер «per-node ping недоступен на этой сборке ядра»; `GetRules` → пустая таблица в diag. Не падать.

---

## §8. Фазы

Все три фазы реализуемы на одном ядре `v1.14.0-lx.1-rc.2` — версионного разрыва нет (декомпиляция AAR подтвердила команды 0-5 и closed-историю).

**Фаза 0 — нативный канал (Kotlin/JNI, без UI-изменений).**
- Новый `BoxCommandClient.kt`; правки `VpnPlugin.kt` (EventChannel'ы + MethodChannel-проброс императивов), `BoxService.kt` (`statusClient.connect` после `startCommandServer`, рядом с `CommandServer` на `BoxService.kt:179`).
- **Три клиента (§2.8):** `statusClient` (always-on, `Status`+`setStatusInterval` 1s), `screenClient` (`Outbounds`+`Groups`+`Connections`, lifecycle по экрану), `profilerClient` (`Connections`, lifecycle по recording). Каждый — свой `CommandClientHandler`, эмитит в свой набор EventChannel-sink'ов.
- `CommandClientHandler`-колбэки — **КАЖДЫЙ** в `try/catch` fail-safe (JNI-no-throw; unchecked exception через JNI = `Runtime::Abort` всего процесса — см. память `project_jni_callbacks_must_not_throw`). Неиспользуемые клиентом колбэки — no-op (но всё равно в try/catch).
- `addCommand(...)` per-клиент (не все 0-5 на одном) + `setStatusInterval` на statusClient (**НАНОсекунды** Go `Duration` = `1_000_000_000L` для 1s; НЕ путать с `URLTestOutbound.timeout` который мс).
- Lifecycle: `statusClient.connect` только на статус `Starting`/`Started` (сокет существует лишь после старта сервера); реконнект+backoff на `disconnected`. `screenClient`/`profilerClient` — connect/disconnect по сигналам из Dart (MethodChannel: открытие экрана / start-stop recording).
- Нативный аккумулятор `Connections` (под `screenClient`+`profilerClient`, refcount) + дросселированный эмиттер (батч по образцу core-log drainer `BoxService.kt:676`, `LOG_QUEUE_MAX=4096`, `DRAIN_BATCH_MAX=200`).
- **Без фича-флага** (решение: CommandClient сразу основной). Откат — через git/ветку, не рантайм-переключатель. Весь Фаза-0-код на ветке `feat/libbox-1.14-migration`, рабочий HTTP-путь не трогается до Фазы 1.

**Фаза 1 расщеплена на 1a (миграция, обратимо) и 1b (выпил, необратимо)** — чтобы железные проверки шли при ещё живом Clash за флагом, а удаление кода — только после того как 1a отъездила на устройстве. Фича-флаг (Фаза 0) **атомарен на весь control-channel** — не поэкранный, иначе гибридный UX (один экран push-1с, другой по-старому).

**Фаза 1a — миграция UI на стримы/команды (`ClashApiClient` ЖИВ за флагом).**
- `writeStatus` → скорость (дельта/интервал, B/s при 1s); `HomeController.heartbeat` → watchdog (см. §2.2 таймаут).
- `writeOutbounds` → node-list (`node_list*.dart`) и масс-пинг; `writeGroups` → группы (`getSelectable`, замена `type=='Selector'`).
- `selectOutbound`; `URLTestOutbound` (масс-пинг worker-pool=10 в клиенте + single); §143 interrupt-on-switch.
- `writeConnectionEvents` → нативный аккумулятор → `StreamBuilder` на **4 экранах**: `stats_screen`, `connections_screen`, профайлер, **`PerAppTraceTab`** (живой потребитель, §5.1) + `TrafficProfiler.bindRuntime` на `Stream<ConnectionEvent>`.
- **Здесь закрываются Q5/Q6/Q8 на железе** (Q1/Q3/Q4 уже сняты кодом, §9). Откат = флаг на `ClashApiClient` (код ещё на месте).

**Фаза 1b — выпил clash_api (необратимо, ТОЛЬКО после валидации 1a на устройстве).**
- Удаление `ClashApiClient`/`ClashEndpoint`/инъекции (§5), вырезание из импорта (§6.1, Q7), фикстуры (§5.4).
- **После 1b единица отката — релиз целиком, не фича-флаг** (код Clash удалён). См. AC §12.10.
- Команды 0-5 + императивы доступны уже на 1.13-поверхности.

**Фаза 2 — расширения (опциональны, поверх closed-истории ядра).**
- Closed-таб: `getClosedAt`-история, TTL/cap, дефолт `filterState(Active)`.
- Опц. NQ/STUN; опц. логи на `SubscribeLog`; `getDeprecatedNotes` → UI-нотис о deprecated-опциях конфига.

### §8.1. Прод-миграция рантайма живого пользователя (P1)

§5/§6 покрывают миграцию *данных* (бэкапы/импорт), но не *рантайм* апдейта. Пользователь обновляется со старого AAR (Clash-порт открыт, HTTP-петля активна) на rc.2 (порт закрыт, `CommandClient`). Требование: **чистый рестарт `BoxService` при апдейте** — не переиспользовать состояние старого канала (старый `ClashApiClient`-endpoint с мёртвым портом/секретом, висящие HTTP-таймеры). При первом старте новой версии: старый канал не реанимируется, поднимается только `CommandClient`. Покрыть тестом «апдейт поверх сессии со старым каналом».

---

## §9. Открытые вопросы (требуют железной проверки)

Телефон `CE8XX48PCI79U4XG` сейчас не подключён — пункты разрешаются на железе до закрытия соответствующей фазы.

| # | Вопрос | Где влияет | Фаза |
|---|---|---|---|
**Закрыто чтением кода ядра (экспертиза SPEC 014, НЕ требует железа):**
- ~~Q1~~ `getRule()` = `rule.String()`, payload включён в строку → адаптер сплитит по первому пробелу (§3.1).
- ~~Q3~~ `delay==0 && error==""` = успех подтверждён `urltest.go:133` + handler (§4.6).
- ~~Q4~~ резолв endpoint реализован (`Endpoint` встраивает `Outbound`) → `URLTestOutbound` на WG/AWG работает (§4.4).
- ~~Q2~~ снят: `activeConnections` = размер аккумулятора после `filterState(Active)`, не сумма счётчиков (§3.1).

**Остаются на железе (клиентская обвязка, не ядро):**

| # | Вопрос | Где влияет | Фаза |
|---|---|---|---|
| Q5 | Реконнект `CommandClient` при рестарте ядра — без утечки/двойной подписки? | Фаза 0 lifecycle | 0 |
| Q6 | JNI-краш-тест колбэков на старом Android (повтор `Runtime::Abort`) | 11 fail-safe колбэков | 0 |
| Q7 | Импорт чужого `clash_api` → блок вырезан, порт не открыт (после rc.2-AAR) | §6.1 | 1b |
| Q8 | `EventChannel` рвётся, если `BoxVpnService` уедет в `:bg`? (зафиксировать тестом) | §2.1 инвариант эмиттера | 0 |
| Q9 | Локаль-краш `setLocale(ru_IL)` в onCreate (из `[[project_libbox_114_migration_api_breaks]]`) — повтор на 1.14-обвязке | смежно, напоминание | 0 |

---

## §10. Риски (severity)

| Sev | Риск | Митигация |
|---|---|---|
| **BLOCKER** | Концептуальная путаница `CommandServer` ⟂ `ClashAPI`: §122 меняет **контракт данных**, а не транспорт (CommandServer держим in-process всегда) | Явно зафиксировано в §0-§4; ревью на «не трогаем CommandServer» |
| **BLOCKER** | `EventChannel` в `:bg` рвётся — эмиттер обязан жить во Flutter-процессе (как `coreLogSink`) | Однопроцессная модель (§2.1); комментарий-инвариант + тест (Q8) |
| **BLOCKER** | Connections приходят **только дельтами** (нет `writeConnections`/pull) | Нативный аккумулятор `Connections` (`applyEvents`/`filterState`), эмит снапшота дросселированно (§3.2) |
| HIGH | 3 `Timer.periodic` → 1 push: backpressure | Нативное дросселирование + батч по образцу core-log drainer (§2.2) |
| HIGH | `TrafficProfiler` ~1000 строк pull-diff (`_pollConnections`) переписать на `ConnectionEventNew/Closed` | Профайлеру эмитим **события** (дельты open/close), не снапшот (§3.2) |
| HIGH | Имена полей `Connection` другие + риск потери `rulePayload` | Маппинг-таблица (§3.1); Q1 на железе |
| HIGH | `lxbox-diag` теряет 4 артефакта | Debug-over-CommandClient + `GetRules` + `Libbox.version()` (§7) |
| HIGH | Импорт чужого `clash_api` открыл бы порт | Вырезать на импорте (§6.1) |
| HIGH | Debug `/clash/*` proxy переписать поверх CommandClient | §7; сохранить контракт путей |
| HIGH | `CommandClient` lifecycle/реконнект (сокет только после старта сервера) | Коннект на `Starting/Started`, backoff на `disconnected` (Фаза 0) |
| HIGH | Dead-tunnel ложные срабатывания на РФ-LTE (радио-джиттер/хэндовер БС) | watchdog-таймаут **8–10с** (≥5–6 пропущенных тиков), «один haptic на серию» (`_heartbeatFailNotified`); НЕ агрессивнее — иначе ложные «соединение потеряно» бьют в боль форума (§2.2) |
| MED | 11 JNI-колбэков должны быть fail-safe | Каждый в `try/catch` (память JNI-no-throw) |
| MED | Closed-история рост памяти | TTL/cap, дефолт `filterState(Active)` (Фаза 2, §3.3) |
| MED | `setStatusInterval` в наносекундах (легко ошибиться) | Явный комментарий; не путать с `URLTestOutbound.timeout` (мс, §4.6) |
| MED | Бэкапы `clash_api` молча отброшены | Документировать (§6.2) + тест |
| MED | `ClashHttpException`-гуманизация (`error_format.dart:41`) | Переезд на `PlatformException` |
| MED | §042 health watchdog (Draft) спроектирован под `clash.fetchTraffic` | Переписать data-source на `StatusMessage` |
| LOW | `routeFinalTag` перенести (`clash_endpoint.dart:36`) | §5.2 — перенос в нейтральный модуль |
| LOW | `generatedVars` осиротеет на `clash_api`/`clash_secret` | Молча игнорируются |
| HIGH | `PerAppTraceTab` — живой потребитель `ClashApiClient` (per-app trace §048), мигрировать на аккумулятор | Переписать на `Stream<ConnectionEvent>` как 4-й экран в §3.2 |

---

## §11. Test plan

### §11.1. Unit
- **Builder**: выход НЕ содержит `experimental.clash_api`; `_ensureClashApiDefaults` отсутствует (build_config_test обновлён).
- **Import-allowlist**: вход с `experimental.clash_api` → выход без него (§6.1); тест на инвариант «порт не открыт».
- **Backup-restore**: восстановление бэкапа с `clash_api`/`secret` в vars → ключи отброшены, остальное цело (§6.2).
- **routeFinalTag**: после переноса читает `route.final` корректно (clash_endpoint_test → новый модуль).
- **Адаптеры**: `writeOutbounds`→node-list маппинг; `writeGroups` `getSelectable`→`Selector`/`getSelected`→`now`; аккумулятор `Connections.applyEvents` (New/Update/Closed, `getReset`).
- **URLTestOutbound инвариант**: `delay==0 && error==""` ⇒ успех; `error!=""` ⇒ единственный признак фейла.
- **Error-format**: `PlatformException` гуманизируется вместо `ClashHttpException`.

### §11.2. Widget
- `stats_screen` / `connections_screen` на `StreamBuilder` (нет `Timer.periodic`) — рендер при push.
- Node-list ms-label/цвет из `getURLTestDelay` (push-обновление после `URLTestOutbound`).
- §048 фильтр: untested (`delay==null`) fail-open проходит; `maxPingMs` гейтит по восстановленному per-node delay.
- Группы: переключение селектора (`selectOutbound`) отражается из `writeGroups`.

### §11.3. E2E на железе (`CE8XX48PCI79U4XG`)
Закрывает Q1–Q8 (§9). Обязательны до закрытия фаз:
- Q4 `URLTestOutbound` на WG/AWG-endpoint; Q3 `delay==0`-успех.
- Q1 `getRule`/`rulePayload`; Q2 `activeConnections`-семантика.
- Q5 реконнект при рестарте ядра; Q6 JNI-краш на старом Android; Q8 `:bg`-разрыв EventChannel.
- Q7 импорт чужого `clash_api` → `adb`-проверка: TCP-порт 127.0.0.1 НЕ слушается.
- Регресс: масс-пинг (worker-pool=10) per-node feedback; profiler open/close-дельты; dead-tunnel watchdog срабатывает на разрыв.

---

## §12. Acceptance criteria

1. Clash HTTP-порт **не открывается** ни в release, ни в debug (`adb shell ss -tnp` — нет listener на Clash-порту), в т.ч. после импорта чужого `clash_api`.
2. Builder не эмитит `experimental.clash_api`; импорт вырезает существующий блок.
3. Канал управления UI↔ядро идёт **только** через `CommandClient` (нет `ClashApiClient` в коде; grep чист). Все потребители мигрированы, включая **`PerAppTraceTab`** (живой, на аккумулятор — не удалён).
4. Все 11 JNI-колбэков в fail-safe `try/catch`; Q6 не воспроизводит `Runtime::Abort`.
5. `stats_screen`/`connections_screen`/профайлер работают на push-стримах, без `Timer.periodic`; backpressure не приводит к ANR.
6. Масс-пинг и single-ping через `URLTestOutbound`; per-node delay восстановлен; §048 фильтр гейтит по нему; инвариант `delay==0&&error==""`=успех соблюдён.
7. `heartbeat`→watchdog корректно ловит dead-tunnel (нет `StatusMessage` > таймаут / `disconnected`).
8. `lxbox-diag.sh` собирает connections/proxies/rules/version **без** Clash HTTP; `/state/clash.api_ok` = «CommandClient connected».
9. Бэкап со старыми `clash_api`-vars восстанавливается без ошибок (ключи отброшены).
10. Откат: **до Фазы 1b** — атомарный фича-флаг на весь канал (HTTP-петля жива); **после 1b** — единица отката релиз целиком (код Clash удалён, флаг откатывает «в пустоту» — иллюзии вечной страховки нет).
11. Проектный AAR синхронизирован с rc.1 (server-less): в `.so` нет `(*Server).Start`/`setupMetaAPI`/`NewServer` (обязательный сопутствующий шаг §1a, не блокер).

---

## §13. Документация к обновлению

- `docs/spec/features/031 debug api` — `/clash/*` и `/state/clash.api_ok` переопределены поверх CommandClient (§7).
- `docs/spec/features/042 health watchdog` (Draft) — data-source `clash.fetchTraffic` → `StatusMessage` (§10 MED).
- `docs/spec/features/016 statistics and connections` — переход на push-стримы/аккумулятор.
- `docs/spec/features/044 per-app traffic profiler` — pull-diff → `ConnectionEvent`-дельты.
- `docs/spec/features/048 home-node-filters` — per-node delay через `URLTestOutbound` (§4.9 решён).
- `docs/DIAGNOSTICS.md` + `scripts/lxbox-diag.sh` — новые источники четырёх артефактов (§7).
- **Migration notes** (новый раздел / changelog §122): импорт вырезает `clash_api`; старые бэкапы теряют `clash_api`/`secret`-vars молча (§6).
- **Спин-офф таска** (OUT OF SCOPE §122): коллизия ключа `lastDelay:Map<tag,ms>` между selector-группами с разными per-group ping-настройками (§4.10) → завести `docs/spec/tasks/NNN.md`.
- Связанная ядровая спека: `sing-box-lx/SPECS/014-LIBBOX_COMMAND_URLTEST_RULES` (SPEC 014) — держать синхронной.

---

> **Железные проверки отложены.** Телефон `CE8XX48PCI79U4XG` сейчас НЕ подключён — все пункты Q1–Q8 (§9) разрешаются на устройстве до закрытия соответствующих фаз; до этого момента статус спеки остаётся Draft.
>
> **Сопутствующий обязательный шаг.** Синхронизировать проектный AAR (`app/android/app/libs/libbox.aar`) с релизным `v1.14.0-lx.1-rc.1` (server-less): убедиться, что в `.so` отсутствуют рантайм-символы `(*Server).Start`/`setupMetaAPI`/`clashapi.NewServer` (§1a, AC §12.11). Не блокер миграции, но без него довод мотивации №1 остаётся в conditional-состоянии.