# 447 — находки проверки v2.24.0 на эмуляторе

| Поле | Значение |
|------|----------|
| Статус | **Исправлено в ветке `wave-446-fixes`**, юнит- и widget-тесты. Device-verify НЕ проводился |
| Дата | 2026-09-15 |
| Повод | Проверка выпущенной v2.24.0 на AVD `LxBox_test` |
| Связанные | [§417](../features/417%20workspaces/spec.md) (Workspaces), §076/§113 (признак грязного конфига), [§225](225-raw-json-routing-rule.md) (JSON-правило), [§413](413-backup-replace-keeps-debug-api.md) (перенос ключей при полной замене) |

## 1. Загрузка слота Workspaces не пересобирала конфиг

**Симптом.** Home → Work через переключатель, затем `POST /action/start-vpn`:
в логе `bootstrap: … dirty=false`, `/config` отдаёт конфиг Home, ядро держит
19 тегов Home вместо 64 у Work. Обратно Work → Home — то же.

**Причина.** Признаком «конфиг устарел» после загрузки был только mtime
(§417 §2.3 шаг 8: `setLastModified(now)` на файл настроек), а
`SubscriptionController.init` выводил `configDirty` из сравнения mtime с
точностью до секунды (`ConfigDirtyCheck.isDirty`). Признак гасили два места:

- `SettingsStorage.flushToDisk()` перед загрузкой — `_save()` при снятом флаге
  выравнивает mtime конфига по настройкам (`touchConfig`). Копирование слота
  занимает десятки миллисекунд, touch настроек попадает в ту же секунду →
  после округления mtime равны → «чисто». В юнит-тесте воспроизводится на
  каждом прогоне (загрузка ~80 мс).
- любой `_save()` между загрузкой и bootstrap'ом нового `HomeScreen`
  (шаги перечитывания, миграция формы §439, фоновые писатели): флаг в памяти
  снят, `_save()` снова выравнивает mtime конфига.

Миграция слота в `_load()` (§439) к причине не относится: при поднятом признаке
она mtime не трогает, а обратная загрузка Work → Home ломалась без миграции.

**Было ли в 2.23.2.** Да. Код цикла (`flushToDisk` → `load` → `_touchSettings`,
`touchConfig` в `_save`, mtime-вывод в `init`) не менялся с §417
(`9c482774`, 04.09). Тот же тест на `git worktree` тега v2.23.2 даёт
`dirty=false` после загрузки.

**Фикс.** Явный признак вместо mtime:

- `WorkspaceController.load` после успешной `WorkspaceStore.load` и ДО
  перечитывания ставит `SettingsStorage.markConfigDirty()`. При поднятом флаге
  `_save()` mtime конфига не выравнивает;
- `main()` после доведённой `WorkspaceStore.recover()` делает то же;
- `SubscriptionController.init` не опускает флаг, поднятый в этом процессе:
  mtime-сравнение работает, только если флаг снят (холодный старт).

Дальше штатная воронка: bootstrap нового `HomeScreen` видит `dirty=true` →
`_rebuildAndClearDirty(silent: true)` → если VPN был поднят, старт после
пересборки; при живом туннеле срабатывает §338/«config changed». Touch
настроек в `WorkspaceStore` остался — он страхует убийство процесса между
загрузкой и пересборкой (флаг в памяти не переживает kill).

**Тест.** `test/services/workspace_config_dirty_test.dart`: загрузка слота →
флаг поднят → запись настроек до bootstrap'а его не гасит → `init` сохраняет →
`generateConfig` собирает узел, который есть только в загруженном слоте.

## 2. Save в AppBar редактора правила обходил проверку JSON

**Симптом.** Кнопка Save формы блокировалась на невалидном теле
(`params_tab.dart`), Save в AppBar и Save из диалога несохранённых правок
вызывали `_save()` без проверки: массив сохранялся и делился на «Rule 2» и
«Rule 2 #2», `{"domain":"c.test",` уходил правилом без тела.

**Фикс.** `CustomRuleEditController.saveBlockReason` (сейчас = `jsonError`) —
одна проверка. Обе кнопки заблокированы при причине (у кнопки AppBar причина в
подсказке), `_save()` при причине не закрывает редактор и показывает её
SnackBar'ом. Текст в поле не трогается.

**Тест.** `test/screens/custom_rule_edit/app_bar_save_gate_test.dart`.

## 3. Мелкое

- Ошибка тела JSON обрезалась многоточием — `errorMaxLines: 4` в
  `json_section.dart`.
- Тайл JSON-правила в списке Routing показывал outbound-пикер со значением
  `direct`: у json-правила outbound нет, `withOutbound` — no-op, пикер ничего не
  менял. Inline-правило с reject держит пикер со значением Reject, но у json
  менять нечего, поэтому пикер скрыт, как в редакторе в json-режиме; тело с
  действием видно в подписи. Условие — `RoutingHelpers.showsOutboundPicker`,
  тест `test/screens/routing_rule_outbound_picker_test.dart`.

## 4. Replace-восстановление сбрасывало флаги стартовых промптов

**Симптом.** После `POST /backup/import` в режиме replace и холодного рестарта
заново всплывали «Add tile» и «Check for updates?».

**Причина.** UI (Backup → Replace, restore с Home) и Debug API сходятся в
`SettingsStorage.replaceRaw(merge: false)`: `vars` заменяются целиком, а
`wizard_*` в allowlist импорта нет. §413 переносил из текущего стораджа только
ключи Debug API.

**Фикс.** Перенос расширен на `SettingsStorage.startupPromptVarKeys`:
`wizard_battery_v1`, `wizard_addtile_v1`, `wizard_update_check_v1`,
`notif_perm_prompted_v1` — если во входящих `vars` ключа нет. Ответ на вопрос
об обновлениях (`auto_check_updates`) приходит из файла, повторный вопрос был
шумом. Тест — `backup_service_test.dart`.
