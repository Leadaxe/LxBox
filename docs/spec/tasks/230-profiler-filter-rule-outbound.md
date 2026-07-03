# §230 — профайлер-фильтр: видимость search + оси rule/outbound

> **СТАТУС: РЕАЛИЗАЦИЯ.** Чисто UI (`stats_screen/`). Данные (rule, outbound-
> цепочки) уже приходят в `TrafficEvent` — новый поток/ядро не нужны.

## Часть A — баг: активный `search` не виден

**Симптом:** клик на домен в детали соединения ставит фильтр (`_filter.search`),
список фильтруется корректно, НО сама строка фильтра нигде не отображается. Юзер
не видит, что за фильтр активен, и снять его может только через «Reset all».

**Причина:** при редизайне §044 виджет отображения `search` не построили.
`_filter.search` только читается как predicate (`profiler_filter.dart` `apply()`
+ `AggregatedView`), но не рендерится. Control-бар (`trace_explorer.dart`)
показывает лишь счётчик `Filter (N)` — текст `search` в него не входит.
Фильтр-окно (`profiler_filter_sheet.dart`) вообще не имеет поля поиска.

**Фикс:** **поле поиска (TextField) в фильтр-окне** (`profiler_filter_sheet.dart`)
— над TabBar, видно на любой вкладке. `TextEditingController` засеян из
`f.search` (клик по домену кладёт значение туда), `onChanged` → `f.search`,
suffix-крестик чистит. Все ручки фильтра в одном месте (рядом с осями
Protocol/App/Rule/Outbound), а не чипом на экране.

**`search` остаётся substring** (case-insensitive `contains`, не regex —
таким он и был). Слово «регулярка» в UI не вводим: клик на домен даёт точное
подстрочное совпадение без экранирования, битого regex нет.

## Часть B — две новые оси фильтра: Rule и Outbound

Ортогонально существующим Protocol (kinds) и App. Данные уже в `TrafficEvent`
(`models.dart`): `rule` (String?, поле 173), `outboundChain` (List<String> —
роутинг-цепочка `[node, …selectors, канал]`), `detourChain` (List<String> —
транспорт/detour).

### Rule-ось
- Фильтр по `event.rule` (какое route-правило сматчило).
- Пустой `rule` → псевдо-значение **«final»** (соединения без явного правила;
  в UI уже показываются как `final` — см. `overview_tab.dart:203`).

### Outbound-ось
- Тег ∈ (`outboundChain` ∪ `detourChain`) — **любое звено**, не только финал.
  Ловит промежуточные селекторы (`✨auto`, `vpn-1`) И detour-транспорт (`WARP`).
  Кейс: «покажи всё, что ушло в отдельный канал / через WARP».

### Модель `ProfilerFilter`
Паттерн как у `_apps` (Set + toggle/has + вклад в activeCount):
```
final Set<String> _rules = {};       // выбранные rule (+ '' как «final»)
final Set<String> _outbounds = {};   // выбранные теги-звенья
bool hasRule(String) / toggleRule(String, bool)
bool hasOutbound(String) / toggleOutbound(String, bool)
```
- `activeCount` += `_rules.length` + `_outbounds.length`.
- `clearAll()` чистит и их.

### Комбинирование
- **Между осями — AND** (как kinds AND apps): событие проходит, если сматчило
  по каждой активной оси.
- **Внутри оси — OR**: `event.rule ∈ _rules` ЛИБО (rule пуст И '' ∈ _rules);
  outbound — пересечение (`_outbounds` ∩ звенья цепочки) непусто.

### apply() — новые ветки
```dart
if (_rules.isNotEmpty) {
  list = list.where((e) => _rules.contains(e.rule ?? ''));
}
if (_outbounds.isNotEmpty) {
  list = list.where((e) {
    final chain = {...e.outboundChain, ...e.detourChain};
    return chain.any(_outbounds.contains);
  });
}
```

### UI — `profiler_filter_sheet.dart`
Две новые вкладки/секции **Rule** и **Outbound** рядом с Protocol/App.
Значения — **динамический список**: собрать уникальные `rule` (+ «final») и
уникальные звенья цепочек из ТЕКУЩИХ событий (фильтровать имеет смысл по тому,
что реально встречается). Источник — тот же поток событий, что explorer отдаёт
в sheet.

## Файлы

- `app/lib/screens/stats_screen/profiler_filter.dart` — оси `_rules`/`_outbounds`
  (toggle/has/activeCount/clearAll/apply).
- `app/lib/screens/stats_screen/trace_explorer.dart` — сбор seenRules/
  seenOutbounds из событий + прокидка в sheet.
- `app/lib/screens/stats_screen/profiler_filter_sheet.dart` — поле поиска
  над TabBar (Часть A) + вкладки Rule/Outbound (Часть B).
- тесты: `app/test/screens/profiler_filter_test.dart` — predicate `apply()`
  для rule/outbound-осей.

## Связано

- §044 (new-profiler — control-строка + ProfilerFilter; тут расширяем оси).
- §181 (routing-line — источник outboundChain/detourChain).
- §177 (kinds-ось по семейству — образец паттерна ортогональных осей).
