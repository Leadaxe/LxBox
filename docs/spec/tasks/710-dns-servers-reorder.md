# 710 — Перестановка DNS-серверов шаблона перетаскиванием

| Field | Value |
|-------|-------|
| Status | Done |
| Start date | 2026-11-03 |
| End date | 2026-11-03 |
| Commits | `9f19ffc4` |
| Related specs | §680 (каталог DNS-серверов), §117/§033 (reorder DNS-правил), §098 (`ReorderGrabStrip`) |

## Problem

Запрос пользователя 03.11.2026: у каждого провайдера в списке DNS-серверов
по 4–6 записей (UDP основной и резервный, DoT, DoH, DoH3, DoQ), а порядок
списка менять нельзя — новые и скопированные серверы встают в хвост, собрать
записи одного провайдера рядом невозможно.

Диагностика: на вкладке DNS `ReorderableListView` обёрнут только вокруг
правил (`_onReorderRules`), секция «DNS Servers» рисуется плоским `map` по
`_displayedServers`. При этом отображаемый список один в один повторяет
`_servers` (резолвер `resolveDisplayedServers` лишь пропускает пустые теги), а
сохранение уже пишет `servers: _servers` списком — порядок персистится без
доработки хранилища и бэкапа.

## Solution

Минимальный вариант по слову владельца (03.11.2026): drag-and-drop серверов
как у правил, порядок хранится в `dns.servers` шаблона. Папки и группировка по
провайдеру — не делаются.

- Секция «DNS Servers» — `ReorderableListView.builder` (`shrinkWrap`,
  `NeverScrollableScrollPhysics`, `buildDefaultDragHandles: false`), как у
  правил на той же вкладке.
- `MergedServerTile` получает `dragIndex` и слева полосу `ReorderGrabStrip`
  по образцу `DnsRuleTile` (Stack, отступ 30 px). Без `dragIndex` тайл
  прежний.
- `_onReorderServers(oldIndex, newIndex)`: индексы display-списка переводятся
  в `_servers` по тегу; элемент переставляется, `_markDirty()`. Семантика
  `newIndex` как у `onReorderItem` правил (уже без перетаскиваемого).
- Ключ элемента — `ValueKey('dns-server-$tag')`.
- Залоченные серверы (used by / пикеры) переставляются как все — лок
  запрещает удаление и выключение, не позицию.
- Ничего другого в UI вкладки не меняется.

## Verification

- Widget-тест `app/test/screens/dns_settings_screen/dns_servers_reorder_test.dart`:
  вкладка с 3+ серверами, перетаскивание 3-го на 1-е место меняет порядок
  `_servers` и порядок тайлов; сохранённый список серверов идёт в новом
  порядке.
- Эмулятор: собрать записи одного провайдера рядом, выйти и вернуться на
  вкладку, перезапустить приложение — порядок сохраняется; конфиг ядра
  `dns.servers` идёт в новом порядке.

## Documentation

- `docs/spec/features/680*` / USER_GUIDE — одна фраза про перестановку
  серверов за полосу слева (если раздел о списке DNS-серверов там есть).
- CHANGELOG Unreleased.
