# §302 — Правила обработки подписок на импорте (заменить / выключить)

**Тип:** feature · **Статус:** реализовано (device-pending) · **Размер:** M · **Область:** subscription import pipeline

Правила с совпадением по строке (literal/regex), применяемые к телу подписки **на импорте/обновлении**. Два действия: **заменить** фрагмент строки или **выключить** ноду (завести, но пометить disabled через §283). Нужны, чтобы чинить кривые/устаревшие параметры из чужих подписок и отсекать ненужные ноды, не дожидаясь фиксов в коде и не гоняя лишнее через фильтр в памяти.

Запрос: 4PDA #1154 / #1146 (k-dmitriy). Прямые примеры пользователя:
- **REPLACE** `hellochrome_120` → `chrome` (починка битого uTLS fingerprint — ср. [§281](281-utls-fingerprint-normalize.md), но там нормализация в ядре app-side; здесь юзерский слой поверх)
- **REPLACE** `&type=raw` → `` (удалить неподдерживаемый параметр из строки, чтобы взялся дефолт)
- **REPLACE** `&sni=xx.xx` → `&sni=yy.yy` (подмена SNI)
- **DISABLE** `^.*(Netherlands).*$` (оставить в списке зачёркнутыми, но не роутить/не пинговать — юзер видит, что отсеклось, и может вернуть)

**Решение по DELETE (согласовано с юзером 2026-07-21):** действие «удалить ноду целиком» **выкинуто** из первой версии. REPLACE `&type=raw → ""` покрывает «вырезать фрагмент строки»; для «убрать ноду из роутинга» есть DISABLE (нода видна зачёркнутой, но не роутится/не пингуется) — это мягче, чем немое исчезновение, и юзер видит, что отсеклось. Полное удаление можно добавить позже, если появится явный запрос.

## Проблема

Сейчас единственный рычаг над содержимым подписки — фильтр по имени/тегу ([§077](077-subscription-filter-with-prefix.md) и далее), который работает **в памяти уже после парсинга**: ноды всё равно распарсены, лежат в БД и пингуются. Нельзя:
- починить баговый параметр внутри URI (фильтр видит только имя, не тело);
- полностью исключить ноду из импорта (не спрятать в UI, а не заводить вообще);
- сделать это единым местом в приложении, без внешнего скрипта-прокладки.

## Решение

**Список правил живёт per-subscription** (не глобально). Каждое правило: `{ action, pattern, replacement, isRegex, caseSensitive, enabled }`, где `action ∈ {replace, disable}`. Применяются **построчно** к телу подписки в порядке списка.

Два действия ложатся на **два этапа** pipeline'а (`fetch → decode → parseAll`), потому что replace работает на сырой строке, а disable — на identity-хеше уже распарсенной ноды:

**Этап A — до `parseAll` (текстовый, на строке тела).** Врезка между `decode` и `parseAll`, [`sources.dart:102-103`](../../../app/lib/services/subscription/sources.dart):
```
final decoded = decode(fetch.body);
// ← врезка A: applyImportRules(decoded, rules)  (построчно, replace + пометка disable-строк)
final nodes = parseAll(rewritten);
```
- **REPLACE** — `pattern` → `replacement` в строке (literal при `isRegex=false`, `RegExp` при `true`). Все вхождения в строке. Работает на **любом** формате тела (URI-list / INI / JSON — это просто текст).
- Порядок значим: replace применяется по списку сверху вниз, **до** проверки disable. Строка, попавшая под disable, проверяется в её послезаменном виде.

**Этап B — после `parseAll` (на `NodeSpec`, через §283).** Для строк, совпавших с `disable`-правилом (в послезаменном виде), кладём `nodeIdentityHash` соответствующей ноды в `disabled_hashes` ([§283](../../STORAGE.md), [`node_hash.dart:65`](../../../app/lib/services/node_hash.dart), билдер пропускает такие: [`build_config.dart:220`](../../../app/lib/services/builder/build_config.dart), [`server_list_build.dart:41`](../../../app/lib/services/builder/server_list_build.dart)):
- **DISABLE** — нода **заводится и видна** в списке (зачёркнутой), но не роутится и не пингуется. Юзер видит, что отсеклось, и может вернуть вручную. Переиспользует существующий §283-механизм — не новое состояние.
- **Хеш — от СУТИ ноды, не от строки (согласовано 2026-07-21).** DISABLE и ручной §283-toggle используют **одну** формулу `nodeIdentityHash = sha256(emit минус tag/detour)` ([`node_hash.dart`](../../../app/lib/services/node_hash.dart)). Это осознанный отказ от варианта «хешировать сырую строку»: единое хеш-пространство сохраняет инвариант §283 (косметическое переименование ноды провайдером `#NL → #NL-2` не роняет выключение) и **не сбрасывает** уже существующие ручные `disabledHashes` у юзеров (формула не меняется). Ручной toggle и disable-правило видят друг друга: выключил правилом → в списке зачёркнуто → тот же хеш.
  - **Привязка disable-строки к ноде (этап B):** `parseAll` для URI-веток идёт `lines.map(parseUri)` и исходную строку рядом с нодой не отдаёт. Сопоставляем **отдельным проходом `parseUri`** по помеченным (послезаменным) строкам в контроллере: `parseUri(line)` → `nodeIdentityHash` → добавить в `disabledHashes`. `parseAll` **не трогаем** (blast-radius минимальный; все примеры юзера — URI-подписки; для INI/JSON `parseUri` построчно неприменим — см. границы).
  - **Взаимодействие с §283-TTL-GC:** disabled_hashes чистится TTL-GC на успешном refresh. Хеши от disable-правила переставляются на **каждом** импорте (правило — источник истины, не разовое действие). Порядок в `_fetchEntryByRef`: сначала проставить disable-хеши от правил (`lastSeen = now`), **потом** GC — GC их не снимет, т.к. `now - lastSeen = 0 ≤ TTL`. Правило побеждает GC.

**`originLine` — оригинал строки до правил, ТОЛЬКО для UI (значок + diff).** `NodeSpec.rawUri` после врезки A хранит **послезаменную** URI-строку (правила применяются до `parseAll`). Чтобы показать «до/после», протаскиваем оригинал отдельно: `applyImportRules` возвращает карту `послезаменная строка → оригинал`, контроллер после парсинга матчит по `node.rawUri` и кладёт оригинал в новое опциональное поле `NodeSpec.originLine` (URI-ноды; `null` для INI/JSON и для нод без замен). На хеш `originLine` **не влияет** — только на отображение.

**View JSON ноды подписки (симметрия с папкой §234).** В long-press меню ноды на detail-экране подписки ([`subscription_node_list.dart:159`](../../../app/lib/screens/subscription_detail_screen/widgets/subscription_node_list.dart) `_showNodeMenu`) добавляем пункт **«View JSON»** — показывает итоговый sing-box outbound `node.emit(TemplateVars.empty).map` (то, во что нода превратится в конфиге, включая эффект REPLACE), как `node_settings_screen.dart:112-113`. Юзер видит финальный JSON, не гадая, что сделали правила.

**Расположение — per-subscription, вкладка «Filters».** Правила живут **в самой подписке**, не глобально: у каждой подписки свой набор. UI — новая (4-я) вкладка на detail-экране подписки, рядом с существующими Nodes / Settings / Source ([`subscription_detail_screen.dart:315-320`](../../../app/lib/screens/subscription_detail_screen.dart), `TabController(length: 3)` → 4). Логично: правила — часть конфигурации конкретного источника (у разных панелей разные баги), и юзер правит их там же, где смотрит ноды подписки.

Флаги/границы (общие для всех действий):
- Поле `importRules: List<ImportRule>` в [`SubscriptionServers`](../../../app/lib/models/server_list.dart) (рядом с `url`, `disabledHashes`, `updateIntervalHours`). Пустой список = поведение как сейчас.
- Тумблер «включить/выключить набор» на вкладке — отключает все правила подписки, не удаляя их. Плюс per-rule `enabled`.
- `caseSensitive` — **per-rule** флаг (подмена параметров бывает регистрозависимой; выкидывание нод по стране — нет). Дефолт `false` — согласуется с [§301](301-regex-filter-case-insensitive.md) (node-фильтры регистронезависимы), но переопределяемо на правиле.
- Инвалидный regex в правиле → правило **скипается** с предупреждением (не роняет импорт подписки). Валидация паттерна в UI редактора правила (как node-фильтр канала).
- Порядок правил значим (цепочка: сначала replace fingerprint, потом disable по стране на послезаменных строках) — список упорядочен, drag-reorder как у каналов.

**Персистенция (инвариант [§221](221-backup-allowlist-export.md)):** `importRules` — часть сериализации `SubscriptionServers`, значит уже попадает в backup/export вместе с подпиской (не новый top-level ключ). Проверить, что поле реально сериализуется в `toJson`/`fromJson` и переживает round-trip бэкапа — иначе тихая потеря правил.

## Файлы

- `lib/models/import_rule.dart` (новый) — `ImportRule` (`action`/`pattern`/`replacement`/`isRegex`/`caseSensitive`/`enabled`) + `enum ImportRuleAction { replace, disable }`, `toJson`/`fromJson`/`copyWith`, компиляция regex с кэшем валидности.
- `lib/models/server_list.dart` — поле `importRules: List<ImportRule>` в `SubscriptionServers` + флаг набора; трио `toJson`/`fromJson`/`copyWith` (эталон — `disabledHashes`/`identity`).
- `lib/models/node_spec.dart` — опциональное поле `originLine` (сырая строка до правил; для UI-значка/diff, `null` по умолчанию). Прокинуть через `copyWith`; на `emit`/хеш не влияет.
- `lib/services/subscription/import_rules.dart` (новый) — pure: `applyImportRules(String body, List<ImportRule>)` → `({String rewritten, Set<String> disabledLines, Map<String,String> originByRewritten})`. Replace построчно + пометка disable-строк + карта послезаменная→оригинал. Testable без сети.
- `lib/services/subscription/sources.dart` — врезка этапа A между `decode` и `parseAll`; результат (disable-строки + origin-карта) прокинуть в `ParseResult` для этапа B и `originLine`.
- `lib/controllers/subscription_controller.dart` — в `_fetchEntryByRef`: (1) проставить `disabledHashes` по disable-строкам через `parseUri`→`nodeIdentityHash` **до** GC; (2) проставить `originLine` на ноды по карте (матч по `rawUri`). Применяется на **каждом** refresh.
- `lib/screens/subscription_detail_screen.dart` — 4-я вкладка «Filters» (`TabController` 3→4, `length: 3`→`4` на строке 144 + `Tab` на 315-321).
- `lib/screens/subscription_detail_screen/widgets/subscription_filters_tab.dart` (новый) — UI списка правил (CRUD + reorder + тумблер набора + валидация regex + выбор action replace/disable).
- `lib/screens/subscription_detail_screen/widgets/subscription_node_list.dart` — значок «были замены» (`originLine != null`) в строке ноды; пункт **«View JSON»** в `_showNodeMenu` (итоговый `emit`) + diff before/after (по `originLine` ↔ `rawUri`).

## Приёмка

- REPLACE: правило `&type=raw → ""` (literal) убирает параметр из строки, нода парсится с дефолтом.
- REPLACE regex: `hellochrome_120 → chrome` чинит fingerprint, нода валидна; в списке значок «замены», View JSON показывает `chrome`.
- DISABLE: `^.*Netherlands.*$` — NL-ноды **видны зачёркнутыми**, не роутятся/не пингуются; юзер может вернуть; их хеши в `disabledHashes`.
- DISABLE переживает refresh: после повторного обновления подписки NL-ноды остаются disabled (правило переставляет хеши **до** GC, §283-TTL-GC их не оживляет).
- DISABLE ↔ ручной §283: нода, выключенная правилом, и та же нода, выключенная кнопкой, дают один `nodeIdentityHash` (суть минус tag/detour) — единое хеш-пространство, ручное выключение не слетает от косметического переименования провайдером.
- Правила — **per-subscription**: набор одной подписки не влияет на другую.
- Порядок: replace, затем disable по послезаменной строке — применяются по порядку.
- Тумблер набора off → тело подписки не трогается, все ноды как раньше, значков нет.
- Инвалидный regex в правиле → это правило скипнуто + предупреждение, остальные правила и импорт работают.
- View JSON: пункт меню ноды подписки показывает итоговый sing-box outbound (симметрия с папкой §234).
- pure `applyImportRules` покрыта unit-тестами (literal/regex/replace/disable-пометка/origin-карта/порядок/битый паттерн/caseSensitive) без сети.
- Backup подписки содержит `importRules`; restore их возвращает (round-trip §221).

## Решённые вопросы (были открыты)

1. **DISABLE-привязка строки к ноде** (этап B): **отдельный проход `parseUri`** по помеченным послезаменным строкам в контроллере. `parseAll` не трогаем.
2. **Хеш DISABLE**: **от сути ноды** (`sha256(emit минус tag/detour)`, §283) — не от сырой строки. Единое хеш-пространство с ручным toggle; старые `disabledHashes` не сбрасываются; переименование провайдером не роняет выключение.
3. **DISABLE vs TTL-GC**: правило проставляет хеши (`lastSeen = now`) **до** GC в `_fetchEntryByRef` → правило побеждает GC.
4. **DELETE**: выкинут из первой версии (см. заголовок). REPLACE покрывает вырезание фрагмента, DISABLE — исключение из роутинга.
5. **originLine**: только для UI (значок + diff/View JSON), на хеш не влияет.
6. **Разделяемость правил**: per-subscription. Расширение («набор на несколько подписок» / шаблоны) — не в первой версии.

## Docs to update

- [`docs/STORAGE.md`](../../../docs/STORAGE.md) — поле `importRules` в схеме `SubscriptionServers` (часть подписки, не top-level; в backup/export вместе с подпиской).
- Feature-спека подписок — import-rules-слой в pipeline `fetch → decode → (import rules) → parseAll → (disable rules)`.
