# §643 — Контракт 1.1.119: обход узлов `for_each_node` / `for_each_node_do`, поля `unique` и `internal`, объектный `default_domain_resolver`

| Поле | Значение |
|------|----------|
| Тип | Синк контракта + движок шаблона + UI + бэкап |
| Статус | D (done), выпущено в v2.25.14 |
| Дата | 2026-10-13 |
| Связанные | контракт 1.1.119 (лаунчер `baf7e9a2`, TASKS_LXBOX §116, SPEC 166, решения D-130 / D-131 / D-132, разрыв N16), §578 (прежний `for_each`, заменяется), §580 (кэш DNS, соседний переключатель), §83 (мягкий снос пресета — отменяется), §441 (`backup_var_skipped`) |

## Проблема

Лаунчер снял `for_each` и ввёл два ключа обхода узлов плюс объектную форму
`route.default_domain_resolver`. LxBox обязан повторить это в своём движке:
корпус `for_each/` переименован и переписан, без правок все корпусные
раннеры и гард переносимых переменных красные. Норма —
`app/contract/docs/TEMPLATE_LANG.md` §2.1, §4.5.1, §6.5–§6.7, §6.9;
обязанности LxBox — `app/contract/TASKS_LXBOX.md` §116. Контракт уже
синхронизирован (`app/contract/VERSION` = 1.1.119, lock на `baf7e9a2`),
зеркала `app/assets/contract` и `docs/contract` обновлены — **синк не
повторять, `app/contract/**` не трогать**.

## Что принёс 1.1.119 → что делает LxBox

| П. | Норма | Что делает LxBox |
|---|---|---|
| 1 | `for_each`, `node_type`, `as` — ошибка загрузки, легаси-чтения нет (D-130) | `PresetForEach` (`parser_config.dart` ~:670) и мягкий снос §83 в `template_loader.dart` (~:74, ~:156) снимаются; ключ `for_each` в пресете — отказ загрузки |
| 2 | два ключа: `for_each_node` (тело на каждый узел, `@node` в scope) и `for_each_node_do` (тело один раз после обхода, без `@node`); ровно один из них | новая модель обхода (два вида), раскрытие в `preset_expand.dart` (~:282) по §6.5 и §6.7.3 |
| 3 | внутри — закрытый список `#filter` / `#do` / `#final`; любой иной ключ, непомеченные `filter`/`do`/`final` — отказ; алиасов нет | строгий разбор ключей обхода; `#filter` валидируется как `cond` §4.1–4.2 существующим `validateCondNode` |
| 4 | имя узла фиксировано `node`; переменная `node` / `node.*` (глобальная или пресета) — отказ | `_ForEachScope` → фиксированное `node`; проверка имён в `validateTemplateConstructs` для глобалей и пресетов |
| 5 | `#do`: `"@имя"` → `{#append: ссылка \| #tpl}`; имя объявлено в `vars` этого пресета, тип `text_list`; пустое значение узла пропускается; дедупа нет (D-131) | сбор по §6.7.1 через существующее вычисление `#tpl`; проверки на загрузке |
| 6 | `#final`: `{#unique, #sort, #limit > 0}`, имя есть в `#do`; порядок применения unique → sort → limit независимо от порядка ключей | применение один раз после обхода, фиксированный порядок |
| 7 | сборка `_do`: база (ввод пользователя или `default_value`) → обход → `#do` → `#final` → `unique` объявления → тело один раз; собранное не персистится; пустой итог — `[]`, правило без условий снимает гейт с `template_fragment_dropped`; неймспейс тегов действует | копия значений на время сборки; `namespace: true` для `_do`, `false` для `for_each_node` (как прежде) |
| 8 | поля объявления: `unique` (bool, только `text_list`, иначе отказ) — дедуп ввода, `default_value`, собранного; `wizard_ui: "internal"` — не в форме, состояние и бэкап игнорируются, не персистится, не экспортируется; импорт — `backup_var_skipped {reason: internal}` (D-132) | `WizardVar.unique`; `internal` по образцу `hidden` в формах плюс фильтр у писателя состояния, экспорта и импорта |
| 9 | пресет `tailscale` на `for_each_node` с `#filter` по `@node.body.type` и `#not @node.skip_presets`; результат сборки прежний | правка `app/assets/wizard_template.json` ~:1877; существующий `tailscale_preset_build_test` — доказательство «байт в байт» |
| 10 | `route.default_domain_resolver` — объект `{server, disable_optimistic_cache}`; глобальная переменная `dns_resolver_no_stale` (bool, default `true`, `wizard_ui: fix`, title «Never serve stale answers for node hostnames»), переносимая, в бэкапе как `dns_optimistic`; читатели понимают строку и объект; подменяющий резолвер меняет только `server` | шаблон, переменная, переключатель во вкладке DNS под выбором резолвера, `kLxPortableVars`, все читатели ключа в `lib/` |

Пресет `node-domains-fresh-dns` из §6.7.4 в шаблон LxBox **не добавлять**.

## Решение

### 1. Модель и загрузка

- В `parser_config.dart` вместо `PresetForEach` — модель обхода (имя на
  усмотрение, например `PresetNodeLoop`): вид (`node` | `nodeDo`), `filter`
  (`Object?`, cond-дерево), `collect` (имя → правая часть `#append`), `final`
  (имя → `{unique, sort, limit}`). `SelectableRule.forEach` → поле новой
  модели; все обращения `preset.forEach` (`preset_expand.dart`,
  `preset_nodes_view.dart`, `dns_controller.dart`, `record_vars.dart`,
  `node_hash.dart`, `preset_on_change.dart`, `lx_backup.dart`, экраны) —
  пересмотреть под два вида.
- **Одна функция разбора-валидации** обхода (сырой JSON пресета +
  объявления переменных → модель или исключение), которой пользуются и
  `validateTemplateConstructs`, и корпусный раннер. Отказы по закрытому
  списку §6.5 и §6.7 (п. 1, 3–6, 8 таблицы), включая: `for_each`;
  `node_type` / `as` внутри обхода; оба ключа; чужой ключ; `#do` или
  `#final` в `for_each_node`; `#do` отсутствует в `_do`; ключ `#do` без `@`;
  имя не из `vars` этого пресета (глобаль, чужое, необъявленное); глагол
  не `#append`, два глагола, операция не объект; тип переменной не
  `text_list`; правая часть объект (кроме `{#tpl}`) или массив; `#final` на
  имя вне `#do`; чужой ключ или не тот тип в `#final` (`#limit: 0`,
  `"200"`, `#sort: "yes"`); `unique` не у `text_list`; переменная `node` /
  `node.*` (глобальная или пресета). В бандл-шаблоне это ошибка
  разработчика — исключение на весь load, как у прочих конструкций (мягкий
  снос §83 отменяется вместе с `for_each`).
- `WizardVar`: поля `unique` (bool, default false) и значение `wizard_ui`
  `internal`.

### 2. Раскрытие (`preset_expand.dart`)

- `for_each_node` — прежний путь §578 без отбора по `node_type`: только
  `#filter` (`evalCond` с резолвером узла поверх переменных пресета;
  отсутствующее значение — ложь), имя узла фиксированное `node`, тело на
  каждый узел подряд, `namespace: false`, предупреждения без дублей.
- `for_each_node_do` — шаги §6.7.3 в этом порядке:
  1. база каждой переменной из `#do`: у пользовательской — значение записи
     (`varsValues`), при отсутствии `default_value`; у `internal` — только
     `default_value`, значение записи игнорируется; при `unique` база без
     дублей; разбиение `text_list` — существующим сплитом `if_engine.dart`
     (~:85);
  2. обход узлов с `#filter`;
  3. `#append` на каждом прошедшем узле: правая часть вычисляется как
     вставка `#tpl` (резолвер узла, затем переменные пресета); скаляр —
     текстом; пустое (нет пути, null, `""`, объект, список) — узел молча
     пропускается; дедупа нет;
  4. `#final`: `#unique` (порядок первого появления) → `#sort` (байтовый,
     по возрастанию, `compareTo` по code units) → `#limit`;
  5. `unique` объявления;
  6. тело один раз с итоговыми значениями, без `@node` (`@node…` в теле —
     необъявленное имя по §5.2), `namespace: true`.
- Собранное живёт только в копии словаря переменных на время сборки;
  `varsValues` записи не меняются.
- Пустой итог — `[]` (как `types/text_list_empty_becomes_empty_array`);
  правило, у которого все условия пусты, снимает существующий гейт с
  `template_fragment_dropped` (кейс `empty_result_rule_dropped`); правило
  с другим условием идёт с `"domain": []`.
- Проба (тестовый конфиг узла) не раскрывает ни один из видов —
  проверить, где сегодня проба исключает `forEach`-пресеты, и сохранить.

### 3. Экраны и сервисы, знающие про обход

- `preset_nodes_view.dart`: набор `node_type` (~:25) исчезает. Видимость
  тумблера «Skip presets» у узла (`node_settings_screen.dart` ~:236) —
  есть пресет с обходом (любого вида), чей `#filter` истинен для этого узла
  при `skip_presets = false`; для `tailscale` это даёт прежнюю видимость.
- Подпись строки пресета на экранах Routing / DNS и превью в редакторе:
  у `for_each_node` — обслуживаемые узлы по `presetForEachNodes` (как
  сейчас); у `for_each_node_do` — подписи нет (`null`), пресет на экранах
  ведёт себя как обычный (тело одно, теги в неймспейсе).
- `dns_controller.dart` ~:175: ветка «пресет обслуживает узлы» — только для
  `for_each_node`.
- `template_overlay.dart` ~:163 — адресация по `#tpl`-тегам не меняется;
  проверить, что ключ пресета больше не упоминает `for_each`.

### 4. `internal` и `unique` вокруг движка

- Формы: `internal` пропускается там же, где `hidden`
  (`parser_config.dart:45` `varsFor`, `routing_screen_helpers.dart:256`,
  `preset_params_tab.dart:81`, `vpn_mode_tab.dart:73` — проверить, что
  исключение для `hidden` там не распространяется на `internal`).
- Состояние: писатель `varsValues` пресета и глобальных переменных снимает
  ключи `internal` молча; при чтении значение `internal` сборкой
  игнорируется (п. 2).
- LX Backup: экспорт не пишет `internal` (пресеты и глобали); импорт
  снимает значение с `backup_var_skipped {name, record, reason: internal}`
  — новая причина в списке `lx_backup.dart` ~:96, запись по образцу
  `lx_backup_import.dart` ~:333 (`record` у пресета — `preset:<ref>`, у
  глобали — как у существующих причин корневых `vars`).
- `unique`: дедуп с сохранением порядка при сохранении из формы
  (`text_list`), нормализация при чтении значения записи, применение к
  `default_value` и к итогу сбора (п. 2, шаг 5).

### 5. Шаблон, DNS-экран, бэкап, читатели резолвера

- `app/assets/wizard_template.json`: пресет `tailscale` (~:1877) →
  `"for_each_node": {"#filter": {"#and": [{"@node.body.type": "tailscale"}, {"#not": "@node.skip_presets"}]}}`,
  тело без изменений. `route.default_domain_resolver` (~:1229) →
  `{"server": "@dns_default_domain_resolver", "disable_optimistic_cache": "@dns_resolver_no_stale"}`.
  Глобальная переменная `dns_resolver_no_stale` рядом с `dns_optimistic`
  (~:783): `type: bool`, `default_value: "true"`, `required: true`,
  `wizard_ui: fix`, title «Never serve stale answers for node hostnames»,
  tooltip по смыслу §6.9 (ответ с истёкшим TTL для имён, которые ядро
  резолвит само — серверов узлов, — не отдаётся из кэша; на DNS-запросы
  приложений не влияет). Оверлеи `app/assets/l10n/{ru,zh}/template.json`
  — по требованиям `template_check --strict` (zh с отступом в один
  пробел, как в файле).
- `dns_settings_screen.dart`: переключатель под выбором резолвера по
  умолчанию, по образцу строки `dns_optimistic` (~:781, `ValueKey`,
  пометка «конфиг требует пересборки» тем же механизмом). Новых UI-строк
  вне шаблона не добавлять без нужды; добавленные — английские, с ru-ключом
  в `ui.json`.
- `lx_backup.dart` ~:233: `kLxPortableVars` += `dns_resolver_no_stale`
  (гард сверки с реестром). В файле бэкапа переменная едет в `vars`, как
  `dns_optimistic`; секция `dns.default_domain_resolver` файла остаётся
  строкой-тегом (BACKUP.md без изменений).
- Читатели `route.default_domain_resolver` в `lib/` (grep целиком):
  `builder/validator.dart` ~:119 и ~:146 (dangling и тип сервера — брать
  `server` из объекта, строку как прежде), running-config / Debug API
  (§311) и любой другой, кто читает ключ из конфига или шаблона. Кто
  подменяет резолвер (выбор на экране DNS через `dns_controller.dart`
  ~:276–358, замена выпавшего сервера при сборке, если такая есть) — меняет
  только `server`, прочие поля объекта сохраняет.

### 6. Корпус и тесты

- Раннер `test/contract/template_for_each_corpus_test.dart` → переименовать
  (например `template_node_loop_corpus_test.dart`) и вести по двум
  каталогам `corpus/template/for_each_node/` и `for_each_node_do/` (формат
  — `corpus/template/README.md`, раздел «Разделы for_each_node/ и
  for_each_node_do/»): `load: reject` = исключение функции разбора из п. 1;
  `vars.json` — значения записи пресета (у `internal` обязаны
  игнорироваться); `expected` — фрагменты, у `_do` один раз. Кейсы
  `subst/default_resolver_object_{defaults,off}` подхватывает
  `template_contract_test.dart` — убедиться, что он их видит.
- Обновить под новый формат: `test/services/builder/preset_for_each_test.dart`,
  `test/builder/tailscale_preset_build_test.dart` (ожидания сборки не
  менять — это доказательство «байт в байт»),
  `test/services/preset_nodes_view_test.dart`,
  `test/services/l10n/template_overlay_test.dart`,
  `test/services/dns_controller_test.dart`, `test/contract_paths.dart`,
  `test/contract/template_load_reject_test.dart` (при необходимости).
- Новые точечные тесты: `internal` не персистится / не экспортируется /
  импорт даёт `backup_var_skipped reason internal`; `unique` при сохранении
  из формы; валидатор принимает объектный резолвер и ловит dangling
  `server`; `kLxPortableVars` ↔ реестр (существующий гард).

### 7. Документация

- `docs/TEMPLATE.md` ~:985: раздел «`for_each`» → два ключа, `#filter`,
  `#do`/`#final`, `unique`, `internal`, объектный резолвер (кратко, со
  ссылкой на TEMPLATE_LANG).
- `docs/STORAGE.md` ~:678, ~:1089: упоминания `for_each` → `for_each_node`;
  строка о том, что значения `internal` в состоянии не хранятся.
- `docs/spec/tasks/578-tailscale-preset-template-for-each.md`: шапка
  «заменено §643 (контракт 1.1.119)».
- `CHANGELOG.md` → Unreleased: контракт 1.1.119; новый переключатель DNS
  «Never serve stale answers for node hostnames» (default on, переносится в
  LX Backup); язык обхода узлов в шаблоне (`for_each_node` /
  `for_each_node_do`), пресет Tailscale без видимых изменений.

## Риски и границы

- Миграции состояния нет: шаблон едет в APK, шаблонов с `for_each` у
  пользователей не бывает.
- Байт в байт у `tailscale` обязателен — красный
  `tailscale_preset_build_test` означает дефект реализации, не ожиданий.
- Расхождение с ожиданием корпуса — не править ожидания; описать в отчёте
  (кейс, ожидалось, получено, почему) — передаётся лаунчеру через
  TASKS_LXBOX.
- Не трогать: `app/contract/**`, `app/contract.lock`, `app/assets/contract/**`,
  `docs/contract/**`, `pubspec.lock`, `analysis_options.yaml`.

## Проверка

- `flutter analyze` всего проекта — без новых issues.
- Локально — только свои тест-файлы (раннер корпуса по двум каталогам,
  обновлённые и новые тесты из п. 6). Полный прогон, каталоги целиком —
  запрещены, их делает CI.
- После правки шаблона и строк: `template_check --strict` и
  `hardcoded_check` — 0 failures / 0 warnings.
- Линты CI: `use_null_aware_elements`,
  `no_leading_underscores_for_local_identifiers`, info-линты тоже валят
  Analyze; гард `engine_no_scheme_names` ловит имена схем в комментариях
  движка.

## Отклонения при реализации

- **Где живёт разбор.** Модель — отдельный файл `lib/models/preset_node_loop.dart`
  (`PresetNodeLoop`, `PresetLoopFinal`, `PresetNodeLoopKind`; реэкспорт из
  `parser_config.dart`), поле `SelectableRule.nodeLoop`. Структурный разбор по
  закрытым спискам §6.5/§6.7 — `PresetNodeLoop.parse` (бросает
  `FormatException`), его зовёт `SelectableRule.fromJson`. «Одна функция»
  для загрузчика и корпуса — `parsePresetNodeLoop` в
  `lib/services/builder/preset_node_loop.dart`: объявления переменных
  пресета (`validateVarDeclaration`), тот же `PresetNodeLoop.parse`
  (ошибка → `TemplateIfError`) и `#filter` через `validateCondNode` в scope
  `PresetNodeScope` (бывший `_ForEachScope`, имя `node` фиксировано).
  Следствие: в `TemplateLoader` структурная ошибка обхода всплывает
  `FormatException` из `WizardTemplate.fromJson` раньше
  `validateTemplateConstructs` — load всё равно падает целиком.
  `validateTemplateConstructs` больше ничего не снимает и возвращает `void`.
- **`#do`, правая часть.** Принимается строка (с `@` — ссылка, без `@` —
  литерал) или ровно `{"#tpl": "<строка>"}`; число, bool, null, иной объект,
  массив — отказ (норма называет только две формы). Строка `"@x"`
  вычисляется как вставка `@{x}` через `evalTpl`.
- **`unique` у объявления.** Отказ при наличии ключа у не-`text_list`
  (любое значение) и при не-bool значении.
- **Переменные `#do` и required.** `presetVarsMap(collected: …)`: у имён из
  `#do` пустая база ошибкой required не считается (значение даёт сбор).
- **Экраны.** `forEachNodeTypes` → `presetLoopNodeTypes`: типы узлов, которые
  пропускает `#filter` (`nodeLoopTypeHint`: равенство или `#in` на
  `@node.body.type`, сам предикат или член верхнего `#and`); null — фильтр
  тип не сужает, тогда `presetNodesForView` эмитит узлы любого типа.
  У `tailscale` сужение `{tailscale}` — эмиссия на экранах прежняя.
  `skipPresetsToggleVisible` принимает тег и тело узла вместо типа и
  вычисляет `#filter` (`presetLoopAcceptsNode`) при значениях переменных
  пресета по умолчанию. `presetForEachNodes` сохранил имя, для
  `for_each_node_do` возвращает пусто.
- **`internal` глобальных переменных.** Писатель `_setVar` берёт объявление
  из `TemplateLoader.cachedOrNull()`; шаблон не в кэше — значение пишется как
  есть (сборка `internal` всё равно не читает, `build_config.dart` берёт
  `default_value`). Импорт корневой переменной `internal` —
  `backup_var_skipped {reason: internal}` с detail = имя (через
  `RecordVarDecls.internalGlobals`), проверка раньше `not_portable`.
- **`internal` у шаблонных DNS-серверов.** Сверх ТЗ, по §6.4 Н2 (оба
  носителя): `normalizeDnsServerVars` снимает такие имена молча,
  импорт секции `dns` (`dns_backup.dart`) называет их `reason: internal`.
- **Читатели резолвера.** Общие помощники `domain_resolver_ref.dart`
  (`domainResolverServer`, `withDomainResolverServer`): `validator.dart`,
  `heal_dangling_dns_resolvers.dart`, `heal_detour_dropped_dns.dart`
  (последний уже понимал объект — переведён на помощник). Running config /
  Debug API ключ не разбирают.
- **Проба.** `probe/probe_config.dart` пресеты не раскрывает вовсе —
  исключать нечего.
- **Эталоны.** `test/fixtures/storage/golden/{avd_v0,rich_v0}.config.json`
  перегенерированы (`UPDATE_GOLDEN=1`): изменился только
  `route.default_domain_resolver` (строка → объект с
  `disable_optimistic_cache: true`); фрагменты `tailscale` в `rich_v0` байт в
  байт прежние.
- **Строки UI.** Подзаголовок переключателя на экране DNS короче подсказки
  переменной в шаблоне; ru и zh добавлены в `ui.json`.
- **Не обновлено:** документы фичи `docs/spec/features/024-TEMPLATE/`
  (EN/RU: `FEATURE`, `template-language`, `preset-bundles`,
  `config-template`, `extending-the-client`) всё ещё описывают `for_each` и
  мягкий снос §83 — вне списка раздела 7.
