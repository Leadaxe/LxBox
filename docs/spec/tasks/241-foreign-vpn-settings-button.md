# §241 — Кнопка «VPN settings» в диалоге «Another VPN is active»

> СТАТУС: реализовано (05.07.2026). Device-фидбэк: v2rayNG boot-receiver
> перехватил слот, юзер не мог понять, кем занят VPN.

## Что

В диалоге `showForeignVpnDialog` (pre-check перед ручным Start, когда VPN-слот
занят другим приложением) — третья кнопка **«VPN settings»**, открывающая
системный экран Settings → VPN (`Settings.ACTION_VPN_SETTINGS`). Там активный
VPN помечен системой как «Connected» — юзер видит перехватчика сам.

## Зачем не имя пакета в тексте

Имя владельца VPN-слота из приложения недостижимо:
`NetworkCapabilities.getOwnerUid()` по javadoc возвращает `INVALID_UID` всем,
кроме самого владельца сети (privacy by design); `VpnTransportInfo` (session
name) редактируется для непривилегированных вызовов. Системный VPN-экран —
единственный zero-permission способ показать юзеру виновника. Точное имя
возможно только через Usage Access-эвристику (FOREGROUND_SERVICE_START
VPN-кандидатов) — отдельная фича, если кейс окажется частым.

## Реализация

- `VpnPlugin.kt`: кейс `openVpnSettings` → существующий helper
  `openSystemSettings(ACTION_VPN_SETTINGS, primaryWithPackage = false)`.
  Action public с API 24 (наш minSdk, §233) — без version-гейтов. Fallback
  не нужен: экран есть на всех Android/OEM.
- `method_names.dart` + `box_vpn_client.dart`: `openVpnSettings()` — по
  образцу `openNotificationSettings` (timeout `_Timeouts.settings`).
- `home_dialogs.dart` / `showForeignVpnDialog`: `TextButton` «VPN settings»
  между Cancel и Switch; открывает настройки через `BoxVpnClient.I` и
  закрывает диалог с `false` (старт НЕ выполняется — юзер ушёл разбираться).

## Вне скоупа

- `showRevokedSnackBar` не трогаем: у Material SnackBar один action, и это
  «Start» (важнее). Текст снекбара уже честный.
  > Апдейт §276: этот SnackBar удалён — он дублировал общий обработчик ошибок
  > §166 и тот его перебивал (`hideCurrentSnackBar`). Текст перехвата теперь
  > показывает §166, без action-кнопки.
- Фоновые точки старта (tile/automation) — диалога там нет by design
  (см. комментарий в `_startWithAutoRefresh`).
