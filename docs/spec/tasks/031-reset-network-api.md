# 031 — Reset Network API exposure (experimental)

| Поле | Значение |
|------|----------|
| Статус | Draft |
| Дата | 2026-05-01 |
| Связанные | [`030 vpn reload button`](030-vpn-reload-button.md), [`039 libbox 1.13 migration`](../features/039%20libbox%201.13%20migration/spec.md) |

## Цель

Экспонировать `commandServer.resetNetwork()` через MethodChannel + Debug API без UI-кнопки. Для **экспериментирования** через adb — чтобы понять реальную семантику этого вызова и сравнить с full reload core ([§030](030-vpn-reload-button.md)).

## Что делает `commandServer.resetNetwork()`

Из исходников sing-box `v1.13.11` (`experimental/libbox/command_server.go`):

```go
func (s *CommandServer) ResetNetwork() {
    instance := s.StartedService.Instance()
    if instance == nil || instance.Box() == nil {
        return
    }
    instance.Box().Router().ResetNetwork()
}
```

Вызывает `box.Router().ResetNetwork()` — переустанавливает network sub-state роутера: outbound dialer bindings, default-interface monitor, DNS-resolver upstream tracking. **БЕЗ recreate'а box runtime**, **БЕЗ drop'а in-flight TCP connections** (теоретически — нужно проверить экспериментально).

Если эта гипотеза подтвердится — это **truly gentle recovery**, более лёгкий чем `Reload core` из [§030](030-vpn-reload-button.md).

## Реализация

### 1. `BoxVpnService.kt`

Companion-method:

```kotlin
companion object {
    const val ACTION_RESET_NETWORK = "com.leadaxe.lxbox.ACTION_RESET_NETWORK"

    fun resetNetwork(context: Context) {
        Log.d(TAG, "[vpn] companion.resetNetwork() current status=${currentStatus.name}")
        context.sendBroadcast(
            Intent(ACTION_RESET_NETWORK).setPackage(context.packageName)
        )
    }
}
```

В `receiver.onReceive`:

```kotlin
ACTION_RESET_NETWORK -> {
    Log.d(TAG, "[vpn] receiver: ACTION_RESET_NETWORK → cs.resetNetwork()")
    runCatching { commandServer?.resetNetwork() }
        .onFailure { Log.e(TAG, "resetNetwork failed", it) }
}
```

В `IntentFilter` — `addAction(ACTION_RESET_NETWORK)`.

### 2. `VpnPlugin.kt`

```kotlin
"resetNetwork" -> {
    BoxVpnService.resetNetwork(applicationContext)
    result.success(true)
}
```

### 3. `BoxVpnClient.dart`

```dart
static const resetNetwork = 'resetNetwork';
static const resetNet = Duration(seconds: 5);

Future<bool> resetNetwork() async {
  final ok = await _invoke<bool>(
    _Methods.resetNetwork,
    timeout: _Timeouts.resetNet,
    onTimeoutValue: false,
  );
  return ok ?? false;
}
```

### 4. Debug API endpoint

В `lib/services/debug/handlers/action.dart` — добавить:

```dart
'POST /action/reset-network' => () async {
  final ok = await BoxVpnClient.I.resetNetwork();
  return JsonResponse({'ok': ok, 'action': 'reset-network'});
}(),
```

Это даёт возможность дёргать через `curl -X POST http://127.0.0.1:9270/action/reset-network -H "Authorization: Bearer ..."` для adb-экспериментов.

## Использование (experimental)

```bash
TOKEN="..."
# trigger
curl -s -X POST -H "Authorization: Bearer $TOKEN" http://127.0.0.1:9270/action/reset-network
# observe behaviour: state, ping, TCP-states, in-flight connections
```

## Test plan (для понимания семантики)

1. Connected VPN с активными background TCP-connections (Telegram/etc.). Триггер resetNetwork. Проверить:
   - Tunnel остаётся `connected`?
   - In-flight TCP — выживают или дропаются?
   - DNS-cache очищается?
   - Outbound dialer'ы перевыбирают underlying interface?
2. Provoke degradation (sleep+handoff). Триггер resetNetwork. Сравнить с reload core (§030):
   - Какой быстрее восстанавливает probes?
   - Какой меньше дропает данные?
3. Если resetNetwork эффективнее — может стать дефолтным recovery action в UI вместо reload core.

## Что НЕ в скопе

- UI-кнопка resetNetwork — только если эксперимент покажет что оно работает лучше reload'а; тогда отдельная UI-таска
- Auto-recovery (auto-trigger при detected degradation)
- Документация результатов экспериментов — добавится в этот же spec по мере накопления
