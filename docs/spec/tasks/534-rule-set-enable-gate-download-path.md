# 534 — гейт `#enable` у rule_set не читается путём скачивания и UI Routing

| Поле | Значение |
|------|----------|
| Статус | **Done** |
| Дата старта | 2026-09-24 |
| Дата завершения | 2026-09-24 |
| Issue | — (дефект найден при работе над §531, см. «Замечание на будущее» в её спеке) |
| Коммиты | ветка `task-534` → `develop` (fast-forward): `fix(534)` ×2, `docs(534)` |
| Связанные spec'ы | §531 (первоисточник замечания; добавила второй гейтованный набор `ru-apps`), §045 (легаси `enabled: "@var"` и `geoip-ru`), §107 (канонический гейт `#enable`, `evalCond`), §265 (ref-var: значение в глобальном `userVars`), §366 (`remoteRuleSetsOfPreset` переехал в `models/`, headless-автообновление), §011 (remote rule_set → локальный кэш `.srs`), §439 (golden-эталоны хранения) |

---

## Проблема

Гейт фрагмента `rule_set` в пресете шаблона читается **двумя путями, и они
разошлись**:

1. **Сборка конфига** — `fragmentGateSatisfied`
   (`app/lib/services/builder/preset_expand.dart:682-707`). Понимает обе формы:
   легаси `enabled` (строка `"@var"` или `bool`, §045) и канонический
   `#enable` (`enableKey`, условие вычисляется `evalCond`, §107). Обе формы
   присутствуют → and. Словарь переменных для гейта — `varsMap`, собранный в
   `expandPreset` (`preset_expand.dart:106-167`): значения `varsValues` правила,
   дефолты `preset.vars`, ref-vars из `globalVars` (§265) и глобальные vars
   как fallback (§264).
2. **Скачивание и UI** — `isRuleSetEnabledFor`
   (`app/lib/models/preset_rule_set.dart:84-112`). Читает **только**
   `rs['enabled']`, сам разбирает `"@var"` (ищет в `varsValues`, иначе
   `default_value`, иначе `'true'`), про `#enable` не знает, `raw == null`
   трактует как always-on.

Через второй путь идут все потребители, кроме билдера:

- `remoteRuleSetsOfPreset` (`preset_rule_set.dart:61-80`, фильтр на строке 72)
  → `RoutingHelpers.remoteRuleSetsOf` / `isRuleSetEnabled`
  (`app/lib/screens/routing_screen/routing_screen_helpers.dart:71-83`);
- `_refreshSrsCache` (`app/lib/screens/routing_screen/routing_srs_cache.dart:151-171`)
  — считает правило «скачанным», когда есть `.srs` **всех** отфильтрованных
  наборов, и при нехватке **принудительно выключает** правило
  (`r.withEnabled(false)`);
- `_downloadSrsForPresetRule` (`routing_srs_cache.dart:277-300`) — качает
  отфильтрованные наборы;
- `presetNeedsDownload` (`routing_screen_helpers.dart:94-101`) — иконка ☁/✅ и
  disabled-switch;
- `RuleSetAutoUpdater` (`app/lib/services/rule_set_auto_updater.dart:255`) —
  кандидаты на фоновое обновление.

**Следствие.** У набора, чей гейт задан только формой `#enable`, экран Routing
и автообновление считают набор **всегда включённым**: при снятой галке набор
всё равно скачивается, требуется в кэше, а при его отсутствии выключается
**всё правило пресета** — даже если пользователь снял галку именно этого
набора, чтобы без него обойтись. Иконка ☁ показывается для набора, который
по гейту выключен и в конфиг не попадёт.

**Кого затрагивает сейчас.** В `app/assets/wizard_template.json` гейт в форме
`#enable` стоит у двух наборов, оба в пресете `ru-direct`:

| Набор | Гейт | Переменная |
|-------|------|------------|
| `geoip-ru` | `"#enable": ["@geoip_enabled"]` | `geoip_enabled` (bool, default `true`) |
| `ru-apps` | `"#enable": ["@apps_enabled"]` | `apps_enabled` (bool, default `true`, добавлена §531) |

Легаси-формы `enabled` у `rule_set` в шаблоне **нет ни у одного набора**
(все `"enabled": true` в файле — поля других объектов: TLS, серверов, правил).
То есть путь UI/скачивания сегодня **не уважает ни один гейт** шаблона.

## Диагностика

Почему разошлось: `isRuleSetEnabledFor` написан в §045 под единственную тогда
форму `enabled: "@var"` и дублирует разбор `@var` вручную. §107 ввёл `#enable`
и обучил ему только билдер (`fragmentGateSatisfied`); UI-хелпер не тронули.
§366 перенёс хелпер из экрана в `models/`, не меняя логики. §531 скопировал
форму гейта у соседа `geoip-ru` и зафиксировал расхождение как замечание.

Почему не ловилось тестами: у хелпера есть только тесты на `update_interval`
(`app/test/services/rule_set_auto_updater_test.dart:172-210`, группа «§366 TTL
из шаблона пресета»), гейт в них не проверяется; golden-эталоны (§439)
покрывают путь сборки, где гейт работает.

Есть ещё одно тихое расхождение легаси-формы: для `enabled: "@x"` с
**необъявленной** переменной хелпер возвращает `true` (fallback `'true'`), а
билдер — `false` (`substituteVars` отдаёт `Dropped` → `substituted is! String`).
При унификации побеждает семантика билдера: набор, который в конфиг не
попадёт, качать незачем.

Проверено, что ref-var (§265) для гейтов сейчас не задействована: у
`geoip_enabled`/`apps_enabled` поля `ref` нет. Но словарь для гейта обязан
учитывать ref-vars так же, как билдер, иначе будущий гейт на ref-переменную
разойдётся снова, в обратную сторону (UI — «выключен», билдер — «включён»,
предупреждение «skipped — no cached file» и никакой кнопки скачать).

## Решение

**Вариант (а): одна семантика гейта в одном месте.** Хелпер UI/скачивания
переиспользует предикат билдера и его же сборку словаря переменных.
Вариант (б) — дублировать гейт обеими формами в шаблоне — отвергнут: хрупко
(два поля на одно условие, следующий набор снова забудет одно из них), и не
чинит легаси-расхождение по необъявленной переменной.

### 1. Сборка словаря переменных — вынести из `expandPreset`

`app/lib/services/builder/preset_expand.dart`: цикл построения `varsMap`
(строки 106-167: `varsValues`/дефолты/optional-null, ref-vars из `globalVars`,
`globalVars` как fallback через `putIfAbsent`) вынести в **публичную чистую
функцию** рядом с `fragmentGateSatisfied`, например:

```dart
/// §534 — единый словарь переменных пресета: им пользуются и сборка
/// (`expandPreset`), и гейт наборов на пути скачивания/UI
/// (`isRuleSetEnabledFor`). Ошибка required-var — в `error`, текст
/// сообщения тот же, что раньше писал `expandPreset` в warnings.
({Map<String, dynamic> vars, String? error}) presetVarsMap(
  CustomRulePreset rule,
  SelectableRule preset, {
  Map<String, String> globalVars = const {},
})
```

`expandPreset` вызывает её и при `error != null` делает ровно то, что делал:
`warnings.add(error); return PresetFragments(warnings: warnings)`. Тексты
предупреждений (`required var "…" set to empty` / `unset`) и порядок ключей в
словаре **не меняются** — поведение сборки байт в байт прежнее, golden'ы это
подтверждают (см. «Приёмка»).

### 2. `isRuleSetEnabledFor` — через `fragmentGateSatisfied`

`app/lib/models/preset_rule_set.dart`:

```dart
bool isRuleSetEnabledFor(
  Map<String, dynamic> rs,
  SelectableRule preset,
  CustomRulePreset rule, {
  Map<String, String> globalVars = const {},
}) =>
    fragmentGateSatisfied(
      rs,
      presetVarsMap(rule, preset, globalVars: globalVars).vars,
    );
```

Ручной разбор `@var` удаляется целиком. `error` словаря игнорируется: если у
пресета не заполнена required-переменная, билдер не выпустит ни одного
фрагмента, и что качать — вопроса нет; гейт вычисляется на частичном словаре.

Импорт `models/` → `services/builder/` допустим: прецедент есть у десятка
моделей (`custom_rule.dart`, `config_node.dart`, `validation.dart` и др.),
архитектурного теста на направление импорта нет (§291 фиксирует другой
инвариант — фасады).

`remoteRuleSetsOfPreset(preset, [rule], {globalVars})` — прокинуть параметр;
без `rule` поведение прежнее (все remote-наборы, для cleanup).

Doc-комментарии обоих хелперов переписать: обе формы гейта, отсутствие обеих
= always-on, «одна семантика с билдером — `fragmentGateSatisfied`».

### 3. Вызывающие — передать глобальные vars (§265)

Аналог `globalVars` билдера на этом пути — `SettingsStorage.getAllVars()`
(билдер берёт flat-vars из `build_config.dart:184-226`; их основа — тот же
словарь userVars, поверх него служебные `vpn_mode`/`proxy_*`, которые для
гейта набора не нужны — см. «Что НЕ делаем»).

- `rule_set_auto_updater.dart` (сбор кандидатов, ~:243-270): рядом с ленивым
  `template ??= await TemplateLoader.load()` один раз прочитать
  `userVars ??= await SettingsStorage.getAllVars()` и передать в
  `remoteRuleSetsOfPreset(preset, r, globalVars: userVars)`.
- Экран Routing: в state (`app/lib/screens/routing_screen.dart`, рядом с
  `WizardTemplate? _template`, :87) поле `Map<String, String> _userVars =
  const {}`; в миксине `routing_srs_cache.dart` — абстрактный getter/setter,
  как у `_template`. Заполнять в начале `_refreshSrsCache()` (он async, зовётся
  из `_load()` после установки `_template` и далее при обновлениях), чтобы
  снимок был свежим на каждом пересчёте кэша. `_remoteRuleSetsOf`
  (`routing_screen.dart:217-220`) и `_presetNeedsDownload` передают
  `_userVars` дальше.
- `RoutingHelpers.remoteRuleSetsOf` / `isRuleSetEnabled` /
  `presetNeedsDownload` — добавить необязательный `globalVars` и прокинуть.

Снимок в state может отстать от Settings, если глобальную переменную поменяли,
не покидая экрана Routing; для текущего шаблона это ни на что не влияет
(ref-гейтов у наборов нет), а при появлении такого гейта пересчёт случится на
следующем `_refreshSrsCache`. Зафиксировать в комментарии у поля.

### 4. Тесты

Новый файл `app/test/models/preset_rule_set_gate_test.dart` (чистые
unit-тесты, без виджетов и platform-каналов; `SelectableRule`/`WizardVar`/
`CustomRulePreset` собираются руками, как в
`rule_set_auto_updater_test.dart:172-176`). Проверить на **обоих** хелперах —
`isRuleSetEnabledFor` и `remoteRuleSetsOfPreset` (с `rule` и без):

| Случай | Ожидание |
|--------|----------|
| `#enable: ["@x"]`, var `x` bool default `true`, `varsValues: {x: "false"}` | выключен; `remoteRuleSetsOfPreset(preset, rule)` его **не содержит**; без `rule` — содержит |
| то же, `varsValues: {x: "true"}` и то же без записи в `varsValues` (дефолт) | включён, содержится |
| легаси `enabled: "@x"` при `"false"` / `"true"` | как выше |
| легаси `enabled: false` / `enabled: true` | выключен / включён |
| без гейта | включён |
| обе формы, одна из них false | выключен (and) |
| легаси `enabled: "@nope"` (переменная не объявлена) | выключен — семантика билдера, тест фиксирует смену поведения с комментарием |
| ref-var: var `r` с `ref: "resolve_enabled"`, `#enable: ["@r"]`, `globalVars: {resolve_enabled: "true"}` | включён |
| то же, `globalVars` пустой, `varsValues: {r: "true"}` | выключен — значение ref берётся из глобального словаря, не из `varsValues` (§265) |

`RoutingHelpers.presetNeedsDownload` (в `app/test/screens/` рядом с
`routing_rule_outbound_picker_test.dart`, или в том же новом файле — по
вкусу): пресет с двумя remote-наборами, один гейтом выключен и **не**
закэширован, второй закэширован → `false` (иконки ☁ нет); гейт включён →
`true`.

`_refreshSrsCache` («не гасит правило»): проверить, можно ли поднять экран
Routing в существующем харнесе `app/test/screens/routing_screen/*` без
platform-каналов и файловой системы (`RuleSetDownloader.cachedPathForPreset`
ходит в `path_provider`). Если да — один тест: правило пресета с выключенным
гейтом набора и пустым кэшем остаётся `enabled`. Если харнес требует мока
ФС/каналов, которых нет, — экранный тест не писать, а в этой спеке (раздел
«Что НЕ делаем») объяснить, почему достаточно unit-уровня: `_refreshSrsCache`
выключает правило только при `remotes.isNotEmpty && !allCached`, а `remotes`
— результат `remoteRuleSetsOfPreset`, который тестами выше покрыт.

Тесты на форматирование UI-строк не писать; ожиданий через `Future.delayed`
не делать (правило репозитория).

### 5. Документация

- `CHANGELOG.md` → `[Unreleased]` → `### Fixed`: одна запись по-русски в стиле
  соседних (что было видно пользователю, что стало, ссылка на эту спеку и
  на §531).
- Эту спеку по завершении перевести в **Done**: заполнить «Коммиты»,
  «Дата завершения», отметить пункты приёмки ✅, дописать «Что НЕ делаем»
  фактами (в т.ч. про экранный тест).
- В спеке §531 (`docs/spec/tasks/531-ru-app-list-ruleset-in-ru-preset.md`)
  в конце раздела «Замечание на будущее» добавить одну строку: «Закрыто
  задачей §534». Больше ничего в §531 не менять.
- Если `grep -rn "isRuleSetEnabledFor\|rule_set.enabled\|enabled: \"@" docs/`
  находит документ, утверждающий, что UI читает только `enabled`, — поправить
  формулировку одной строкой; новых разделов не заводить.

### 6. Файл выключенного гейтом набора — не сирота

Добавлено при ревью. После п. 2 `_refreshSrsCache` держал в `activeDiskIds`
только включённые гейтом наборы, и `pruneOrphans` удалял `.srs` набора со
снятой галкой при следующем открытии Routing. Итог «снял и вернул галку
GeoIP» — повторная закачка ~150 КБ с `raw.githubusercontent.com`, который в РФ
блокируется (риск 1 в §531). Файлы выключенного **правила** экран держит и
так (цикл по `_customRules` не пропускает `!r.enabled`), выключенный **набор**
держим так же.

Выбор вынесен в чистую функцию `RoutingHelpers.presetCachePlan(rule, preset,
{globalVars})` (`routing_screen_helpers.dart`):

- `keepCacheIds` — cacheId **всех** remote-наборов пресета
  (`remoteRuleSetsOf(preset)` без `rule`), они уходят в `activeDiskIds`;
- `required` — только включённые гейтом (`remoteRuleSetsOf(preset, rule,
  globalVars)`): по ним считаются `_srsCached`, `allCached` и выключение
  правила, как в п. 3.

Свежесть файла при возврате галки обеспечивает автообновление по TTL:
метаданные (`.meta.json`) защищены тем же cacheId.

### 7. Редактор правила: докачка при включении галки видит `#enable`

Добавлено при ревью. `CustomRuleEditController.onBoolVarToggle`
(`app/lib/screens/custom_rule_edit/edit_controller.dart`) при включении
bool-переменной докачивает наборы, которыми она управляет, но отбирал их
синтаксически — `rs['enabled'] == '@<var>'`. Наборы с `#enable` (`geoip-ru`,
`ru-apps`) он не видел: возврат галки ничего не качал, а у правила на Routing
появлялась ☁.

Отбор стал семантическим — чистый хелпер `ruleSetsEnabledByVar(preset, rule,
varName, {globalVars})` рядом с `isRuleSetEnabledFor`
(`app/lib/models/preset_rule_set.dart`): remote-наборы, у которых гейт ложен
при `varName = false` и истинен при `varName = true` (прочие переменные — как
в правиле). Обе формы гейта — через `isRuleSetEnabledFor`. Составной гейт
(`["@x", "@y"]` при `y = false`) в список не попадает: включением `x` его не
включить. Контроллер передаёт правило из текущих `varsValues` формы и свой
снимок `globalVars` (тот же, что для §265 и превью). Остальное поведение метода
— докачка при включении, откат галки при ошибке, toggle-off без закачек — не
менялось.

## Что НЕ делаем

- **Шаблон `wizard_template.json` не трогаем** — вариант (б) отвергнут.
- **Служебные vars билдера (`vpn_mode`, `proxy_*`, `rule_enable`) на путь
  скачивания не тащим.** У наборов шаблона гейтов на них нет; словарь пути
  скачивания = переменные пресета + `userVars`. Если такой гейт когда-нибудь
  появится, расширять `presetVarsMap`-вызов, а не заводить третий парсер.
- **`fragmentGateSatisfied`, `evalCond`, `enableKey` не меняем** — только
  переиспользуем.
- **Golden-эталоны не перегенерируем.** Предупреждение
  `remote rule_set "…" skipped — no cached file` пишет билдер
  (`preset_expand.dart:189-197`), а он гейт `#enable` уважал и до задачи;
  задача меняет только путь скачивания/UI. Изменившийся golden = сломан путь
  сборки (п. 1), а не повод перегенерировать.
- Контракт (`app/contract/**`, `contract.lock`), `analysis_options.yaml`,
  `pubspec.lock` — не трогаем.

По итогам реализации:

- **Экранный тест `_refreshSrsCache` не писали.** В
  `app/test/screens/routing_screen/` лежат только тесты строк правил узлов
  (`node_rule_rows_test.dart`, `node_rule_tile_test.dart`); `RoutingScreen`
  целиком не поднимает ни один тест репозитория. Экрану нужны
  `SubscriptionController`, мок канала `path_provider` (в него ходят
  `RuleSetDownloader` и `SettingsStorage`) и шаблон через `TemplateLoader` —
  такого харнеса нет. Хватает unit-уровня: `_refreshSrsCache` гасит правило
  только при `remotes.isNotEmpty && !allCached`, а `remotes` — это
  `presetCachePlan(...).required` = `remoteRuleSetsOfPreset(preset, rule,
  userVars)`, покрытый `app/test/models/preset_rule_set_gate_test.dart` по всей
  таблице п. 4, как и выбор файлов, которые держим от `pruneOrphans` (п. 6).
  Там же сверка с билдером на боевом `ru-direct`: при всех четырёх сочетаниях
  `geoip_enabled` × `apps_enabled` путь скачивания отдаёт ровно те наборы,
  которые `expandPreset` кладёт в конфиг.
- **`globalVars` у списочных хелперов — позиционный.** Dart не даёт смешать
  `[rule]` и `{globalVars}` в одной сигнатуре, поэтому у
  `remoteRuleSetsOfPreset` и `RoutingHelpers.remoteRuleSetsOf` это третий
  необязательный позиционный параметр (`remoteRuleSetsOfPreset(preset, r,
  userVars)`). У `isRuleSetEnabledFor`, `RoutingHelpers.isRuleSetEnabled` и
  `presetNeedsDownload` — именованный, как в п. 2.
- **`presetVarsMap` на ошибке required-var словарь достраивает:** у сломанной
  переменной `null`, в `error` — первая ошибка по порядку `preset.vars`.
  `expandPreset` на ошибке выходит с тем же единственным warning, что и раньше
  (оба текста проверены тестом).
- **`_refreshSrsCache` зовётся только из `_load()`**, «и далее при
  обновлениях» из п. 3 не подтвердилось: снимок `_userVars` обновляется на
  каждом открытии экрана Routing. Гейтов на переменных пресета это не касается —
  `varsValues` читаются из правила при каждом построении тайла.

## Риски

1. **Смена поведения легаси-формы при необъявленной переменной** (`true` →
   `false`). В шаблоне легаси-формы нет вовсе, у пользователей пресеты
   разворачиваются из живого шаблона (`kind: preset` + `varsValues`), своих
   `rule_set`-гейтов они не пишут — риск теоретический, зафиксирован тестом.
2. **`_userVars` — снимок.** См. п. 3; для текущего шаблона безразлично.
3. **Правило, уже выключенное старым поведением.** Пользователь, у которого
   `_refreshSrsCache` раньше погасил правило из-за отсутствующего `.srs`
   выключенного набора, увидит правило выключенным и после фикса — мы не
   включаем правила за пользователя. Он включает его сам, и теперь оно
   остаётся включённым. В CHANGELOG об этом одна фраза.
4. **Порядок в `_refreshSrsCache`.** Чтение `getAllVars()` добавляет await
   перед пересчётом; экран и так грузится асинхронно (`_load`), задержка —
   одно чтение prefs.

## Приёмка

1. ✅ `isRuleSetEnabledFor` не содержит собственного разбора `@var`; единственная
   точка семантики гейта — `fragmentGateSatisfied` + `presetVarsMap`.
2. ✅ `expandPreset` использует `presetVarsMap`; `flutter test
   test/services/builder/preset_expand_test.dart` и
   `test/builder/registry_gate_test.dart` зелёные.
3. ✅ `flutter test test/storage_migration/` зелёный, **без изменений** в
   `app/test/fixtures/storage/golden/**`.
4. ✅ Новые тесты по таблице п. 4 зелёные; `test/services/rule_set_auto_updater_test.dart`,
   `test/screens/routing_screen/`, `test/screens/routing_rule_outbound_picker_test.dart`
   зелёные.
5. ✅ `flutter analyze` (весь проект, без пути): новых issues 0 (baseline 19).
6. ✅ CHANGELOG `[Unreleased] → Fixed` пополнен; §531 получил строку «Закрыто
   задачей §534»; эта спека — Done.
7. ✅ `_refreshSrsCache` защищает от `pruneOrphans` файлы всех remote-наборов
   пресета, требует только включённые гейтом (`RoutingHelpers.presetCachePlan`,
   тест в `preset_rule_set_gate_test.dart`).
8. ✅ `onBoolVarToggle` отбирает наборы через `ruleSetsEnabledByVar`: `#enable`
   и легаси `enabled` — в списке, без гейта / гейт на другую переменную /
   составной гейт с выключенной второй переменной — нет (тесты там же);
   `flutter test test/screens/custom_rule_edit/` зелёный.
9. CI `checks` на голове `develop` после push зелёный (проверка по `head_sha`
   через `gh api`).
10. На устройстве (вне CI, после релиза): в пресете «Ru internet segment» снять
   галку «Russian apps by package» при отсутствующем
   `preset__ru-direct__ru-apps.srs` — правило остаётся включённым, иконки ☁ у
   него нет, `ru-apps` не скачивается; вернуть галку — редактор сразу качает
   набор (п. 7). Снять и вернуть галку при уже скачанном файле — файл
   остаётся в кэше, повторной закачки нет (п. 6).
