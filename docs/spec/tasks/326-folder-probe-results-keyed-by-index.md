# §326 — Результаты теста в папке привязаны к позиции, а не к узлу

| | |
|---|---|
| Статус | ✅ Реализовано (device-pending) |
| Дата | 2026-07-31 |
| Связанные | [`234 folders`](../features/234%20folders/spec.md), [`236 folder probe`](236-folder-probe-ui-rework.md), [`283 node disable`](283-subscription-node-disable.md), [`284 WARP endpoint scanner`](284-warp-endpoint-scanner.md), [`296 probe controller`](296-probe-controller.md), [`325 per-channel ping`](325-mass-ping-wipes-other-channels.md) |

## Проблема

Сценарий пользователя: папка из генератора WARP (§284), сотня членов, Test —
часть узлов падает. Начинаешь удалять мёртвые по одному — бейджи пинга
разъезжаются: значения ведут себя так, будто привязаны к порядковому номеру
строки, а не к самому серверу. После удаления одного члена в середине списка
все замеры ниже него смещаются на одну позицию вверх и показывают чужие числа.

## Причина

Результаты пробы на экране папки хранятся с **позиционным ключом**
([folder_detail_screen.dart:59](../../../app/lib/screens/folder_detail_screen.dart:59)):

```dart
final Map<int, ProbeResult> _probe = {};
```

Отрисовка — по тому же индексу (`probe: _probe[i]`), поэтому ключ обязан
совпадать с текущей позицией члена в `_folder.members`.

Для **перестановок** это чинили ремапом, и он корректный:

| Операция | Место | Что делает |
|---|---|---|
| drag-reorder | [:1160–1171](../../../app/lib/screens/folder_detail_screen.dart:1160) | ручной сдвиг ключей вокруг `oldIndex`/`newIndex` |
| sort by ping | [:504](../../../app/lib/screens/folder_detail_screen.dart:504) | `ProbeController.remapAfterReorder` |
| удаление мёртвых пачкой | [:493](../../../app/lib/screens/folder_detail_screen.dart:493) | `_probe.clear()` — честно сбрасывает всё |

Дыра — **точечное удаление**, которое ремапа не получило вовсе:

| Путь | Место | Итог |
|---|---|---|
| `_deleteMember` (меню члена → Delete) | [:955](../../../app/lib/screens/folder_detail_screen.dart:955) | `removeMemberAt` + голый `setState(() {})` |
| `AutoGroupDeleted` (удаление из редактора группы) | [:769](../../../app/lib/screens/folder_detail_screen.dart:769) | то же |

Состав уехал, ключи `_probe` — нет. Ровно то, что видел пользователь.

## Почему не «дописать ещё один ремап»

Ремап — лечение симптома: каждая новая операция над составом обязана помнить о
`_probe`, и цена забывчивости — молча неверные числа на экране (два пути уже
забыли). Позиция вообще не является идентичностью узла.

## Решение

Ключ результата — **идентичность узла**, а не позиция.

### Ключ

`nodeIdentityHash(node)` из
[node_hash.dart:65](../../../app/lib/services/node_hash.dart:65) — тот же
механизм, что уже держит per-node disable подписок (§283): sha256 от
канонического sing-box-map узла минус `tag`/`detour`.

Рассмотренные и отклонённые кандидаты:

| Кандидат | Почему нет |
|---|---|
| `NodeSpec.tag` | внутри папки **не уникален** — уникализация (`allocateTag`) живёт только в билдере конфига и до модели папки не доходит; у WARP-генератора десятки членов с одной ремаркой. Плюс мутабелен: правка ремарки роняет ключ |
| `NodeSpec.id` | `newUuidV4()` на каждом разборе `raw`; `FolderMember.copyWith(raw:)` делает re-parse → новый id. Не переживает даже редактирование члена |
| позиция (текущее) | см. «Причина» |

Семантика при правке параметров узла: хеш меняется → старый замер отвязывается.
Это **намеренно** — правка порта/uuid/sni означает другой сервер, прежнее
измерение к нему не относится (решение юзера 2026-07-31).

### Битые члены

У нечитаемого `raw` нода не распарсилась (`node == null`), хеша нет. Ключ —
`'raw:' + raw`. Такой член не пингуется, но слот под вердикт `invalid` занимать
обязан.

### Дубли

`nodeIdentityHash` по построению склеивает одинаковые серверы (в §283 это
by design — «один toggle гасит все»). Для замеров склейка означала бы «два
одинаковых узла делят одну ячейку» — тот же баг, только реже.

Дедуп при построении ключей: идём по `members` по порядку, для повторно
встреченного хеша добавляем суффикс `#2`, `#3`, … Ключ остаётся детерминированным
от **состава**, а не от позиции: удаление члена в середине ключи остальных не
трогает; сдвинутся только сами дубли — а они неразличимы по определению.

Для WARP-папки (§284) вопрос не встаёт: генератор варьирует endpoint, у каждого
члена свой `ip:port` → хеши расходятся.

### Форма

```dart
final Map<String, ProbeResult> _probe = {};

/// Ключи членов папки в порядке позиций: probeKeys(members)[i] — ключ i-го.
static List<String> probeKeys(List<FolderMember> members);
```

`ProbeRunner` продолжает отдавать `onResult(index, result)` — он работает над
плоским `List<NodeSpec?>` и о папках не знает (§296). Перевод индекса в ключ
делает экран на границе: `_probe[keys[i]] = r`.

### Кеш ключей

`nodeIdentityHash` — sha256 по emit-map узла; считать его в `itemBuilder` на
каждый ребилд каждой строки дорого (у WARP-папки ~100 членов). Экран держит
`_memberProbeKeys()` с инвалидацией по `identical()` на самом списке членов:
`SubscriptionController` на любую мутацию состава строит новый список
(`[...folder.members]`), а правка члена меняет `raw` → список тоже новый.

### Граница «хеш → индекс»

Bulk-операции применяются позиционными мутаторами контроллера
(`setMembersEnabled`, `removeMembersAt`, `applyMembersOrder`), поэтому
`ProbeController.unreachableIndexes` / `slowerThan` / `pingSortOrder` **остаются
индексными**. Меняется только их вход: экран передаёт им карту, спроецированную
на текущие позиции.

```dart
Map<int, ProbeResult> _probeByIndex() {
  final keys = ProbeController.probeKeys(_folder.members);
  return {
    for (var i = 0; i < keys.length; i++)
      if (_probe[keys[i]] case final r?) i: r,
  };
}
```

### Что удаляется

| Удаляем | Почему |
|---|---|
| `ProbeController.remapAfterReorder` | reorder ключи не трогает |
| ручной сдвиг ключей на drag ([:1160–1171](../../../app/lib/screens/folder_detail_screen.dart:1160)) | то же |
| `_probe.clear()` после `_deleteUnreachable` ([:493](../../../app/lib/screens/folder_detail_screen.dart:493)) | результаты выживших остаются валидными — их больше не надо выбрасывать |

Точечные удаления (`_deleteMember`, `AutoGroupDeleted`) правки не требуют вовсе:
их `setState(() {})` теперь достаточен. Это и есть проверка решения — путь,
который забыли, чинится тем, что помнить больше нечего.

## Файлы

| Файл | Изменение |
|---|---|
| [`probe_controller.dart`](../../../app/lib/services/probe/probe_controller.dart) | `+probeKeys`, `−remapAfterReorder`; bulk-хелперы без изменений |
| [`folder_detail_screen.dart`](../../../app/lib/screens/folder_detail_screen.dart) | `_probe` → `Map<String, ProbeResult>`, `_probeByIndex()`, снятие ремапов |
| [`probe_controller_test.dart`](../../../app/test/services/probe/probe_controller_test.dart) | тесты `probeKeys` (дубли, битые, стабильность при удалении); снятие тестов `remapAfterReorder` |

## Проверка

1. Папка WARP-генератора, Test, удалить мёртвый член из середины → бейджи
   оставшихся не сдвигаются.
2. Дубль одного сервера дважды в папке → два независимых бейджа.
3. Drag-reorder после теста → бейджи едут вместе со строками.
4. Sort by ping → порядок по возрастанию, бейджи совпадают.
5. Правка узла (сменить порт) → его бейдж гаснет, соседние целы.
6. Битый член → бейдж `invalid` на своей строке.
