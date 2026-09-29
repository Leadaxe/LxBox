[English](desktop-transfer.md) · [Русский](desktop-transfer.ru.md)

# Перенос на десктоп (LX Backup)

| Поле | Значение |
|------|----------|
| Фича | [017-BACKUP_AND_STORAGE](../FEATURE.ru.md) |
| Обещания | P10–P16, P25 |
| Состояние | ✅ написана по коду, 2026-09-28 |

## Что делает

Карточка «Transfer to desktop» на экране Backup & restore переносит общую
часть настроек между телефоном и десктопным лаунчером: подписки, серверы,
папки, цепочки, Направления, правила, DNS, переносимые переменные,
`route.final`, регистрации WARP. Формат — LX Backup контракта 1.0; чему у
другой стороны нет места, то отбрасывается и называется («Anything the other
side has no place for is dropped, and the app tells you exactly what did not
make it.»). Полной копии эта карточка не заменяет.

## Параметры

| Что | Значение |
|-----|----------|
| Имя файла экспорта | `lx-backup.json` |
| Версия записи | `lx_backup: 2` (контракт 1.0) |
| Версии чтения | `1` (семейство 0.x) и `2`; больше — отказ «обновите приложение»; не число / нет поля — «не файл LX Backup» |
| Переносимые переменные | `auto_detect_interface`, `dns_cache_capacity`, `dns_default_domain_resolver`, `dns_final`, `dns_optimistic`, `dns_store_cache`, `dns_strategy`, `ipv6_enabled`, `log_level`, `resolve_strategy`, `tls_fragment`, `tls_fragment_fallback_delay`, `tls_mixed_case_sni`, `tls_record_fragment`, `tun_address`, `tun_address6`, `tun_mtu`, `tun_stack`, `urltest_interval`, `urltest_tolerance`, `urltest_url` — зеркало реестра контракта |
| Способ сохранения | тот же лист, что у полной копии |

## Входы / Выходы

**Входы:** текущие настройки (экспорт); файл LX Backup 1.0 или 0.x
(импорт); подтверждение превью.

**Выходы:** файл `{lx_backup, exported_by{app, version}, exported_at,
sources[], directions[], rules[], dns{}, vars{}, route{final}, warp[]}`;
при потерях экспорта — диалог «Not included in the file» («These settings
have no place in the shared format:»). Превью импорта «Import backup»:
«From <app> <version>», счётчики Directions / Chains / Rules / Subscriptions
/ Servers / Variables / DNS entries / WARP accounts, список «Not applied
as-is:» и строка «Importing replaces the current rules.». Итог — «Imported N
rules, M directions and K settings» (варианты) с «; chains: N» или «Imported
N rule(s), M items not applied».

## Правила и инварианты

- **Экспорт:** записи источников — та же форма, что в хранении, со срезом
  по таблице полей контракта; поля LxBox без дома в 1.0 названы
  `backup_local_only_dropped` одним предупреждением на запись; отметки
  выключенных узлов едут, вердикт ядра — нет (P16).
- **Слияние источников:** подписка — по URL; папка — по `id`, затем по
  имени среди прежних; узел — по телу (две тёзки — две папки). Повторный
  импорт ничего не добавляет (P11). Совпавшая папка берёт настройки файла,
  но держит свой `id` и имя.
- **Направления и цепочки:** занятый тег — приехавшее не применяется
  (`backup_direction_exists`, `backup_chain_exists`), своё остаётся (P13).
- **Правила:** замещают правила приёмника; порядок — по номерам файла.
  Цель правила сверяется после слияния источников и Направлений: неизвестная
  цель — правило выключено (`backup_unknown_outbound`); `route.final` в
  никуда — не применяется (`backup_final_dropped`) (P14). Чужой пресет
  приезжает выключенным (`backup_unknown_preset`).
- **DNS** — слиянием; запись без места — `backup_dns_entry_skipped`.
- **Переменные:** только переносимые; прочие — `backup_var_skipped` с
  причиной (`not_portable`, `undeclared`, `superseded`, `no_record`) (P15).
- **WARP:** регистрация применяется, только если своей нет; неразобранная —
  `backup_warp_skipped`.
- **Незнакомое названо:** поле записи — `backup_unknown_field`, поле чужого
  типа — `backup_field_type_mismatch`, вид записи без места —
  `backup_source_kind_unsupported`, упрощённая группа —
  `backup_group_degraded`, секции узла — `backup_section_record_dropped`
  (P12). Файл при этом читается.
- План импорта считается один раз для превью и **заново** в момент записи —
  по свежему состоянию (фоновое обновление подписок между превью и
  подтверждением не затирается) (P25).
- Все секции пишутся в память и одной записью на диск в конце: прерывание
  не оставляет половину настроек.

## Границы

- Полная копия этой карточкой не читается и не пишется —
  [восстановление полной копии](full-backup-restore.ru.md).
- Настройки приложения, отладка, тумблеры VPN, раздельное туннелирование —
  не переносятся (local-only).
- Выбора отдельных секций на импорте нет.
- Нормы формата — контракт с лаунчером (`docs/contract/`); здесь — поведение
  LxBox как стороны контракта.

## Ревизии

| # | Ревизия | Статус | Суть |
|---|---------|--------|------|
| 1 | [393F](../../../tasks/393F-directions/spec.md) | Released v2.21.0 | Направления, цепочки, DNS, WARP, `route.final` в переносе; коды занятых тегов |
| 2 | [401](../../../tasks/401-backup-state-serialization.md) | DEVICE-VERIFIED | Бэкап = сериализация состояния; карман провоза упразднён, потери названы |
| 3 | [406](../../../tasks/406-import-canonical-body-case-sensitive-tags.md) | Done | Канон тела узла, регистрозависимые теги |
| 4 | [407](../../../tasks/407-backup-corpus-pre-state-merge.md) | Done | Корпус: предсостояние кейса и прогон слияния |
| 5 | [409](../../../tasks/409-direction-ping-options-backup.md) | Done | Бюджет теста узла Направлений в переносе |
| 6 | [438](../../../tasks/438-lx-backup-1-0-read-write.md) | Released v2.24.0 | Запись 1.0, чтение 1.0 и 0.x, отказ новее |
| 7 | [439F](../../../tasks/439F-storage-contract-1-0/spec.md) | Released v2.24.0 | Переводчик удалён: файл и хранение — одна форма записей |
| 8 | [441](../../../tasks/441-template-preset-vars-in-record.md) | Released v2.24.0 | Переменные шаблонных DNS-серверов и пресетов в записи |
| 9 | [489](../../../tasks/489-core-reject-verdict-not-backup.md) | Released v2.25.0 | Вердикт страховки не едет в бэкап |
| 10 | [511](../../../tasks/511-ui-review-findings-after-v2251.md) | Released v2.25.2 | Порядок заведённых записей в `sources[]` как в файле |
