# 015 — Android 9-11 quick-connect: defensive обёртки

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата | 2026-04-29 |
| Связанные spec'ы | [`032 quick connect`](../features/032%20quick%20connect/spec.md) |

## Проблема

После добавления `LxBoxTileService` (§032 Quick Connect) есть риск class-verification fails на Android 9-11 — `Tile.subtitle` (API 29+), `requestListeningState` и т.п. могут привести к `NoClassDefFoundError`/`VerifyError` на старых ART, и любой такой `Error` в `BoxVpnService.setStatus` валит старт VPN целиком.

Параллельно в манифесте `<uses-permission FOREGROUND_SERVICE_SPECIAL_USE>` и `android:foregroundServiceType="specialUse"` — оба API 34+. На API <34 они либо игнорируются, либо обрабатываются OEM-специфично; на API 34+ строгие OEM (One UI 6, MIUI 14) могут требовать typed `startForeground` для VPN-сервиса.

## Решение

1. `Tile.subtitle = ...` извлечён в `@RequiresApi(Q)` helper в [`LxBoxTileService.kt`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/LxBoxTileService.kt) — class verifier видит явный API-tag и не валит загрузку класса на старых API.
2. `LxBoxTileService.refreshTile` и [`QuickShortcuts.refresh`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/QuickShortcuts.kt) — early return на API <30 + outer `try { Throwable }`. Quick Connect — primary tier (API 30+), на best-effort устройствах честный no-op.
3. Все callsites Quick-Connect-побочки в [`BoxVpnService.setStatus / onDestroy`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxVpnService.kt) и [`BoxApplication.initialize`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxApplication.kt) обёрнуты в `runCatching` — побочные сбои tile/shortcut'ов не валят старт VPN.
4. [`AndroidManifest.xml`](../../../app/android/app/src/main/AndroidManifest.xml) — `FOREGROUND_SERVICE_SPECIAL_USE` permission гейтнут `android:minSdkVersion="34"`. На младших API не запрашивается. Атрибут `foregroundServiceType="specialUse"` оставлен (нужен на 34+, на 30 парсится как unknown FGS-bit без runtime exception).
5. [`ServiceNotification.show`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/ServiceNotification.kt) на API 34+ — typed `startForeground(id, notif, FOREGROUND_SERVICE_TYPE_SPECIAL_USE)`; на младших API — старый 2-арг API.

## Verification

- Сборка release APK компилируется (compileSdk 36, minSdk 26).
- На API 30+ Quick Settings tile + home-screen shortcut работают как до правок.
- На API <30 Quick Connect — no-op, не пытается грузить TileService-классы.
