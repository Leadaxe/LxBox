# 015 — Android 9-11 quick-connect регрессия (defensive fix)

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата старта | 2026-04-29 |
| Дата завершения | 2026-04-29 |
| Коммиты | (не закоммичено на момент написания отчёта; диф в `git status`) |
| Связанные spec'ы | [`032 quick connect`](../features/032%20quick%20connect/spec.md) |

## Проблема

Внешний пользователь (Maxim Novikov) сообщил, что после обновления на свежую develop-сборку (с фиксом VLESS [task 012](012-vless-packet-encoding-libbox-panic.md)) приложение **закрывается сразу после нажатия OK на системный VPN-consent диалог**. Воспроизводится на трёх устройствах:

- Samsung A50, Android 11 (API 30) — ❌ падает
- Samsung A10, Android 11 (API 30) — ❌ падает
- Huawei Y9 2018, Android 9 (API 28) — ❌ падает
- Samsung S10 Lite, Android 13 (API 33) — ✅ работает

Один и тот же APK, разное поведение на разных API-уровнях. Логи через `adb logcat` пользователю собрать сложно (нет компьютера/USB-debugging навыков).

## Диагностика

Симптом «работает на 13, не работает на 9-11 при одинаковом APK» классически указывает на одну из двух категорий:

1. **NoClassDefFoundError / VerifyError при class verification** — ART на старых Android'ах верифицирует bytecode при первой загрузке класса; если в коде есть прямая ссылка на API-константу/метод выше уровня устройства без `if (Build.VERSION.SDK_INT >= …)` обёртки, класс не грузится и процесс умирает при первом обращении.
2. **Unknown manifest-атрибут с разной обработкой на разных API** — `foregroundServiceType="specialUse"` валиден только с API 34, на 30/28 это unknown bit; разные OEM (One UI Samsung, EMUI Huawei) могут обрабатывать его по-разному.

Регрессия появилась после v1.4.2 в коммите `f766e6e feat(§032): Quick Connect`. Между публичным v1.4.2 и собранным develop'ом добавлены:

- `LxBoxTileService` — новый `TileService` (API 24+).
- Вызов `LxBoxTileService.refreshTile(applicationContext)` из `BoxVpnService.setStatus()` и `onDestroy()` — на каждый transition статуса.
- `<service .vpn.LxBoxTileService>` в `AndroidManifest.xml`.

Critical path при нажатии Start:

```
MainActivity.onActivityResult(VPN_REQUEST_CODE, RESULT_OK)
  → BoxVpnService.start(context) → startForegroundService
  → onCreate → BoxApplication.initialize(applicationContext)
  → onStartCommand → notification.show() → service.startForeground(…)
  → setStatus(Starting)
    → LxBoxTileService.refreshTile(applicationContext)   ← новое поведение
  → serviceScope.launch { startSingbox() }
```

`LxBoxTileService.refreshTile()` тянет загрузку класса `LxBoxTileService` (companion-object), внутри которого есть instance-метод `renderTile` со ссылками на `Tile.subtitle = ...` (API 29+). На старых Android ART class verifier может отказаться загружать класс целиком — даже несмотря на runtime-`if (SDK_INT >= Q)` guard внутри метода — и весь процесс падает.

Параллельный кандидат — `foregroundServiceType="specialUse"` в манифесте + `<uses-permission FOREGROUND_SERVICE_SPECIAL_USE>` (оба — API 34). На API 30/28 атрибут парсится как unknown FGS-bit; некоторые OEM могут отказывать в `startForeground()` или валить инсталляцию (наблюдалось в bug-репортах VPN-приложений на Samsung One UI 3).

`adb logcat` от пользователя не получили, поэтому защищаемся **defensively сразу по обоим направлениям**.

## Решение

### 1. Изоляция API-зависимых вызовов в `@RequiresApi` helper'ах

[`LxBoxTileService.kt`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/LxBoxTileService.kt):

`Tile.subtitle = ...` извлечён в отдельную функцию с `@RequiresApi(Build.VERSION_CODES.Q)`:

```kotlin
@RequiresApi(Build.VERSION_CODES.Q)
private fun applySubtitle(tile: Tile, text: String) {
    tile.subtitle = text
}
```

R8 / class verifier видят явный API-tag и не трогают `renderTile()` верификацией на старых API.

### 2. Gate Quick Connect фич на primary tier (API 30+)

[`LxBoxTileService.refreshTile`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/LxBoxTileService.kt) и [`QuickShortcuts.refresh`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/QuickShortcuts.kt) теперь начинаются с:

```kotlin
if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
```

Это согласуется с CLAUDE.md «Primary (11+, API 30+) — все фичи; Best-effort (8-10) — базовый VPN, фичи API 30+ деградируют к no-op». Quick Connect — фича primary-tier, на best-effort устройствах честный no-op без шансов уронить процесс.

### 3. Outer try-catch на `Throwable`

Все callsites Quick-Connect-побочки (в `BoxVpnService.setStatus`, `BoxVpnService.onDestroy`, `BoxApplication.initialize`) обёрнуты в `runCatching { … }.onFailure { Log.w(…) }`. Внутри самих `refreshTile` / `QuickShortcuts.refresh` — `try { … } catch (t: Throwable)`. **Throwable**, не Exception — ловим `Error`-наследников (`NoClassDefFoundError`, `VerifyError`, `OutOfMemoryError`).

### 4. Manifest: `FOREGROUND_SERVICE_SPECIAL_USE` permission гейтится на minSdk=34

[`AndroidManifest.xml`](../../../app/android/app/src/main/AndroidManifest.xml):

```xml
<uses-permission
    android:name="android.permission.FOREGROUND_SERVICE_SPECIAL_USE"
    android:minSdkVersion="34" />
```

На API <34 permission не запрашивается, не отображается в Settings → App permissions, не валидируется PackageManager'ом. На API ≥34 — работает как раньше.

Атрибут `android:foregroundServiceType="specialUse"` на сервисе оставлен — manifest не поддерживает per-attribute SDK gating, и на API 30 unknown FGS-bit парсится в bitmask без runtime exception. Атрибут нужен на API 34+ для классификации сервиса (иначе `MissingForegroundServiceTypeException` при `startForeground` на строгих OEM — One UI 6, MIUI 14).

### 5. Typed `startForeground` на API 34+

[`ServiceNotification.show`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/ServiceNotification.kt) теперь:

```kotlin
if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
    service.startForeground(id, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
} else {
    service.startForeground(id, notification)
}
```

На API 30 и ниже — старый 2-арг API, ровно как было в v1.4.2 (никакого изменения поведения для Maxim'а). На API 34+ — typed-перегрузка как страховка от строгих OEM, которые могут не доверять manifest-классификации.

## Что не сделано (вынесено)

- **Throwable catch вокруг `Libbox.newService` / `svc.start`** — отдельная [task 016](016-libbox-newservice-throwable-catch.md). Логически связано, но касается другого call-path'а (sing-box bootstrap), не Quick Connect.
- **Persisted stderr.log + UI viewer** — [task 017](017-stderr-rotation-on-cold-start.md), [task 018](018-stderr-viewer-debug-tab.md). Чтобы при следующем подобном инциденте сразу видеть Go-stacktrace в Debug-экране, не выпрашивая `adb logcat`.

## Verification

- Локальная сборка release APK через `scripts/build-local-apk.sh` — должна компилироваться (compileSdk=36, minSdk=26, targetSdk=flutter-default).
- Smoke-тест на эмуляторе Android 11 (API 30) — VPN стартует через UI Start без падения процесса.
- Регресс-тест на эмуляторе Android 13/14 — Quick Settings tile + home-screen shortcut работают как до правок (никаких визуальных деградаций, поскольку gate `>= R` совпадает с минимумом, на котором фича задумывалась как primary).

## Дальше

Этот fix защищает **только** от категории «class loading / unknown manifest-атрибут» — то есть от регрессии Quick Connect. Если Maxim после обновления APK всё ещё видит вылет — причина в другом call-path'е (вероятно нативный Go panic в libbox при парсинге конфига). Тогда нужны логи через [task 017+018](018-stderr-viewer-debug-tab.md), которые дадут пользователю самостоятельно отдать stderr-stacktrace без adb.
