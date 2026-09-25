# 555 — язык шаблона: паритет с решениями лаунчера по SPEC 143 (сплайс, `options_open`, `@runtime.*`, коды с параметрами)

| Поле | Значение |
|------|----------|
| Статус | Сделано (пункты 1–6); UI мультивыбора и свободного ввода — follow-up |
| Дата старта | 2026-09-25 |
| Дата завершения | 2026-09-26 |
| Коммиты | ac3fd07b (движок: сплайс, `runtime.*`, `options_open`, накопитель), 257b0e1d (гейты `template_fragment_dropped`, отчёт сборки), docs — см. историю ветки task-555 |
| Связанные spec'ы | §120 (движок шаблона), §033 (пресеты), §103 (`#if` в массиве); лаунчер SPEC 143 §7, §3.2 |

## Проблема

Лаунчер (desktop) переводит сборку конфига на канонический обходчик и
закрепляет решения владельца по языку шаблона (SPEC 143, 25.09.2026).
Один шаблон обязан давать одинаковый конфиг на обеих платформах. Сверка
Dart-движка показала четыре расхождения; остальное совпадает.

Источник норм: `app/contract/docs/TEMPLATE_LANG.md` после 1.1.68 (§2.1, §2.2,
§3, §4.4, §5.2, §7.2) и `contract/TASKS_LXBOX.md` §64. Решения владельца
приняты через лаунчер, не переподтверждать.

## Диагностика

| № | Норма SPEC 143 | Dart сегодня | Вердикт |
|---|---|---|---|
| 1 | Массив-ветка `{"#if": {…, "value": [..]}}` в элементе массива вливается на один уровень; `[[..]]` даёт вложение; литерал и `text_list` не различаются | `_walkList` (`if_engine.dart`, около :283) делает `out.add(taken)` — массив вкладывается | правка |
| 2 | Нет коллапса `["@name"]` в скаляр | коллапса нет; голая `text_list`-ссылка в элементе сплайсится (Т6) | совпадает |
| 3 | `type` и `options` ортогональны; объектная форма `options` не меняет `type`; новый флаг `options_open`; `enum` = `text` + закрытые `options`; `text_list` + `options` = мультивыбор; каст только по `type` | `parser_config.dart` ~:469–517, 585–593 и `coerceVarValue` уже так; хардкод-списков имён нет; `options_open` отсутствует | грамматика: правка |
| 4 | `@runtime.platform/arch/target` в позиции значения: на mobile unresolved → Dropped ключа/элемента; в предикате `false`; неизвестное поле после `@runtime.` → `template_var_undeclared {name}` + плейсхолдер | `walk()` ~:141 трактует как необъявленное имя → плейсхолдер утекает в конфиг; предикат `false` случайно, общим путём | правка |
| 5 | Предупреждения с параметрами `template_var_undeclared {name}`, `template_unknown_directive {key}`, `template_int_clamped {name,value}`, `template_int_invalid {name,value}`; дедуп по (код, параметры); показ в итоге сборки, сохранение не блокируют | два кода, `templateWarnVarUndeclared` не ставится; callback `void Function(String)` без параметров и дедупа; подключён только в тесте корпуса | не реализовано |
| 6 | Телу пресета видны все переменные шаблона; пустое → Dropped ключа; фрагмент без обязательных полей выпадает с кодом | `presetVarsMap` (`preset_expand.dart` ~:649–710) и гейты rule/dns_rule/rule_set есть; DNS-сервер без адреса — проверить; коды на выпадение не ставятся | совпадает, кроме кодов |
| 7 | Новые фикстуры корпуса | тест `template_contract_test.dart` ~:250 подхватывает дерево автоматически | без правок |

## Решение

Волна одного Opus-исполнителя в worktree `task-555`, после выхода контракта
1.1.68 и синка `app/contract` (только `git archive`, см. память по контракту).

1. **Сплайс** — `_walkList`: если результат ветки `List`, `out.addAll`,
   иначе `out.add`. Никаких проверок типа переменной. `[[..]]` тогда даёт один
   вложенный элемент само собой. Обновить комментарий про паритет с Go.
2. **Грамматика `options`** — `parser_config.dart`: поле `options_open: bool`
   (по умолчанию `false`); при `true` значение вне списка допускается и
   проходит `coerceVarValue` по `type`. `text_list` + `options` — принимается
   как список выбранных значений из `options` (плюс свои при `options_open`).
   UI-редактор мультивыбора и свободного ввода — отдельная подзадача, здесь
   только модель, разбор и каст; `var_values_model.dart` не должен ломаться
   на таких объявлениях.
3. **`@runtime.*`** — резервированный неймспейс в резолвере: имена
   `runtime.platform`, `runtime.arch`, `runtime.target` на mobile считаются
   объявленными со значением `null` → `Dropped.instance`; в предикате →
   `false` явно, не через общий путь. Прочее `runtime.<x>` →
   `template_var_undeclared {name}` и плейсхолдер как есть. Ни одно значение
   `@runtime.*` не должно попасть в итоговый JSON.
4. **Предупреждения** — тип `TemplateWarning {code, params}`, накопитель с
   дедупом по (код, params); ставятся: `template_var_undeclared` при
   необъявленном имени в значении/предикате, `template_unknown_directive`,
   `template_int_clamped` и `template_int_invalid` из `coerceVarValue`, код на
   выпадение фрагмента из гейтов `preset_expand.dart` (имя кода — по
   `warnings.json` контракта 1.1.68, свой не выдумывать). Поток доводится до
   пользователя в итоге сборки (экран/лента, где сегодня показывается результат
   `build_config`), сохранение не блокирует. Формат корпуса не меняется:
   тест сравнивает список кодов без параметров.
5. **Гейт DNS-сервера без адреса** — если в `preset_expand.dart` нет,
   добавить по образцу гейта `dns_rule`, с кодом.
6. Документация: `docs/spec/features/120 …/spec.md` — параграф «нормы 1.1.68»
   со ссылкой сюда; `CHANGELOG.md` — строка в Unreleased.

## Риски и edge cases

- Существующие шаблоны, где автор рассчитывал на вложение массива в ветке
  `#if` (сегодняшнее поведение Dart): после правки станут плоскими. Проверить
  встроенные шаблоны и пресеты `grep -rn '"value": \[' app/assets` на
  массив-ветки в позиции элемента.
- Утечка `"@runtime.platform"` в конфиг сегодня возможна; после правки ключ
  выпадает — шаблоны, где это было единственное значение обязательного поля,
  теперь отбраковываются гейтом с кодом. Это желаемое поведение.
- `options_open` не должен менять поведение существующих объявлений без флага.
- Дедуп предупреждений — по параметрам тоже: два разных необъявленных имени —
  две записи.

## Верификация

**Результат (2026-09-26).** `test/contract/template_contract_test.dart` —
118/118 зелёные, включая `array_element/literal_array_branch_splices`,
`array_element/double_brackets_nest`, `array_element/text_list_branch_splices`.
`test/builder/if_engine_test.dart` — 53/53, новый интеграционный тест группы
«§555»: `@runtime.platform`/`arch`/`target` дают Dropped и не попадают в JSON,
`@runtime.nope` дважды — одна запись `template_var_undeclared {name:
runtime.nope}`; сплайс ветки-массива и `[[..]]`. `dart analyze` по
изменённым файлам — без замечаний. Полный прогон — CI.

Встроенный шаблон `app/assets/wizard_template.json`: массив-веток `#if` в
позиции элемента нет (скрипт обхода JSON + `grep '"value": \['` по
`app/assets` — единственное попадание в реестре wireguard, не шаблон);
поведение встроенных пресетов сплайс не меняет.

**Что сделано по пунктам.**
1. `_walkList`: `List`-результат ветки — `addAll`, иначе `add`; голая
   `@ref` в элементе идёт через `walk` (Dropped выпадает, `runtime.*` тоже).
2. `WizardVar.optionsOpen` (`options_open`), `acceptsValue` для UI;
   `coerceVarValue` по-прежнему только по `type`.
3. `_resolveRef`: известные поля `runtime.*` → Dropped, в предикате `false`
   явно; неизвестные → `template_var_undeclared {name}` + плейсхолдер;
   валидатор предикатов пропускает известные `runtime.*`.
4. `TemplateWarning {code, params}`, `TemplateWarnings` (дедуп по
   (код, params)), сбор через зону (`collectTemplateWarnings`) вместо
   глобального `onTemplateWarning`; `int_clamped`/`int_invalid` с
   `{name, value}` из `coerceVarValue`, `unknown_directive {key}`.
   `buildConfig` идёт в зоне накопителя, `BuildResult.templateWarnings`,
   EN-строки (заголовок реестра) первыми в `emitWarnings` → AppLog;
   сохранение не блокируют.
5. Гейты `preset_expand.dart` с кодом `template_fragment_dropped {owner,
   kind, reason}`: `route.rules` без `outbound/action`, `dns.rules` без
   `server/action`, правило без `rule_set` после чистки ссылок (оба вида),
   `route.rule_set` без источника по `type` (`url`/`path`/`rules`,
   нераспознанный тип — `url/path`), новый гейт `dns.servers` адресного типа
   без `server` — у пресетных (`expandPreset`) и шаблонных
   (`resolveDnsServersBodies`, owner — тег) серверов.
6. `features/120 …/spec.md` — параграф «Нормы контракта 1.1.68–1.1.70»,
   строка в `CHANGELOG.md`.

- Один затронутый тест: `app/test/contract/template_contract_test.dart` на
  новых фикстурах 1.1.68 (`array_element/literal_array_branch_splices`,
  `array_element/double_brackets_nest`, `array_element/text_list_branch_splices`,
  `subst/single_element_array_keeps_array`, `subst/text_list_in_value_position`,
  `types/int_with_options_stays_int`, `types/options_open_custom_value`,
  `unresolved/preset_body_declares_all_template_vars`). Фикстура `@runtime.*`
  в значениях — desktop-расширение, на mobile пропускается по README корпуса.
- Один интеграционный тест на волну: `@runtime.platform` в значении даёт
  Dropped и не попадает в JSON, а предупреждение с параметрами доходит до
  накопителя один раз при двух вхождениях.
- Полный прогон — только CI, дежурный Sonnet.

## Нерешённое / follow-up

- Отдельной UI-поверхности для `template_degraded` (снекбар/лента на Home)
  нет: записи идут первыми в `emitWarnings` → AppLog, как весь отчёт сборки
  сегодня. Новый видимый экран — по решению владельца (UI молча не меняем).
- Строковые предупреждения пресетов «rule skipped — references missing
  rule_set (download SRS first)» оставлены рядом с кодом: они несут подсказку
  про скачивание SRS, которой в коде нет.
- Шаблонные DNS-серверы видят только свои `vars` (§441), не все переменные
  шаблона, как на desktop; необъявленное имя в их теле по-прежнему даёт
  Dropped ключа + строковое предупреждение §441. Расхождение с §66 — вынести
  отдельной задачей, если лаунчер потребует.
- Гейт «правило без условий» реализован как выпадение правила, у которого
  после чистки ссылок не осталось ни одного `rule_set` (reason `rule_set`);
  общий критерий «нет ни одного поля-условия» без списка полей sing-box не
  выразим — при необходимости уточнить у лаунчера (`isRuleEmpty`).

- UI мультивыбора (`text_list` + `options`) и свободного ввода
  (`options_open`) в редакторе переменных — отдельная задача после этой.
- Формулировка про `runtime.*` на mobile («объявлено, null» → Dropped)
  зафиксирована лаунчером в §64 и TEMPLATE_LANG §7.2 — закрыто.
- Способ синка контракта: LxBox на 1.1.56, шаблонный материал в 1.1.68–1.1.70;
  между ними §53–§63 (примитивы реестра, 69 файлов корпуса) в LxBox не сделаны.
  Вариант 1 — точечно положить в gitignored `app/contract` только
  `docs/TEMPLATE_LANG.md`, `registry/vars.json`, `registry/warnings.json`
  (коды шаблона) и `corpus/template`, зеркало и lock не трогать, полный бамп
  отдельной волной. Вариант 2 — полный синк 1.1.70 и задача поверх. Решает
  владелец.
