# 541 — вкладка Appearance в App Settings и тумблер двух колонок

| Поле | Значение |
|------|----------|
| Статус | **Done** |
| Дата старта | 2026-09-24 |
| Дата завершения | 2026-09-24 |
| Коммиты | ветка `task-541` → `develop` |
| Связанные spec'ы | §537 (две колонки списка узлов), §220 (Allow rotation), §279 (язык), §052 (deep-links в настройки), §221 (бэкап preferences) |

---

## Зачем

Две колонки списка узлов (§537) включались безусловно при ширине ≥ 600 dp.
Решение владельца: только по галочке, галочка по умолчанию включена и живёт в
новой вкладке настроек про внешний вид.

## Решение

- App Settings: вкладки General, **Appearance**, Subscriptions, Diagnostics,
  Automation. Вкладка — `app_settings_screen/widgets/appearance_tab.dart`,
  stateless по образцу `GeneralTab`.
- Из General в Appearance перенесены: секция «Appearance» (тема), тумблер
  «Allow rotation» (стоит сразу под темой), секция «Language». Новая секция
  «Node list» с тумблером «Two columns on wide screens». Строки не менялись.
- Ключ storage `node_list_two_columns` (`'true'`/`'false'`, дефолт `true`) —
  тот же механизм `getVar`/`setVar`, что у `allow_rotation`; добавлен в
  allowlist `_appFeatureFlagVars`, поэтому едет в бэкап и restore.
- Живое значение — `SettingsStorage.nodeListTwoColumns` (`ValueNotifier<bool>`):
  сеттер обновляет его сразу, геттер синхронизирует с хранилищем; читается в
  `main()` до `runApp`. `_NodeListColumns` слушает notifier через
  `ValueListenableBuilder`, смена применяется без перезапуска.
- `nodeListColumnCount(width, isManual:, twoColumnsEnabled: true)`: две колонки
  только при `twoColumnsEnabled && !isManual && width >= 600`.
- Индексы `AppSettingsScreen(initialTab:)` сдвинуты: Subscriptions 1→2,
  Diagnostics 2→3, Automation 3→4 (debug_screen, custom_rule_edit_screen,
  wifi_saved_picker_sheet, core_logs_hint_banner, subscriptions_screen);
  support-ссылка `app-settings` получила вкладку `appearance`.

## Проверка

- `test/screens/home/node_list_two_columns_test.dart`: тумблер выключен при
  1280 dp → одна колонка, включение на лету → две; дефолт → две.
- Эмулятор `LxBox_test`: вкладка Appearance открывается, тумблер виден.

## Что осталось

- После restore бэкапа notifier подхватывает новое значение при следующем
  чтении (открытие App Settings или перезапуск).
