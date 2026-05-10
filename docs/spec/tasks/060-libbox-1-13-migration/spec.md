# 060 — libbox 1.13 migration + Dart wrapper cleanup

| Поле | Значение |
|------|----------|
| Статус | Done (libbox 1.13.11 в продакшене) |
| Дата | 2026-04-30 |
| История | Был `features/039 libbox 1.13 migration`, демотирован в task через §054 (one-shot migration) |
| Зависимости | [`features/012 native vpn service`](../../features/012%20native%20vpn%20service/spec.md), [`features/031 debug api`](../../features/031%20debug%20api/spec.md) |
| Триггер | Issue: после ~27 минут аптайма VPN clash delay endpoint молча перестаёт отвечать → все ноды показывают "err" в UI. Root cause найден: DNS cache dedup-lock leak в sing-box, fix `aba8346b`/`e7a9c902` ("Fix DNS cache lock goroutine leak") вошёл в `v1.12.21+` и `v1.13.0+`. Решение — bump libbox; одновременно мигрируем на 1.13.x как актуальную major-ветку. |

## Цель

**Две связанные задачи в одной фиче:**

1. **Phase A — Dart wrapper cleanup**: причесать `app/lib/vpn/box_vpn_client.dart` накопленным опытом — типизация (status enum, AppInfo model, BackgroundMode enum), timeout'ы на критических MethodChannel-вызовах, singleton + DI для тестируемости, метод-name константы.

2. **Phase B — libbox 1.13 migration**: поднять libbox с `1.12.12` до `1.13.11` и переписать Kotlin-обёртку нативного VPN сервиса под новую single-CommandServer-архитектуру. Без регрессий, по канонической реф-реализации `SagerNet/sing-box-for-android`.

**Почему вместе:** обе задачи трогают тот же стек (Layer 3 Dart-bridge + Layer 4 Kotlin native). Делать в один заход — меньше merge conflict'ов, чистая граница "before / after" в истории. Phase A идёт **первой** (Dart-side стабилизирован), затем Phase B (native переписан) — так downstream callsite'ы при нативном рефакторе уже на типизированных API.

**Не в скопе:**
- Новые фичи sing-box 1.13 (HTTP/3 inbound, новые транспорты) — отдельные таски при необходимости.
- Reactive bump на каждый patch-релиз libbox — пин остаётся ручным; spec фиксирует процесс ad-hoc.
- Изменение config-builder'а: builder уже emit'ит 1.13-совместимую schema (verified — endpoints[] для WireGuard, новый DNS, route-action sniff/hijack).
- **Splitting BoxVpnClient на несколько узких клиентов** (VpnLifecycleClient, AppListClient, etc.) — обсуждалось, отклонено: 195 строк в одном файле не страшно; ROI splitting'а низкий.
- **`requestAddTile` → sealed `AddTileResult`** — обсуждалось, отклонено: один callsite, опечатки маловероятны, лишний boilerplate.

---

## Phase A — Dart wrapper cleanup

Файл `app/lib/vpn/box_vpn_client.dart` (195 строк, наша обёртка над MethodChannel/EventChannel — заменила сторонний plugin `flutter_singbox_vpn`). Сейчас работает корректно, но накопил technical debt: stringly-typed API, нет timeout'ов, статичная state-organization без DI.

### A.1 — `VpnStatus` enum (был `String`)

**Сейчас:**
```dart
Future<String> getVpnStatus() async { ... }   // 'Started' | 'Starting' | 'Stopped' | 'Stopping'
Stream<Map<String, dynamic>> get onStatusChanged;  // {"status": "Started"}
```

**Стало:**
```dart
enum VpnStatus { stopped, starting, started, stopping }

class VpnStatusEvent {
  final VpnStatus status;
  final String? errorReason;
  // ... fromMap factory
}

Future<VpnStatus> getVpnStatus() async { ... }
Stream<VpnStatusEvent> get onStatusChanged;
```

**Почему:** `HomeController._handleStatusEvent` сейчас парсит строку вручную через switch-case. Дублирование 5+ местах в коде. Type-safe enum исключает опечатки и упрощает refactoring.

**Wire-protocol с native не меняется** — Kotlin продолжает слать `'Started'`/`'Starting'`/etc. Парсинг — клиентская сторона.

### A.2 — `BackgroundMode` enum (был `String`)

**Сейчас:**
```dart
Future<String> getBackgroundMode() async { ... }  // 'never' | 'lazy' | 'always'
Future<void> setBackgroundMode(String mode) async { ... }
```

**Стало:**
```dart
enum BackgroundMode { never, lazy, always }

Future<BackgroundMode> getBackgroundMode() async { ... }
Future<void> setBackgroundMode(BackgroundMode mode) async { ... }
```

**Почему:** тот же аргумент. Используется в Settings screen и при init'е HomeController.

### A.3 — `AppInfo` модель (был `Map<String, dynamic>`)

**Сейчас:**
```dart
Future<List<Map<String, dynamic>>> getInstalledApps() async { ... }
Future<Map<String, dynamic>?> getAppInfo(String packageName) async { ... }
```

**Стало:**
```dart
class AppInfo {
  final String packageName;
  final String name;
  final bool isSystem;
  final String? iconBase64;  // null = не запрашивали
  
  factory AppInfo.fromMap(Map<String, dynamic> m) => ...;
}

Future<List<AppInfo>> getInstalledApps() async { ... }
Future<AppInfo?> getAppInfo(String packageName) async { ... }
```

**Почему:** Routing screen + AppInfoCache работают с этими данными. Сейчас по коду ходит `Map<String, dynamic>` — caller'у надо знать какие ключи есть. Модель документирует контракт.

### A.4 — Timeout'ы на критических MethodChannel-вызовах

**Сейчас** все вызовы `await _methods.invokeMethod(...)` могут висеть навсегда если native deadlock'ится (мы это уже видели в clash-delay багу).

**Стало:**
```dart
class _Timeouts {
  static const startVpn = Duration(seconds: 30);
  static const stopVpn = Duration(seconds: 10);   // блокирующий — но небесконечно
  static const status = Duration(seconds: 3);     // critical при init'е
  static const config = Duration(seconds: 5);
  static const apps = Duration(seconds: 15);     // getInstalledApps медленный на старых
  static const settings = Duration(seconds: 5);  // open* / is*
}

Future<VpnStatus> getVpnStatus() async {
  try {
    final s = await _methods.invokeMethod<String>('getVpnStatus')
        .timeout(_Timeouts.status);
    return VpnStatusParse.parse(s);
  } on TimeoutException {
    AppLog.I.error('BoxVpnClient: getVpnStatus timed out');
    return VpnStatus.stopped;  // best-effort fallback
  }
}
```

**Почему:** `getVpnStatus` блокирует init'е HomeController — если native висит, **весь Flutter UI стоит**. Timeout + log + fallback. Аналогично остальные критические.

### A.5 — Singleton + DI для тестов

**Сейчас:**
```dart
class BoxVpnClient {
  static const _methods = MethodChannel(...);   // static
  static const _statusEvents = EventChannel(...); // static
  Future<bool> saveConfig(...) async { ... }    // instance methods
}
```

State static, методы instance — притворяющийся singleton'ом класс. Несовместимо с остальным кодбейзом (`AppLog.I`, `HapticService.I`).

**Стало:**
```dart
class BoxVpnClient {
  BoxVpnClient._({MethodChannel? methods, EventChannel? events})
    : _methods = methods ?? const MethodChannel('com.leadaxe.lxbox/methods'),
      _events = events ?? const EventChannel('com.leadaxe.lxbox/status_events');
  
  /// Production singleton.
  static final I = BoxVpnClient._();
  
  /// Test factory — inject mock channels.
  @visibleForTesting
  factory BoxVpnClient.forTest({
    required MethodChannel methods,
    required EventChannel events,
  }) => BoxVpnClient._(methods: methods, events: events);
  
  final MethodChannel _methods;
  final EventChannel _events;
  // ...
}
```

**Почему:** единый стиль с другими services + возможность mock'ать MethodChannel в юнит-тестах. У нас тестов мало, но открыть путь стоит.

### A.6 — Method-name константы

**Сейчас** в каждом методе строки: `'saveConfig'`, `'startVPN'`, etc.

**Стало:**
```dart
class _Methods {
  static const saveConfig = 'saveConfig';
  static const startVPN = 'startVPN';
  static const stopVPN = 'stopVPN';
  static const getVpnStatus = 'getVpnStatus';
  // ... ~25 констант
}
```

**Почему:** опечатки технически возможны (хотя редки); централизация контракта с native.

### Что Phase A НЕ меняет

- **Wire-protocol с native** — Kotlin handler'ы продолжают принимать те же method names и аргументы, отдавать те же ответы
- **Public API классов потребителей** (`HomeController`, `Settings screens`) — на стороне callsite меняется тип возврата (String → enum), но семантика и порядок вызовов остаются
- **`stopVPN()` блокирующий** — намеренно, comment про race с `onStartCommand` guard'ом сохраняется
- **`_statusStream` через `asBroadcastStream()`** — сохраняется (там tested-by-fire решение про zombie listener)
- **`getVpnStatus()` pull-метод** — остаётся (нужен для re-attach на cold start)

---

## Phase B — Native Kotlin deep rewrite

Это не точечный port минимально-чтобы-скомпилилось. Это **полная инвентаризация и оптимизация Kotlin-слоя VPN**. Накоплен technical debt, есть мёртвый код, есть избыточный mutable state. Фича 039 — момент чтобы пройтись по нему системно.

### B.0 — Скоуп: 14 файлов в `app/android/.../vpn/` (~2000 строк)

| Файл | Lines | Что внутри | Затронуто миграцией | Cleanup-кандидат |
|---|---|---|---|---|
| `BoxVpnService.kt` | **552** | Android Service + libbox lifecycle + status broadcasting | 🔴 ядро миграции | 🔴 высокий: ~12 mutable полей, race-prone state machine, verbose logging |
| `VpnPlugin.kt` | **542** | MethodChannel handlers (28+ методов от Dart) | 🟢 не затронуто (другой layer) | 🟡 средний: аудит handler'ов, errors, dead code |
| `LxBoxTileService.kt` | 171 | Quick Settings tile (spec 032) | 🟢 не затронуто | 🟢 низкий: недавний код, чистый |
| `PlatformInterfaceWrapper.kt` | 137 | `PlatformInterface` impl | 🔴 ядро миграции | 🟡 уже в плане Phase B |
| `DefaultNetworkListener.kt` | 94 | API 28-30 fallback network listener | 🟢 не затронуто | 🟢 низкий: недавно тронули (issue #3) |
| `DefaultNetworkMonitor.kt` | 89 | API 31+ network monitor | 🟢 не затронуто | 🟢 низкий |
| `BoxApplication.kt` | 89 | Application init, libbox.setup, redirectStderr, race barrier | 🟡 проверить (Libbox.setup signature?) | 🟢 низкий: чистый, недавно правили |
| `QuickShortcuts.kt` | 89 | Home shortcut (spec 032) | 🟢 не затронуто | 🟢 низкий |
| `ServiceNotification.kt` | 84 | Foreground notification | 🟢 не затронуто | 🟢 низкий |
| `BootReceiver.kt` | 66 | Auto-start on boot | 🟢 не затронуто | 🟢 низкий |
| `ConfigManager.kt` | 53 | Config file persistence | 🟢 не затронуто | 🟢 низкий |
| `Extensions.kt` | 19 | Kotlin extension functions | 🟢 не затронуто | 🟢 низкий |
| `LocalResolver.kt` | 18 | DNS resolver bridge to Android system | 🟡 проверить (interface stable?) | 🟢 низкий |
| `VpnStatus.kt` | 10 | Enum class | 🟢 не затронуто | 🟢 низкий |

**Главный кандидат на deep refactor — `BoxVpnService.kt`** (552 строки). Он содержит:
- Android Service callbacks (onCreate / onStartCommand / onDestroy / onRevoke / onTaskRemoved / onBind)
- libbox lifecycle (startSingbox / doStop / cleanupStaleResources)
- Status state machine (Stopped / Starting / Started / Stopping)
- IDLE_MODE_CHANGED broadcast receiver
- VPN tunnel building (Builder API)
- Notification orchestration
- Re-attach logic после force-stop
- PlatformInterfaceWrapper и CommandServerHandler implementations

Слишком много concerns в одном классе — плотный кандидат на splitting. Но осторожно: Android Service одиночный, его не разорвать. Можно разве что **выделить вспомогательные классы**: например `VpnLifecycleStateMachine`, `VpnTunnelBuilder`, `IdleModeBroadcastReceiver`.

### B.1 — Архитектурная миграция libbox 1.12 → 1.13

Sing-box 1.13 переехал на **single-entry-point архитектуру**. Класс `BoxService` удалён целиком; всё его API поглощено в `CommandServer`. Это меняет lifecycle нашего нативного сервиса в семи местах: создание, старт, reload, pause/wake, shutdown, error reporting, лог-routing.

В libbox 1.12.x жили **два** класса:

```
Libbox.newService(config, platform) → BoxService     ← владел sing-box runtime
                                       boxService.start() / .pause() / .wake() / .close()
CommandServer(handler, maxLines)                     ← Unix-socket для Clash dashboard
                                       cs.setService(svc) / .start() / .resetLog() / .close()
```

В libbox 1.13.x всё стало через `CommandServer`:

```
CommandServer(handler, platform)                     ← единый объект
                                       cs.start()                              — поднять Unix socket
                                       cs.startOrReloadService(config, opts)  — стартовать/перезагрузить sing-box
                                       cs.pause() / .wake()                   — idle/wake
                                       cs.closeService()                      — остановить sing-box (server жив)
                                       cs.close()                             — полное выключение
                                       cs.setError(msg)                       — отдать ошибку наверх
                                       cs.writeMessage(level, msg)            — заинжектить в лог
```

Класс `BoxService` в 1.13 **отсутствует** в `io.nekohasekai.libbox.*` AAR пакете. `Libbox.newService(...)` тоже **удалён**.

---

## Маппинг API: 1.12 → 1.13

| Что было в 1.12 | Стало в 1.13 | Комментарий |
|---|---|---|
| `Libbox.newService(config, platform)` → `BoxService` | `CommandServer(handler, platform)` ctor + `cs.startOrReloadService(config, OverrideOptions())` | двухфазно: создание сервера отделено от старта sing-box runtime |
| `boxService.start()` | `cs.startOrReloadService(config, opts)` | то же что и initial start |
| `boxService.pause()` | `cs.pause()` | identical semantics |
| `boxService.wake()` | `cs.wake()` | identical semantics |
| `boxService.close()` | `cs.closeService()` | бросает на ошибке — wrap `runCatching` |
| `Seq.destroyRef(boxService.refnum)` | **удалить полностью** | Go runtime self-cleans; manual destroyRef вызывает double-free |
| `commandServer.setService(svc)` | **удалить** | сервер сам владеет box после `startOrReloadService` |
| `commandServer.resetLog()` | **удалить** | replacement отсутствует; логи идут через `CommandClient` subscription |
| `commandServer.writeMessage(String)` | `cs.writeMessage(int level, String)` | level — sing-box `slog` int (3=Panic, 4=Error, 5=Warn, 6=Info, 7=Debug, 8=Trace) |
| `PlatformInterface.writeLog(String)` | `CommandServerHandler.writeDebugMessage(String)` | переехал с PlatformInterface на CommandServerHandler |
| `PlatformInterface.packageNameByUid(int)` | **удалён** | sing-box теперь сам резолвит через `ConnectionOwner.androidPackageNames` |
| `PlatformInterface.uidByPackageName(String)` | **удалён** | то же |
| `PlatformInterface.findConnectionOwner(...) → int` | `findConnectionOwner(...) → ConnectionOwner` | возвращаемый тип — struct с `userId`, `userName`, `processPath`, `androidPackageNames`. Один callback вместо трёх |
| `CommandServerHandler.postServiceClose()` | **удалён** | заменено на `serviceStop() throws Exception` (host-получает запрос-стопа от dashboard) |
| `CommandServerHandler.getSystemProxyStatus()` → `*SystemProxyStatus` | `→ SystemProxyStatus throws Exception` | в Kotlin сигнатура та же (gomobile mapping `(T, error)` → `T throws`) |
| `CommandServerHandler.serviceStop()` | **новый required** | вызывается когда внешний клиент (например Clash) просит остановить сервис |

---

## Новый lifecycle (canonical, по реф-реализации SagerNet/sing-box-for-android)

```
┌──────────────────────────────────────────────────────────────────────┐
│ Android Service Lifecycle (BoxVpnService)                            │
│                                                                      │
│   onCreate()                                                          │
│      └─ Libbox.setup() once                                           │
│      └─ Libbox.redirectStderr() once                                  │
│                                                                      │
│   onStartCommand()                                                    │
│      └─ commandServer = CommandServer(this, this)                    │
│      └─ commandServer.start()              ← открыть Unix socket     │
│      └─ register IDLE_MODE broadcast receiver                         │
│      └─ buildConfig() → JSON-string                                   │
│      └─ commandServer.startOrReloadService(config, OverrideOptions())│
│      └─ DefaultNetworkMonitor.start()                                 │
│      └─ notification.show("Connected")                                │
│                                                                      │
│   ────── runtime events ──────                                       │
│                                                                      │
│   IDLE_MODE_CHANGED broadcast                                         │
│      └─ if (idle)  commandServer.pause()                             │
│         else        commandServer.wake()                              │
│                                                                      │
│   serviceReload() callback (from Clash dashboard)                    │
│      └─ rebuild config                                                │
│      └─ commandServer.startOrReloadService(newConfig, OverrideOptions()) │
│                                                                      │
│   serviceStop() callback (from Clash dashboard)                      │
│      └─ doStop() — наш стандартный shutdown path                     │
│                                                                      │
│   onRevoke() (system / другое VPN-app)                               │
│      └─ doStop()                                                      │
│                                                                      │
│   ────── shutdown ──────                                             │
│                                                                      │
│   doStop() / onDestroy()                                              │
│      └─ unregister IDLE_MODE receiver                                 │
│      └─ notification.stop()                                           │
│      └─ launch on Dispatchers.IO:                                    │
│           ├─ fileDescriptor.close()                                  │
│           ├─ DefaultNetworkMonitor.stop()                             │
│           ├─ runCatching { commandServer.closeService() }            │
│           │      .onFailure { commandServer.setError("…") }          │
│           ├─ commandServer.close()                                    │
│           │   ⚠ NO Seq.destroyRef — Go owns lifetime                 │
│           ├─ stopSelf()                                               │
└──────────────────────────────────────────────────────────────────────┘
```

### Ключевые инварианты

1. **Order matters on shutdown**: `closeService()` → `close()`. Перепутать = Go callbacks могут не дренироваться вовремя → ANR.
2. **Shutdown на background thread**: `Dispatchers.IO`. На main thread может ANR'ить, потому что Go side ждёт callback'и.
3. **CommandServer создаётся раз в Android Service lifecycle** (т.е. на `onStartCommand`). НЕ на каждый VPN-connect.
4. **`startOrReloadService` единая точка**: и для initial start, и для reload-on-config-change. Sing-box сам разруливает.
5. **`closeService()` бросает** — обязательно `runCatching` + report через `setError(msg)`.
6. **`Seq.destroyRef` НЕ ВЫЗЫВАЕМ** — Go runtime владеет refnum'ами; manual destroyRef = double-free.
7. **`commandServer.close()` НЕ бросает** — финальный clean.

---

## B.2 — Cleanup objectives (помимо libbox-миграции)

Помимо механической замены 1.12 API на 1.13, заявленные улучшения качества Kotlin-слоя:

### B.2.1 — Уменьшить mutable state в `BoxVpnService`

Текущий `BoxVpnService.kt` имеет ~12 `var`-полей: `boxService`, `commandServer`, `fileDescriptor`, `status`, `receiverRegistered`, `receiver`, `notification`, `serviceScope`, etc. Каждое — потенциальная race-condition. План:

- **`status` → StateFlow** — атомарная state-machine с типизированными переходами; вместо `var status: VpnStatus` сделать `private val _status = MutableStateFlow(...)` и подписки в Dart через единый Flow (вместо событийного broadcast)
- **`receiverRegistered` boolean** — заменить на nullable receiver (если не null — значит зарегистрирован), уменьшит дублирующий state
- **`fileDescriptor` мутирующий** — обернуть в helper-метод `closeAndNullify` с idempotency check
- **`serviceScope`** — оставить `var`, но прокидывать `Job` родителю чтобы было `cancel()`-friendly

### B.2.2 — Чёткие границы concerns

Текущий `BoxVpnService` — God class на 552 строки. План разделения:

| Новый класс | Что выносим | Текущее положение |
|---|---|---|
| `VpnLifecycleStateMachine` | Status state machine + переходы + broadcast в Dart | inline в BoxVpnService (~80 строк) |
| `VpnTunnelBuilder` | Сборка `VpnService.Builder` (mtu, addresses, dns, search domains) | inline в `openTun()` (~60 строк) |
| `IdleModeReceiver` | BroadcastReceiver для `ACTION_DEVICE_IDLE_MODE_CHANGED` | inline в `BoxVpnService.kt` (~40 строк) |
| `CommandServerLifecycle` | `startOrReloadService` / `closeService` / `close` orchestration с `runCatching` + retry guard | новый код после Phase B.1 |

Цель: `BoxVpnService.kt` сократится с 552 до ~300 строк, каждый из выделенных классов — 50-100 строк, single-responsibility.

### B.2.3 — Coroutine usage cleanup

- **`runBlocking` audit** — найти все `runBlocking { ... }`, заменить на `suspend fun` где caller может быть suspend; оставить только в callback'ах из Java/Kotlin-non-suspend кода
- **Consistent Dispatchers** — сейчас вперемешку `Dispatchers.IO`, `Dispatchers.Main`, и нет явного default. Зафиксировать: shutdown = IO, status emit = Main, libbox calls = IO
- **`GlobalScope` нет** — каждая coroutine должна иметь scope, привязанный к Service lifecycle (`serviceScope`)

### B.2.4 — Log volume reduce

Сейчас `BoxVpnService` пишет `Log.d(TAG, ...)` на каждом state transition + каждой libbox-операции. Это ~30+ debug-events на один connect/disconnect cycle. План:

- **Debug-only build flag** — `Log.d` только если `BuildConfig.DEBUG`; в release — silent
- **Структурированный лог** — вместо `Log.d(TAG, "[vpn] doStop ENTER status=...")` сделать helper `logVpnLifecycle(event, fields...)` с consistent format
- **Critical events → AppLog** — то что юзер должен видеть в Debug screen (ошибки, race detection) идёт через `Libbox.writeMessage` или MethodChannel в Dart `AppLog`

### B.2.5 — Dead code removal

Аудит файлов на:
- Закомментированный код (TODO/FIXME без даты — пометить или убрать)
- Unused imports
- Unused fields/methods
- Deprecated API calls с suppressed warnings — пересмотреть, мб уже есть нормальная альтернатива

### B.2.6 — Race conditions audit

Особенно state transitions в BoxVpnService:
- `Stopped → Starting` — что если onStartCommand зашёл дважды быстро?
- `Starting → Started` — что если libbox упал mid-start?
- `Started → Stopping` — что если IDLE_MODE_CHANGED пришёл во время stop?
- `Stopping → Stopped` — что если onDestroy и doStop вошли одновременно?

Для каждого перехода — guard с явным comment "почему именно тут".

### B.2.7 — Comments policy

Оставить только нетривиальные комментарии: те что объясняют **"почему так а не иначе"**, ссылки на upstream issues, фиксированные баги.

Удалить:
- `// TODO: cleanup later` без owner и даты
- `// This sets the X` комментарии (тавтология)
- Закомментированный старый код

### B.2.8 — Тесты — что прибавится в скоупе

Юнит-тесты для классов которые выделим:
- `VpnLifecycleStateMachine` — все валидные/невалидные переходы
- `VpnTunnelBuilder` — построение Builder из `OpenTunOptions`
- `CommandServerLifecycle.shutdown` — order of operations + error paths

Не пишем тесты для самого `BoxVpnService` (Android Service, нужен Robolectric — out of scope).

---

## B.3 — Канонический референс

**Все архитектурные решения сверять с** `SagerNet/sing-box-for-android/app/src/main/java/io/nekohasekai/sfa/bg/BoxService.kt` — это код самого upstream, написан автором sing-box.

Принципы:
- Любая нетривиальная решка → comment с file:line ссылкой на SFA
- Если отступаем от SFA-pattern'а → обязательно comment с обоснованием (напр., "у нас VPN-only, не TUN-mode стандалон, поэтому X")
- При сомнениях — следуем SFA. Они работают над production-приложением который используется владельцами sing-box; их код — наиболее vetted reference в экосистеме

**SFA — reference, не идеал.** У них есть свои inconsistencies (комментарий `// Seq.destroyRef(refnum)` в комментарии — оставлено как documentation вместо удаления). Мы не копируем 1-в-1, но не отступаем без причины.

---

## Реализация — единый коммит

**Подход**: вся работа делается на feature-ветке `feat/039-libbox-1.13-migration` и приземляется **одним коммитом**. Тесты, сборка, install — только в конце, после того как ВСЕ изменения готовы. Spec выполняет роль детального плана работ — каждый раздел выше (Phase A.1-A.6, Phase B.1-B.3, Phase C) превращается в логическую часть единого diff'а.

### Почему один коммит, а не серия атомарных

- Spec уже разбит на логические фазы → читать diff нужно вместе со spec'ом, а не отдельно
- Между фазами нет смысла state'а где половина мигрирована (А1 enum + старый String → mixed types на одной фазе компиляции)
- Меньше merge-conflict'ов с develop за время работы
- При ревью важна целостная картина "до/после", не пошаговая эволюция

**Trade-off:** если регрессия — bisect показывает один коммит, отлаживать сложнее. Митигация — спека (этот файл) задокументирует все логические шаги, можно ментально reconstruct'ить порядок.

### Порядок работы (внутренний, в одной ветке, без промежуточных коммитов)

#### Фаза A — Dart wrapper cleanup
1. **A.1** — `enum VpnStatus`, `VpnStatusEvent` модель, обновить `box_vpn_client.dart`. Поправить callsite'ы в `home_controller.dart`, `home_state.dart`.
2. **A.2** — `enum BackgroundMode`, обновить `box_vpn_client.dart`, `app_settings_screen.dart`.
3. **A.3** — `class AppInfo`, новый файл `models/app_info.dart`. Обновить `box_vpn_client.dart`, `routing_screen.dart`, `app_info_cache.dart`.
4. **A.4** — Timeout'ы на критических вызовах. Все `_methods.invokeMethod(...)` обёрнуты в `.timeout(_Timeouts.X)` + try/catch + AppLog.error.
5. **A.5** — Method-name константы `class _Methods`. Все строки имён → константы.
6. **A.6** — Singleton `BoxVpnClient.I` + `forTest({methods, events})` factory. Все callsite'ы → `.I`.

После Фазы A — `flutter analyze` должен пройти без ошибок, даже если ничего не запускали на телефоне.

#### Фаза B — Native Kotlin deep rewrite
7. **B.0** — Bump gradle pin: `1.12.12 → 1.13.11`.
8. **B.1** — `PlatformInterfaceWrapper.kt`: `findConnectionOwner` → `ConnectionOwner` struct, удалить `packageNameByUid`/`uidByPackageName`/`PackageManager` import.
9. **B.2** — Создать `VpnLifecycleStateMachine.kt` (StateFlow<VpnStatus> + типизированные переходы), вынести из `BoxVpnService`.
10. **B.3** — Создать `VpnTunnelBuilder.kt`, вынести `VpnService.Builder` логику.
11. **B.4** — Создать `IdleModeReceiver.kt`, вынести broadcast receiver.
12. **B.5** — `BoxVpnService.kt`: миграция на `CommandServer` (главный шаг). Реализовать `CommandServerHandler` (`serviceStop`, `writeDebugMessage` вместо `postServiceClose`/`writeLog`). `Libbox.newService` → `cs.startOrReloadService(config, OverrideOptions())`. Удалить `Seq.destroyRef`. Все файлы кроссылки сверять с `SFA/BoxService.kt:line`.
13. **B.6** — Pause/wake через `cs.pause()/wake()` в `IdleModeReceiver` callback. Two-phase shutdown: `closeService()` → `close()` → `stopSelf()` на `Dispatchers.IO` coroutine с `runCatching` + `setError`.
14. **B.7** — Cleanup: log volume reduce (Log.d → debug-only через BuildConfig.DEBUG check), dead code removal, comments policy. Аудит `VpnPlugin.kt` handler'ов.

#### Фаза C — Cleanup + docs
15. **C.1** — Убрать `"format": "domain_suffix"` из `wizard_template.json:448`.
16. **C.2** — Обновить CLAUDE.md (1.12.12 → 1.13.11), CHANGELOG entry, `pubspec.yaml` → `1.6.0`, новый файл `docs/releases/v1.6.0.md`, обновить `RELEASE_NOTES.md`.

#### В самом конце — build + tests
17. `flutter build apk --release --target-platform android-arm64`
18. `scripts/install-apk.sh`
19. Smoke + полный test suite (см. ниже)
20. Проверка ConnectionOwner package names в Stats UI (см. сценарий #10 — отвечает на вопрос Сценарий A/B/C)
21. Run `flutter analyze` final time
22. Если всё green — `git add` + `git commit`:

```
feat(vpn): migrate to libbox 1.13.11 + Dart wrapper cleanup

См. полный план в docs/spec/features/039 libbox 1.13 migration/spec.md.

Phase A — Dart wrapper cleanup (BoxVpnClient):
  - VpnStatus enum (was String)
  - BackgroundMode enum (was String)
  - AppInfo model (was Map<String, dynamic>)
  - MethodChannel timeouts on critical paths
  - Method-name constants
  - Singleton + DI factory

Phase B — libbox 1.13 + Kotlin deep rewrite:
  - libbox: 1.12.12 → 1.13.11 (DNS dedup-lock leak fix)
  - PlatformInterface: ConnectionOwner struct, drop UID-mapping callbacks
  - Extract: VpnLifecycleStateMachine, VpnTunnelBuilder, IdleModeReceiver
  - BoxService → CommandServer single-entry-point architecture
  - Two-phase shutdown on Dispatchers.IO
  - Log volume reduce + dead code removal

Phase C:
  - wizard_template.json cleanup
  - Version bump → 1.6.0

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

23. Push, открыть PR develop ← `feat/039-libbox-1.13-migration`

---

## Test plan

### Smoke (после каждого коммита)
1. `flutter build apk --release --target-platform android-arm64`
2. `scripts/install-apk.sh`
3. Открыть app — не крашится на старте
4. About-screen показывает `1.5.0+13`
5. Connect VPN → tunnel up
6. Mass ping → все ноды получают delay (не -1)
7. Disconnect → нет orphan процессов

### Полный (перед merge)
| # | Сценарий | Ожидание | Проверка |
|---|---|---|---|
| 1 | Cold VPN start | `CommandServer` ctor + `start()` + `startOrReloadService()` без exception | `adb logcat` — нет ERROR от libbox |
| 2 | Hot config reload (selector switch / subscription update) | `startOrReloadService` повторно, Unix socket остаётся жив | `curl http://127.0.0.1:9269/state` до и после — `tunnel: connected`, no socket reset |
| 3 | Doze pause/wake | `pause()` → `wake()` парами; TUN не сброшен | `adb shell dumpsys deviceidle force-idle` → `force-active` |
| 4 | WiFi → cellular handoff | `DefaultNetworkMonitor` fires `updateDefaultInterface`; box не перезапускается | `adb shell svc wifi disable` после connect через wifi |
| 5 | VPN revoke (другое VPN-app) | `onRevoke()` → ordered shutdown | Установить другой VPN, активировать → наш `tunnel: revoked` |
| 6 | Force-stop из настроек | На следующий запуск Unix socket не залип | `adb shell am force-stop com.leadaxe.lxbox` → reopen app |
| 7 | `closeService` failure | `setError` пайп срабатывает | (нужен runtime trigger; гипотетический) |
| 8 | Длительный аптайм | DNS dedup-lock leak отсутствует — пинг работает после 1 часа | Connect → `sleep 3700` → mass ping → все ноды OK (vs текущий bug на 1.12.12 — отказ через 27 мин) |
| 9 | Rapid start/stop toggling | Нет double-start / double-close | Toggle 10 раз быстро в UI |
| 10 | `connection_owner` packages показываются в Stats | LxBox UI показывает `com.telegram.messenger` для Telegram-соединений | Connect VPN → открыть Telegram → проверить Stats > Connections |

### Регрессия по поддерживаемым Android-versions
Тестируем на:
- Android 15 (API 35) — primary, OnePlus CPH2411
- Android 11 (API 30) — Maxim's Samsung A50 (если ремотно тестируется)
- Android 8 (API 26) — minSdk бoundary; verify VPN starts at all (без `findConnectionOwner` — sing-box использует `useProcFS`)

---

## Риски и митигации

| Риск | Вероятность | Митигация |
|---|---|---|
| Subtle race в `startOrReloadService` при rapid reload (selector spam) | Средняя | Test #9 + epoch-based debounce в HomeController (уже есть) |
| `Seq.destroyRef` забыли убрать → double-free → SIGSEGV | Низкая (компилятор поймает если совсем удалили) | grep `destroyRef` после refactor — должно быть 0 хитов |
| Idle/wake broadcast регистрация утекает между service restart'ами | Средняя | Bracket register/unregister в `onStartCommand` / shutdown coroutine |
| `commandServer.close()` без предварительного `closeService()` подвешивает Go-thread | Высокая (если перепутать порядок) | Тест #1 + #6 |
| 1.13.x требует новых Android permissions, которые мы не запросили | Низкая | Manifest review — sing-box-for-android Manifest.xml diff |
| Builder LxBox генерит конфиг отвергнутый 1.13 | Уже исключено (verified в research-фазе) | — |

---

## Rollback plan

Если в production обнаружится регрессия:
1. Revert последнего merge feat/039 → develop
2. Поднять hot-fix branch с pin'ом `1.12.25` (содержит DNS-fix без архитектурной миграции)
3. Cherry-pick `chore(wizard_template)` cleanup и docs
4. Outline failure mode в этом spec файле, status → "Reverted, see commit X"

Ветка `feat/039` не удаляется — миграция повторяется позже с фиксом причины.

---

## Зависимости от внешних артефактов

- `com.github.singbox-android:libbox:1.13.11` опубликован в JitPack (verified 2026-04-23).
- `SagerNet/sing-box-for-android` master branch содержит canonical 1.13 lifecycle — используется как reference. Файл `app/src/main/java/io/nekohasekai/sfa/bg/BoxService.kt`.

## Обновления в других местах

- `CLAUDE.md`: строка `sing-box native library (libbox 1.12.12 via JitPack)` → `1.13.11`
- `README.md`: если упоминается версия — обновить
- `CHANGELOG.md`: добавить в Unreleased: `Build/CI: bump libbox 1.12.12 → 1.13.11 (см. spec 039)`
- `docs/ARCHITECTURE.md`: если упоминается lifecycle BoxService — переписать раздел под CommandServer
