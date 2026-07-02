# §220 — toggle «Allow rotation» (снятие портретной фиксации)

> **СТАТУС: РЕАЛИЗАЦИЯ.** UI + storage-флаг, native не трогаем.

## Проблема

Приложение жёстко зафиксировано в портрете:
[main.dart](../../../app/lib/main.dart) перед `runApp` вызывает
`SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp])`.
В `AndroidManifest.xml` `screenOrientation` НЕ задан — фиксация живёт только
на Dart-стороне.

Фидбэк с 4PDA (02.07.2026): на планшете принудительный портрет неудобен —
устройство обычно в ландшафтной доке/чехле.

Решение согласовано с leadaxe: **не** авто-детект планшета по `shortestSide`,
а явная настройка в App Settings. Default = OFF (портрет, как всегда было) —
поведение на телефонах не меняется, пока юзер сам не включит.

## Решение

### Storage

Новый app feature-flag в `vars`:

| Ключ | Default | Семантика |
|---|---|---|
| `allow_rotation` | `'false'` | `'true'` → поворот разрешён |

- `SettingsStorage.getAllowRotation()` / `setAllowRotation(bool)` — обычная
  пара акцессоров поверх `getVar`/`setVar`.
- Ключ добавляется в `_appFeatureFlagVars` — иначе restore бэкапа его
  отбросит (default-deny allowlist; грабля §130 `masque_account`).

### Применение ориентации

Общий helper в `main.dart` (вызывается из двух мест — старт и toggle):

```dart
Future<void> applyAllowRotationSetting() async {
  allow = await SettingsStorage.getAllowRotation();  // try → false
  await SystemChrome.setPreferredOrientations(
    allow ? const [] : const [DeviceOrientation.portraitUp]);
}
```

- **OFF** → `[portraitUp]` — байт-в-байт прежнее поведение.
- **ON** → **пустой список** = «нет предпочтений»: система сама решает по
  своему auto-rotate (учитывает системный rotation-lock юзера). Мы не
  перечисляем ориентации вручную — не залипаем в перевёрнутый портрет и
  не спорим с системной блокировкой поворота.
- На старте вызов заменяет прежний хардкод `setPreferredOrientations`
  (после best-effort init-try, до `runApp`). Ошибка чтения storage →
  безопасный дефолт (портрет).

### UI

App Settings → **General → Behavior**, `SwitchListTile` сразу после
«Auto-start on boot»:

- title «Allow rotation», icon `Icons.screen_rotation`;
- subtitle: rotate to landscape, follows the system auto-rotate setting;
- toggle применяется **мгновенно** (`setAllowRotationSetting` → helper),
  рестарт не нужен, снэкбар не требуется.

## Файлы

| Слой | Файл | Изменение |
|---|---|---|
| storage | `app/lib/services/settings_storage.dart` | +`allow_rotation` в `_appFeatureFlagVars`; +get/setAllowRotation |
| bootstrap | `app/lib/main.dart` | хардкод портрета → `applyAllowRotationSetting()` (+ сам helper) |
| UI state | `app/lib/screens/app_settings_screen.dart` | state `_allowRotation` + load + `_toggleAllowRotation` |
| UI | `app/lib/screens/app_settings_screen/widgets/general_tab.dart` | +SwitchListTile в Behavior |
| docs | `docs/STORAGE.md` | строка в таблице `vars` |

## НЕ трогаем

- `AndroidManifest.xml` — `screenOrientation` там и не было.
- Native (Kotlin) — ориентация целиком Flutter-side.
- Layout экранов — списочные, ширину переживают; точечные overflow-фиксы
  (если найдутся на устройстве) — отдельными тасками.
- Никакого детекта планшета — флаг честно работает и на телефоне.

## Тесты

- Unit не нужен (тривиальная пара акцессоров + SystemChrome, который в
  unit-тестах замокан).
- Device: toggle ON → повернуть устройство → landscape без рестарта;
  toggle OFF в landscape → возврат в портрет; перезапуск приложения
  сохраняет выбор; системный auto-rotate OFF + toggle ON → не крутится
  (уважаем систему).

## Связанные

- §158 — App Settings TabBar (структура экрана).
- §130/§219 — грабля restore-allowlist (`masque_account`), повторена здесь.
- 4PDA-фидбэк июнь–июль 2026 (бэклог-источник).
