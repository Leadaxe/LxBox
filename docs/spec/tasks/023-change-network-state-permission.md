# 023 — Отсутствующий `CHANGE_NETWORK_STATE` permission на Android 9-11

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата | 2026-04-29 |
| Связанные spec'ы | [`012 native vpn service`](../features/012%20native%20vpn%20service/spec.md) |

## Проблема

VPN валит процесс с `REASON_CRASH` в ApplicationExitInfo сразу после OK на consent на Android 9-11; на Android 12+ — работает. Stacktrace через канал D §038 (logcat tail):

```
java.lang.SecurityException: com.leadaxe.lxbox was not granted either of these permissions:
  android.permission.CHANGE_NETWORK_STATE, android.permission.WRITE_SETTINGS.
at android.net.ConnectivityManager.requestNetwork(ConnectivityManager.java:4344)
at com.leadaxe.lxbox.vpn.DefaultNetworkListener.requestDefaultNetwork(...)
```

В [`DefaultNetworkListener`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/DefaultNetworkListener.kt):

```kotlin
Build.VERSION.SDK_INT >= 31 -> cm.registerBestMatchingNetworkCallback(...)  // только ACCESS_NETWORK_STATE
Build.VERSION.SDK_INT >= 28 -> cm.requestNetwork(request, Callback, mainHandler)  // + CHANGE_NETWORK_STATE
```

`requestNetwork` — это «активный» запрос (система может активировать другую сеть), отсюда строгий permission. `registerBestMatchingNetworkCallback` — пассивный, без него.

## Решение

```xml
<uses-permission android:name="android.permission.CHANGE_NETWORK_STATE" />
```

`normal`-permission, без runtime-prompt'а, миграция silent.

## Verification

- На Android 9-11 — `requestNetwork(...)` отрабатывает без SecurityException.
- На Android 12+ — поведение не меняется (ветка `>=31`).
