# 068 — Extract `NodeViewItem` view-model class

| Поле | Значение |
|------|----------|
| Статус | Released в v1.9.0 (выполнен **внутри PR §048** при срабатывании trigger'а) |
| Дата | 2026-05-12 |
| Зависимости | Нет. Pure refactor. |
| Связанные | [`features/048 home-node-filters`](../features/048%20home-node-filters/spec.md) — extract делается внутри этого PR если itemBuilder раздулся или появился второй call-site `NodeRow`. |
| Триггер | `NodeRow` widget принимает 14+ параметров через конструктор (`tag`, `active`, `delay`, `pingBusy`, `tunnelUp`, `busy`, callbacks, `urltestNow`, `hasDetour`, `protocolLabel` …). Это **partial view-model** в форме arguments-bag. При расширении (filter feature добавляет `matches: bool`) — список параметров растёт, чище упаковать в named class. |

## Когда extract имеет смысл

**Не делается as separate task — выполняется внутри PR §048 при срабатывании одного из trigger'ов:**

1. **itemBuilder в `_buildNodeList` раздулся**. После добавления filter logic + detour + urltest detection + proto detection + matches вычисления — каждая итерация >50 строк локальных derived values. Хочется отделить «собрали snapshot строки» от «нарисовали».

2. **Появился второй call-site** `NodeRow`. Если в процессе работы над §048 (или сразу после) выяснится что другой screen (Stats / Subscriptions detail / Routing) хочет переиспользовать `NodeRow` — extract = **реакция на факт**, не гипотеза.

Если ни один trigger не сработал — `NodeRow(matches: bool, ...14 args)` остаётся как есть. YAGNI.

## Цель

Извлечь `NodeViewItem` — immutable data class содержащий **всё что нужно для render'а одной node row**. `NodeRow` принимает один parameter `item: NodeViewItem` вместо 14+ explicit fields. Никакого изменения behaviour, только архитектура.

После рефактора:
- `home_screen.dart::_buildNodeList` строит `NodeViewItem` per tag в itemBuilder
- `NodeRow(item: vi, ...callbacks)` — single positional arg + callbacks-bundle
- Другие screens могут использовать `NodeViewItem` для consistent node display

## Не в скопе

- **Новые фильтры / поведение** — это §048. Здесь только rename.
- **Унификация callbacks** в одном callback-class. Callbacks остаются inline в `NodeRow` constructor — они per-screen specific.
- **Other screens переписывать под `NodeViewItem`** — у них пока нет node rows.
- **Перенос `_buildNodeList` логики в widget tree** — структура `home_screen.dart` не меняется.

---

## Текущее состояние

[home_screen.dart:1853-1873](../../../app/lib/screens/home_screen.dart#L1853) — `NodeRow` constructor:

```dart
NodeRow(
  tag: tag,
  active: tag == state.activeInGroup,
  highlighted: tag == state.highlightedNode,
  delay: state.lastDelay[tag],
  pingBusy: state.pingBusy[tag] == '…',
  tunnelUp: state.tunnelUp,
  busy: state.busy,
  onHighlight: () => _controller.setHighlightedNode(tag),
  onActivate: () => unawaited(_controller.switchNode(tag)),
  onPing: () => unawaited(_controller.runNodeUrltest(tag)),
  onCopy: (mode) => _copyNodeJson(tag, state, mode),
  onCopyUri: () => _copyNodeUri(tag),
  onViewJson: () => _viewOutboundJson(tag, state),
  urltestNow: urltestNow,
  onRunUrltest: isUrltestGroup ? () => unawaited(_controller.runGroupUrltest(tag)) : null,
  hasDetour: cache.detourTags.contains(tag),
  protocolLabel: protoType != null ? _protoLabel(protoType) : null,
);
```

14 data fields + 6 callbacks = 20 параметров.

[widgets/node_row.dart](../../../app/lib/widgets/node_row.dart) — `class NodeRow extends StatelessWidget` с теми же 14+ `final` instance variables.

---

## Целевая модель

### `lib/widgets/node_view_item.dart` NEW

```dart
/// Immutable data for one node row. Все derived values для рендера —
/// вычисляются в `home_screen::_buildNodeList::itemBuilder` (или другом
/// caller'е) и пакуются сюда. `NodeRow` widget — pure render от этой модели.
class NodeViewItem {
  const NodeViewItem({
    required this.tag,
    required this.active,
    required this.highlighted,
    required this.delay,
    required this.pingBusy,
    required this.tunnelUp,
    required this.busy,
    required this.urltestNow,
    required this.hasDetour,
    required this.protocolLabel,
    required this.matches,   // ← §048 filter result (если PR §048 уже добавил поле — здесь оно)
  });

  final String tag;
  final bool active;
  final bool highlighted;
  final int? delay;
  final bool pingBusy;
  final bool tunnelUp;
  final bool busy;
  final String? urltestNow;
  final bool hasDetour;
  final String? protocolLabel;
  final bool matches;   // false = render dimmed via Opacity
}
```

### `NodeRow` после рефактора

```dart
class NodeRow extends StatelessWidget {
  const NodeRow({
    super.key,
    required this.item,
    required this.onHighlight,
    required this.onActivate,
    required this.onPing,
    this.onCopy,
    this.onCopyUri,
    this.onViewJson,
    this.onRunUrltest,
  });

  final NodeViewItem item;

  final VoidCallback onHighlight;
  final VoidCallback onActivate;
  final VoidCallback onPing;
  final ValueChanged<CopyMode>? onCopy;
  final VoidCallback? onCopyUri;
  final VoidCallback? onViewJson;
  final VoidCallback? onRunUrltest;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: item.matches ? 1.0 : 0.4,   // single source of opacity (см. §048)
      child: _buildContent(context),
    );
  }
}
```

### `home_screen.dart::_buildNodeList::itemBuilder`

```dart
itemBuilder: (context, i) {
  final tag = displayNodes[i];
  // derived data — снаружи widget
  final urltestNow = ClashApiClient.urltestNow(state.proxiesJson, tag);
  final proxyEntry = ClashApiClient.proxyEntry(state.proxiesJson, tag);
  final isUrltestGroup = proxyEntry != null &&
      (proxyEntry['type']?.toString().toLowerCase() ?? '').contains('urltest');
  final protoType = cache.protoByTag[tag] ??
      (urltestNow != null ? cache.protoByTag[urltestNow] : null);

  final item = NodeViewItem(
    tag: tag,
    active: tag == state.activeInGroup,
    highlighted: tag == state.highlightedNode,
    delay: state.lastDelay[tag],
    pingBusy: state.pingBusy[tag] == '…',
    tunnelUp: state.tunnelUp,
    busy: state.busy,
    urltestNow: urltestNow,
    hasDetour: cache.detourTags.contains(tag),
    protocolLabel: protoType != null ? _protoLabel(protoType) : null,
    matches: filter.passes(tag),
  );

  return NodeRow(
    item: item,
    onHighlight: () => _controller.setHighlightedNode(tag),
    onActivate: () => unawaited(_controller.switchNode(tag)),
    onPing: () => unawaited(_controller.runNodeUrltest(tag)),
    onCopy: (mode) => _copyNodeJson(tag, state, mode),
    onCopyUri: () => _copyNodeUri(tag),
    onViewJson: () => _viewOutboundJson(tag, state),
    onRunUrltest: isUrltestGroup
        ? () => unawaited(_controller.runGroupUrltest(tag))
        : null,
  );
},
```

---

## Преимущества

1. **itemBuilder читается как ETL**: derived values → assemble NodeViewItem → pass to widget. Чёткое разделение «собрали snapshot строки» от «нарисовали».
2. **Tests проще**: `NodeViewItem.copyWith(matches: false)` — tweaking одного поля в группе тестов вместо повторять 14 named args.
3. **Естественный extension point** для будущих filter feature / per-row hints.
4. **NodeRow остаётся agnostic** к state структуре — принимает готовую data shape.

---

## Не делаем здесь

- **Factory `NodeViewItem.fromState(HomeState state, String tag, ConfigCache cache)`** — логика построения остаётся в `_buildNodeList::itemBuilder`. Каждый screen может иметь свою logic построения (другое active selection, другие callbacks).
- **`Equatable` или `@override hashCode/==`** — Flutter сравнивает widgets по identity. Если будет flickering — добавим тогда.

---

## Файлы (если trigger сработал)

| Файл | Изменение |
|---|---|
| `app/lib/widgets/node_view_item.dart` NEW | Immutable data class |
| `app/lib/widgets/node_row.dart` | Принимает `NodeViewItem item` + callbacks. Внутри `build` — `item.field` вместо `field`. `Opacity(opacity: item.matches ? 1.0 : 0.4)` wrapper. |
| `app/lib/screens/home_screen.dart` | `_buildNodeList::itemBuilder` собирает `NodeViewItem` локально, передаёт в `NodeRow`. |

---

## Test plan

`flutter analyze` clean, `flutter test` зелёный — refactor без behaviour changes.

Manual smoke на устройстве: node list рендерится точно как было (active/highlight/ping/copy/long-press menu). Никаких visible UX изменений.

---

## Risks

| Риск | Митигация |
|---|---|
| Пропустить один field при маппинге | Analyzer (undefined_identifier) + smoke test |
| Equality / hashCode для performance | V1 — без `==`. Если будет flickering — добавить potом. |
| Breaking change для other screens | `NodeRow` используется **только в home_screen.dart** (один call-site). |

---

## Объём

~80 строк новый класс + ~50 диффа NodeRow + ~30 в home_screen. Fast.
