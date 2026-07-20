# tool/l10n — l10n guard-rails (§285)

Все команды запускаются из `app/`. CI гоняет их в job `checks`
(`.github/workflows/ci.yml`, шаг «L10n checks») — **все четыре checker'а идут
с `--strict` на каждом push/PR** (warnings фатальны: непереведённый / orphan
ключ словаря).

```
dart run tool/l10n/ui_check.dart [--strict]
dart run tool/l10n/template_check.dart [--strict]
dart run tool/l10n/hardcoded_check.dart [--strict] [--write-baseline]
dart run tool/l10n/kotlin_check.dart [--strict]
```

- **ui_check** (§285, заменил ARB-эпохи `arb_check`): AST-скан `lib/` собирает
  все обращения к локализатору (`getLocalText.s/.plural`, `t`/`loc`-параметры
  `renderWith`/`messageWith`, `GetLocalText.en`) и сверяет с natural-key
  словарём `assets/l10n/ru/ui.json`:
  - **missing** — ключ из кода отсутствует в словаре (warn, strict→fail);
  - **orphan** — ключ словаря не встречается в коде (warn, strict→fail);
  - **orphan-special** — форма `special["N"]` определена, но код не зовёт её
    с индексом N (warn, strict→fail);
  - **usage-conflict** — один ключ зовут и `.s`, и `.plural` (fail всегда);
  - **shape** — `.s`-ключ с plural-объектом-значением, или `.plural`-ключ без
    полного набора форм resolver'а (`RuPluralResolver.forms` = one/few/many/
    other), или использованный индекс формы N отсутствует в словаре
    (fail всегда);
  - **arity** — набор printf-плейсхолдеров (`%s`/`%d`/`%K$s`; `%%` литерал) в
    ключе ≠ набору в переводе/каждой plural-форме (fail всегда).

  Динамические (не-литеральные) ключи `getLocalText.s(var)` валидировать
  нельзя — только считаются. Логика скана+валидации — `src/ui_scan.dart`
  (чистая, без `dart:io`), покрыта self-тестом `test/tool/ui_check_test.dart`.
- **template_check**: overlay-файлы `assets/l10n/<tag>/template.json` — тот же
  shape, что ui/-словарь: `{ "<english>": { "value": "<перевод>" } }`. Отдельного
  `en.json` нет — английский базовый и живёт в самом `wizard_template.json`
  (он же fallback); checker извлекает display-строки через `TemplateOverlay.extract`
  и сверяет с ними каждый overlay. Неизвестный ключ (english-текст не извлекается
  из шаблона) / пустой value / value с `@`-префиксом или `{` — fail;
  непереведённый english-ключ — warn (strict→fail).
- **hardcoded_check**: ratchet. `hardcoded_baseline.json` — grandfathered-сайты
  (hash канонизирован: `${...}` → `{}`); **baseline пуст** — любой новый
  hardcoded display-литерал fail'ит CI. `Text(getLocalText.s("..."))` легален
  (литерал — аргумент getLocalText, не прямой аргумент `Text`). Скан рекурсивно
  спускается в ветки ternary/switch-expression в display-позициях (каждая
  строковая ветка — самостоятельный сайт). Логика скана —
  `src/hardcoded_scan.dart`, покрыта self-тестом
  `test/tool/hardcoded_scan_test.dart`. Правка текста существующего литерала
  (hotfix) легальна, пока счётчик сайтов файла не растёт — `--write-baseline`.
  Точечное исключение: `// l10n-exempt: <причина>` на строке литерала или
  строкой выше.
- Snack/dialog-хелперы с display-параметрами регистрируются в
  `l10n_helpers.json` — незарегистрированный хелпер = дыра в ratchet.
- **kotlin_check**: grep-tier гвард нативных строк Android (CI — безусловный
  `--strict`): литералы в notification/toast/shortcut/tile/stopAndAlert-вызовах
  и `android:label` без `@string` — находка (wire-префикс `alert:` исключён);
  + parity `values/strings.xml` ↔ `values-ru/strings.xml` (перевод каждого
  translatable-ключа, orphan-ключи, наборы `%n$s`-placeholder'ов).
- **hardcoded_check — rendering-locality (§285, fail-режим)**: `renderEn(` —
  только в модельных иерархиях `lib/models/*` (где он определён) и в
  allowlist-файлах machine-поверхностей (`render_allowlist.json`: automation,
  Debug API, build_config, home/subscription-контроллеры, home_screen); прямой
  `GetLocalText.en` вне `lib/models/*` → fail (идти через `renderEn()`); паттерн
  «поле `WizardTemplate?` + присваивание в initState» → fail (fetch шаблона — в
  `didChangeDependencies`, решение 15 спеки). `.render()` (UiMsg → String через
  ambient `getLocalText` активной локали) больше **не** гейтится по каталогу —
  он не требует BuildContext и безопасен из сервисов/контроллеров.
