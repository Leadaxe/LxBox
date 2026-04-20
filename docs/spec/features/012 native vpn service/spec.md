# 012 — Native VPN Service

| Поле | Значение |
|------|----------|
| Статус | Реализовано |

## Контекст

Приложение использовало сторонний pub.dev плагин `flutter_singbox_vpn`. Плагин непопулярен, хранит конфиг в SharedPreferences, содержит лишний код. Цель: перенести всю нативную Android логику напрямую в проект + добавить автоподключение при загрузке.

## Native VPN Service (удаление flutter_singbox_vpn)

### Убрано
- `flutter_singbox_vpn` из `pubspec.yaml`
- TileService, BootReceiver (заменён своим), ProxyService, AppChangeReceiver, per-app tunneling, traffic_events

### Нативный код в `android/app/`

Пакет: `com.leadaxe.lxbox.vpn`

| Файл | Назначение |
|------|-----------|
| `VpnPlugin.kt` | Flutter MethodChannel + EventChannel мост |
| `BoxVpnService.kt` | Android VpnService + запуск libbox |
| `ConfigManager.kt` | Хранение конфига в файле (не SharedPreferences) |
| `ServiceNotification.kt` | Foreground notification |
| `VpnStatus.kt` | Enum статусов |

### Хранение конфига

Файл: `/data/data/com.leadaxe.lxbox/files/singbox_config.json`

### Контракт Flutter <-> Android

**MethodChannel**: `"com.leadaxe.lxbox/methods"`

| Метод | Вход | Выход | Семантика |
|-------|------|-------|-----------|
| `saveConfig` | `config: String` | `bool` | Пишет config на диск, no side effects на running tunnel |
| `getConfig` | — | `String` | Чтение config с диска |
| `startVPN` | — | `bool` | **Не blocking** — возвращает сразу после отправки `startForegroundService`. Actual Started прилетает через broadcast |
| `stopVPN` | — | `bool` | **Blocking до `setStatus(Stopped)` или 5с timeout** (§ «Status pipeline»). `true` = реально остановлен, `false` = timeout/error |
| `getVpnStatus` | — | `String` | Pull-метод: читает `BoxVpnService.Companion.currentStatus` (volatile mirror). Нужен для resync после reattach Flutter-процесса (broadcast'ы шлются только на transitions, steady-state pull даёт свежий статус) |
| `setNotificationTitle` | `title: String` | `bool` | Обновляет title в foreground notification |
| + ряд helper-методов | | | Battery-opt, installed apps, auto-start/keep-on-exit toggles, etc. |

**EventChannel**: `"com.leadaxe.lxbox/status_events"`

```json
{"status": "Started" | "Starting" | "Stopped" | "Stopping" | "Revoked", "error": "..."?}
```

`error` опционально — наполняется например при `Revoked` с текстом `"VPN revoked by another app"`.

## Status pipeline reliability (v1.4.0)

Broadcast-канал между native и Flutter (`EventChannel.receiveBroadcastStream`) имеет ряд underlying слабых мест: Doze/OOM могут терять broadcast'ы, `VpnPlugin.statusSink` — mutable поле где последний `onListen` перезаписывает предыдущий. Эти issues были ликвидированы в v1.4.0 через три независимые правки; детальный разбор в `docs/spec/tasks/001..004`.

### 1. Shared broadcast stream на Dart-стороне

`BoxVpnClient.onStatusChanged` теперь кэшируется через `late final` + `asBroadcastStream()`. Один underlying controller на весь lifecycle клиента, native `onListen` вызывается ровно один раз. Множественные Dart-listener'ы (основной + `firstWhere` в reconnect) работают параллельно, не перехватывая друг друга.

**До v1.4.0:** каждый вызов getter'а создавал новый `receiveBroadcastStream()` → новый onListen → перезапись `statusSink` в plugin. Когда `firstWhere` завершался, `onCancel` обнулял sink → основной listener становился зомби, все последующие broadcast'ы терялись.

### 2. Blocking `stopVPN` + `stopAwait` Completer

```kotlin
// BoxVpnService.Companion
@Volatile private var stopCompleter: CompletableDeferred<Unit>? = null

fun stopAwait(context: Context): Deferred<Unit> {
    if (currentStatus == VpnStatus.Stopped) return CompletableDeferred(Unit)
    val completer = CompletableDeferred<Unit>()
    stopCompleter?.cancel()         // re-entry protection
    stopCompleter = completer
    context.sendBroadcast(Intent(ACTION_STOP).setPackage(context.packageName))
    return completer
}
```

В `setStatus(newStatus)`:

```kotlin
if (newStatus == VpnStatus.Stopped) {
    stopCompleter?.complete(Unit)
    stopCompleter = null
}
```

Finality-signal о полном завершении stop'а идёт через **direct Completer**, не через broadcast. Broadcast по-прежнему уведомляет UI о transitions (fast path), но «реально ли завершилось» знает только Completer.

`VpnPlugin.stopVPN` handler:

```kotlin
private fun stopVpn(result: MethodChannel.Result) {
    pluginScope.launch {
        val ok = try {
            withTimeout(5_000) { BoxVpnService.stopAwait(context).await() }
            true
        } catch (_: TimeoutCancellationException) { false }
        catch (_: Exception) { false }
        result.success(ok)
    }
}
```

Caller в Dart получает control только после `setStatus(Stopped)`. Это исключает race в `onStartCommand:97` guard (`if (status != Stopped) return START_NOT_STICKY` — silent-return без setStatus(Starting) broadcast'а), который ловил reconnect'ы до v1.4.0.

### 3. Currentstatus mirror + getVpnStatus pull

```kotlin
@Volatile var currentStatus: VpnStatus = VpnStatus.Stopped
    private set
```

Обновляется в каждом `setStatus(...)`. Читается из любого потока без блокировки. Используется:

- `VpnPlugin.getVpnStatus` → каждый pull из Dart.
- `HomeController.init()` — сразу после подписки на broadcast stream, чтобы закрыть gap между process-restart и steady-state Started (keep-on-exit сценарий).
- `HomeController._resyncOnResume` (§ `003 home screen §8d`) — event-driven re-sync при возврате в app из background'а.

### 4. Revoke path

`onRevoke()` в service отзывает VPN корректно — cleanup + `setStatus(VpnStatus.Stopped, error = "VPN revoked by another app")` + `stopSelf()`. UX-сторона обрабатывает transition в `TunnelStatus.revoked` через SnackBar (§ `003 home screen §8c`).

`stopCompleter` — если ждался в этот момент — получает complete (setStatus(Stopped) всё равно вызывается).

### 5. Что остаётся unreliable

**Не решено (edge cases):**

- **Doze/OOM kill service без onDestroy callback.** Процесс Flutter может быть жив, но native service умер силой без broadcast'а. `onAppResumed` pull покрывает часть случаев, но если app остался в foreground — пропустим.
- **System broadcast delays.** В rare случаях broadcast может прийти с секундной задержкой. Наш 5с timeout в stopAwait покрывает с 60× запасом.

Если эти edge cases станут реальным issue у юзеров — добавить: явный `Log.d` telemetry divergence detection + decide между lightweight reconcile-on-divergence vs polling loop (отказались по запросу пользователя — паразитная нагрузка).

## Auto-connect on Boot

**Status:** Реализовано

### Android BootReceiver
- `RECEIVE_BOOT_COMPLETED` permission в AndroidManifest.
- `BootReceiver` — BroadcastReceiver, запускает VPN сервис при `ACTION_BOOT_COMPLETED`.
- Настройка "Auto-start on boot" в App Settings (SharedPreferences).

### Stop on App Swipe
- Настройка "Keep VPN on exit" — если выключена, VPN останавливается при свайпе приложения.
- Реализовано через `onTaskRemoved` в VpnService.

## Файлы

| Файл | Изменения |
|------|-----------|
| `android/app/src/main/kotlin/.../vpn/VpnPlugin.kt` | Flutter plugin |
| `android/app/src/main/kotlin/.../vpn/BoxVpnService.kt` | VpnService |
| `android/app/src/main/kotlin/.../vpn/ConfigManager.kt` | Хранение конфига |
| `android/app/src/main/kotlin/.../vpn/ServiceNotification.kt` | Notification |
| `android/app/src/main/kotlin/.../BootReceiver.kt` | Запуск VPN при загрузке |
| `lib/vpn/box_vpn_client.dart` | Dart-обёртка |
| `android/app/src/main/AndroidManifest.xml` | RECEIVE_BOOT_COMPLETED, BootReceiver |

## Критерии приёмки

- [x] `flutter_singbox_vpn` удалён из `pubspec.yaml`.
- [x] VPN запускается и останавливается через нативный `BoxVpnService`.
- [x] Конфиг сохраняется в `files/singbox_config.json`.
- [x] Статусы корректно доходят до Dart через EventChannel.
- [x] Notification показывается при активном VPN.
- [x] VPN запускается автоматически при загрузке устройства.
- [x] "Keep VPN on exit" контролирует поведение при свайпе.
- [x] `stopVPN` blocking до `Stopped` с 5с timeout (v1.4.0).
- [x] Reconnect через композицию `stop+start` не имеет race в `onStartCommand` guard (v1.4.0).
- [x] `getVpnStatus` pull позволяет re-sync после process reattach (v1.4.0).
- [x] Revoke от другого VPN обрабатывается через `onRevoke` с error-message в broadcast (v1.4.0).
