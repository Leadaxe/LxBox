# §211 — диалог «активен другой VPN» перед стартом

> **СТАТУС: СПЕКА.** Native (Kotlin) detect + Dart MethodChannel + UI-диалог.

## Проблема

При ручном старте из UI, если на устройстве **уже активен другой VPN**, мы
молча его перебиваем. `VpnService.prepare()` возвращает `null` в ДВУХ случаях,
которые код не различает ([VpnPlugin.kt:992](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/VpnPlugin.kt),
[MainActivity.kt:233](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/MainActivity.kt)):

1. наше VPN-разрешение выдано, **чужого активного VPN нет** → стартуем молча ✅
2. наше разрешение выдано, но **прямо сейчас активен ДРУГОЙ VPN** → `prepare()`
   тоже отдаёт `null` (consent уже есть), мы зовём `BoxVpnService.start()`,
   `establish()` молча отзывает (`onRevoke`) чужой туннель **без вопроса**.

Конкуренты (см. скриншоты FPTN) в случае 2 показывают **свой** in-app диалог
«Активен другой VPN — переключиться?». Android такого диалога не делает —
это их собственный `AlertDialog`. У нас его нет → перебиваем чужой VPN молча.

## Решение

Перед стартом из UI спросить native: «есть ли сейчас активный чужой VPN?».
Если да — показать наш диалог подтверждения. По SWITCH → обычный старт;
по CANCEL → ничего не делаем.

### Detect (native, Kotlin)

Новый MethodChannel-метод `isForeignVpnActive` в [VpnPlugin.kt](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/VpnPlugin.kt):

```kotlin
"isForeignVpnActive" -> result.success(isForeignVpnActive())

private fun isForeignVpnActive(): Boolean {
    // Наш сервис ещё не поднят (мы стартуем) → любая VPN-сеть = чужая.
    if (BoxVpnService.currentStatus != VpnStatus.Stopped) return false
    val cm = BoxApplication.connectivity
    return cm.allNetworks.any { n ->
        cm.getNetworkCapabilities(n)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
    }
}
```

Источник истины — `ConnectivityManager` + `NetworkCapabilities.TRANSPORT_VPN`
(тот же приём, что `DefaultNetworkMonitor.isVpn`, уже есть в проекте). Если наш
сервис уже в не-Stopped состоянии — это мы сами, не чужой; вернуть false.

### Dart-обёртка

[box_vpn_client.dart](../../../app/lib/vpn/box_vpn_client.dart):
```dart
Future<bool> isForeignVpnActive() async =>
    await _invoke<bool>(_Methods.isForeignVpnActive, onTimeoutValue: false) ?? false;
```
+ `method_names.dart`.

### UI-гейт

Только для **ручного старта из UI** — `_startWithAutoRefresh` в
[home_screen.dart](../../../app/lib/screens/home_screen.dart). Tile / quick-
shortcut / automation-intent / Debug API — фоновые, диалог некуда показать,
их поведение не трогаем (перебивают молча, как сейчас).

Перед `_controller.start()`:
```dart
if (await _vpn.isForeignVpnActive() && mounted) {
  final ok = await showForeignVpnDialog(context);  // null/false → отмена
  if (ok != true) return;
}
```

Диалог в [home_dialogs.dart](../../../app/lib/screens/home/home_dialogs.dart)
(рядом с остальными), стиль = наш `AlertDialog.adaptive`:
- title: **"Another VPN is active"**
- content: **"Another VPN app is currently running. Switch to L×Box?"**
- кнопки: **Cancel** (pop false) / **Switch** (FilledButton, pop true)

## Файлы

| Слой | Файл | Изменение |
|---|---|---|
| native | `VpnPlugin.kt` | `when`-ветка + `isForeignVpnActive()` |
| Dart | `vpn/box_vpn_client.dart` + `method_names.dart` | обёртка |
| Dart | `screens/home/home_dialogs.dart` | `showForeignVpnDialog` |
| Dart | `screens/home_screen.dart` | гейт в `_startWithAutoRefresh` |

## НЕ трогаем

- Фоновые точки старта (tile/shortcut/automation/Debug API/boot) — без диалога.
- §192 proxy-режим (без TUN) — там вообще не зовём prepare, чужой VPN не рвём;
  detect бессмыслен, но и не вреден (вернёт true → диалог → старт без revoke).
  Гейт можно навесить только под `hasTun` если потребуется; в первой версии
  диалог покажем всегда при активном чужом VPN — это честно и не ломает proxy.

## Тесты

- `isForeignVpnActive` Dart-обёртка: MethodChannel-мок → true/false/timeout.
- Device: включить любой другой VPN → тап Start в L×Box → диалог; Cancel = чужой
  жив; Switch = наш стартует, чужой отозван.

## Связанные

- §192 — proxy-prepare-revokes-foreign-vpn (тот же класс проблемы, другой угол).
- §012 — `showRevokedSnackBar` (обратное: НАС отозвал чужой VPN).
