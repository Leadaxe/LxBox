# §388 — bulk-действия по результатам probe на подписке (паритет с папкой)

| Поле | Значение |
|------|----------|
| Статус | Done, DEVICE-PENDING |
| Дата старта | 2026-08-11 |
| Дата завершения | 2026-08-11 |
| Связанные spec'ы | §339 — probe на вкладке Nodes подписки; §284/§296 — bulk-действия папки; §283 — per-node disable (`disabledHashes`); §332 — bulk «все вкл/выкл» + ENABLE-правила; §326 — identity-ключи результатов; §336 — вердикт `group` |

## Проблема

Запрос пользователя (11.08.2026): у папки и у подписки одинаковый probe-тест
(«Test servers», сводка `ok / err / broken`), но действия по результатам есть
только у папки — меню «Disable slower than…» / «Disable unreachable» /
«Delete unreachable». На подписке после теста остаются только поштучные
тумблеры §283: пропинговал 700 нод — три десятка ошибок выключай пальцем.

Нужен паритет: те же bulk-действия на вкладке Nodes подписки.

## Решение

Переносятся **два** действия (решение юзера — оба сразу):

| Действие папки | Подписка | Механика |
|---|---|---|
| Disable slower than… | ✓ переносится | отметки §283 вместо `setMembersEnabled` |
| Disable unreachable | ✓ переносится | то же |
| Delete unreachable | ✗ НЕ переносится | ноды принадлежат провайдеру, refresh их вернёт; «удалить» для подписки = «отключить», оно уже есть |
| Sort by ping | ✗ вне скоупа | порядок нод подписки — провайдерский |

### Маппинг «результат → отметка»

Прямой, без reverse-lookup'ов: результаты probe ключуются
`nodeIdentityHash` (§326/§339, `probeKeysForNodes`), отметки §283 — тем же
хешом. Bulk-решения остаются чистыми index-хелперами `ProbeController`
(`unreachableIndexes` / `slowerThan`, — семантика §336 «`group` не входит»
сохраняется бесплатно); граница «ключ → индекс» — новый `_probeByIndex()`
экрана (паттерн §326 папки), индексы → `NodeSpec` → хеши в контроллере.

### Изменения

1. **`SubscriptionController.setSubscriptionNodesEnabled(index, nodes,
   {enabled})`** — пачечный аналог `toggleSubscriptionNode` §283 /
   `setAllSubscriptionNodes` §332: merge/remove identity-хешей в
   `disabledHashes`, `_persist` + notify. Отметки — ручные §283 со всей
   существующей механикой (TTL, GC на успешном refresh).
2. **`subscription_detail_screen.dart`** — меню `⋮` в probe-баре (виден при
   `_probe.isNotEmpty && !_testing`, как в папке): «Disable slower than…»
   (диалог порога, префилл `orangeMs`) и «Disable unreachable»
   (failed + broken + invalid).

### ENABLE-правила фильтров (§332)

Отметки лягут как ручные §283, а ENABLE-правило на следующем refresh их
**снимет** (правило — источник истины). Согласованное поведение: если у
подписки есть usable-правило с action=enable — предупреждаем:

- «Disable unreachable» — подтверждающий диалог (без правил его нет,
  паритет с папкой: действие мгновенное);
- «Disable slower than…» — строка-предупреждение в уже существующем
  диалоге порога.

## L10n

Ключи меню/диалогов/снекбаров папки переиспользованы как есть (перевод уже в
`ru/ui.json`). Новые ключи: «Disable %d servers that failed the test?»
(plural) и предупреждение про Enable-правила.

## Тесты

Чистые хелперы (`unreachableIndexes`/`slowerThan`) и билдер-эффект
`disabledHashes` уже покрыты существующими тестами; новый метод контроллера —
map-merge, идентичный `setAllSubscriptionNodes`. Верификация UI — устройством:
probe на подписке с мёртвыми нодами → меню → оба действия → серые строки →
rebuild не эмитит отключённые (существующий §283-путь).
