# 123 — Модель подписок (BoxService / CommandClient)

| Поле | Значение |
|------|----------|
| Тип | Feature (архитектура каналов данных между ядром, native и Dart) |
| Статус | Реализовано (база §122 миграции; энергомодель §163/§164 внедрена) |
| Связано | [122 commandclient-migration](../122%20commandclient-migration/spec.md), [task 163 home-screen-data-model](../../tasks/163-home-screen-data-model-refactor.md), ядровой SPEC 014/015 |

Единый референс: **как устроены все каналы данных** между sing-box-ядром, native-слоем (Kotlin) и Dart-UI. Что за клиенты/подписки существуют, что каждый несёт, какой у него жизненный цикл, и **почему именно так**. Цель — чтобы решения не пересматривались вслепую и новые потребители подключались по правилам.

---

## 1. Два независимых мира статуса — НЕ путать

В системе **два** разных канала, оба про «состояние», но с разной ролью и разной надёжностью.

### 1.1 VPN-статус — нативный broadcast (НЕ CommandClient)

**Источник:** `BoxService.setStatus(VpnStatus)` → `service.sendBroadcast(BROADCAST_STATUS)`.
**Транспорт:** Android-broadcast → `VpnPlugin.statusReceiver` (системный `BroadcastReceiver`, `registerReceiver` в `onAttachedToEngine`) → `statusSink` → EventChannel `com.leadaxe.lxbox/status_events` → Dart `onStatusChanged` → `_handleStatusEvent`.
**Несёт:** connected / disconnected / connecting / stopping / revoked / error+errorMessage.
**Природа:** событие (дискретный переход фазы туннеля).

**Почему именно broadcast, а НЕ `SubscribeServiceStatus` через CommandClient:**
1. **Независимость от CommandClient.** `SubscribeServiceStatus` идёт через CommandClient-соединение. Оборвётся оно при живом ядре (реконнект клиента, пауза в фоне) — стрим статуса умрёт, UI ложно покажет «VPN упал», хотя туннель работает. Broadcast питается от самого `VpnService` — ближе к источнику истины «туннель up/down».
2. **Работает в фоне независимо от CC-клиентов.** `BroadcastReceiver` живёт пока жив процесс. Даже когда statusClient/screenClient усыплены в фоне (§4), выключение/падение VPN всё равно прилетает через broadcast → `_handleStatusEvent`. Усыпление CC-клиентов НЕ слепит нас к выключению VPN.
3. **Фазы уже покрыты нативно.** `setStatus` шлёт Starting/Started/Stopping/Stopped/revoked + errorMessage → connecting-спиннер и error-причина есть без второго канала. `SubscribeServiceStatus` (5 фаз IDLE/STARTING/STARTED/STOPPING/FATAL) дублировал бы их через более хрупкий канал. (В AAR rc.4 `CommandServiceStatus` и так нет — команды: `CommandStatus=1`/`CommandGroup=2`/`CommandClashMode=3`.)

**Дребезг `setStatus(Stopped)`** (несколько teardown-путей слали повторный/запоздалый Stopped → перетирал live-state при reconnect) закрыт: **native dedup** в `setStatus` (`status==newStatus && error==null` → no-op) + **Dart stale-terminal guard** в `_handleStatusEvent` (повторный терминал при уже-терминальном prevTunnel не рвёт стримы).

### 1.2 Connected()/Disconnected() колбэки CommandClient — НЕ для VPN-статуса

`CommandClientHandler` имеет `connected()` / `disconnected(message)` — но это статус **CommandClient-соединения с command-сервером ядра**, НЕ статус VPN-туннеля. Используются только для:
- логирования жизненного цикла клиента;
- **реконнекта** statusClient (`disconnected` → `scheduleReconnect` если `tunnelAlive`).

Не маппить их на VPN connected/disconnected UI — для этого §1.1.

---

## 2. CommandClient: три клиента (по жизненному циклу)

Управление/данные ядра идут через libbox `CommandClient` (gRPC поверх unix-сокета `command.sock`). **Три отдельных клиента**, разделённых по жизненному циклу — каждый владеет `AtomicReference<CommandClient?>` + `AtomicInteger`-gen (защита от устаревших колбэков).

Подписка = `CommandClientOptions.addCommand(int)` + колбэки `CommandClientHandler.write*` (прямых `subscribe*` в AAR нет). Команды (rc.4): `CommandStatus=1`, `CommandGroup=2`, `CommandClashMode=3`, плюс `CommandOutbounds`, `CommandConnections`.

| Клиент | Команды | Несёт | Жизненный цикл | Потребители |
|--------|---------|-------|----------------|-------------|
| **statusClient** | `CommandStatus` (+`setStatusInterval`) | трафик up/down, uplinkTotal/downlinkTotal, память, connectionsIn/Out | поднят пока туннель up + foreground; **спит в фоне** (§4) | шапка главного (скорость/conns-бейдж), Stats-счётчики |
| **screenClient** | `CommandOutbounds` + `CommandGroup` + `CommandConnections` | дерево групп (выбор/urlTestDelay), плоский node-list, connection-события | refcount по открытию экрана-потребителя; **спит в фоне** (§4) | главный (groups), Stats/Connections (connections) |
| **profilerClient** | `CommandConnections` | connection-события для per-app live | **по явному recording** (▶ START); **ЖИВЁТ в фоне** | Live/Per-app trace (§048) |

### 2.1 Почему три, а не один

- **statusClient отдельно от screenClient** — развязка **частоты** от **состава**. `setStatusInterval` управляет частотой только status-тиков и меняется лишь пересозданием клиента (§3). Будь они слиты, каждое переключение FAST↔NORMAL (вход/выход в Stats) рвало бы groups/connections-подписку. Раздельность держит groups/connections стабильными при смене status-частоты. (Энергополитика у них теперь одинаковая — оба спят в фоне, §4 — но это не повод сливать: довод про частоту остаётся.)
- **profilerClient отдельно** — у него уникальный жизненный цикл: живёт **по recording**, а не по видимости экрана, и **продолжается в фоне** (юзер запустил запись и свернул приложение — запись не должна прерваться). Независим от screenClient (своя `CommandConnections`-подписка + `ProfilerHandler`) → усыпление screenClient в фоне его не задевает.

### 2.2 Карта «экран ← клиенты»

| Экран / действие | statusClient | screenClient | profilerClient |
|------------------|:---:|:---:|:---:|
| Главный экран | ✅ (трафик-шапка) | ✅ (groups) | — |
| Stats / Connections | ✅ (счётчики) | ✅ (connections) | — |
| Recording (▶ START) | — | — | ✅ |

Stats держит **statusClient + screenClient** (как главный), НЕ profilerClient. profilerClient — это про recording-действие, не про открытие Stats-экрана.

---

## 3. Частота status-стрима (§163)

`setStatusInterval(long ns)` — параметр `CommandClientOptions`, диктует ядру период генерации `StatusMessage`. **Меняется только пересозданием клиента** (нет метода на живом `CommandClient`). «Динамика» = поменять `@Volatile statusIntervalNs` + вызвать `connectStatus()` (новый клиент с новым интервалом, старый `getAndSet().disconnect()`; reconnect по локальному сокету — дёшев).

| Режим | Интервал | Тиков/сек | Когда |
|-------|----------|-----------|-------|
| **NORMAL** | 5e8 нс = 0.5с | 2 | foreground, главный экран (цифра скорости — 0.5с глазу достаточно) |
| **FAST** | 1e8 нс = 0.1с | 10 | foreground, открыт Stats (плавность счётчиков) |
| **пауза** | — | 0 | фон (§4) |

Тик генерируется **независимо от изменения данных** (на простаивающем туннеле тоже приходит) → резать частоту = прямая экономия CPU/IPC/marshal на всей цепочке (ядро → gRPC → EventChannel → Dart). UI-троттлы (главный `_trafficEmitThrottle`=1с, память Stats `_memoryRefresh`=3с) экономят только ребилд UI — поздно; резать надо у источника (интервал).

---

## 4. Энергомодель: сон в фоне (§164)

**Правило:** в фоне (`onAppPaused`) живёт **только profilerClient** (если идёт recording). statusClient + screenClient + heartbeat — спят.

| Клиент / таймер | onAppPaused (фон) | Обоснование |
|-----------------|-------------------|-------------|
| **statusClient** | 😴 `pauseStatus()` (disconnect, 0 тиков) | UI не виден; dead-tunnel в фоне ловит broadcast (§1.1), не status-watchdog |
| **screenClient** | 😴 `pauseScreen()` (disconnect, **refcount сохраняется**) | UI закрыт/невидим; groups/connections в фоне не нужны |
| **profilerClient** | ✅ живёт | recording идёт в фоне по явному START — прерывать нельзя |
| **heartbeat-таймер** | 😴 `_stopHeartbeat()` (уже) | в фоне UI не виден; dead-tunnel ловит broadcast |

**onAppResumed:** `resumeStatus()` (NORMAL); `resumeScreen()` — поднять screenClient **только если refcount>0** (экран-потребитель всё ещё открыт); heartbeat — рестарт. `_resyncOnResume` делает немедленный pull VPN-статуса (native) → свежий статус сразу, не ждём первый тик.

**Почему усыпление безопасно:** выключение/падение VPN в фоне прилетает через нативный broadcast (§1.1, п.2), не через CC-клиенты. Усыпив status/screen, мы теряем только статистику (невидимую в фоне), но НЕ слепнем к состоянию туннеля.

**screenClient пауза ≠ disconnectScreen.** `disconnectScreen` декрементит refcount (контракт «потребитель ушёл»). Lifecycle-пауза в фоне НЕ означает что потребитель ушёл — экран всё ещё открыт, просто не виден. Поэтому отдельные `pauseScreen`/`resumeScreen` гасят/поднимают клиента, **не трогая `screenRefs`** (как `pauseStatus`/`resumeStatus` не трогают `tunnelAlive`).

---

## 5. Доставка снапшотов native → Dart

Каждый CC-канал — свой EventChannel + `@Volatile` sink в `BoxVpnService`-companion:

| Канал | EventChannel | Sink |
|-------|--------------|------|
| status | `lxbox/cc/status` | `ccStatusSink` |
| outbounds | `lxbox/cc/outbounds` | `ccOutboundsSink` |
| groups | `lxbox/cc/groups` | `ccGroupsSink` |
| connections | `lxbox/cc/connections` | `ccConnectionsSink` |

**Эмиттеры** (`SnapshotEmitter`): `LinkedBlockingQueue` (cap `QUEUE_MAX`) + drop-newest при переполнении (не блокируем producer-thread ядра) + single Runnable + main-Handler + batch. Колбэки `write*` проверяют `gen` (устаревшее поколение после реконнекта → drop) и `sink != null` (нет подписчика → drop, кроме accumulator'а §5.1).

**JNI-no-throw:** каждый колбэк handler'а в `runCatching` — unchecked exception через JNI = `Runtime::Abort` всего процесса.

**Dart-сторона** (`CcChannel`): `_sharedStream` (broadcast fan-out + replay-кэш) — каждый EventChannel держит ОДИН native sink, а подписчиков в Dart несколько (главный + Stats); broadcast с replay даёт каждому актуальный снапшот. `resetCaches()` на disconnect — чтобы новый подписчик не получил устаревший снапшот прошлой сессии.

### 5.1 Connections — аккумулятор (дельты, не снапшот)

`writeConnectionEvents` шлёт **дельту** между вызовами (created/closed), не полный список. Аккумулятор (`connectionsAccumulator`) держится в Kotlin, применяет КАЖДУЮ дельту по порядку, эмитит полный снапшот. Накапливает ВСЕГДА пока screenClient жив (даже если Dart-sink null) — иначе created-дельты до подписки теряются → Stats при открытии пуст. `getReset()` = replace.

---

## 6. Pull vs push (groups) — гибрид (§163)

CommandClient push-only по природе. Для **groups** добавлен unary-pull `getGroups()` (rc.4 SPEC 015) — lifeline там, где push дырявый.

- **push** (`SubscribeGroups` → `_onCcGroups`) — live-обновления: авто-переключение urltest-группы, urlTestDelay. **Остаётся.**
- **pull** (`getGroups`) — на событиях: connected (потерянный стартовый push), после switchNode (мгновенный selected), pullToRefresh (свайп). Семантика `null`=не-STARTED / `[]`=нет групп / непустой=снапшот.
- **empty-push guard**: пустой push поверх непустого `ccGroups` игнорируется (шум гонки waitForStarted).

Детали — [task 163 §3](../../tasks/163-home-screen-data-model-refactor.md).

---

## 7. Реконнект

`scheduleReconnect(delayMs)` с backoff (`RECONNECT_BACKOFF_START_MS`=500 → `RECONNECT_BACKOFF_MAX_MS`=8000). statusClient: на `disconnected`-колбэк реконнект если `tunnelAlive && !statusPaused`. screenClient/profilerClient — без авто-реконнекта (поднимаются явно по lifecycle/recording).

---

## 8. Полный teardown

`shutdownAll()` (из `BoxService.doStop`/`closeCommandServerAtomic`): `tunnelAlive=false`, `screenRefs=0`, disconnect всех трёх клиентов, `connectionsAccumulator=null`. `stopStatus()` — только statusClient (`tunnelAlive=false`).

---

## 9. Решения (фиксация, без историй)

1. **VPN-статус — нативный broadcast, НЕ `SubscribeServiceStatus`** (§1.1). Хрупкость CommandClient-канала + работа в фоне + фазы уже покрыты.
2. **Три CommandClient'а раздельны** (§2.1). status/screen — развязка частоты от состава; profiler — уникальный фон-lifecycle.
3. **НЕ сливать status+screen** даже при единой энергополитике — довод частоты (§3) остаётся.
4. **В фоне живёт только profilerClient** (§4). status/screen/heartbeat спят; выключение VPN ловит broadcast.
5. **groups — гибрид push+pull** (§6), НЕ инверсия и НЕ чистый push.
6. **status-частота: NORMAL 0.5с / FAST 0.1с (Stats) / пауза (фон)** (§3-4).

---

## 10. Затронутые файлы

- `app/android/.../BoxCommandClient.kt` — три клиента, `connectStatus/connectScreenClient/connectProfilerClient`, `setStatusFast/pauseStatus/resumeStatus`, эмиттеры, аккумулятор, реконнект.
- `app/android/.../BoxService.kt` — `setStatus` (broadcast + dedup), teardown.
- `app/android/.../VpnPlugin.kt` — EventChannel'ы, statusReceiver (broadcast), cc-RPC cases.
- `app/android/.../BoxVpnService.kt` — `cc*Sink` companion.
- `app/lib/vpn/cc_channel.dart` — `_sharedStream` (broadcast+replay), `getGroups`, императивы.
- `app/lib/vpn/box_vpn_client.dart` — `onStatusChanged` (VPN-статус EventChannel).
- `app/lib/controllers/home_controller.dart` — `_handleStatusEvent`, `_onCcStatus`, `_onCcGroups`, `_startGroupsPull`, lifecycle `onAppPaused/Resumed`.

---

## 11. Вне скоупа / отложено

- Слияние status+screen в один клиент — отклонено (§9.3).
- `SubscribeServiceStatus` для VPN-статуса — отклонено (§9.1).
- Разнос screenClient на groups-client + connections-client (главный не тянул бы connections) — возможная будущая оптимизация, не сделано.
- `getOutbounds`-pull — зарезервирован (node-list из групп; нужен для плоского списка endpoint'ов).
- Реализация энергомодели §4 (`pauseScreen`/`resumeScreen` + триггеры lifecycle/Stats) — task §164.
