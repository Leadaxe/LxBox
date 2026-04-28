# 014 — Quick Connect: QS tile + home-screen shortcut

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата старта | 2026-04-28 |
| Дата завершения | 2026-04-28 |
| Коммиты | (закомичено в одном/двух коммитах §032 на ветке `develop`) |
| Связанные spec'ы | [`032 quick connect`](../features/032%20quick%20connect/spec.md) |
| Связанные issue | [#1 Add Android Quick Settings tile and app icon shortcut](https://github.com/Leadaxe/LxBox/issues/1) |

## Проблема

Юзеры просили (issue #1, и регулярные жалобы в фидбеке) две точки управления VPN без открытия приложения:

1. **Quick Settings tile** в системной шторке — тап = toggle, плитка показывает текущий статус.
2. **Long-press на иконку app'а** на хоум-скрине — пункт «Toggle VPN», тап = toggle без открытия UI.

Существующий flow требовал каждый раз открывать app, ждать загрузки Flutter-engine и нажимать главный экран — медленно и раздражает у тех, кто десятки раз в день включает/выключает VPN (например, разделение оплаты подписок vs локальные сервисы).

## Диагностика

Спека `§032 quick connect` уже была написана (Draft, 2026-04-20) и закрывала весь scope, включая ключевую ловушку — **VPN consent dance**:

- `VpnService.prepare(applicationContext)` возвращает `Intent != null` если consent ещё не давали. Этот intent нужно стартовать через `startActivityForResult` **из Activity** — `TileService` и `BroadcastReceiver` Activity'ёй не являются.
- Логика: первый тап на tile/shortcut → открываем `MainActivity` со extras `{action: connect|disconnect|toggle}` → activity дёргает `prepare()`, после `RESULT_OK` стартует сервис и закрывает себя.
- Все последующие тапы (после успешного consent'а) идут напрямую `BoxVpnService.start(context)` без UI.

UX-добавка перед началом: первый раз, когда tile/shortcut открывает `MainActivity` ради consent-диалога, мы показываем системный toast «Opening L×Box for VPN permission (one-time)» — иначе у юзера wtf-момент: «я нажал на tile, почему открылось приложение?». После `RESULT_OK` activity делает `finish()`, чтобы юзер вернулся обратно на хоум — это то, что он ожидал от tile/shortcut.

Edge-кейс OEM `requestAddTileService` (API 33+) — на ColorOS / MIUI / HyperOS prompt может молча не показаться. Mitigation: текстовая инструкция «потяни шторку → редактирование → перетащи L×Box» в UI fallback и в snackbar после `error: …` от native.

## Решение

### Native (Kotlin)

| Файл | Что |
|------|-----|
| [`LxBoxTileService.kt`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/LxBoxTileService.kt) | Новый `TileService`. `onClick` — toggle с гейтами на transient-статусы; `onStartListening` рендерит state из `BoxVpnService.currentStatus`; `connectOrPromptConsent` показывает toast и `startActivityAndCollapse(MainActivity, extras=connect)` если consent ещё не был. На API 34+ используется `PendingIntent`-overload (новый контракт). |
| [`MainActivity.kt`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/MainActivity.kt) | `handleQuickAction(intent)` обрабатывает extras `action ∈ {connect, disconnect, toggle}`, дёргает `VpnService.prepare(...)` если нужно, после `RESULT_OK` стартует `BoxVpnService` и `finish()`'ит себя — юзер не видит app. На `RESULT_CANCELED` — toast `qc_consent_denied` и `finish()`. Extras очищаются после первой обработки (защита от повторного срабатывания при rotation/reattach). |
| [`BoxVpnService.kt`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxVpnService.kt) | В `setStatus(...)` — `LxBoxTileService.refreshTile(applicationContext)` после broadcast'а (no-op если tile не в шторке). В `onDestroy` — страховка: если `currentStatus != Stopped` (OOM-kill), сбрасываем и refresh'им tile, чтобы он не врал «Connected». |
| [`VpnPlugin.kt`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/VpnPlugin.kt) | `requestAddTile` method-channel handler — на API 33+ зовёт `StatusBarManager.requestAddTileService(...)` асинхронно (Consumer-callback → `result.success(...)` через `mainHandler`). Возвращает короткий статус-стринг: `added` / `already` / `dismissed` / `unsupported` / `no_activity` / `error: ...`. Есть guard от двойного `success()` на OEM, которые зовут consumer несколько раз. |

### Resources

| Файл | Что |
|------|-----|
| [`AndroidManifest.xml`](../../../app/android/app/src/main/AndroidManifest.xml) | `<service .vpn.LxBoxTileService>` с `BIND_QUICK_SETTINGS_TILE` и intent-filter на `action.QS_TILE`. На MainActivity добавлен `<meta-data android:name="android.app.shortcuts" .../>`. |
| [`res/xml/shortcuts.xml`](../../../app/android/app/src/main/res/xml/shortcuts.xml) | Static shortcut `toggle_vpn` с label `@string/shortcut_toggle_*`, intent на MainActivity с `extra action=toggle`. |
| [`res/values/strings.xml`](../../../app/android/app/src/main/res/values/strings.xml) | Новый файл (раньше не было): `qc_first_open`, `qc_consent_denied`, `shortcut_toggle_short`, `shortcut_toggle_long`. |

### Dart side

| Файл | Что |
|------|-----|
| [`lib/vpn/box_vpn_client.dart`](../../../app/lib/vpn/box_vpn_client.dart) | `requestAddTile()` обёртка над method-channel'ом; возвращает строку-статус. |
| [`lib/screens/app_settings_screen.dart`](../../../app/lib/screens/app_settings_screen.dart) | В General-табе блок «Quick connect» с двумя ListTile'ями: «Quick Settings tile» (с кнопкой `Add` → `_addQuickSettingsTile`) и «Home-screen shortcut» (без действия — инструкция). SnackBar с локализованным сообщением для каждого исхода `requestAddTile`. |

## Риски и edge cases

| Риск | Поведение |
|------|-----------|
| `requestAddTileService` молча игнорируется на ColorOS/MIUI/HyperOS | `success: error: timeout` → SnackBar с инструкцией о ручном перетаскивании. Кнопка `Add` остаётся доступной для повторной попытки. |
| `currentStatus` остался `Started` после OOM-kill сервиса | `onDestroy` сбрасывает в `Stopped` + `refreshTile`. Tile отрисуется как Disconnected на следующем `onStartListening`. |
| Несколько tile-кликов подряд | `onClick` синхронно проверяет `currentStatus` — если уже не `Stopped`, второй клик игнорится. `Starting`/`Stopping` молча проходят. |
| Activity открыта через `am start --es action toggle` через debug-канал во время Flutter cold-start | `handleQuickAction` вызывается из `onCreate` после `super.onCreate(...)` — Flutter-engine ещё инициализируется, но `BoxVpnService.start/stop` идёт через `applicationContext`, не через Flutter. Smoke-test это подтвердил. |
| Subtitle на API < 29 (Android 8–9) | `Tile.subtitle` доступен с API 29 — на старых системах остаётся только `label = "L×Box"`, без статуса. Subtitle-вызовы guard'ятся `Build.VERSION.SDK_INT >= Q`. |
| Два consumer-вызова от системы при `requestAddTileService` | `AtomicBoolean` guard в plugin — `result.success()` идёт ровно один раз. |

## Верификация

**Автоматическая (через adb)** — пройдена на боевом устройстве 192.168.1.71:5555 (MTK / ColorOS):

1. `dumpsys package com.leadaxe.lxbox` — TileService и MainActivity видны:
   ```
   com.leadaxe.lxbox/.vpn.LxBoxTileService filter ... permission BIND_QUICK_SETTINGS_TILE
   ```
2. `dumpsys shortcut` — shortcut `toggle_vpn` зарегистрирован, intent `cmp=com.leadaxe.lxbox/.MainActivity` + `extras={action=toggle}`.
3. `am start -n com.leadaxe.lxbox/.MainActivity --es action toggle` (имитация shortcut tap), VPN в `Stopped`:
   ```
   MainActivity: handleQuickAction action=toggle currentStatus=Stopped
   BoxVpnService: companion.start() → startForegroundService
   BoxVpnService: setStatus(Started) — sendBroadcast
   currentTask:Task{...com.android.launcher/.Launcher}   # finish() сработал
   ```
4. То же ещё раз с VPN в `Started` — toggle off:
   ```
   handleQuickAction action=toggle currentStatus=Started
   BoxVpnService: companion.stop() → sendBroadcast(ACTION_STOP)
   BoxVpnService: setStatus(Stopping)
   BoxVpnService: doStop cleanup done → setStatus(Stopped) + stopSelf()
   onDestroy status=Stopped
   ```

**Что осталось проверить руками** (нельзя из adb):

- [ ] Перетаскивание tile в шторку через системный редактор (Android 7+).
- [ ] Tile state Active/Inactive и subtitle Connected/Disconnected/Connecting/Stopping live во время реального VPN.
- [ ] Кнопка `Add` в App Settings → General → Quick connect → системный prompt от `StatusBarManager.requestAddTileService` (API 33+ только; на этом девайсе — ColorOS, может молча не показать → SnackBar с fallback).
- [ ] VPN consent-диалог на «чистой» установке (без раннее данного consent'а) → toast `qc_first_open` → consent → start → activity finish'нулась.
- [ ] Long-press на иконку app'а на home-screen → видно «Toggle VPN» → тап → VPN starts/stops без открытия UI (после первого consent'а).

## Нерешённое / follow-up

- **Dynamic shortcut** (контекстный label «Connect» / «Disconnect» в зависимости от статуса) — отложено в spec §032 → MVP+1. Текущая реализация — static «Toggle VPN». Следующая задача может это закрыть через `ShortcutManager.updateShortcuts(...)` в `BoxVpnService.setStatus`.
- **Tile-only acceptance тесты** (instrumented Espresso для `TileService.onClick`) — не пишутся: `TileService` сложно тестить без живого System UI bind'а, ROI низкий, а smoke-test через adb даёт нужное покрытие критичных путей.
- **iOS / Wear OS** — out of scope для Android-only клиента.
