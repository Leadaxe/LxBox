# §641 — Экран импорта бэкапа: правда о правилах после §640

| Поле | Значение |
|------|----------|
| Тип | Дефект UI (следствие §640) |
| Статус | ТЗ, исполнитель запущен |
| Дата | 2026-10-14 |
| Связанные | §640 (файл без ключа `rules` правил не трогает; код `backup_rules_replaced`), контракт 1.1.116 / TASKS_LXBOX §113 («отдельная фраза UI для кода»), §393 B5/B6 (счётчики снека), §633 (Merge) |

## Проблема

После §640 экран импорта (`app/lib/screens/backup_screen.dart`) говорит
неправду в трёх местах:

1. Превью подтверждения (`_confirmLxImport`, `:495`) всегда заканчивается
   строкой «Importing replaces the current rules.» (`:534`) — для файла без
   ключа `rules` это ложь: правила приёмника не тронутся (§640).
2. Код `backup_rules_replaced` — warning, и снек считает его в «не
   применено»: `skipped = parsed.warnings.length` (`:446`) → «Imported N
   rule(s), 1 items not applied» (`:460`) после любого полного импорта
   поверх непустых правил, хотя всё применилось.
3. В превью тот же код стоит под заголовком «Not applied as-is:» (`:525`),
   среди реальных отказов.

## Диагностика

- `LxBackupFile.rulesDeclared` (`lx_backup.dart:685`) — признак, что ключ
  `rules` в файле есть.
- Предупреждение ставит план импорта: `lx_backup_import.dart:314`,
  `LxBackupWarning(kWarnRulesReplaced, 'rules: ${receiver.rules.length}')`,
  только при `receiver.rules.length > 0`. Константа —
  `kWarnRulesReplaced` (`lx_backup.dart:227`).
- Исполнителю установить, что именно приходит в `_confirmLxImport` и в снек:
  разобранный файл до плана или `plan.file` с `extraWarnings`. Если превью
  видит файл до плана — число правил приёмника для фразы берётся напрямую
  (`SettingsStorage.getCustomRules()`), а не из предупреждения.

## Решение

Строки — английские, окончательные (сверить с `docs/EDITORIAL_POLICY.ru.md`
8.3); `ru`/`zh` `assets/l10n/*/ui.json` дополнить.

### Превью (`_confirmLxImport`)

Последняя строка превью — по признаку файла и состоянию приёмника:

| `rulesDeclared` | Правил у приёмника | Строка |
|---|---|---|
| нет | любое | «This file has no rules. The current rules stay.» |
| да | 0 | «Importing adds the file's rules.» |
| да | N > 0 | «Importing replaces the current %d rule(s).» |

Код `backup_rules_replaced` из списка под «Not applied as-is:» убирается
(фразу о нём несёт последняя строка); если после исключения список пуст —
заголовок «Not applied as-is:» не показывается.

### Снек после импорта

- `skipped` считается без `kWarnRulesReplaced`: это не отказ, а
  состоявшаяся замена.
- Если замена была (предупреждение есть), к сообщению снека добавляется
  хвост «, replaced %d rule(s)» с `count` из предупреждения — во всех ветках
  сообщения (§393 B5/B6), формат согласовать с существующими строками.
  Пример: «Imported 3 rules, 2 directions and 1 settings, replaced 5
  rule(s)».
- Файл без ключа `rules`: `parsed.rules.length` = 0 и правила не трогались —
  в сообщении не писать «Imported 0 rule(s)»; если прочие счётчики нулевые,
  сообщение «Nothing to import: the file has no rules, directions or
  settings.» — только если такая ветка в коде отсутствует; существующие
  ветки при ненулевых счётчиках не менять.

### Что не трогать

- Полный бэкап хранения (не LX Backup): свой диалог, своя норма — без
  изменений.
- Прочие warning-коды в превью и в счётчике — как были.

## Проверка

- Существующий тест экрана импорта (найти по `backup_screen` в `app/test/
  screens`): дополнить случаями таблицы превью (три строки) и снека
  (замена без «not applied»; «replaced N» в хвосте). Новый файл — только
  если тестов экрана нет.
- `ui_check`/`hardcoded_check` 0/0; `ru`/`zh` строки добавлены.
- Линты CI: `use_null_aware_elements`, `no_leading_underscores_for_local_identifiers`.

## Документация

- `docs/spec/features/017-BACKUP_AND_STORAGE` (функция переноса/импорта,
  md + ru) — фразы превью и снека.
- `CHANGELOG.md` — одной строкой, под записью §640.
