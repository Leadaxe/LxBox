# §277 — «Suspend active-route tunnels» молча не сохранялся: немой гейт → disabled

| Поле | Значение |
|---|---|
| Статус | РЕАЛИЗОВАНО (develop, 2026-07-16) |
| Связанные спеки | §272 (reachable-окно, породившая), §215 (базовый idle-suspend UI) |
| Ядро | не затронуто |

## Проблема

Репорт с форума: «Suspend active-route tunnels ставлю Off, выхожу-захожу —
написано 5 минут. И вообще кроме 5 минут другие значения не запоминаются».

Дропдаун `route_idle_suspend_reachable` (§272) зависит от базового порога
`route_idle_suspend` (§215): ядро отвергает reachable без базового
(`lx_idle_suspend_reachable requires lx_idle_suspend`), генератор reachable-ключ
без базового не эмитит (`build_config.dart:374-382`). Зависимость в UI была
выражена **ранним return внутри `onChanged`**
(`settings_screen.dart:411`, до фикса):

```dart
onChanged: (String? v) {
  if (!_vpnLoaded || v == null || _idleSuspend.isEmpty) return; // немой гейт
  unawaited(_applyIdleSuspendReachable(v));
},
```

Непустой `onChanged` для Flutter означает «контрол активен»: дропдаун выглядит
рабочим, юзер выбирает значение, виджет его показывает — а запись молча
отброшена. При следующем входе на экран грузится storage-значение (или дефолт
`'5m'`, если ключа нет) — «выбор откатился». Оба симптома репорта — это один
дефект при базовом пороге в Off:

1. «возвращается на 5 минут» — выбор не сохранился, при перезаходе дефолт;
2. «другие значения не запоминаются» — гейт отбрасывает *любой* выбор.

Сама зависимость корректна — дефект в механике её выражения: рассинхрон между
тем, что контрол показывает, и тем, что сохранено.

## Решение

Гейт переносится из тела обработчика в сам факт наличия обработчика —
каноническое disabled-состояние Flutter (`onChanged: null` → дропдаун серый,
некликабельный):

```dart
onChanged: (!_vpnLoaded || _idleSuspend.isEmpty)
    ? null // базовый порог Off → контрол честно неактивен
    : (String? v) {
        if (v == null) return;
        unawaited(_applyIdleSuspendReachable(v));
      },
```

- Базовый порог Off → дропдаун неактивен: нечему молча проваливаться. Хранимое
  значение показывается серым и переживает выключение базового (включил обратно
  — прежний выбор снова действует; генератор и так гейтит эмиссию).
- Базовый порог включён → любой выбор сохраняется (гейт `_idleSuspend.isEmpty`
  при этом и так false).
- В description дропдауна добавлена последняя фраза
  `Requires "Suspend idle tunnels" to be on.` — юзер видит, *почему* контрол
  серый.
- `InputDecoration.enabled` зеркалит условие: `onChanged: null` серит контент
  и стрелку, но рамка `OutlineInputBorder` без этого оставалась бы в
  enabled-цвете (находка адверсарного ревью, линза widget-semantics).

Смежное поведение не тронуто: переключение базового Off↔включён внутри сессии
перерисовывает экран через `setState` в `_applyIdleSuspend` → disabled-состояние
обновляется сразу.

## Верификация

Widget-тест не добавлен: у `SettingsScreen` нет pump-харнесса (существующие
тесты в `test/screens/` покрывают чистые проекции/контроллеры, полный pump
требует HomeController + SubscriptionController + TemplateLoader + storage).
Фикс декларативный (условие ↔ `null`-обработчик), логика записи
`_applyIdleSuspendReachable` не менялась.

Вместо этого — адверсарное multi-agent ревью (3 независимые линзы, каждая с
задачей ОПРОВЕРГНУТЬ фикс; ни одна не опровергла), с проверкой против
исходников Flutter SDK 3.41.6 (`dropdown.dart`), а не по памяти:

- **widget-semantics**: `onChanged: null` → внутренний `DropdownButton`
  disabled (GestureDetector(onTap:null), canRequestFocus:false, стиль
  `Theme.disabledColor`); значение продолжает отображаться (IndexedStack по
  `_selectedIndex`); флип null↔non-null через setState перестраивает FormField
  на месте — дропдаун оживает сразу после включения базового порога, без
  пересоздания. `didUpdateWidget` синхронизирует `initialValue` → десинк
  показа и стейта невозможен.
- **state-flow**: путей тихой потери выбора не осталось; хранимый `'15m'` при
  базовом Off в конфиг не эмитится (`build_config.dart:373-382`), при
  включении — эмитится на следующей сборке; инвариант ядра
  `reachable >= base` выполнен конструктивно (опции базового ≤ 5m, reachable
  ≥ 5m); §221-симметрия backup (allowlist ⊆ export) для обоих ключей на месте
  и фиксом не затронута.
- **ux-regression**: оба симптома репорта закрыты одним корнем; уход с экрана
  до завершения async-записи безопасен (setState синхронный, future переживает
  dispose, `flush: true`); `!_vpnLoaded` — мёртвая защита (экран под
  спиннером, пока `_loading`).

`flutter analyze` (весь проект) — 0 issues; `flutter test` — 1904/1904.

## Docs to update

- `CHANGELOG.md` → `[Unreleased]` / Fixed — сделано в этом же коммите.
- Остальное — none: Debug API / ARCHITECTURE не затронуты.

## Свип на тот же паттерн (2 независимых агента, разными методами)

Прочие ранние return в обработчиках `lib/` — почти все benign: no-op-гейты
(`value == current`), null-защита, мёртвая защита `!_vpnLoaded` в четырёх
контролах System-вкладки (недостижима: экран под спиннером, пока
`_vpnLoaded=false`), гейты с видимым фидбэком (SnackBar/диалог). Не benign
или спорное — вынесено отдельно, в скоуп §277 не входит:

- `folder_detail_screen.dart:984/1047/1059` — orphan-гейты `if (_index < 0)
  return;` у reorder/Switch/onTap члена папки. Агенты разошлись в оценке
  достижимости (внешняя мутация entries через Debug API folder CRUD / restore
  при открытом экране vs «entries мутируются на месте»); требует отдельного
  разбора → вынесено в фоновую задачу.
- `app_picker_screen.dart:169/197` — пункт меню «Export to clipboard» активен
  во время загрузки, но глотается гейтом `_loading` (соседние пункты честно
  disabled) — мелкая рассинхронизация того же семейства.

## Вне скоупа

- Смена дефолта `route_idle_suspend_reachable` (`'5m'`) — решение владельца
  §272, жалобу не порождает.
- Находки свипа выше (folder_detail orphan-гейты, app_picker export) — другие
  экраны, отдельные задачи.
