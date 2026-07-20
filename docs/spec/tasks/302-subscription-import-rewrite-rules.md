# §302 — Правила обработки подписок на импорте (заменить / удалить / выключить)

**Тип:** feature · **Статус:** открыто (сбор требований) · **Размер:** M · **Область:** subscription import pipeline

Правила с совпадением по строке (literal/regex), применяемые к телу подписки **на импорте/обновлении**. Три действия: **заменить** фрагмент, **удалить** ноду (не заводить вообще) или **выключить** ноду (завести, но пометить disabled). Нужны, чтобы чинить кривые/устаревшие параметры из чужих подписок и отсекать ненужные ноды, не дожидаясь фиксов в коде и не гоняя лишнее через фильтр в памяти.

Запрос: 4PDA #1154 / #1146 (k-dmitriy). Прямые примеры пользователя:
- **REPLACE** `hellochrome_120` → `chrome` (починка битого uTLS fingerprint — ср. [§281](281-utls-fingerprint-normalize.md), но там нормализация в ядре app-side; здесь юзерский слой поверх)
- **REPLACE** `&type=raw` → `` (удалить неподдерживаемый параметр, чтобы взялся дефолт)
- **REPLACE** `&sni=xx.xx` → `&sni=yy.yy` (подмена SNI)
- **DELETE** `^.*(Russia|\bRU\b).*$` (выкинуть RU-ноды целиком)
- **DELETE** `^vless://.*` (выкинуть все ноды протокола)
- **DISABLE** `^.*(Netherlands).*$` (оставить в списке зачёркнутыми, но не роутить/не пинговать — юзер видит, что отсеклось, и может вернуть)

## Проблема

Сейчас единственный рычаг над содержимым подписки — фильтр по имени/тегу ([§077](077-subscription-filter-with-prefix.md) и далее), который работает **в памяти уже после парсинга**: ноды всё равно распарсены, лежат в БД и пингуются. Нельзя:
- починить баговый параметр внутри URI (фильтр видит только имя, не тело);
- полностью исключить ноду из импорта (не спрятать в UI, а не заводить вообще);
- сделать это единым местом в приложении, без внешнего скрипта-прокладки.

## Решение

**Список правил** в глобальных настройках подписок (рядом с `auto_update_subs`). Каждое правило: `{ action, pattern, replacement, isRegex, caseSensitive, enabled }`, где `action ∈ {replace, delete, disable}`. Применяются **построчно** к телу подписки в порядке списка.

Три действия ложатся на **два этапа** pipeline'а (`fetch → decode → parseAll`), потому что replace/delete работают на сырой строке, а disable — на identity-хеше уже распарсенной ноды:

**Этап A — до `parseAll` (текстовый, на строке тела).** Врезка между `decode` и `parseAll`, [`sources.dart:102-103`](../../../app/lib/services/subscription/sources.dart):
```
final decoded = decode(fetch.body);
// ← врезка A: applyTextRules(decoded, rules)  (построчно, replace + delete)
final nodes = parseAll(decoded);
```
- **REPLACE** — `pattern` → `replacement` в строке (literal при `isRegex=false`, `RegExp` при `true`). Все вхождения в строке.
- **DELETE** — строка, совпавшая с `pattern`, **выкидывается** из тела до парсинга. Нода не заводится, не пингуется, не занимает БД, в списке её нет. Кейс `^.*Russia.*$`.

**Этап B — после `parseAll` (на `NodeSpec`, через §283).** Для строк, совпавших с `disable`-правилом, запоминаем совпадение, распознаём соответствующую распарсенную ноду и кладём её `nodeIdentityHash` в `disabled_hashes` ([§283](../../STORAGE.md), [`node_hash.dart:65`](../../../app/lib/services/node_hash.dart), билдер пропускает такие: [`build_config.dart:220`](../../../app/lib/services/builder/build_config.dart), [`server_list_build.dart:41`](../../../app/lib/services/builder/server_list_build.dart)):
- **DISABLE** — нода **заводится и видна** в списке (зачёркнутой), но не роутится и не пингуется. Юзер видит, что отсеклось, и может вернуть вручную. Переиспользует существующий §283-механизм — не новое состояние.
  - **Грабля привязки:** сопоставить «строку, совпавшую с disable-правилом» ↔ «распарсенную ноду» надёжнее по позиции/парсингу той же строки через `parseUri`, чем повторным матчем regex по имени. Решить при реализации: либо `parseAll` возвращает исходную строку рядом с `NodeSpec`, либо disable-правила прогоняются отдельным проходом `parseUri` на помеченных строках.
  - **Взаимодействие с §283-TTL-GC:** disabled_hashes чистится TTL-GC на успешном refresh. Хеши, проставленные правилом, должны переставляться при каждом импорте (правило — источник истины, не разовое действие), иначе GC их снимет и нода «оживёт». Т.е. disable-правило применяется на **каждом** обновлении, а не один раз.

**Расположение — per-subscription, вкладка «Filters».** Правила живут **в самой подписке**, не глобально: у каждой подписки свой набор. UI — новая (4-я) вкладка на detail-экране подписки, рядом с существующими Nodes / Settings / Source ([`subscription_detail_screen.dart:315-320`](../../../app/lib/screens/subscription_detail_screen.dart), `TabController(length: 3)` → 4). Логично: правила — часть конфигурации конкретного источника (у разных панелей разные баги), и юзер правит их там же, где смотрит ноды подписки.

Флаги/границы (общие для всех действий):
- Поле `importRules: List<ImportRule>` в [`SubscriptionServers`](../../../app/lib/models/server_list.dart) (рядом с `url`, `disabledHashes`, `updateIntervalHours`). Пустой список = поведение как сейчас.
- Тумблер «включить/выключить набор» на вкладке — отключает все правила подписки, не удаляя их. Плюс per-rule `enabled`.
- `caseSensitive` — **per-rule** флаг (подмена параметров бывает регистрозависимой; выкидывание нод по стране — нет). Дефолт `false` — согласуется с [§301](301-regex-filter-case-insensitive.md) (node-фильтры регистронезависимы), но переопределяемо на правиле.
- Инвалидный regex в правиле → правило **скипается** с предупреждением (не роняет импорт подписки). Валидация паттерна в UI редактора правила (как node-фильтр канала).
- Порядок правил значим (цепочка: сначала delete RU, потом replace fingerprint у оставшихся, потом disable по стране) — список упорядочен, drag-reorder как у каналов. delete раньше replace/disable дешевле (меньше строк на последующие проходы).

**Персистенция (инвариант [§221](221-backup-allowlist-export.md)):** `importRules` — часть сериализации `SubscriptionServers`, значит уже попадает в backup/export вместе с подпиской (не новый top-level ключ). Проверить, что поле реально сериализуется в `toJson`/`fromJson` и переживает round-trip бэкапа — иначе тихая потеря правил.

## Файлы

- `lib/models/` — `ImportRule` (`action`/`pattern`/`replacement`/`isRegex`/`caseSensitive`/`enabled`) + поле `importRules` в `SubscriptionServers` (`server_list.dart`), сериализация `toJson`/`fromJson`.
- `lib/services/subscription/import_rules.dart` (новый) — pure-функции: `applyTextRules(String body, List<ImportRule>)` (replace + delete, этап A) и `disableMatches(...)` → набор строк/хешей для этапа B. Testable без сети.
- `lib/services/subscription/sources.dart` — врезка этапа A между `decode` и `parseAll`; проброс disable-совпадений на этап B.
- `lib/controllers/subscription_controller.dart` — в `_fetchEntryByRef` после `parseAll`: проставить `disabledHashes` по disable-правилам (переиспользуя §283-путь). Применяется на **каждом** refresh (правило — источник истины).
- `lib/screens/subscription_detail_screen.dart` — 4-я вкладка «Filters» (`TabController` 3→4).
- `lib/screens/subscription_detail_screen/widgets/subscription_filters_tab.dart` (новый) — UI списка правил (CRUD + reorder + тумблер набора + валидация regex + выбор action).

## Приёмка

- REPLACE: правило `&type=raw → ""` (literal) убирает параметр из URI, нода парсится с дефолтом.
- REPLACE regex: `hellochrome_120 → chrome` чинит fingerprint, нода валидна.
- DELETE: `^.*(Russia|\bRU\b).*$` (regex) — RU-ноды **не появляются** в списке (не заведены, не пингуются).
- DELETE: `^vless://.*` — ни одной vless-ноды на импорте.
- DISABLE: `^.*Netherlands.*$` — NL-ноды **видны зачёркнутыми**, не роутятся/не пингуются; юзер может вернуть; их хеши в `disabledHashes`.
- DISABLE переживает refresh: после повторного обновления подписки NL-ноды остаются disabled (правило переставляет хеши, §283-TTL-GC их не оживляет).
- Правила — **per-subscription**: набор одной подписки не влияет на другую.
- Порядок: два правила, второе зависит от результата первого — применяются по порядку.
- Тумблер набора off → тело подписки не трогается, все ноды как раньше.
- Инвалидный regex в правиле → это правило скипнуто + предупреждение, остальные правила и импорт работают.
- pure `applyTextRules` покрыта unit-тестами (literal/regex/replace/delete/порядок/битый паттерн/caseSensitive) без сети.
- Backup подписки содержит `importRules`; restore их возвращает (round-trip §221).

## Открытые вопросы (согласовать до реализации)

1. **DISABLE-привязка строки к ноде** (этап B): как надёжно сопоставить совпавшую строку тела с распарсенной `NodeSpec` для взятия `nodeIdentityHash`? Варианты: (а) `parseAll` возвращает исходную строку рядом с каждой нодой; (б) отдельный проход `parseUri` по помеченным строкам. Влияет на API `parseAll`.
2. **DISABLE vs TTL-GC**: подтвердить, что переустановка хешей на каждом refresh не конфликтует с §283-GC (правило-источник истины должно побеждать GC).
3. **Разделяемость правил**: per-subscription (эта спека). Возможное расширение — «применить набор правил к нескольким подпискам» / шаблоны наборов. Не в первой версии.

## Docs to update

- [`docs/STORAGE.md`](../../../docs/STORAGE.md) — поле `importRules` в схеме `SubscriptionServers` (часть подписки, не top-level; в backup/export вместе с подпиской).
- Feature-спека подписок — import-rules-слой в pipeline `fetch → decode → (text rules) → parseAll → (disable rules)`.
