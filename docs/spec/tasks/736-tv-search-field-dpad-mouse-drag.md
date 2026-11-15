# 736 — Android TV: список приложений в пикере не прокручивается пультом (D-pad упирается в поиск, «мышь» не тянет)

| | |
|---|---|
| **Статус** | Done — на эмуляторе Android TV и приставке не проверено |
| **Дата** | 2026-11-15 |
| **Повод** | [#220](https://github.com/Leadaxe/LxBox/issues/220), magratsk |
| **Связанные** | [622 — передача телефон→TV, D-pad-дефекты](622-device-transfer-phone-to-tv.md), [679 — TV без фиксации ориентации](679-tv-no-portrait-lock.md), [412 — строка пикера без onTap](412-app-picker-checkbox-only-tap.md), [693 — UID в пикере](693-app-picker-shared-uid-hint.md) |

## Docs to update

- эта задача
- CHANGELOG.md — Unreleased, Fixed

## Problem

На Android TV в выборе приложений для туннелирования (Routing → Tunnel apps →
добавить, `AppPickerScreen`) список нельзя прокрутить:

1. пульт в режиме «мышь»: зажатая левая кнопка с движением список не тянет;
2. D-pad: фокус доходит до строки поиска и остаётся в ней, «вниз» ни к чему
   не ведёт.

Отметить можно только видимые строки или искать по имени.

## Diagnosis

Экран — `app/lib/screens/app_picker_screen.dart`, поле поиска над
`ListView.builder` (до правки `TextField` на строке 228, список на 254).
Используется из трёх мест: `tun_apps_tab.dart:94` (Tunnel apps — экран из
issue), `custom_rule_edit_screen.dart:362` (приложения правила
маршрутизации), `diagnostics/url_check_tab.dart:139` (URL Check).

**D-pad.** Стрелки в фокусированном `TextField` забирает
`DefaultTextEditingShortcuts` (Flutter 3.47,
`widgets/default_text_editing_shortcuts.dart:205`: ↓ =
`ExtendSelectionVerticallyToAdjacentLineIntent`, в однострочном поле каретка
в конец) — событие обработано, обход фокуса не запускается. Обёртка
`Shortcuts` с обычным `DirectionalFocusIntent` (приём из 622,
`backup_screen/import_preview_dialog.dart:252` `_arrowsMoveFocus`) тут не
помогает: `EditableText` перекрывает `DirectionalFocusIntent` своим
`DirectionalFocusAction.forTextField()` (`widgets/editable_text.dart:5699`),
а тот при `ignoreTextFields: true` (дефолт интента) ничего не делает
(`widgets/focus_traversal.dart:2436`). Нужен тот же приём, но с
`ignoreTextFields: false`.

**«Мышь».** Своего `ScrollBehavior` в приложении не было (`MaterialApp` без
`scrollBehavior:`). Дефолт Flutter `ScrollBehavior.dragDevices`
(`widgets/scroll_configuration.dart:29,120`) — touch, stylus, invertedStylus,
trackpad, unknown; **без mouse**: мышью список крутится только колесом.
Пульт TV в режиме «мышь» (и аэромышь) приходит как
`PointerDeviceKind.mouse` без колеса — прокрутки нет вовсе. Дефект общий
для всех списков приложения на TV, не только пикера.

## Solution

1. `app/lib/widgets/dpad_field_exit.dart` — `DpadFieldExit`: `Shortcuts`
   ↑/↓ (без модификаторов) → `DirectionalFocusIntent(…, ignoreTextFields:
   false)`. ←/→ остаются каретке. Только для однострочных полей. Обёрнуты
   все однострочные поля поиска над списками:
   - `screens/app_picker_screen.dart` — пикер приложений (issue);
   - `screens/per_app_trace_tab/app_multi_picker.dart` — выбор приложений в
     фильтре профайлера;
   - `screens/debug_screen.dart` — фильтр логов;
   - `screens/stats_screen/profiler_filter_sheet.dart` — поиск
     domain/IP/app;
   - `screens/home/filter_widgets.dart` `RegexFilterField` — фильтр узлов
     (главный, папка, node filter picker).
   Работает на любом устройстве, не только TV: на телефоне с аппаратной
   клавиатурой ↑/↓ в этих полях больше не ставят каретку в начало/конец
   (остаются Home/End) — приемлемо.
2. `app/lib/widgets/tv_scroll_behavior.dart` — `TvScrollBehavior`
   (`MaterialScrollBehavior` + `PointerDeviceKind.mouse` в `dragDevices`).
   `main.dart` `scrollBehaviorFor(isTelevision:)` подаёт его в
   `MaterialApp.scrollBehavior` только на TV; признак — новый синхронный
   `UrlLauncher.isTelevisionCached` (кеш заполняет
   `applyAllowRotationSetting` до `runApp`). Глобально, а не на экране: на TV
   «мышью» не тянется ни один список.

**Решение: мышь-перетаскивание только на TV** (подтвердить у владельца).
Альтернатива — глобально на всех устройствах (как нативный Android, где
мышь тянет RecyclerView). Не взято: на телефоне/планшете с мышью
перетаскивание в однострочном `TextField` (внутри у него горизонтальный
`Scrollable`, наследующий поведение) конкурировало бы с выделением текста
мышью, а жалоб с телефонов нет.

## Risks and edge cases

- На TV мышью-перетаскиванием в поле ввода текст прокручивается, а не
  выделяется — для пульта это не сценарий.
- Если канал `isTelevision` не ответил к `runApp`, на TV останется штатное
  поведение (кеш false) — как было до правки.
- Ленивый список: D-pad идёт по видимым + cacheExtent строкам, Flutter
  докручивает список за фокусом (`Scrollable.ensureVisible`); в тесте 25
  шагов вниз по 60 строкам проходят.
- Многострочные поля (редакторы, формы с `maxLines > 1`) не тронуты; обычные
  однострочные поля форм на TV тоже держат ↓ — отдельный вопрос, жалоб нет.
- Строки пикера без `onTap` (§412): фокус D-pad попадает на `Checkbox`
  строки, OK/Enter переключает его — это и есть выбор с пульта.

## Verification

- `app/test/screens/app_picker_tv_scroll_test.dart`:
  - ↓ из поля поиска — фокус на элементе `ListView`, 25 раз ↓ — список
    прокручен, ↑ до упора — фокус снова в поиске;
  - TV (`scrollBehaviorFor(isTelevision: true)`): drag с
    `PointerDeviceKind.mouse` прокручивает список;
  - телефон: `scrollBehaviorFor(false) == null`, мышь не тянет (как было),
    палец тянет.
- Без исправления: D-pad-тест падает (`Expected: false, Actual: <true>` —
  фокус остался в поле), мышь-тест падает (`Actual: <0.0>`), проверено
  локально.
- `flutter analyze` по изменённым файлам — чисто; соседние
  `app_picker_row_tap_test`, `app_picker_pop_test` — зелёные.
- Не проверено: эмулятор Android TV, реальная приставка с пультом в режиме
  мыши.

## Unresolved / follow-up

- Подтвердить у владельца: перетаскивание мышью — только TV (сейчас) или
  на всех устройствах.
- Однострочные поля форм (не поиск) на TV — ↓ тоже не выводит; при жалобе
  обернуть `DpadFieldExit` общим виджетом поля.
