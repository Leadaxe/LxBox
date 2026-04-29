# 015 — Quick Connect §032 polish: monochrome icon, dynamic shortcuts, direct-render, optimistic UX

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата старта | 2026-04-29 |
| Дата завершения | 2026-04-29 |
| Коммиты | `68bd006` fix lateinit · `dfb470c` dynamic shortcuts · `0eac2f2` tile polish |
| Связанные spec'ы | [`032 quick connect`](../features/032%20quick%20connect/spec.md) |
| Связанные tasks | [014 — §032 MVP](014-quick-connect-tile-shortcut.md) |
| Связанные issue | [#1](https://github.com/Leadaxe/LxBox/issues/1) |

## Проблема

После релиза §032 MVP (task 014) обнаружилось четыре UX/устойчивости проблемы:

1. **Иконка плитки** — пустой белый квадратик вместо нормального glyph'а. Использовался `R.mipmap.ic_launcher` (полноцветная PNG), QS-tile тинтит icon как monochrome — без single-path vector выглядело как сломанный плейсхолдер.
2. **Long-press shortcut** — статический «Toggle VPN» без контекста состояния. Юзер ожидает «Connect» когда выключен и «Disconnect» когда включён.
3. **Tile не перерисовывался** между переключениями на ColorOS — `requestListeningState` молча no-op'ил, когда система считала что «уже слушает». Tile залипал в старом state до повторного открытия шторки.
4. **Краш при tile-tap'е в свежем процессе после OOM** — `BoxVpnService.onStartCommand` падал с `UninitializedPropertyAccessException: lateinit property application has not been initialized`. `BoxApplication.initialize` вызывался только из `VpnPlugin.onAttachedToEngine`, а если процесс стартует через QS-tile (без UI) — Flutter-engine не инициализировался.

## Диагностика

### Иконка
QS-tile system applies tint based on `Tile.STATE_ACTIVE/INACTIVE`. Tint работает для single-path white-on-transparent vector drawable. Цветной PNG/mipmap не имеет alpha-mask нужного формата — система рендерит как пустой rect.

### Static → dynamic shortcut
`ShortcutManager.dynamicShortcuts` позволяет выставлять / переписывать набор short-press пунктов. Hook — `BoxVpnService.setStatus`: каждый раз когда статус меняется, перепушиваем меню под текущий `currentStatus`.

API gate: `Build.VERSION.SDK_INT >= R` (Android 11+) — primary support tier; на best-effort 8-10 не делаем чтобы избежать API/OEM-сюрпризов с `ShortcutManager`.

### Direct render
`requestListeningState` зависит от состояния системного TileService binding и не всегда триггерит `onStartListening`. Решение — держать `WeakReference<LxBoxTileService>` в companion'е, выставлять в `onStartListening` / чистить в `onStopListening`. В `refreshTile` сначала идёт прямой `instanceRef?.get()?.renderTile()` через `mainHandler.post` — работает всегда пока tile bound. Fallback на `requestListeningState` оставлен для не-bound сценариев.

### Lateinit fix
Когда tile тапается в свежем процессе (после OOM-kill / SIGABRT-recovery / cold-boot), Android создаёт процесс и стартует BoxVpnService минуя любой UI. `VpnPlugin.onAttachedToEngine` (где раньше единственная инициализация) не запускается. `BoxApplication.application: lateinit Context` остаётся без значения, libbox setup не отрабатывает, первый libbox call в `onStartCommand` крашит.

Решение: `BoxVpnService.onCreate()` зовёт `BoxApplication.initialize(applicationContext)`. Метод идемпотентен (`if (initialized) return`), безопасно дёргать всегда.

## Решение

### Файлы

| Файл | Что |
|------|-----|
| [`res/drawable/ic_lxbox_tile.xml`](../../../app/android/app/src/main/res/drawable/ic_lxbox_tile.xml) (new) | Material `verified_user` (shield) — white-on-transparent vector, тинтится системой. |
| [`LxBoxTileService.kt`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/LxBoxTileService.kt) | `R.mipmap.ic_launcher` → `R.drawable.ic_lxbox_tile`. `WeakReference<LxBoxTileService>` в companion'е, set/clear в `onStartListening`/`onStopListening`. `refreshTile` direct-call через main handler. `onClick` рисует optimistic destination state. `subtitle` за `@RequiresApi(Q)`-helper'ом. |
| [`QuickShortcuts.kt`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/QuickShortcuts.kt) (new) | `refresh(ctx)` — пушит dynamic shortcuts на основе `BoxVpnService.currentStatus`. API >= R, runCatching на rate-limit `IllegalStateException`. |
| [`BoxApplication.kt`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxApplication.kt) | После `initialized = true` — `runCatching { QuickShortcuts.refresh(...) }`. Defensive runCatching на libbox setup тоже добавлен. |
| [`BoxVpnService.kt`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxVpnService.kt) | `onCreate { BoxApplication.initialize(applicationContext) }`. В `setStatus` — `LxBoxTileService.refreshTile` + `QuickShortcuts.refresh`, оба в `runCatching`. |
| [`AndroidManifest.xml`](../../../app/android/app/src/main/AndroidManifest.xml) | `<meta-data android:name="android.app.shortcuts">` снят. |
| [`res/xml/shortcuts.xml`](https://github.com/Leadaxe/LxBox/blob/develop/) | **deleted** — статический shortcut больше не нужен. |
| [`res/values/strings.xml`](../../../app/android/app/src/main/res/values/strings.xml) | Убраны `shortcut_toggle_short` / `_long`. |

### UX-эффекты

- **Tile при тапе** — мгновенный flip цвета (optimistic destination state), реальный статус подхватывается через broadcast → direct-render.
- **Long-press на иконке** — контекстное меню «Connect» / «Disconnect» по состоянию.
- **Иконка** — корректный shield, тинтится по active/inactive.
- **OOM-recovery** — tile-tap в свежем процессе теперь не крашит сервис.

## Риски и edge cases

| Риск | Поведение |
|------|-----------|
| Очень быстрый stop (200ms) — пользователь не успевает заметить «Stopping…» | UX-приемлемо, status в плитке обновляется до `Disconnected` сразу. На медленных стопах (libbox WireGuard cleanup) intermediate state виден. |
| `ShortcutManager` rate-limit (`IllegalStateException` после многократных `dynamicShortcuts =`) | Логируем `W`, следующий `setStatus` push'нет повторно. |
| ColorOS `Couldn't find tile` warning в logcat | Direct-render через WeakRef обходит проблему. Warning остаётся как side-effect `requestListeningState` fallback'а. |
| Старые Android 8-10 (best-effort tier) | `QuickShortcuts.refresh` no-op'ит (`SDK_INT < R`). Tile рендерится через legacy paths, subtitle не показывается. |
| Optimistic onClick → real status разошёлся (старт не получился) | Real `setStatus` поверх перерисует плитку с фактическим статусом — пользователь увидит что вернулся в Stopped. |

## Верификация

**Smoke-test через adb на 192.168.1.71:5555 (ColorOS / MTK Dimensity):**

1. `dumpsys shortcut com.leadaxe.lxbox` — после старта app'а виден `qc_connect` (Stopped) или `qc_disconnect` (Started), label корректный, intent с `extra action=connect`/`disconnect`.
2. Tap по плитке через `cmd statusbar click-tile com.leadaxe.lxbox/.vpn.LxBoxTileService` — `onClick` логируется, optimistic flip → `BoxVpnService.start/stop` пайплайн отрабатывает.
3. Realtime logcat подтвердил: `setStatus(Stopping)` → `LxBoxTileService.refreshTile` → `instanceRef.get()?.renderTile()` через main handler → `tile.updateTile()` без warning'ов от системы.
4. После kill -9 процесса и повторного tap'а на tile — VPN стартует, нет `UninitializedPropertyAccessException` (lateinit fix отработал).

**Ручная проверка пользователем:**
- Иконка плитки — корректный shield, цвет меняется на тапе мгновенно.
- Long-press на иконке app'а — пункт «Connect» когда VPN off, «Disconnect» когда on.
- Connect/disconnect через плитку — VPN реально включается/выключается.
- На свежей установке (или после Forget VPN в системе) — toast `qc_first_open` + consent диалог + finish() activity.

## Нерешённое / follow-up

- **Native crash в libbox.so при stop (pc 0x880dc8)** — sporadic, sigabort в Go runtime / cgo bridge. Без debug-symbols libbox не докопаешься. Заведено как отдельное расследование (см. внешний sing-box upstream).
- **«Stopping…» иногда мелькает слишком быстро (~200ms)** на нормальных стопах — пользователь может не успеть заметить. Можно добавить минимальный hold transient-стадий ~600ms, если поступит UX-фидбэк. Сейчас не делаем — поведение детерминировано тем что отдаёт libbox.
- **Tile editor превью** на ColorOS использует tile-service `android:icon` из манифеста (мы оставили цветной mipmap). Если перейти полностью на monochrome — превью в редакторе будет белый квадрат. Текущее решение (manifest = mipmap, tile-в-шторке = vector) оптимально.
