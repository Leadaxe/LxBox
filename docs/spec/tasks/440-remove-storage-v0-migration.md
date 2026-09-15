# 440 — Техдолг: удалить миграцию хранения 2.23.2 и `.v0.bak`

| Поле | Значение |
|------|----------|
| Статус | Backlog — техдолг. Решение владельца 15.09.2026: удалить через несколько дней после выпуска 2.24.0 (номер 2.23.3 до решения о minor) |
| Дата | 2026-09-15 |
| Связанные | [§439](../features/439%20storage-contract-1-0/spec.md) §3 (миграция), §3.5 (откат), §2.2 (legacy-читатели); прецедент — [§229](229-remove-preset-id-migration.md) |

## Что удалить

- `app/lib/services/storage_migration/legacy_form_v0.dart` — замороженные
  читатели формы 2.23.2.
- Шаги формы 2.23.2 в `migrate_storage.dart`: v0 → записи 1.0, мёртвые
  ключи, `channels` → `directions`, деление json-массива, `presetId` по
  карте шаблона. Также `migrate_node_links.dart` (финальные строки →
  NodeLink) и `legacy_autogroup.dart` (`autogroup://` → `kind: auto`).
- Подключения миграции:
  - `_load()`/`_replaceRaw` в `settings_storage/io.dart`;
  - `BackupContents` и `applyImport` в `backup_service.dart`;
  - Debug `POST /backup/import` (`applied.migrated`);
  - `WorkspaceStore._performLoad` (копия `.v0.bak` слота).
- Копия `lxbox_settings.json.v0.bak`: запись, `SettingsStorage.exportV0Backup`,
  Debug `GET /backup/export?include=storage&from=v0_bak`.
- `SettingsStorage.subscriptionBodiesForMigration`,
  `presetIdsForMigration`.
- Терпимое чтение dev-форм, которых нет ни в одном выпуске:
  - двойной префикс preset-ref DNS (`ru-direct:ru-direct:x`);
  - `members_rule`/`pool_badge` на уровне узла autogroup.
- Чтение файла правил `format: 1` через legacy-читатели.
- Тесты и фикстуры миграции: `test/storage_migration/migrate_*`,
  `workspace_legacy_slot_load_test`, `backup_service_legacy_test`,
  `backup_import_legacy_test`, `legacy_dns_reader_test`. Golden-фикстуры
  `rich_v0`/`avd_v0` в форме 2.23.2 перевести в форму 1.0 или снять вместе с
  golden-тестами миграции.
- Доки: `docs/STORAGE.md` (раздел миграции, `.v0.bak`),
  `docs/api/debug-api-reference.md` (`from=v0_bak`, `applied.migrated`).

## Что остаётся

- `storage_version: 1` и проверка «версия выше известной».
- Чтение LX Backup `lx_backup: 1` (0.x) — решение владельца В3: старые
  бэкапы читаются. Это отдельный legacy-декодер в `lx_backup.dart`, не
  миграция хранения.

## Последствия, которые принимаем

- Пользователь, который обновится с 2.23.2 или старше сразу на версию без
  миграции (пропустив 2.23.3), получит пустое хранение: источники,
  цепочки, правила и DNS-записи не прочитаются.
- Внутренний бэкап (`app: lxbox`, `kind: backup`), снятый на 2.23.2 или
  раньше, перестанет восстанавливаться. LX Backup (`lx_backup: 1`)
  по-прежнему читается.
- Спящий слот Workspaces, ни разу не загруженный на 2.23.3, при загрузке
  окажется пустым.

## Когда

После выпуска 2.23.3, когда основная масса пользователей обновилась
(Google Play, F-Droid, GitHub). Точную дату назначает владелец.
