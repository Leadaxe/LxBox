# §182 — Кнопки Stop / Reconnect в foreground-уведомлении

| Поле | Значение |
|------|----------|
| Статус | Done (device-verified 2026-06-26) |
| Тип | task (UX-улучшение существующей фичи [`012 native vpn service`](../features/012%20native%20vpn%20service/spec.md)) |
| Дата старта | 2026-06-26 |
| Дата завершения | 2026-06-26 |
| Коммиты | `7dd86a8` feat(§182): кнопки Stop/Reconnect в foreground-уведомлении |
| Связанные spec'ы | [§012 native vpn service](../features/012%20native%20vpn%20service/spec.md), [§002 blocking stopVPN + intent reset](002-blocking-stopvpn-intent-reset.md), [§123 имя сервера в шторке](123-server-name-in-notification.md), [§129 force-stop](129-vpnservice-force-stop-on-stuck-core.md) |

## Проблема

Фидбэк #180 (llava), #261 (iliyal): **«Кнопки Stop/Reconnect в уведомлении»**.

Есть плитка быстрых настроек (QS-tile #183) и launcher-shortcut'ы, но **в самом
постоянном foreground-уведомлении сервиса кнопок нет** — только тап по нему
открывает приложение. Чтобы остановить или переподключить VPN, юзер вынужден
открыть приложение либо лезть в шторку быстрых настроек.

Текущее уведомление ([ServiceNotification.kt](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/ServiceNotification.kt))
не имеет **ни одной** `addAction` — только `setContentIntent` (тап → открыть приложение).

Целевой вид (кнопки добавляются под title/text из [§123](123-server-name-in-notification.md)):

```
┌─────────────────────────────────────────┐
│ 🔒 L×Box [final = vpn-1]                  │   title  (§123)
│    vpn-1: L: 🇫🇮⚡Финляндия-2              │   text   (§123)
│  ─────────────────────────────────────   │
│   [ Stop ]        [ Reconnect ]           │   ← §182 НОВОЕ
└─────────────────────────────────────────┘
```

> **Язык лейблов — английский.** Весь native-текст в проекте захардкожен по-английски
> (`"Starting..."`, `"Connected"`, `"Error"`, `"Connecting…"`, `"Stopping…"` в
> `BoxService.kt`/`LxBoxTileService.kt`), `getString(R.string…)` в Kotlin не
> используется — i18n-механизма для native-строк нет. `"Stop"` / `"Reconnect"`
> инлайном консистентно с существующим кодом.

## Диагностика (что уже есть, на чём строим)

Механика остановки готова и надёжна — добивать почти нечего:

- **Stop**: `BoxVpnService.ACTION_STOP` → `BoxService.receiver.onReceive` → `doStop()`
  (blocking teardown + `stopSelf()`). Тот же broadcast шлёт `companion.stop(context)`.
- **Reconnect-семантики на native НЕТ как примитива**: `reconnect()` живёт в Dart
  (`home_controller`: `_stopInternal` → `_startInternal`). Из уведомления при
  убитом UI Dart-движка может не быть → нужен **native-side reconnect**.
- **Ресивер регистрируется динамически** в `onStartCommand` через
  `ContextCompat.registerReceiver(..., RECEIVER_NOT_EXPORTED)` (НЕ в манифесте) —
  новый action добавляется в тот же `IntentFilter`.
- **`stopAwait()`** (companion-level `CompletableDeferred`, комплитится из
  `setStatus(Stopped)` → `completeStopIfWaiting()`) уже умеет «дождаться полного
  Stopped» независимо от `serviceScope`. Это фундамент честного reconnect'а — §002.
- **`onStartCommand` guard**: `if (status != Stopped) return START_NOT_STICKY`
  (silent-return). Старт поверх не-Stopped — молча проваливается. Reconnect обязан
  дождаться Stopped перед новым стартом.

## Решение

### 1. Stop — тривиально

`addAction` с `PendingIntent.getBroadcast(ACTION_STOP)`. Тот же broadcast, что шлёт
`companion.stop()`/`stopAwait()` → `receiver` → `doStop()`. Новой логики в teardown'е нет.

### 2. Reconnect — новый native-side примитив `ACTION_RECONNECT`

**Принцип: reconnect = `stopAwait()` (дождаться полного Stopped) → `start()`
(новый `startForegroundService`).** Именно через `stopAwait`, а НЕ «`doStop()` и
сразу `start()`», потому что `doStop()` асинхронный (cleanup на `serviceScope`,
`setStatus(Stopped)`/`stopSelf()` в конце); ранний `start()` попадёт в
`onStartCommand` guard и сервис не перезапустится. `stopAwait()` уже дожидается
`Stopped` через `stopCompleter` — переиспользуем как есть (это ровно тот race,
что §002 закрыл для Dart-пути).

**Где крутить ожидание.** НЕ на `serviceScope` — его отменяет `onDestroy` после
`stopSelf()`, и корутина с `await()` умрёт на полпути. Нужен **companion-level scope
уровня процесса**, переживающий смерть конкретного service-инстанса (как
`stopCompleter`). Заводим в `BoxVpnService.companion`:

```kotlin
/// §182 — process-level scope для reconnect-цепочки stopAwait→start.
/// НЕ на serviceScope: doStop()→stopSelf()→onDestroy отменил бы serviceScope
/// до того как мы дождёмся Stopped и сделаем новый start. Живёт на уровне
/// процесса (companion), как stopCompleter.
private val reconnectScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

/// §182 — guard от двойного reconnect'а (двойной тап по кнопке в шторке).
@Volatile
private var reconnecting: Boolean = false

/// §182 — native-side reconnect. JNI no-throw-инвариант (§141/§151): зовётся из
/// BroadcastReceiver, всё тело защищено — никакой throw наружу.
fun reconnect(context: Context) {
    Log.d(TAG, "[vpn] companion.reconnect() current status=${currentStatus.name}")
    if (reconnecting) {
        Log.w(TAG, "[vpn] reconnect already in progress — ignore")
        return
    }
    if (currentStatus == VpnStatus.Stopped) {
        start(context)   // нечего останавливать — просто старт
        return
    }
    reconnecting = true
    reconnectScope.launch {
        val stopped = try {
            withTimeout(6_000) { stopAwait(context).await(); true }
        } catch (t: Throwable) {
            Log.w(TAG, "[vpn] reconnect: stop phase failed/timeout: ${t.message}")
            false
        }
        if (stopped) {
            start(context)   // startForegroundService(ACTION_START)
        } else {
            // stop не подтвердился — НЕ стартуем поверх (избегаем guard-залипания).
            // Юзер увидит что VPN не поднялся, повторит вручную.
            Log.w(TAG, "[vpn] reconnect aborted — stop not confirmed")
        }
        reconnecting = false
    }
}
```

> `reconnectScope` создаётся один раз при загрузке класса (companion init),
> переживает рестарты сервиса, не отменяется нигде (лёгкий: SupervisorJob, одна
> короткоживущая корутина за reconnect). `reconnecting`-флаг сбрасывается всегда
> в конце корутины.

**Дублирование с Dart `reconnect()` — осознанно.** Уведомление обязано работать
с убитым UI, Dart-путь требует живого Flutter-движка. Оба идемпотентны и сходятся
к одному состоянию через `setStatus`/broadcast (Dart пересинхронится по broadcast'у
`Started`, если движок жив; через `getVpnStatus` pull — после re-attach).

### 3. ACTION_RECONNECT — `RECEIVER_NOT_EXPORTED`, broadcast только от себя

Кнопки шлют **explicit** broadcast с `setPackage(packageName)`, ресивер
`RECEIVER_NOT_EXPORTED` → извне не дёрнуть. PendingIntent'ы — `FLAG_IMMUTABLE`
(требование API 31+).

### 4. ServiceNotification — построение кнопок

`ServiceNotification` сейчас не знает про статус (`show(title, text)`). Добавляем
два `PendingIntent.getBroadcast` и навешиваем на builder:

```kotlin
private fun broadcastPI(action: String, requestCode: Int): PendingIntent {
    val intent = Intent(action).setPackage(service.packageName)
    return PendingIntent.getBroadcast(
        service, requestCode, intent,
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
}

// в builder (init):
builder
    .addAction(0, "Stop",      broadcastPI(BoxVpnService.ACTION_STOP, 1))
    .addAction(0, "Reconnect", broadcastPI(BoxVpnService.ACTION_RECONNECT, 2))
```

- **icon = 0**: на Android 7+ action-иконки в развёрнутом уведомлении compat-стиль
  скрывает — самодельные drawable не нужны, текст-лейбл достаточен. (В проекте есть
  только `ic_qc_stop`/`ic_qc_play` для QS-tile/shortcuts; в шторке используется
  системная `android.R.drawable.ic_lock_lock`.)
- ⚠️ **Грабли**: `NotificationCompat.Builder.addAction` **не идемпотентен** —
  каждый вызов добавляет ещё одну кнопку. Builder создаётся один раз в `init` и
  переиспользуется между `show(...)` → `addAction` зовём **строго в init**, НЕ в
  `show()`, иначе кнопки стекаются на каждый апдейт title/text.

### Когда показывать кнопки

| Фаза | title/text | Кнопки |
|---|---|---|
| `Starting` (`onStartCommand` → `"Starting..."`) | бренд / «Starting...» | Stop + Reconnect (D-2) |
| `Started` (`startSingbox` финал) | §123 строки | **Stop + Reconnect** |
| `"Error"` (`stopAndAlert`) | Error / message | кнопки есть (живут доли секунды — сразу `stop()`+`stopSelf()`) |

Кнопки навешиваем один раз в init и оставляем на всех `show(...)`. Error-кейс
сразу сопровождается `notification.stop()` + `stopSelf()`, лишние кнопки в нём
живут доли секунды — приемлемо для v1.

## Изменения

### Native (Kotlin)

| Файл | Изменение |
|---|---|
| [`BoxVpnService.kt`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxVpnService.kt) | + `const val ACTION_RECONNECT = "com.leadaxe.lxbox.ACTION_RECONNECT"`. + companion `reconnectScope` + `@Volatile reconnecting` + `fun reconnect(context)` (см. snippet). |
| [`BoxService.kt`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxService.kt) | В `receiver.onReceive` `when`: + ветка `BoxVpnService.ACTION_RECONNECT -> runCatching { BoxVpnService.reconnect(service.applicationContext) }` (через companion — reconnect переживает stopSelf). В `onStartCommand` `IntentFilter`: + `addAction(BoxVpnService.ACTION_RECONNECT)`. |
| [`ServiceNotification.kt`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/ServiceNotification.kt) | + два `addAction` + helper `broadcastPI` — строго в `init` (не в `show`). |

### Dart

**Изменений НЕ требуется.** Reconnect полностью native. Существующий broadcast-listener
(`onStatusChanged`) подхватит `Stopping`→`Stopped`→`Starting`→`Started`, UI обновится
сам. Pull через `getVpnStatus` покрывает re-attach после kill.

### Manifest

**Изменений НЕ требуется.** Ресивер регистрируется динамически (`RECEIVER_NOT_EXPORTED`),
не в манифесте. `POST_NOTIFICATIONS` уже объявлен. Action-кнопки уведомления не
требуют отдельного permission.

## Риски и edge cases

| Случай | Поведение |
|---|---|
| **JNI no-throw** (§141/§151) | `reconnect()` зовётся из `BroadcastReceiver` (не из JNI-колбэка ядра напрямую), но тело защищено `try/catch`/`runCatching`, ветка в `when` обёрнута `runCatching` — никакой throw наружу. |
| Двойной тап по Reconnect | `reconnecting`-guard: второй вызов — no-op до завершения первого. |
| Reconnect когда уже Stopped (гонка с авто-стопом) | `currentStatus == Stopped` → просто `start()`, без ожидания. |
| Stop-фаза reconnect'а зависла (как §129 detour-stuck) | `withTimeout(6_000)` → reconnect aborts, поверх НЕ стартуем (не залипаем в guard). Юзер повторит. forceStop-эскалация — отложена (D-1). |
| **UI-движок убит, уведомление живо** (keep-on-exit) | reconnect полностью native, не зависит от Dart. ✓ — главный смысл фичи. |
| Тап Stop во время Starting | `doStop` отрабатывает из любого не-Stopped статуса (guard только Stopped/Stopping). ✓ |
| `reconnectScope` и onDestroy | scope companion-level, `onDestroy`(`serviceScope.cancel`) его НЕ трогает — корутина доживёт до `start()`. ✓ |
| Внешний дёрг `ACTION_RECONNECT` | `RECEIVER_NOT_EXPORTED` + explicit `setPackage` → извне не послать. ✓ |

**Намеренно НЕ покрыто:** самодельные drawable-иконки кнопок; отдельный
notification-канал; пересборка Dart `reconnect()`; кнопка выбора ноды из шторки.

## Верификация

§182 — **чисто native (Kotlin)**, Dart-код не меняется → `flutter test` нерелевантен.
Проверка: сборка APK (`./scripts/build-local-apk.sh`) + **device-verify** (как §123/§180).

Критерии приёмки (на устройстве):

- [x] При активном VPN в развёрнутой шторке видны кнопки **Stop** и **Reconnect**.
- [x] Тап **Stop** → VPN останавливается (как кнопка Stop в приложении), уведомление гаснет.
- [x] Тап **Reconnect** → туннель пересоздаётся: `Stopping`→`Stopped`→`Starting`→`Started`
      в logcat; трафик восстанавливается; UI (если открыт) синхронно отражает реконнект.
- [x] **Reconnect работает при убитом UI** (keep-on-exit ON, приложение свайпнуто из
      recents, затем тап Reconnect в шторке) — туннель пересоздаётся без открытия приложения.
- [x] Двойной тап по Reconnect не плодит двойной старт (guard).
- [x] Reconnect когда VPN уже остановлен → корректный single start.
- [x] `ACTION_RECONNECT` не дёргается извне (другое приложение не может послать —
      `RECEIVER_NOT_EXPORTED` + `setPackage`).

## Решённые вопросы

- **D-1. Stop-фаза reconnect'а зависла** → **abort + лог** (без forceStop-эскалации в v1).
  forceStop()→start() добавим только если на устройстве поймаем stuck-stop. Отражено
  в `reconnect()`: `withTimeout(6_000)` → `stopped=false` → reconnect aborts.
- **D-2. Reconnect-кнопка в фазе `Starting`** → **показывать всегда** вместе со Stop.
  Кнопки навешиваются один раз в `init` и присутствуют во всех фазах (Starting/Started/Error).

## Docs to update

| Файл | Что добавить |
|---|---|
| [`docs/spec/features/012 native vpn service/spec.md`](../features/012%20native%20vpn%20service/spec.md) | В раздел про ServiceNotification — action-кнопки Stop/Reconnect + новый `ACTION_RECONNECT` + companion `reconnect()`. |
| [`docs/ARCHITECTURE.md`](../../ARCHITECTURE.md) | Native-side секция: `ACTION_RECONNECT` в списке broadcast-action'ов сервиса. |
| [`CHANGELOG.md`](../../../CHANGELOG.md) / `RELEASE_NOTES.md` | На bump'е версии: «Stop / Reconnect buttons in the persistent notification (#180/#261)». |
| [`app/pubspec.yaml`](../../../app/pubspec.yaml) | Patch bump в release-batch'е. |

> **Процесс (AGENTS.md):** работа идёт в feature-ветке (текущая
> `feat/libbox-1.14-migration` или новая от `develop`), **не** в `main`.
> Коммит/push — **только по явной команде оператора**.
