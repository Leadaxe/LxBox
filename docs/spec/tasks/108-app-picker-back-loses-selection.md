# 108 — AppPicker: системный back терял выбор приложений

**Дата:** 2026-06-10 · **Статус:** DONE (released v2.0.2)
**Симптом (field report):** Routing → Tunnel Applications (режим allow) →
Add → пикер → отметить приложения → системный «назад»/жест — выбор не
сохраняется. Через стрелку в AppBar — сохраняется.

## Root cause

`AppPickerScreen` возвращал `AppPickerResult` только из кастомной стрелки
AppBar (`_safePop` → `Navigator.pop(context, result)`), а системный back
проходил через `PopScope` с **пустым** handler'ом и `canPop: true` по
умолчанию (`app_picker_screen.dart:148-149` до фикса) — роут попался с
`result = null`, и caller (`tun_apps_tab._pickApps`) молча выкидывал
селекцию (`if (result == null) return`).

Жил с самого появления пикера (§017, commit `bbad759`) — не регрессия
§076/§107. Соседние экраны (`subscriptions_screen.dart:213`,
`custom_rule_edit_screen.dart:345`) используют правильный паттерн.

## Fix

`app_picker_screen.dart`: `canPop: false` +
`onPopInvokedWithResult: (didPop, _) { if (didPop) return; _safePop(); }` —
системный back перехватывается и попается программно с результатом,
идентично стрелке. Guard `_popped` от двойного pop уже был.

`single_app_picker_screen.dart` (per-app trace) не затронут — там выбор
попается тапом по элементу, back = отмена by design.

## Tests

```
test/screens/app_picker_pop_test.dart (NEW, 2 теста)
  - системный back (maybePop) возвращает текущий выбор
  - стрелка в AppBar возвращает выбор (без регрессии)
```
