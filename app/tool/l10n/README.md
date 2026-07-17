# tool/l10n — l10n guard-rails (§279)

Все команды запускаются из `app/`. CI гоняет их в job `checks`
(`.github/workflows/ci.yml`, шаг «L10n checks»); на tag-билдах template/arb
получают `--strict` (warnings становятся фатальными).

```
dart run tool/l10n/template_check.dart [--strict] [--write-en] [--accept <tag>:<key>]
dart run tool/l10n/arb_check.dart [--strict]
dart run tool/l10n/hardcoded_check.dart [--write-baseline]
dart run tool/l10n/kotlin_check.dart [--strict]   # report-only до Phase 6
```

- **template_check**: `assets/l10n/template/en.json` — генерируемое зеркало
  display-строк шаблона, обязано быть byte-equal свежей экстракции;
  регенерация — `--write-en`. В ru.json каждая запись несёт `src` — первые
  8 hex sha256 английского значения. Изменился en-текст → ключ протухает;
  после пересмотра перевода принять новый hash: `--accept ru:<key>`.
- **hardcoded_check**: ratchet. `hardcoded_baseline.json` — grandfathered-сайты
  (hash канонизирован: `${...}` → `{}`). Новый сайт → fail; удалённые сайты
  сужают baseline (`--write-baseline`); правка текста существующего литерала
  (hotfix) легальна, пока счётчик сайтов файла не растёт — тоже
  `--write-baseline`. Точечное исключение: `// l10n-exempt: <причина>` на
  строке литерала или строкой выше.
- Snack/dialog-хелперы с display-параметрами регистрируются в
  `l10n_helpers.json` — незарегистрированный хелпер = дыра в ratchet.
