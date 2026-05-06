# 031 — Reset Network API exposure (experimental)

| Поле | Значение |
|------|----------|
| Статус | Draft |
| Дата | 2026-05-01 |
| Связанные | [`030 vpn reload button`](030-vpn-reload-button.md), [`039 libbox 1.13 migration`](../features/039%20libbox%201.13%20migration/spec.md) |

## Цель

Экспонировать `commandServer.resetNetwork()` через MethodChannel + Debug API без UI-кнопки. Для **экспериментирования** через adb — чтобы понять реальную семантику этого вызова и сравнить с full reload core ([§030](030-vpn-reload-button.md)).

## Что делает `commandServer.resetNetwork()` (по исходникам sing-box v1.13.11)

Изначальная гипотеза в этой спеке была **"БЕЗ drop'а in-flight TCP connections"**. Это **неверно** — чтение исходников показало, что resetNetwork закрывает **все** active connections. Ниже актуальный разбор по строкам.

### Цепочка вызова

```
CommandServer.ResetNetwork()                                  experimental/libbox/command_server.go:233
  → instance.Box().Router().ResetNetwork()                    route/router.go:226
      ├─ r.network.ResetNetwork()                             route/network.go:454
      └─ r.dns.ResetNetwork()                                 dns/router.go:455
```

### `network.ResetNetwork()` — закрывает ВСЕ connections + interface refresh

```go
func (r *NetworkManager) ResetNetwork() {
    if r.connectionManager != nil {
        r.connectionManager.CloseAll()                        // ← закрывает ВСЕ active connections
    }

    for _, endpoint := range r.endpoint.Endpoints() {
        if listener, ok := endpoint.(adapter.InterfaceUpdateListener); ok {
            listener.InterfaceUpdated()                       // endpoint dialers re-bind
        }
    }
    for _, inbound := range r.inbound.Inbounds() {
        if listener, ok := inbound.(adapter.InterfaceUpdateListener); ok {
            listener.InterfaceUpdated()                       // inbound (TUN, mixed) re-bind
        }
    }
    for _, outbound := range r.outbound.Outbounds() {
        if listener, ok := outbound.(adapter.InterfaceUpdateListener); ok {
            listener.InterfaceUpdated()                       // outbound dialers re-bind
        }
    }
}
```

`connectionManager.CloseAll()` (из `route/conn.go:51`) — `io.Closer.Close()` для каждого tracked connection: пользовательские TCP через TUN, mux-сессии, открытые DoH connections, всё что висит в connection tracker.

`InterfaceUpdated()` для outbound — каждый dialer перевыбирает underlying network handle (важно когда default interface поменялся, например wifi↔cellular).

### `dns.ResetNetwork()` — DNS cache flush + transport reset

```go
func (r *Router) ResetNetwork() {
    r.ClearCache()                                            // DNS-кэш очищается
    for _, transport := range r.transport.Transports() {
        transport.Reset()                                     // каждый DoH/DoT/UDP/TCP transport
    }
}
```

`HTTPSTransport.Reset()` (для `google_doh`-style серверов, `dns/transport/https.go:148`):
```go
t.transport.CloseIdleConnections()                            // старые HTTP/2 conn'ы к DoH дропнуты
t.transport = t.transport.Clone()                             // новый клиент создаётся с нуля
```

Аналогично для `tls`/`udp`/`tcp` транспортов — каждый `Reset()` закрывает свои persistent connections.

### Что НЕ делает

- ❌ recreate box runtime (config не перечитывается)
- ❌ закрыть CommandServer (Unix-socket держится, Clash dashboard не дисконнектится)
- ❌ убить Android Service / VpnService
- ❌ передернуть TUN fd (он остаётся, юзер не теряет VPN-permission)
- ❌ остановить inbound listeners (тот же TUN-inbound продолжает принимать пакеты)

### Сравнение с `Reload core` (§030 / `startOrReloadService`)

| Действие | resetNetwork | reload (§030) |
|---|---|---|
| Закрыть all in-flight connections | ✓ | ✓ (косвенно, через recycle) |
| DNS cache flush | ✓ | ✓ |
| DNS transports reset | ✓ | ✓ (создаются заново) |
| Outbound dialer rebind | ✓ | ✓ |
| Перечитать конфиг | ✗ | ✓ |
| Recreate box runtime | ✗ | ✓ |
| Recreate inbound listeners | ✗ | ✓ |
| Tun fd | стабилен | может быть rebound (~1s gap) |
| CommandServer | стабилен | стабилен |
| Service/VpnService | стабилен | стабилен |

`resetNetwork` — **средняя** глубина (рвёт connections + DNS state, но не пересоздаёт runtime). Для чисто network-recovery scenarios (после wake / network change / NAT timeout) это правильный выбор: дешевле reload'а, при этом достаточно агрессивный чтобы вычистить zombie connections и stale DoH sessions.

### Когда sing-box зовёт `ResetNetwork()` сам (без нашего trigger'а)

Из исходников `route/network.go`:

```go
notifyInterfaceUpdate()     line 521  // default interface changed (любой platform)
notifyWindowsPowerEvent()   line 528  // Windows EVENT_SUSPEND
                            line 536  // Windows EVENT_RESUME / EVENT_RESUME_AUTOMATIC
```

И:
- `service/oomkiller/service.go:180` — после OOM kill (Linux server-side фича)
- `experimental/clashapi/connections.go:105` — какой-то Clash API endpoint трогает (нужно проверить условие)

**На Android**: только `notifyInterfaceUpdate`. Triggered когда наш `DefaultNetworkMonitor.checkUpdate(network)` зовёт `InterfaceUpdateListener.updateDefaultInterface(name, idx, ...)`. Если default network не менялся (phone в кармане 1 минуту, wifi остался активен) — sing-box ResetNetwork **сам не вызывает**, hanging connections копятся.

Это motivates auto-recovery hook (см. §035 candidate task) — на USER_PRESENT / wake events явно дёргать resetNetwork.

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

## Test plan (sanity-check семантики)

После того как семантика установлена по исходникам, экспериментальная проверка нужна только для подтверждения наблюдаемого поведения:

1. Connected VPN с активными background TCP-connections (Telegram/etc.). Trigger resetNetwork (через `BoxVpnClient.resetNetwork()` или Debug API после доделки endpoint'а). Ожидание:
   - Tunnel остаётся `connected` ✓
   - Connection tracker (`/clash/connections`) показывает **0 active connections сразу после вызова** (CloseAll отработал)
   - Через 1-3 сек connection tracker снова заполняется новыми TCP (приложения пересоздают)
   - DoH connection к `dns.google` пересоздаётся при первом DNS-запросе после reset (новый TLS handshake)
2. Provoke degradation (sleep+handoff с zombie connections в tracker). Trigger resetNetwork:
   - Zombie connections (с 0 bytes traffic, age 10+ минут) исчезают из tracker
   - Pings восстанавливаются (потому что DoH cache очищен и dialer пере-bind'ится на актуальный network)
3. Сравнить с reload core (§030):
   - Reload: tunnel `Starting`-flicker, ~3s spinner, recreate inbound listeners
   - resetNetwork: tunnel остаётся `connected`, мгновенный, inbound не трогается
   - Verdict: для network-only recovery (wake / network change / NAT timeout) **resetNetwork предпочтителен**

## Что НЕ в скопе этой таски

- **UI-кнопка resetNetwork** — отдельная decision'ка после auto-recovery (§035 candidate). Возможно UI не нужен — auto-recovery + Reload (§030) как manual fallback покрывают все сценарии.
- **Auto-recovery / event-driven trigger** — отдельная таска (§035 candidate): на `USER_PRESENT` / wake / heartbeat-timeout / `DefaultNetworkMonitor.onAvailable(newNetwork)` дёргать resetNetwork. Это решает основной user-visible баг "после wake direct/auto не работает".
- **Доделка Debug API endpoint** `POST /action/reset-network` — упомянуто в этой спеке как пункт 4 имплементации, но фактически в `lib/services/debug/handlers/action.dart` НЕ добавлено. Делать в рамках §035 (для отладки auto-recovery).

## История гипотез

- **2026-05-01 (первоначальная гипотеза)**: «БЕЗ drop'а in-flight TCP connections» — описывалось как «truly gentle recovery».
- **2026-05-05 (актуально)**: гипотеза опровергнута чтением исходников sing-box v1.13.11. resetNetwork **closes ALL connections** через `connectionManager.CloseAll()` + reset DNS transports. Это не gentle, но **легче** чем reload (не recreate runtime/inbound). Для bug'а "stale connections after wake" это правильный инструмент.
