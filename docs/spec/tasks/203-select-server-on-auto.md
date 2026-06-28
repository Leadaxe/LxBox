# §203 — «Select server» в меню auto-ноды + фикс позиции пинга

> **СТАТУС: РЕАЛИЗОВАНО (28.06.2026).** Расширение [§125](../features/125%20configurable-channels/spec.md) /
> [§199](../../../CHANGELOG.md). Ветка `feat/select-server-203`.

## Контекст / два изменения

**A. Фикс позиции пинга (регресс §199).** §199 перестроил `_buildSubtitleRow`
(node_row.dart): сервер `→ <node>` получил приоритет, транспорт уступает. Но в
обычной ноде (`arrow == null`, есть только `proto`) раскладка стала
`[proto flex:1] [Spacer flex:1] [right]` — `proto` и `Spacer` делили остаток
ширины **поровну** → пинг (`right`) всплывал в СЕРЕДИНУ строки. Юзер заметил на
устройстве (`425MS` в центре строки `XPNet №6`).

**B. «Select server» (новое).** В auto-группе по строке `→ <node>` видно, какой
сервер выбрал urltest, но перейти к нему в списке нельзя. Нужен пункт
контекстного меню auto-ноды → подсветить и проскроллить к выбранному серверу.

## Решения (согласованы с юзером 28.06.2026)

**A:** пинг ВСЕГДА у правого края. Вся левая часть (active / arrow / proto) — в
одном `Expanded`, который съедает остаток и толкает `right` вправо; конкуренции
flex-ов между proto и Spacer'ом больше нет. Приоритет сервера из §199 сохранён
(arrow flex:3, proto flex:1 внутри Expanded).

**B (вариант A из обсуждения):** «Select server» = **подсветка + best-effort
scroll**, НЕ переключение канала (auto продолжает сам выбирать быстрейший).
Пункт виден только для ноды с текущим выбором (`urltestNow != null`). Название —
`Select server`, иконка `Icons.my_location`.

## Реализация

| Слой | Файл | Изменение |
|---|---|---|
| вёрстка | `widgets/node_row.dart` `_buildSubtitleRow` | левая часть в `Expanded`, `right` фикс. справа |
| меню | `node_row.dart` | поле `onSelectServer` + пункт `select_server` (если `!= null`) + switch-case |
| провод | `screens/home/widgets/node_list.dart` | `rowKeyFor` + `onSelectServer`; `onSelectServer: urltestNow != null ? () => onSelectServer(urltestNow) : null`; GlobalKey на row |
| scroll | `screens/home_screen.dart` | `Map<String,GlobalKey> _nodeRowKeys` (ленивая) + `_scrollToNode(tag)` = `setHighlightedNode` + `Scrollable.ensureVisible` по ключу |

### Scroll-механика

Паттерн из `app_settings_screen.dart` (`Scrollable.ensureVisible` + GlobalKey).
Список `ReorderableListView.builder` ленивый → дальняя нода не смонтирована,
`currentContext == null`. Поэтому двухфазно:
1. **Подсветка** (`setHighlightedNode`) ставится в state ВСЕГДА — надёжно,
   красит строку (`highlighted` в NodeViewItem).
2. **Scroll** — best-effort: если строка смонтирована, `ensureVisible` плавно
   подскроллит; если нет — подсветка остаётся, юзер увидит её при прокрутке.

GlobalKey навешен на сам `row` (новый `KeyedSubtree`), а reorder-key остаётся
`ValueKey('node-$tag')` (его требует ReorderableListView — нельзя подменять).

## Тесты

Без отдельных unit-тестов: A — чисто layout (визуально проверяется на
устройстве), B — UI-проводка колбэка + ensureVisible (виджет-тест с фейковым
ленивым списком и скроллом непропорционально хрупок к объёму). Покрыто
device-проверкой + полным прогоном (analyze clean, 1362 теста зелёные).

## Связанные

- [§199] (CHANGELOG) — приоритет сервера в auto (его регресс чинит часть A).
- [§125 configurable-channels](../features/125%20configurable-channels/spec.md) — auto-двойник канала, urltestNow.
