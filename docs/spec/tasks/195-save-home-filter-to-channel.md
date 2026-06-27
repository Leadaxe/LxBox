# §195 — Сохранить regex-фильтр с главной в активный канал

> **СТАТУС: РЕАЛИЗОВАНО (27.06.2026).** Расширение [§125](../features/125%20configurable-channels/spec.md).
> Ветка `feat/configurable-channels-125`.

## Контекст

§048 — глобальный regex-фильтр нод на главной (поле в filter-panel, таб Regex).
Это «песочница»: юзер экспериментирует с regex над набором нод, видит результат
вживую. §125 закрепил, что удачный regex портируется в per-channel `node_filter`
**вручную** (через редактор канала) — это «независимые слои».

Задача — убрать ручной перенос: дать прямую кнопку «сохранить этот regex в
активный канал» прямо из поля фильтра на главной.

## Цель

В [`RegexFilterField`](../../../app/lib/screens/home/filter_widgets.dart) справа
от `×` (clear) добавить кнопку (💾). Видна когда поле непустое + есть активный
канал. Клик → диалог выбора, **как применить** текущий regex в **активный канал**
(`state.selectedGroup` — это всегда selector-канал, см. §125 F4):

- **Channel filter** → `channel.nodeFilter` (что показывать/фильтровать в канале).
- **Default** → `channel.defaultFilter` (первая matched нода → `options.default`).

**Сохранение явное, НЕ тихое** (решение юзера): после выбора поля открывается
[`ChannelEditScreen`](../../../app/lib/screens/channel_edit_screen.dart) этого
канала с **предзаполненным** полем — юзер видит куда легло значение, может
доредактировать и сохраняет через Save в редакторе. Это переход «главная →
Routing → Channels → нужный канал» в один тап, с готовым regex в поле.
Результат (saved-канал) применяется на главной: `updateChannel` + rebuild конфига.

## Нецели

- Глобальный «default-фильтр на главной» (применять ко всем). Обе опции пишут в
  ОДИН активный канал — это §125-настройки, не глобальная песочница.
- Сохранение protocol/subscription/detour-фильтров — только regex-поле.
- Инверсия (`!`-negate) в сохранённый фильтр НЕ переносится — `nodeFilter`/
  `defaultFilter` это голый regex по tag (§125), без invert-семантики.

## UX

```
┌─ Regex filter ────────────────────────────────┐
│ [!] 🔍 [ 🇩🇪|🇳🇱              ]  [💾] [×]      │   💾 = save, видна при непустом
└────────────────────────────────────────────────┘
        тап 💾 →
┌─ Save filter to "Моя Германия" (vpn-1) ────────┐
│  Where to save "🇩🇪|🇳🇱"?                        │
│  ┌──────────────┐  ┌──────────────┐            │
│  │ Channel      │  │ Default      │  [Cancel]  │
│  │ filter       │  │              │            │
│  └──────────────┘  └──────────────┘            │
└────────────────────────────────────────────────┘
```

- 💾-иконка: `Icons.save_outlined`, 18px, перед `×` в `suffixIcon`-row.
- Диалог: title «Save to: <label> (<tag>)», два action-варианта + Cancel.
- Активный канал ∉ channels (рассинхрон) / `selectedGroup == null` → 💾 не
  показываем (нечего/некуда сохранять). Пустой regex → не показываем (как `×`).
- После save — SnackBar «Saved to <label>».
- Невалидный regex → save заблокирован (как и фильтр не применяется).

## Data flow

```
RegexFilterField (filter_widgets.dart)
  + onSaveRegex: ValueChanged<String>?  // null → 💾 скрыта
  💾 tap → onSaveRegex(controller.text)

FilterPanel (filter_panel.dart)
  + onSaveRegex проброшен в RegexFilterField

node_list.dart (есть controller+state)
  onSaveRegex: (pattern) => _saveRegexToChannel(context, pattern)
  _saveRegexToChannel:
    1. tag = state.selectedGroup; channel = channels.firstWhere(tag)
       (null → no-op, но 💾 и так скрыта)
    2. showDialog → выбор 'node' | 'default' | null(cancel)
    3. updated = channel.copyWith(nodeFilter: p) ИЛИ copyWith(defaultFilter: p)
    4. SettingsStorage.updateChannel(updated)
    5. controller.refreshChannelLabels() (label не меняется, но channels-кеш
       консистентен) + rebuild конфига (configDirty → пересборка)
    6. SnackBar
```

`node_list` НЕ держит `List<Channel>` — тянет `SettingsStorage.getChannels()` в
`_saveRegexToChannel` (редкая операция, не на каждый build). Видимость 💾 — по
`state.selectedGroup != null && state.groups.contains(selectedGroup)`.

## Rebuild

Запись `node_filter`/`default_filter` — config-significant (билдер их читает,
§125 F1-F3). `updateChannel` → `setChannels` уже зовёт `markConfigDirty`.
Пересборка — через существующий механизм (как редактор канала): после save
дёрнуть `subController.generateConfig` + `home.saveParsedConfig`, либо положиться
на configDirty-баннер. Выбрать минимально-инвазивный путь при реализации
(channel-edit на routing-экране уже не делает явный rebuild — полагается на
configDirty + home-return observer; здесь же мы на главной → нужен явный rebuild
или показать «нужна пересборка»). **Решение:** явный rebuild после save (юзер на
главной ждёт эффекта сразу).

## Файлы

| Файл | Изменение |
|---|---|
| `app/lib/screens/home/filter_widgets.dart` | `RegexFilterField.onSaveRegex` + 💾-кнопка |
| `app/lib/screens/home/widgets/filter_panel.dart` | проброс `onSaveRegex` |
| `app/lib/screens/home/widgets/node_list.dart` | `_saveRegexToChannel` + диалог + видимость |
| `app/test/screens/...` | виджет-тест 💾-видимости + диалог (по возможности) |

## Связанные

- [§125 configurable-channels](../features/125%20configurable-channels/spec.md) —
  `node_filter`/`default_filter`, `updateChannel`, активный канал = selectedGroup.
- [§048 home-node-filters](../features/048%20home-node-filters/spec.md) —
  глобальная песочница; эта таска даёт мост песочница→канал.
