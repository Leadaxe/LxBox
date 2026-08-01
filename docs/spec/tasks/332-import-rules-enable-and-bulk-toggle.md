# §332 — Действие Enable в import-rules + кнопка «вкл/выкл все» на вкладке Nodes

| | |
|---|---|
| Статус | ✅ Реализовано (device-pending) |
| Дата | 2026-08-01 |
| Связанные | [`302 import-rules`](302-subscription-import-rewrite-rules.md), [`307 rules non-incremental`](307-import-rules-prefix-accumulation.md), [`283 node-disable`](../features/283%20subscription-node-disable/spec.md), [`331 blue banner`](331-blue-banner-and-manual-refresh-reaction.md) |

## Проблема

4PDA (hapatsa #1323): сменил DISABLE-фильтр «FI» на «NL» — выключились и FI,
и NL узлы, включить нечем.

Механика: правила умеют только выключать. На refresh итоговые отметки — merge
([subscription_controller.dart:1892](../../../app/lib/controllers/subscription_controller.dart)):
`{...GC(старые), ...новые от правил}`. GC (`gcDisabledHashes`) снимает отметку
только у узла, который **ушёл из подписки** (и то после TTL); узлу, который в
подписке остался, GC наоборот освежает `lastSeen`. FI-узлы после смены правила
остаются выключенными навсегда: они в теле есть, правило про них молчит.

Асимметрия с REPLACE: тот пересчитывается с нуля каждый прогон (§307), DISABLE
же персистится в `disabledHashes` и оттуда не выводится.

Решено (обсуждение в теме, консенсус NeoCat #1325 / k-dmitriy #1330 /
hapatsa #1326): **не** менять модель хранения — правила последовательные,
поэтому достаточно действия «Enable»: первым правилом можно «включить всё»
(сброс прошлых отключений), дальше выборочно выключать. Плюс кнопка
«вкл/выкл все» на вкладке Nodes как ручной выход.

## Нецели

- Раздельное хранение ручных (§283) и правило-отметок — отвергнуто: остаётся
  одна карта `disabledHashes`, Enable-правило снимает и ручные отметки тоже
  (правило — источник истины, когда матчится).
- Bulk-toggle для папок (§234 members) — другой экран, другая модель, вне scope.
- Пресеты/подсказки «match all» в редакторе — идиома документируется, UI не
  усложняем.

## Решение

### 1. `ImportRuleAction.enable`

Модель ([import_rule.dart](../../../app/lib/models/import_rule.dart)):
третье значение enum + `fromName('enable')` + ветка в `summary` («Enable»).
`isUsable` не меняется: как у disable — достаточно одного пригодного условия,
цели нет.

Движок ([import_rules.dart](../../../app/lib/services/subscription/import_rules.dart)):
`NodeRuleOutcome.disabled` становится тристейтом `bool?`:

| значение | смысл |
|---|---|
| `null` | disable/enable-правила узла не касались |
| `true` | выключить (положить хеш в `disabledHashes`) |
| `false` | включить принудительно (снять хеш, включая ручной) |

Правила идут сверху вниз, **последнее сработавшее enable/disable побеждает**
(и «выключить всё → включить NL» = whitelist, и «включить всё → выключить FI»
= сброс + blacklist). `ImportRulesResult` получает `enabledIndexes` рядом с
`disabledIndexes` (по построению не пересекаются).

Merge на refresh ([subscription_controller.dart](../../../app/lib/controllers/subscription_controller.dart),
`_fetchEntryByRef`): порядок — GC → снять enable-хеши → положить disable-хеши.
Вынесен в pure-helper рядом с `gcDisabledHashes`
([node_hash.dart](../../../app/lib/services/node_hash.dart)):

```dart
Map<String, DateTime> applyRuleMarks(base, {enable, disable, now});
```

`_applyRulesToNodes` возвращает record `({Set<String> disable, Set<String> enable})`;
регидрация из кэша, как раньше, результат игнорирует (persisted-карта уже
содержит итог последнего refresh — §283: регидрация не сигнал).

Идиома «match all» для правила-сброса: условие с пустым путём + `matches` +
`.*` (пустой путь сериализует весь JSON узла — значение всегда непустое).

Совместимость назад: старая версия приложения читает `action: enable` через
старый `fromName` → получит `replace` без цели → правило непригодно и молча
пропускается. Деградация тихая, узлы не портятся.

### 2. Кнопка «вкл/выкл все» (вкладка Nodes)

Контроллер: `setAllSubscriptionNodes(int index, {required bool enabled})`:

- **enable** → `disabledHashes = {}` (снимает всё: ручные, правило-отметки,
  TTL-хвосты ушедших узлов). Правила при следующем refresh поставят свои
  отметки заново — честно, они источник истины.
- **disable** → merge `{...старые, для каждого top-level узла: hash: now}`
  (старые TTL-отметки ушедших узлов не теряются — §283 GC доделает).

UI ([subscription_meta.dart](../../../app/lib/screens/subscription_detail_screen/widgets/subscription_meta.dart)):
компактная адаптивная кнопка в строке счётчиков: есть выключенные →
«Enable all», иначе «Disable all». Диалога нет — действие обратимо той же
кнопкой. Показ — только для подписок с загруженными узлами (проброс из
[subscription_detail_screen.dart](../../../app/lib/screens/subscription_detail_screen.dart)).

### 3. UI правил (Filters)

- Редактор: третий сегмент «Enable» (иконка check), описание — что действие
  снимает отметки, в том числе ручные.
- Плитка правила: бейдж «Enable» (зелёный; Replace — синий, Disable — оранжевый).
- Вкладка Matches: `outcome.disabled == false` → «Will be enabled» (зелёный).

## Файлы

| Файл | Изменение |
|---|---|
| `models/import_rule.dart` | enum + fromName + summary |
| `services/subscription/import_rules.dart` | тристейт outcome, `enabledIndexes` |
| `services/node_hash.dart` | pure `applyRuleMarks` |
| `controllers/subscription_controller.dart` | record из `_applyRulesToNodes`, merge через helper, `setAllSubscriptionNodes` |
| `widgets/subscription_filters_tab.dart` | сегмент, бейдж, тексты, Matches-превью |
| `widgets/subscription_meta.dart` | адаптивная кнопка Enable all / Disable all |
| `subscription_detail_screen.dart` | проброс totalCount/callback |
| `test/subscription/import_rules_test.dart` | enable: последний побеждает, whitelist/blacklist-цепочки, сериализация |
| `test/services/node_hash_test.dart` | `applyRuleMarks`: снятие ручной отметки, порядок с GC |
| `assets/l10n/ru/ui.json` | переводы новых строк |

## Docs to update

- `CHANGELOG.md` → Unreleased: enable-действие правил + bulk-кнопка.

## Проверка

- [x] `flutter test` — вся сьюта (2622)
- [x] `flutter analyze` — весь проект, чисто
- [x] 4 l10n-чекера `--strict` (ui_check поймал пропущенный «Will be enabled» — добавлен)
- [ ] **device**: сценарий hapatsa — DISABLE «FI», применить; сменить на «NL»,
      применить → FI снова включены только если первым стоит Enable-сброс;
      без него — кнопка «Enable all» возвращает всё разом
