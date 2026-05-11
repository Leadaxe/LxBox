# 030 — VPN Reload core button

| Поле | Значение |
|------|----------|
| Статус | Draft |
| Дата | 2026-05-01 |
| Связанные spec'ы | [`tasks/060-libbox-1-13-migration`](060-libbox-1-13-migration/spec.md), [`031 debug api`](../features/031%20debug%20api/spec.md) |

## Цель

Дать юзеру **более мягкие способы перезапуска** VPN-core, без полного recreation Android Service. Текущий `Disconnect → Connect` через main-кнопку — heavy: убивает Android Service и tunnel дропается на 5-10 секунд. Inplace-методы sing-box (через `commandServer`) сохраняют tun и быстрее восстанавливают.

## Решение

Кнопка **"Reload"** в AppBar `home_screen` (когда `tunnel == connected`), которая зовёт `commandServer.startOrReloadService(config, OverrideOptions())` **inplace** на existing CommandServer. Пересоздаёт box runtime, но **не убивает Android Service** — tun не дропается на длительный период, юзер не теряет VPN-permission session.

Если Reload не помог — юзер прибегает к full Disconnect → Connect через main button.

> Альтернативный, более "лёгкий" recovery — `commandServer.resetNetwork()` — выделен в отдельную task'у [`031`](031-reset-network-api.md). На UI пока не выводится; экспонируется только через MethodChannel + Debug API для экспериментов.

### Что это делает архитектурно

В sing-box 1.13 `startOrReloadService` — единый entry point для start и reload (см. [§060 libbox 1.13 migration](060-libbox-1-13-migration/spec.md)). Reload:
- **Не убивает** Android Service / VpnService
- **Не убивает** CommandServer (Unix-socket остаётся живой; Clash dashboard не теряет connection)
- **Recyclит** только sing-box runtime внутри: closes outbound dialers, drops in-flight TCP, rebuilds DNS resolver, re-evaluates routes
- Tun fd может быть пере-bound, но коротко (~1 sec); юзер не успевает заметить разрыв

### UX

```
┌────────────────────────────────────┐
│ AppBar:  ⟳ ← reload button         │
│   visible только когда tunnel up   │
│   tap → snackbar "Reloading core…" │
│        (без подтверждения)         │
│   ~3s spinner                       │
│   on success → snackbar "Reloaded ✓"│
│   on fail → snackbar "Reload failed"│
└────────────────────────────────────┘
```

**Cooldown 3 секунды** — после tap кнопка disabled на 3s, чтобы юзер не спамил при тревоге. Достаточно чтобы операция отработала и status events пришли в UI.

### Поведение при разных tunnel-states

| Tunnel state | Reload button |
|---|---|
| `connected` | enabled, видна |
| `connecting` / `stopping` | hidden или disabled (transient) |
| `disconnected` / `revoked` / `error` | hidden (нет смысла reload'ить остановленное) |

## Реализация

### 1. `BoxVpnService.kt`

Companion-method `reload(context)` (зеркало `stop()`):

```kotlin
companion object {
    const val ACTION_RELOAD = "com.leadaxe.lxbox.ACTION_RELOAD"

    fun reload(context: Context) {
        Log.d(TAG, "[vpn] companion.reload() current status=${currentStatus.name}")
        context.sendBroadcast(
            Intent(ACTION_RELOAD).setPackage(context.packageName)
        )
    }
}
```

В `receiver.onReceive` — новый case:

```kotlin
ACTION_RELOAD -> {
    Log.d(TAG, "[vpn] receiver: ACTION_RELOAD → serviceReload()")
    serviceReload()  // existing CommandServerHandler-метод; recycles box runtime
}
```

**`serviceReload()`** уже реализован для `CommandServerHandler` callback (вызывается когда внешний клиент типа Clash dashboard просит reload). Сейчас он:
1. Сетит status `Starting`
2. Зовёт `cs.startOrReloadService(config, OverrideOptions())`
3. На успех — снова status `Started`

Никаких изменений в `serviceReload` не нужно — переиспользуем существующий код.

В `IntentFilter` (registerReceiver в onStartCommand) — добавить `addAction(ACTION_RELOAD)`.

### 2. `VpnPlugin.kt`

MethodChannel handler:

```kotlin
"reloadVPN" -> {
    BoxVpnService.reload(applicationContext)
    result.success(true)
}
```

### 3. `BoxVpnClient.dart`

```dart
// в _Methods class
static const reloadVPN = 'reloadVPN';

// timeout
static const reload = Duration(seconds: 10);

// public API
Future<bool> reloadVPN() async {
  final ok = await _invoke<bool>(
    _Methods.reloadVPN,
    timeout: _Timeouts.reload,
    onTimeoutValue: false,
  );
  return ok ?? false;
}
```

### 4. `home_controller.dart`

С 3-сек cooldown'ом:

```dart
DateTime? _lastReloadTap;
static const _reloadCooldown = Duration(seconds: 3);

bool get canReload =>
    _state.tunnelUp &&
    (_lastReloadTap == null ||
     DateTime.now().difference(_lastReloadTap!) > _reloadCooldown);

Future<void> reloadVpn() async {
  if (!canReload) return;
  _lastReloadTap = DateTime.now();
  notifyListeners();
  final ok = await _vpn.reloadVPN();
  _addDebug(DebugSource.app, '[vpn] reload → ok=$ok');
}
```

### 5. `home_screen.dart`

**Не добавляем** новую кнопку — заменяем поведение существующей `_buildReloadButton` (Icons.refresh с long-press menu, которая уже была на главном экране).

Раньше **default tap** при `tunnelUp + не-dirty config` вызывал `_controller.reconnect()` (full stop+start). Меняем на `_controller.reloadVpn()` (in-place):

```dart
void _runDefaultReload(HomeState state) {
  HapticService.I.onConnectTap();
  if (!state.tunnelUp) {
    unawaited(_rebuildAndStart());
    return;
  }
  final dirty = _subController.configDirty || _needsRestart;
  if (dirty) {
    unawaited(_rebuildAndReconnect());  // tunnel down → не релевантно для in-place
  } else {
    unawaited(_controller.reloadVpn());  // ← БЫЛО reconnect(), стало reloadVpn()
  }
}
```

Label кнопки меняется: `'Reconnect'` → `'Reload'`.

Long-press menu **сохраняется** — содержит явный пункт "Reconnect" который зовёт `_controller.reconnect()` (heavy fallback) для случаев когда in-place reload не помог. То есть юзер имеет:

| Действие | Поведение |
|---|---|
| **Tap** (default) | In-place reload (light, ~3s) |
| **Long-press → Reconnect** | Full stop+start (heavy fallback) |
| **Long-press → Rebuild config only** | Без restart'а |
| **Long-press → Rebuild + reconnect** | Heavy + config rebuild |

Cooldown на default tap — через `controller.canReload` getter (3 сек).

## Test plan

1. **Smoke**: connected VPN → tap Reload → snackbar → tunnel остаётся connected → mass ping работает после ~3s recycle
2. **Recovery**: provoke degradation → tap Reload → пинги восстановились
3. **Edge — disconnected**: tunnel stopped → reload button скрыта
4. **Edge — cooldown**: tap → tap снова через 1s → ignored. Через 4s → срабатывает.
5. **Edge — spam**: tap 5 раз подряд → cooldown держит, sing-box не падает
6. **Edge — failure** (broken config?) — handler catch'ит exception, status stays connected, error в logs

## Risks

| Риск | Митигация |
|---|---|
| Reload не лечит degradation в edge cases (deeper internal corruption) | Графefuly fail; user может прибегнуть к full Disconnect/Connect — fallback path остаётся |
| In-flight TCP connections дропаются (юзер качает файл, нажал reload) | Это inherent поведение reload'а; tooltip "Reload VPN core" дает понять |
| Race: tap Reload пока в `Stopping` | Receiver игнорирует ACTION_RELOAD если status != connected (добавим guard) |

## Что НЕ в скопе этой таски

- Auto-recovery (детект degradation → авто-trigger reload) — отдельная задача
- Изоляция WHICH из 4 sub-actions реально лечит (configs reload + connections close + selector switch + urltest) — отдельная исследовательская задача
- True "gentle" reset (DNS-cache only, dialer pool only) — требует upstream изменений в sing-box; не решаем

## Verification

После implementation — повторить sleep+handoff scenario из long-running ping теста (cycle deg → 0/24), нажать Reload → проверить что pings восстанавливаются 19+/24 без полного `disconnect → connect`.
