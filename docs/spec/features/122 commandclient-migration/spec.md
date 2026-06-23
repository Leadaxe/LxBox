# §122 — Переход на libbox CommandClient (отказ от Clash API)

| Поле | Значение |
|---|---|
| Статус | Draft |
| Дата | 2026-06-24 |
| Связанные spec'ы | §012 (native vpn service), §121 (libbox-1.14-adoption — родитель), §016 (statistics & connections), §044 (per-app profiler), §048 (home-node-filters), §042 (health watchdog — data-source переезжает сюда), §031 (debug api), §043/§010 (core-log — НЕ затрагивается) |
| Память | [[project_libbox_114_migration_api_breaks]], [[project_jni_callbacks_must_not_throw]], [[project_dns_routing_king]], [[feedback_no_destructive_diagnostics]] |
| Затронутые файлы | `app/lib/services/clash_api_client.dart`, `app/lib/config/clash_endpoint.dart`, `app/lib/controllers/home_controller.dart` (+`heartbeat.dart`/`ping_orchestration.dart`/`config_io.dart`), `app/lib/screens/{connections_screen,stats_screen}.dart`, `app/lib/services/traffic_profiler.dart`, `app/lib/screens/home_screen.dart`, `app/lib/services/debug/handlers/{clash,action,state,profiler,help}.dart`, `app/lib/services/builder/build_config.dart`, `app/assets/wizard_template.json`, Kotlin `BoxService.kt`/`VpnPlugin.kt`/`BoxApplication.kt`, `scripts/lxbox-diag.sh`, `docs/{ARCHITECTURE,STORAGE,DIAGNOSTICS}.md` |

---

## 0. Главный тезис (читать первым)

**Это не рефактор транспорта — это замена контракта данных.** Clash API HTTP (RESTful listener на 127.0.0.1:63130, который поднимает **само ядро sing-box** из блока `experimental.clash_api`) и libbox `CommandServer`/`CommandClient` (unix-socket `command.sock`) — два **независимых** механизма ядра. Они отдают пересекающиеся, но не идентичные данные:

- **доставка**: Clash = pull-снапшот (`GET /connections` → полный список); CommandClient = push-дельты (`writeConnectionEvents(ConnectionEvents)`, нет `writeConnections`).
- **имена полей Connection другие**: `metadata.processPath`/`upload`/`download`/`start`/`chains`/`rule`/`rulePayload` (Clash) vs `ProcessInfo.getProcessPath()`/`getUplink()`/`getDownlink()`/`getCreatedAt()`/`chain()`/`getRule()` (CommandClient — `rulePayload` отдельным полем НЕТ).
- **управление**: `selectOutbound(group, outbound)`, `urlTest(group)`, `closeConnection(id)` — паритет есть; **single-node `delay(tag)` аналога НЕТ** (см. §4.5, BLOCKER-кандидат для §048).

Спека, написанная как «та же труба, другой сокет», породит регрессы. Каждое место парсинга `/connections` (4 шт.) переписывается на новый объект.

---

## 1. Мотивация

1. **Безопасность.** `experimental.clash_api.external_controller` заставляет ядро открыть **слушающий TCP-порт на 127.0.0.1** (рандомизируется в 49152–65535, `build_config.dart:471-487`; на устройстве ~63130). На Android `127.0.0.1` доступен **любому** приложению в системе — secret (`Authorization: Bearer`) единственная защита, и он лежит в конфиге на диске. CommandClient ходит через приватный unix-socket `command.sock` в `filesDir` (права процесса-владельца) — поверхность атаки исчезает. `BoxService.kt:436-437` уже фиксирует, что «CommandServer держал binding на Clash API port (63130)» — порт реально живёт.
2. **Нативность.** CommandClient — штатный канал libbox для GUI-клиентов (SagerNet/SFA через него и работают). Мы уже держим `CommandServer(this, platformInterface)` in-process (`BoxService.kt:342`), но потребляем данные кружным путём через HTTP-петлю. CommandClient — прямой потребитель того же сервера.
3. **Потенциал (недостижим через Clash).** `StatusMessage` отдаёт **готовую скорость от ядра** (`getUplink()/getDownlink()`, байт/с) — сейчас `fetchTraffic()` (`clash_api_client.dart:203`) считает дельту сам поверх `/connections`-агрегации. Сверх того доступны: `getDeprecatedNotes()` (предупреждения о deprecated-опциях конфига), `ConnectionEvent`-дельты (точные open/close без diff'а снапшотов), `getClosedAt()`/`ConnectionStateClosed` (closed-история alpha.33, есть в нашем AAR), `startNetworkQualityTest`/`startSTUNTest`. Ничего из этого Clash REST не даёт.

---

## 2. Архитектура

### 2.1 Процессная модель (ядро решения — разрешено явно)

**Precondition (проверена):** приложение **одно-процессное** — у `BoxVpnService` в `AndroidManifest.xml` нет `android:process` (grep по `android/` = 0 вхождений). `BoxService` (CSH + `CommandServer`), `BoxVpnService` (PI), Flutter-engine (`VpnPlugin`) и Go-ядро живут в `com.leadaxe.lxbox`.

**Решение (Final, см. §6 #1): CommandClient поднимается в Kotlin, в main-процессе, рядом с CommandServer в `BoxService` — НО эмиттер данных в Dart (EventChannel sink) обязан жить там же, где Flutter-engine.** Поскольку сейчас всё в одном процессе, это совпадает. **Жёсткое ограничение на будущее:** если `BoxVpnService` когда-либо уедет в `:bg` (`android:process`), `EventChannel`-sink порвётся (он не кросс-процессный — как `coreLogSink`, `@Volatile companion`, виден только в своём процессе). Поэтому в коде новый класс-мост `BoxCommandClient` обязан эмитить через тот же `binaryMessenger`, что `VpnPlugin` (main-процесс), а не через companion-поле, читаемое из чужого процесса. Сегодня — реализуем по образцу `coreLog`-pipeline; инвариант «эмиттер в Flutter-процессе» фиксируем комментарием и тестом процессной модели.

```
┌─────────────────────── процесс com.leadaxe.lxbox (ОДИН) ───────────────────────┐
│                                                                                 │
│  ┌── Flutter engine ──────────────┐         ┌── Go-ядро sing-box (libbox JNI) ──┐│
│  │ HomeController / stats_screen  │         │  CommandServer (unix socket)      ││
│  │ connections_screen / profiler  │         │   command.sock                    ││
│  │   (Dart, Stream-подписчики)    │         │   /data/.../files/command.sock    ││
│  └──────────▲─────────────────────┘         └──────▲────────────────────────────┘│
│             │ EventChannel(s)  +  MethodChannel(imperative)                       │
│             │ (status/groups/connections push;  selectOutbound/urlTest/close)     │
│  ┌──────────┴───────── Kotlin (VpnPlugin + BoxService) ──────────────────────┐    │
│  │  NEW: BoxCommandClient                                                     │    │
│  │    CommandClient(handler=BoxCommandClientHandler, opts addCommand 1..5)    │────┘ connect()
│  │    handler.writeStatus/writeGroups/writeOutbounds/writeConnectionEvents…   │  via command.sock
│  │    → marshal → EventChannel.sink.success(json)  [main-process sink]        │
│  │    imperative: selectOutbound/urlTest/closeConnection/closeConnections     │
│  └───────────────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────────┘
```

CommandServer уже стартует в `onStartCommand`-корутине (`BoxService.kt:179`) после барьера `BoxApplication.libboxReady`. `command.sock` ядро кладёт в `basePath = filesDir` (`BoxApplication.kt:80,89`) = `/data/data/com.leadaxe.lxbox/files/command.sock`.

### 2.2 Инверсия push vs poll

| | Было (Clash HTTP, pull) | Станет (CommandClient, push) |
|---|---|---|
| Скорость/трафик | `heartbeat.dart:53` `fetchTraffic()` каждые 20с | `writeStatus(StatusMessage)` push, `setStatusInterval(≈1s)` |
| Группы/узлы | `heartbeat.dart:65` `fetchProxies()` + `home_controller.dart:544` | `writeGroups(OutboundGroupIterator)` push |
| Connections (Stats) | `stats_screen.dart:115` Timer 3с | `writeConnectionEvents` дельты, native-аккумулятор → snapshot push |
| Connections (экран) | `connections_screen.dart:130` Timer 2с | то же |
| Profiler Source B | `traffic_profiler.dart:_pollConnections` 1–2с (`home_screen.dart:128`) | `ConnectionEventNew/Update/Closed` push |
| Логи | НЕ через Clash (push из Kotlin, §043) | без изменений (опц. перевести на `writeLogs`, см. §7 фаза 2) |
| Liveness | `pingVersion()` `home_controller.dart:543` | `connected()`/`disconnected()` колбэки |

**Влияние на state-слой:**
- `HomeController.heartbeat` (`heartbeat.dart`) перестаёт быть активным поллером. Превращается в **watchdog** «давно не было `StatusMessage` / пришёл `disconnected`» → dead-tunnel (см. §4.3). Интервал 20с из §141 остаётся как watchdog-таймаут, не как poll-период.
- `stats_screen.dart` / `connections_screen.dart` — `StatefulWidget` с `Timer.periodic`+`setState` → `StreamBuilder` поверх нового EventChannel-стрима. Поле `final ClashApiClient clash` (`stats_screen.dart:27`, `connections_screen.dart:55`) удаляется/заменяется на DI стрима.
- `TrafficProfiler.bindRuntime(connections: () => …fetchConnections())` (`home_screen.dart:128`, `traffic_profiler.dart:85-93`) меняет сигнатуру: вместо `ConnectionsFetcher`-callback → подписка на `Stream<ConnectionEvent>`. `_pollConnections` (`traffic_profiler.dart:910-1086`) c ручным diff'ом open/close переписывается на приём нативных событий.

### 2.3 Таблица соответствия (каждый вызов → эквивалент → где сейчас)

| Текущий Clash-вызов | Файл:строка | CommandClient-эквивалент |
|---|---|---|
| `fetchTraffic()` → `TrafficSnapshot` | `heartbeat.dart:53` | `writeStatus` → `StatusMessage.getUplink/Downlink/UplinkTotal/DownlinkTotal/Memory/ConnectionsIn/Out` |
| `fetchProxies()` | `home_controller.dart:544`, `heartbeat.dart:65` | `writeGroups(OutboundGroupIterator)` (subscribe `CommandGroup=2`) |
| `selectorGroupTags()` (`type=='Selector'`) | `home_controller.dart:551` | `OutboundGroup.getSelectable()` (семантика, не type-строка) |
| `proxyEntry()` / `urltestNow()` | `home_controller.dart:590`, `node_list.dart:228-232`, `node_list_presenter.dart:62,74` | `OutboundGroup.getSelected()` + `getItems()` |
| `selectInGroup(group, tag)` | `home_controller.dart:622` | `selectOutbound(groupTag, outboundTag)` — **двухаргументный** |
| `delay(tag)` single-node | `ping_orchestration.dart:30,234` | **НЕТ прямого аналога** — см. §4.5 |
| `groupDelay(group)` | `ping_orchestration.dart:174` | `urlTest(groupTag)` → результат через `writeGroups`→`OutboundGroupItem.getURLTestDelay()` |
| `cancelDelays()` | `ping_orchestration.dart:292` | нет аналога (`urlTest` fire-and-forget) — см. §4.5 |
| `fetchConnections()` | `home_controller.dart:630`, `stats_screen.dart:115`, `connections_screen.dart:130`, `traffic_profiler` | `writeConnectionEvents` + native `Connections.applyEvents()` аккумулятор |
| `connectionIdsInChain(conns, group)` | `home_controller.dart:631` | native-аккумулятор: фильтр по `Connection.chain().contains(group)` |
| `closeConnection(id)` | `home_controller.dart:639`, `connections_screen.dart:174` | `closeConnection(id)` (паритет) |
| `closeAllConnections()` | `connections_screen.dart:181`, recovery §087 | `closeConnections()` (паритет) |
| `pingVersion()` | `home_controller.dart:543`, `state.dart:50` | `connected()` колбэк (liveness); версия — `Libbox.version()` через `getCoreVersion` MethodChannel |
| `/clash/*` Debug proxy | `debug/handlers/clash.dart:19` | переписать поверх MethodChannel→CommandClient (см. §5) |
| `/state/clash → api_ok` | `debug/handlers/state.dart:48-52` | `api_ok` = «CommandClient connected: bool» |

---

## 3. Модель данных

### 3.1 Маппинг AAR-структур на Dart-модели

**StatusMessage → `TrafficSnapshot`** (`clash_api_client.dart:223`):
| Dart-поле | Источник | Примечание |
|---|---|---|
| `uploadTotal` | `getUplinkTotal()` (long) | сейчас агрегируется из `/connections` |
| `downloadTotal` | `getDownlinkTotal()` (long) | то же |
| `uploadSpeed`/`downloadSpeed` (новое) | `getUplink()/getDownlink()` (long, B/s) | **апгрейд** — готовая скорость от ядра |
| `memory` | `getMemory()` (long) | сейчас из `/connections`-топа |
| `activeConnections` | `getConnectionsIn()+getConnectionsOut()` (int) | **проверить семантику на железе:** in+out vs `len(connections)`; сейчас = длина списка |

**OutboundGroup / OutboundGroupItem → наша группа/узел** (`node_list_presenter`, `node_list.dart`):
- `OutboundGroup`: `getTag()`, `getType()`, `getSelectable()` (→ замена `type=='Selector'`), `getSelected()` (→ замена парсинга `now`), `getIsExpand()`, `getItems()→OutboundGroupItemIterator`.
- `OutboundGroupItem`: `getTag()`, `getType()`, `getURLTestDelay()` (int, ms → `state.lastDelay[tag]` §048), `getURLTestTime()` (long).
- `state.proxiesJson` (сырой JSON из `/proxies`) **исчезает** → заменяется типизированной моделью из `writeGroups`. `urltestNow` (static в `node_list_presenter:62,74`, `node_list.dart:228`) переписывается на `OutboundGroup.getSelected()`.

**Connection (libbox) → единый адаптер → внутренняя модель.** Ввести **один** адаптер `Connection(libbox JSON) → AppConnection`, переписать на него ВСЕ 4 места парсинга: `connections_screen.dart:130-162`, `stats_screen.dart:131-173`, `traffic_profiler._pollConnections`, `TrafficSnapshot.fromConnectionsJson` (`clash_api_client.dart:256`).

| Старое (Clash `metadata.*`) | Новое (libbox Connection) |
|---|---|
| `id` | `getID()` |
| `metadata.processPath` | `getProcessInfo().getProcessPath()` |
| `metadata.process` / packageNames | `getProcessInfo().packageNames()` (StringIterator), `getUserName()`, `getUserID()` |
| `metadata.host` | `getDomain()` |
| `metadata.destinationIP`/`destinationPort` | `getDestination()` / `displayDestination()` |
| `metadata.network` | `getNetwork()` |
| `chains` | `chain()` (StringIterator) |
| `rule` | `getRule()` |
| `rulePayload` | **НЕТ отдельного поля** — проверить на железе, склеен ли payload в `getRule()` (см. §3.3) |
| `upload`/`download` | `getUplink()`/`getDownlink()` (long) |
| `start` | `getCreatedAt()` (long) |
| — (нет в Clash) | `getClosedAt()` (long) — closed-история |

**DeprecatedNote** (новое, опц.): `getName()/message()/messageWithLink()/impending()` → UI-нотификация о deprecated-опциях после `serviceReload`.

### 3.2 Connections — дельты, не снапшот (BLOCKER §3.2 разбора)

Нет `writeConnections`/нет pull. Handler получает `writeConnectionEvents(ConnectionEvents)`: `getReset()` (boolean — полный начальный снапшот/сброс) + `ConnectionEventIterator`. Каждый `ConnectionEvent`: `getType()` (`ConnectionEventNew=0`/`Update=1`/`Closed=2`), `getID()`, `getConnection()` (для closed может быть null/частичным), `getUplinkDelta()/getDownlinkDelta()` (long), `getClosedAt()`.

**Решение:** native-аккумулятор `Connections` (есть в нашем AAR): `applyEvents(ConnectionEvents)`, `filterState(int)`, `sortByDate/Traffic`, `iterator()`. Аккумулятор держится **в Kotlin** (проще для Dart), эмитит в Dart **полный снапшот** (сериализованный) на каждое изменение, дросселированный (см. §4.2). `traffic_profiler` — особый случай: ему нужны именно **события** open/close, поэтому для него EventChannel эмитит дельты (`ConnectionEventNew/Closed`), Dart не diff'ит снапшоты.

### 3.3 Closed-история (есть в нашем AAR)

Подтверждено: `Connection.getClosedAt()`, `ConnectionEvent.getClosedAt()`, `ConnectionEventClosed=2`, `ConnectionStateClosed=2`, `Connections.filterState/applyEvents`. **Апсайд:** можно показывать закрытые соединения в Stats/Connections (новая фича, без апгрейда AAR). **Чинит accumulate-баг:** точные close-события вместо «исчезло из снапшота». **Риск — рост памяти** (§6.2): аккумулятор по умолчанию `filterState(ConnectionStateActive=1)`; closed копит только когда соответствующий экран открыт, с TTL/cap.

---

## 4. Функциональный паритет — где регресс

| # | Sev | Что не 1:1 | Митигация |
|---|---|---|---|
| 4.1 | HIGH | 3 `Timer.periodic` (stats 3с / conn 2с / profiler 1–2с) + heartbeat 20с — все pull; CommandClient = **один** push-поток (`setStatusInterval`). Нельзя «3с одному, 20с другому». | Один native-подписчик, `statusInterval≈1s` (= min нужд), экраны подписываются на Stream. Разные `EventChannel`'ы для status/groups/connections. |
| 4.2 | HIGH | Backpressure: push 1/с × N conn заливает UI; `getReset()`-снапшот огромен. | Дросселирование на native (эмит не чаще X), батч + cap по образцу `coreLog` (`BoxService.kt:676-696`, `LOG_QUEUE_MAX=4096`, `DRAIN_BATCH_MAX=200`). |
| 4.3 | MED | Dead-tunnel detection (§141, 20с — нецель удлинять). Liveness меняет семантику: было «N HTTP-фейлов», станет `disconnected()`/«нет StatusMessage > таймаут». | Native: `disconnected` → dead-tunnel broadcast. Dart heartbeat → watchdog «давно не было StatusMessage». `_maxHeartbeatFailures` переосмыслить. |
| 4.4 | HIGH | `TrafficProfiler` (~1000 строк, `bindRuntime`+`_pollConnections`) завязан на pull-diff. | Сигнатура `bindRuntime` → подписка на `Stream<ConnectionEvent>`; diff-логика → нативные `ConnectionEventNew/Closed`. **Самый большой объём переписывания.** |
| **4.5** | **BLOCKER-кандидат** | **Нет single-node delay в CommandClient.** Есть только `urlTest(groupTag)`. §048 ping-фильтр (Released v1.9.0) читает per-node `state.lastDelay[tag]`; mass-ping (`ping_orchestration.dart:234`, concurrency=10 через `delay(tag)`) и single-node (`ping_orchestration.dart:30`) **теряют аналог**. `cancelDelays()` (`:292`) тоже не выразим. | **Проверить на железе:** триггерит ли `urlTest(group)` на **селектор**-группе (не urltest) тест всех детей с заполнением `OutboundGroupItem.getURLTestDelay()`. Если ДА — §048 переезжает на `writeGroups`-delays. Если НЕТ — оставить single-node delay через read-only Clash HTTP (см. §5/§6) ИЛИ принять регресс per-node ping для селекторов. **Решение блокирует фазу 1.** |

---

## 5. Что удаляется

### 5.1 Поимённый список

| Объект | Файл | Действие |
|---|---|---|
| `ClashApiClient` + `TrafficSnapshot.fromConnectionsJson` + `ClashHttpException` | `lib/services/clash_api_client.dart` | Удалить класс-клиент; `TrafficSnapshot`/`AppStat`-модели сохранить (наполнять из StatusMessage/Connection). `static urltestNow/proxyEntry/connectionIdsInChain` (`:67,78,91`) → перенести в адаптер групп/connections. |
| `ClashEndpoint.fromConfigJson` | `lib/config/clash_endpoint.dart:13` | Удалить. **`routeFinalTag` (`:36`) — ПЕРЕНЕСТИ** (читает `route.final`, к Clash не относится; нужен в `home_controller.dart:374,557`). Иначе ломается авто-выбор стартовой группы. |
| `_rebuildClashEndpoint()` / `_clash` / `clashClient` | `home_controller.dart:35-36,533-536`, `config_io.dart:14-23` | Заменить на lifecycle нового стрим-клиента. |
| блок `experimental.clash_api` | `wizard_template.json:602-605` | Вырезать. `experimental.cache_file` (`:606`) оставить. |
| UI-секция vars `clash_api`/`clash_secret` | `wizard_template.json:236,244` | Вырезать всю секцию → `clash_api/secret` выпадают из import-allowlist (§159) и §113 автоматически. |
| `_ensureClashApiDefaults` + вызов | `build_config.dart:471-487`, `:116` | Удалить функцию и вызов (рандомизация порта 49152–65535 + 32-hex secret). Порядок относительно VPN-mode/`_substituteVars` (`:120`) сохранить. |
| `generatedVars`-writeback | `subscription_controller.dart:705-710` | Осиротеет (цикл по пустому map). Оставить как точку расширения (low-risk) ИЛИ вычистить. |
| `/clash/*` proxy, `/state/clash`, `/profiler/*` Source B | `debug/handlers/{clash,state,profiler,action,help}.dart` | См. §5.2/§5.3. |
| тесты-фикстуры | `test/builder/build_config_test.dart`, `clash_endpoint_test.dart`, `config_dirty_flag_test.dart`, `pipeline_e2e_test.dart`, `detour_append_replace_test.dart` | Удалить рандомизация-тест; вычистить `userVars:{'clash_api':…}`; `config_dirty_flag_test:95` переписать на другой не-config var; widget-тесты экранов → mock Stream вместо mock HTTP. |
| `PerAppTraceTab.clash` | `per_app_trace_tab.dart` | Мёртвый проброс — удалить (cleanup). |
| `ClashHttpException`-ветка | `error_format.dart:41` | Заменить на `CommandClientException`/`PlatformException`-ветку. |

### 5.2 Обратная совместимость подписок (HIGH §7.1)

**«Не добавлять» ≠ «вырезать».** Юзер импортирует готовый sing-box конфиг из подписки/файла, где `experimental.clash_api` уже есть → ядро поднимет HTTP-listener впустую (риск port-scan, ради которого мы рандомизировали порт; хуже — статичный `127.0.0.1:9090` даёт конфликт портов между сессиями). **Builder/validator обязан вырезать `experimental.clash_api` из импортированных конфигов**, не только не добавлять свой. Старые бэкапы с `clash_api`/`clash_secret` в vars молча отбросятся §159 default-deny при импорте — желательное поведение, **задокументировать в migration notes** + тест на импорт старого бэкапа.

### 5.3 §121-проверка (DNS/routing не страдают)

`validator.dart` (143 стр.) — 0 ссылок на `clash_api`/`external_controller`/`experimental`. Блок живёт в `experimental.*`, не внутри `route`/`dns` (`wizard_template.json:602` рядом, но отдельная ветка). Нет routing/DNS-правил, гейтящихся `#if @clash_api`. §121 «выключенный пресет уносит DNS» здесь неприменим — clash_api статический блок, не пресет.

---

## 6. Влияние на диагностику (HIGH — нельзя ослепнуть)

`scripts/lxbox-diag.sh` снимает (только при forward `:63130`):
- `:106` `clash_connections.json`, `:107` `clash_proxies.json`, `:108` `clash_rules.json`, `:109` `clash_version.json` — прямой `curl` к Clash-порту.
- `:93` `/state/clash` (через наш Debug API) — завязан на `pingVersion()`.

Это **главный инструмент проекта** ([[feedback_no_destructive_diagnostics]]: «первое действие при любом баге = `lxbox-diag.sh`»). `/connections` (chains+rule per conn) — единственный способ понять «куда идёт TCP», этих данных нет в info-логах sing-box (`DIAGNOSTICS.md`).

**Решение (Final, см. §6 #2): гибрид — оставить Clash HTTP-listener как ОПЦИОНАЛЬНЫЙ read-only диагностический канал под debug-флагом, management полностью на CommandClient.** Обоснование:
- `/rules`-снапшот (`lxbox-diag.sh:108`) CommandClient **вообще не экспонирует** (команды 0–5 = Log/Status/Group/ClashMode/Connections/Outbounds, rules нет) — невосстановимая потеря интроспекции routing-таблицы без HTTP.
- Single-node delay (§4.5) может потребовать HTTP, если `urlTest(group)` не покрывает селекторы.

**Реализация гибрида:** `experimental.clash_api` инжектится в конфиг **только** когда включён существующий debug-флаг core-logs (`setCoreLogsEnabled`, `BootReceiver`, `VpnPlugin.kt:274-281`) ИЛИ отдельный «diagnostics»-флаг; в обычном (release) режиме блок не добавляется → порт не открывается. Dart-клиент `ClashApiClient` удаляется в любом случае — HTTP остаётся **только** для adb/curl-диагностики, не для UI. `debug/handlers/clash.dart` `/clash/*` proxy переписать поверх MethodChannel→CommandClient (живёт всегда), `/rules` — fallback на HTTP когда флаг включён, иначе документированный `501 Not Available`. `lxbox-diag.sh` + `DIAGNOSTICS.md` обновить: connections/proxies через Debug-API-over-CommandClient, rules только под флагом.

**Альтернатива (если выбран полный отказ):** вся интроспекция connections/groups через наш Debug API (`/clash/*` переписан поверх CommandClient), `/rules` теряется насовсем (acceptable loss, задокументировать). Спека **обязана выбрать одно** — рекомендация: гибрид (read-only HTTP под флагом), т.к. дешевле и не теряет rules.

---

## 7. Фазы реализации

### Фаза 0 — подготовка (native-обвязка, процессный мост)
**Файлы:** Kotlin `BoxCommandClient.kt` (новый), `VpnPlugin.kt` (новые EventChannel'ы), `BoxService.kt` (точка `connect()` после `startCommandServer`, `BoxService.kt:179`).
**Работа:** реализовать `CommandClientHandler` (11 колбэков, **каждый в try/catch fail-safe** — §7.6/JNI-no-throw), `CommandClientOptions().addCommand(1..5)`, `setStatusInterval` (наносекунды!), lifecycle `connect()`/`disconnect()` + retry-with-backoff (гонка: сокет существует только после старта сервера, §2.4 — коннектить на статус `Started`/`Starting`), реконнект на `disconnected(message)`. native-аккумулятор `Connections` + дросселированный эмиттер по образцу `coreLog`-drainer.
**Риск:** процессная гонка старта; JNI-abort при unchecked exception. **Откат:** фича-флаг — оба пути (HTTP+CommandClient) сосуществуют, переключатель в settings/debug.

### Фаза 1 — миграция UI на CommandClient (на стабильной 1.13-эквивалентной поверхности)
> Команды 1–5 и императивы `selectOutbound`/`urlTest`/`closeConnection`/`closeConnections` доступны и в 1.13-линейке; closed-история — нет, поэтому она в фазе 2.

**Файлы:** `home_controller.dart`/`heartbeat.dart`/`ping_orchestration.dart`/`config_io.dart`, `stats_screen.dart`, `connections_screen.dart`, `traffic_profiler.dart`, `home_screen.dart`, `node_list*.dart`, `error_format.dart`, `debug/handlers/{clash,state,action,profiler,help}.dart`, `wizard_template.json`, `build_config.dart`, тесты.
**Работа:** writeStatus→скорость/трафик (heartbeat→watchdog); writeGroups→группы/узлы (`selectorGroupTags`→`getSelectable`); selectOutbound/urlTest; writeConnectionEvents→native-аккумулятор→StreamBuilder (3 экрана + profiler); связать §143 interrupt-on-switch с аккумулятором; выпил `_ensureClashApiDefaults` + блока из шаблона (с учётом §5.2 — вырезать из импорта); решить §4.5.
**Риск:** §4.5 (single-node delay), §3.1 (`rulePayload` потеря), backpressure. **Откат:** фича-флаг из фазы 0 — вернуть HTTP-путь.

### Фаза 2 — closed-история + опц. NQ/STUN (1.14, отдельно)
**Файлы:** `connections_screen.dart`/`stats_screen.dart` (closed-таб), native-аккумулятор (`filterState`/TTL).
**Работа:** показ закрытых соединений (`getClosedAt`/`ConnectionStateClosed`), TTL/cap (§6.2 память); опц. `startNetworkQualityTest`/`startSTUNTest` как диагностика; опц. перевод логов с push-Kotlin на `writeLogs`; `getDeprecatedNotes` → UI-нотис.
**Риск:** неограниченный рост памяти closed-аккумулятора. **Откат:** closed-таб за флагом; default `filterState(Active)`.

---

## 8. Открытые вопросы

| # | Вопрос | Рекомендация |
|---|---|---|
| 1 | Где CommandClient — `BoxService` (A) или `VpnPlugin` (B)? | Поднять рядом с CommandServer в `BoxService` (A, переиспользует scope/teardown), НО эмиттер sink — через `VpnPlugin.binaryMessenger` (main-процесс). Зафиксировать инвариант «эмиттер в Flutter-процессе» комментарием+тестом, чтобы будущий `:bg` не порвал EventChannel. |
| 2 | Полный отказ или гибрид (read-only HTTP под флагом)? | **Гибрид** — оставить HTTP-listener под debug-флагом ради `/rules` и потенциального single-node delay; UI-клиент `ClashApiClient` удалить в любом случае (см. §6). |
| 3 | §4.5: `urlTest(group)` покрывает per-node delay селекторов? | **Проверить на железе ДО фазы 1** (блокирует §048). Если нет — single-node ping через read-only HTTP (гибрид §6) или принять регресс для селекторов. |
| 4 | `rulePayload` есть в `getRule()`? | Проверить на железе (by-rule агрегация Stats `stats_screen.dart`, `clash_api_client.dart` `byRule`). Если склеен — адаптер сплитит; если нет — by-rule теряет payload-гранулярность. |
| 5 | `activeConnections` = `ConnectionsIn+Out` или `len(connections)`? | Проверить семантику StatusMessage на железе; сейчас = длина списка (`connections_screen`/`traffic_bar`). |
| 6 | Rate-limit push-частоты? | Да: `setStatusInterval≈1s` + native-дросселирование снапшота connections (§4.2), батч по образцу `coreLog`-drainer. |
| 7 | Версия ядра для фазы 1? | Команды 1–5 + императивы доступны на текущей 1.14-ветке (`feat/libbox-1.14-migration`) и не требуют closed-истории; closed-история (фаза 2) — наш AAR её уже даёт. |
| 8 | Где аккумулятор connections — Kotlin или Dart? | Kotlin (native `Connections.applyEvents`) — проще для Dart, эмит готовый снапшот; profiler отдельно получает дельты. |

---

## 9. Риски и митигации

| # | Риск | Sev | Митигация |
|---|---|---|---|
| 0 | Концептуальная путаница CommandServer⟂ClashAPI — «тот же транспорт» | BLOCKER | §0/§3: замена контракта данных, единый адаптер Connection, дельты вместо снапшота. |
| 2.1 | CommandClient в `:bg`-процессе → EventChannel рвётся | BLOCKER | §2.1: эмиттер обязан жить в Flutter-процессе; инвариант + тест процессной модели. |
| 3.2 | Connections только дельтами, нет pull | BLOCKER | native `Connections.applyEvents`-аккумулятор, эмит снапшота. |
| 4.5 | Нет single-node delay → §048/mass-ping регресс | BLOCKER-кандидат | Проверка на железе (Q3); fallback read-only HTTP. |
| 1.1 | Debug `/clash/*` proxy (8+ роутов) умрёт | HIGH | Переписать поверх CommandClient (MethodChannel) ИЛИ read-only HTTP (§6). |
| 1.2 | Debug actions (`action.dart` switch/urltest/reset) | HIGH | Едут следом за HomeController; тест-план покрывает. |
| 2.2/2.3 | EventChannel процессность + CommandClient lifecycle/реконнект | HIGH | §2.1/Фаза 0: connect после `libboxReady`+`Started`, retry-backoff, реконнект на `disconnected`. |
| 3.1 | Имена полей Connection другие; `rulePayload` потеря | HIGH | Единый адаптер; Q4 проверка `getRule()`. |
| 3.3/4.3 | `/version` ping исчезает; dead-tunnel семантика | HIGH/MED | Liveness = `connected/disconnected`; heartbeat→watchdog. |
| 4.1/4.2 | 3 Timer→1 push-поток; backpressure | HIGH | Один подписчик, StreamBuilder, дросселирование по `coreLog`-паттерну. |
| 4.4 | TrafficProfiler ~1000 строк pull-diff | HIGH | `bindRuntime`→Stream of ConnectionEvent; нативные open/close. |
| 5.1 | `lxbox-diag.sh` теряет 3 артефакта + curl-playbook | HIGH | §6 гибрид: connections/proxies через Debug-over-CommandClient; rules под флагом. |
| 7.1 | Импортированные конфиги приносят чужой `clash_api` | HIGH | Builder/validator **вырезает** блок из импорта, не только не добавляет. |
| 7.6 | 11 новых JNI-колбэков = Runtime::Abort без try/catch | MED | Каждый handler-метод в try/catch fail-safe ([[project_jni_callbacks_must_not_throw]]); null-sink guard как `coreLogSink`. |
| 6.2 | Closed-история = неограниченный рост памяти | MED | default `filterState(Active)`; closed с TTL/cap только при открытом экране. |
| 7.7 | `setStatusInterval` наносекунды (Go Duration) | MED | Явная константа + комментарий + ассерт/unit-тест. |
| 2.5 | Двойной канал (HTTP+socket) если гибрид | MED | Осознанно: ядро держит оба, ресурсно ОК; `clash_api` в конфиге только под debug-флагом. |
| 7.2 | Бэкапы с `clash_api`/`secret` в vars молча отбрасываются | MED | Migration note + тест импорта старого бэкапа. |
| 7.5 | `ClashHttpException` гуманизация ошибок | MED | Новый `CommandClientException`/`PlatformException`-ветка в `error_format.dart:41`. |
| 7.10 | §042 Health Watchdog (Draft) спроектирован под `clash.fetchTraffic/delay` | MED | Cross-ref §122→§042: переписать data-source на `StatusMessage`/`Groups` ДО реализации. |
| 1.6 | `/rules` не экспонируется CommandClient | LOW/MED | Read-only HTTP под флагом (§6) ИЛИ acceptable loss задокументировать. |
| 7.4/7.11 | `generatedVars` осиротеет; `PerAppTraceTab.clash` мёртв | LOW | Cleanup (опц.). |
| 7.8 | `routeFinalTag` в `clash_endpoint.dart` | LOW | Перенести при удалении файла. |

---

## 10. Test plan

- **Unit:** адаптер `Connection(libbox)→AppConnection` (все поля, StringIterator-итерация); `StatusMessage→TrafficSnapshot`; `setStatusInterval` наносекунды (ассерт порядка величины); native-аккумулятор `applyEvents` (New/Update/Closed/Reset). Удалить/переписать `build_config_test`, `clash_endpoint_test`, `config_dirty_flag_test:95`, `pipeline_e2e_test`, `detour_append_replace_test`.
- **Widget:** `stats_screen`/`connections_screen` на mock `Stream` (вместо mock HTTP); close-кнопки → `closeConnection`/`closeConnections`.
- **E2E on-device (`CE8XX48PCI79U4XG`):** (1) скорость/трафик в traffic_bar из writeStatus; (2) выбор узла `selectOutbound` + §143 interrupt; (3) **Q3: `urlTest` на селектор-группе → заполняются ли per-node delays** (блокирующая проверка §048); (4) Q4: `getRule()` содержит payload; (5) Q5: `activeConnections` семантика; (6) profiler Live/Aggregated на нативных событиях; (7) dead-tunnel через `disconnected`; (8) реконнект при рестарте ядра; (9) JNI-краш-тест на старом Android (колбэки не валят процесс); (10) Debug `/clash/*`-over-CommandClient + `lxbox-diag.sh` новый путь; (11) импорт чужого конфига с `clash_api` → блок вырезан, порт не открыт.

## 11. Docs to update

`docs/ARCHITECTURE.md` (стр.49 «управление через Clash API»; брокеры событий 108–111 push vs poll; раздел Clash API client 1126–1179; design decisions 1242–1244; extraction roadmap 1403 — снять `clash_api_dart`), `docs/STORAGE.md:144` (формулировка core-log), `docs/DIAGNOSTICS.md` (новый источник connections/proxies/rules), `scripts/lxbox-diag.sh`, `docs/api/debug-api-reference.md` + `docs/api/clash-api-reference.md` (переписать/удалить), `docs/spec/features/042 health watchdog/spec.md` (data-source TBD на CommandClient), `CHANGELOG.md` (Unreleased). Имплементация не завершена пока docs не обновлены.

## 12. Acceptance criteria

- [ ] В release-конфиге `experimental.clash_api` отсутствует; TCP-порт на 127.0.0.1 не слушается (проверка `netstat`/diag).
- [ ] Импортированный конфиг с чужим `clash_api` → блок вырезан.
- [ ] Скорость/трафик, группы/узлы, connections, выбор узла, close, §143 interrupt, profiler, dead-tunnel — работают через CommandClient (E2E пройдены).
- [ ] §048 ping-фильтр функционирует (Q3 разрешён); если регресс — задокументирован.
- [ ] Все 11 JNI-колбэков fail-safe; краш-тест на старом Android не валит процесс.
- [ ] Диагностика (`lxbox-diag.sh` + `/clash/*` Debug) работает по новому пути; `/rules` доступен под флагом или потеря задокументирована.
- [ ] `ClashApiClient`/`ClashEndpoint.fromConfigJson` удалены; `routeFinalTag` перенесён; тесты зелёные.
- [ ] Docs (§11) обновлены.

---

**Три факта, требующие проверки на железе ДО фазы 1 (блокирующие):** (1) `urlTest(group)` на селектор-группе заполняет ли per-node `getURLTestDelay()` — иначе §048 ping-фильтр регрессирует; (2) `Connection.getRule()` содержит ли `rulePayload` — иначе by-rule агрегация Stats теряет гранулярность; (3) `StatusMessage.getConnectionsIn()+Out()` vs `len(connections)` семантика для `activeConnections`.
