# §229 — удалить one-shot миграцию preset_id (техдолг §228)

> **СТАТУС: ЗАПЛАНИРОВАНО (не начато).** Выполнять В СЛЕДУЮЩЕМ РЕЛИЗЕ ПОСЛЕ
> того, как релиз с §228 уйдёт в прод и юзеры обновятся. НЕ раньше.

## Контекст

§228 переименовал preset_id (`bittorrent-direct`→`bittorrent`,
`private-ip-direct`→`private-ip`, `block_unknown`→`unknown-traffic`) и добавил
one-shot storage-миграцию `_migrateRenamedPresetIds`, чтобы у существующих
юзеров сохранённые в `custom_rules` правила не стали «Preset not found».

Миграция **одноразовая**: отрабатывает на первом запуске после обновления,
ставит guard `preset_ids_remapped: true` и больше не делает ничего. После того
как релиз с §228 разошёлся и юзеры обновились, их storage уже отремаплен —
код миграции становится мёртвым грузом.

## Когда выполнять

**Строго после релиза, содержащего §228**, когда разумно считать, что
подавляющее большинство активных юзеров обновились (обычно ≥1 релизный цикл).
Проверить по CHANGELOG: §228 должен быть в **предыдущем** выпущенном теге, а не
в текущей разработке. Если §228 ещё не в релизе — **не трогать**.

## Что удалить

- `app/lib/services/settings_storage/sources_rules.dart`:
  - функция `_migrateRenamedPresetIds`;
  - константа `_renamedPresetIds`.
- `app/lib/services/settings_storage.dart`:
  - static-обёртка `migrateRenamedPresetIds`.
- `app/lib/main.dart`:
  - вызов `await SettingsStorage.migrateRenamedPresetIds();` в init.
- `app/test/migration/preset_id_remap_test.dart` — удалить файл.

## Что НЕ удалять

- **Guard-ключ `preset_ids_remapped`** оставить в persisted-keys list
  (`settings_storage.dart`) — чтобы имя не переиспользовалось и старые storage
  с этим ключом не считались мусором. Пометить комментарием «§228 legacy guard,
  миграция удалена в §229; ключ сохранён для downgrade-friendliness».
- Переименованные id в шаблоне (`bittorrent`/`private-ip`/`unknown-traffic`) —
  это финальные имена, остаются.

## Риск

Единственный риск удаления — юзер, который пропустил релиз с §228 и обновляется
СРАЗУ на релиз с §229 (перепрыгнул через промежуточный). У него старые id в
storage не отремапятся → правила `bittorrent-direct`/`private-ip-direct`/
`block_unknown` станут «Preset not found» (правило показывает warning, дропается
при сборке — конфиг не падает, деградация мягкая). Приемлемо для редкого
перепрыгивания; при желании — оставить в §229 короткий комментарий-напоминание
в CHANGELOG про удалённую миграцию.

## Связано

- §228 (ввёл миграцию) — [`228-fakeip-preset.md`](228-fakeip-preset.md).
- STORAGE.md Migration history — обновить: пометить запись §228 как
  «миграция удалена в §229, guard-ключ сохранён».
