# tool/l10n — l10n guard-rails (§279)

Все команды запускаются из `app/`. CI гоняет их в job `checks`
(`.github/workflows/ci.yml`, шаг «L10n checks») — **с Phase 7 все четыре
checker'а идут с `--strict` на каждом push/PR** (warnings фатальны:
протухший `src`-hash, непереведённый ru-ключ, orphan-ключ ARB). Прежний
двухступенчатый режим («warnings на PR, fail на tag») удалён.

```
dart run tool/l10n/template_check.dart [--strict] [--write-en] [--accept <tag>:<key>]
dart run tool/l10n/arb_check.dart [--strict]
dart run tool/l10n/hardcoded_check.dart [--strict] [--write-baseline]
dart run tool/l10n/kotlin_check.dart [--strict]
```

- **template_check**: `assets/l10n/template/en.json` — генерируемое зеркало
  display-строк шаблона, обязано быть byte-equal свежей экстракции;
  регенерация — `--write-en`. В ru.json каждая запись несёт `src` — первые
  8 hex sha256 английского значения. Изменился en-текст → ключ протухает;
  после пересмотра перевода принять новый hash: `--accept ru:<key>`.
- **hardcoded_check**: ratchet. `hardcoded_baseline.json` — grandfathered-сайты
  (hash канонизирован: `${...}` → `{}`); **с Phase 7 baseline пуст** — любой
  новый hardcoded display-литерал fail'ит CI. Скан рекурсивно спускается в
  ветки ternary/switch-expression в display-позициях (каждая строковая ветка —
  самостоятельный сайт). Логика скана — `src/hardcoded_scan.dart`, покрыта
  self-тестом `test/tool/hardcoded_scan_test.dart`. Правка текста
  существующего литерала (hotfix) легальна, пока счётчик сайтов файла не
  растёт — `--write-baseline`. Точечное исключение:
  `// l10n-exempt: <причина>` на строке литерала или строкой выше.
- Snack/dialog-хелперы с display-параметрами регистрируются в
  `l10n_helpers.json` — незарегистрированный хелпер = дыра в ratchet.
- **kotlin_check**: grep-tier гвард нативных строк Android (Phase 6, CI —
  безусловный `--strict`): литералы в notification/toast/shortcut/tile/
  stopAndAlert-вызовах и `android:label` без `@string` — находка (wire-префикс
  `alert:` исключён); + parity `values/strings.xml` ↔ `values-ru/strings.xml`
  (перевод каждого translatable-ключа, orphan-ключи, наборы
  `%n$s`-placeholder'ов).
- **hardcoded_check — rendering-locality (Phase 4, fail-режим)**: `.render(`
  легален в `lib/screens|lib/widgets` или в функции с
  `AppLocalizations`-параметром; `renderEn(` — только в allowlist-файлах
  machine-поверхностей (`render_allowlist.json`: automation, Debug API,
  AppLog-сайты, notification-push, emitWarnings); `L10n.current` вне
  allowlist → fail; прямой `L10n.en` вне `lib/models/ui_msg.dart` → fail;
  паттерн «поле `WizardTemplate?` + присваивание в initState» → fail
  (fetch шаблона — в `didChangeDependencies`, решение 15 спеки).
