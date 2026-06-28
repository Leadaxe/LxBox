# §197 — Инверсия node_filter канала (исключающий фильтр)

> **СТАТУС: РЕАЛИЗОВАНО (28.06.2026).** Расширение [§125](../features/125%20configurable-channels/spec.md).
> Ветка `feat/configurable-channels-125`.

## Контекст

§125 per-channel `node_filter` — regex по итоговому tag ноды: в канал попадают
**совпавшие** (`baseNodes.where(re.hasMatch)`). Понятия «исключить» не было —
юзер не мог задать «все ноды КРОМЕ bypass». Попытка написать `!/bypass/` в поле
не работала: `!` и `/.../` — литералы Dart-regex, не инверсия (`/.../` это
JS-синтаксис, Dart его не понимает).

## Цель

Добавить инверсию `node_filter` как **отдельный тогл** (`!`-кнопка `NegateToggle`,
как в §048-фильтре на главной), а не префикс/обёртку в тексте. true → в канал
попадают ноды, чей tag **НЕ** матчит regex.

- Только `node_filter`. `default_filter` инверсии НЕ имеет (семантически мутно:
  «default = первая НЕ матчащая нода»).
- Пустой `node_filter` → инверсия игнорируется (все ноды).

## Модель / storage

`Channel` + `bool nodeFilterInvert` (default false). JSON-ключ
`node_filter_invert`. Старые каналы без ключа → false (fromJson-дефолт).
Миграция не нужна (новое поле, дефолт false).

## Билдер

`_buildChannelGroups.nodesFor`:
```dart
return baseNodes.where((t) => re.hasMatch(t) != c.nodeFilterInvert).toList();
```
`hasMatch != invert` — XOR: invert=false → совпавшие; invert=true → НЕ совпавшие.
Пустой набор после инверсии (regex матчит всё) → fallback direct-out (как §125).

## UX (редактор канала)

`ChannelEditScreen` — `NegateToggle` слева от node_filter-поля (Row, как §048
`RegexFilterField`). Тогл красный = инверсия. Live-превью учитывает инверсию
(`matched: N` / `excluded → matched: N`).

## §195-проброс

Сохранение regex с главной (§195) переносит и инверсию: `onSaveRegex(pattern,
invert)` — главный фильтр (`f.regexInvert`) → `nodeFilterInvert` канала (только
для node_filter; default не имеет инверсии). Сигнатура колбэка расширена
`String → (String, bool)`.

## Файлы

| Файл | Изменение |
|---|---|
| `app/lib/models/channel.dart` | `nodeFilterInvert` + copyWith/json |
| `app/lib/services/builder/build_config.dart` | `nodesFor` XOR-инверсия |
| `app/lib/screens/channel_edit_screen.dart` | NegateToggle + превью |
| `app/lib/screens/home/filter_widgets.dart` + `filter_panel.dart` + `node_list.dart` | onSaveRegex(pattern, invert) проброс (§195) |
| `docs/STORAGE.md` | ключ `node_filter_invert` |
| тесты | channel_test (round-trip) + channel_groups_test (инверсия node-set) |

## Связанные

- [§125 configurable-channels](../features/125%20configurable-channels/spec.md) — node_filter.
- [§195 save-home-filter-to-channel](195-save-home-filter-to-channel.md) — проброс инверсии.
- [§048 home-node-filters](../features/048%20home-node-filters/spec.md) — эталон NegateToggle.
