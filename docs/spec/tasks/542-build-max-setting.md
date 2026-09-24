# 542 — `lx.wg.build_max` в настройки

| Поле | Значение |
|------|----------|
| Статус | **Реализовано**. Проверено: юнит-тесты билдера, скриншот эмулятора |
| Дата | 2026-09-24 |
| Ядро | `v1.14.2-lx.1`, SPEC 097 (`lx.wg.build_max`, `0` = без потолка) |
| Связанные | §536 (была константа `build_max: 5`), §215/§272 (пороги сна), §277 (disabled вместо немого гейта), §291 (форму хранилища не мигрируем) |

## Зачем

§536 писал `build_max: 5` константой. Замер показал: бюджет разбирает и
выбранный узел (`teardown by=budget`), а ожидающие слота падают в urltest с
ошибкой. Решение владельца 24.09.2026 — вынести число в настройки, включая
`0` = без потолка.

## Что сделано

- **Storage:** top-level ключ `wg_build_max` (`int`, дефолт `5`, отсутствие
  или мусор → `5`), `SettingsStorage.getWgBuildMax` / `saveWgBuildMax`,
  config-significant (`markConfigDirty`). Ключ в `allowedTopLevelKeys` и в
  экспорте бэкапа (`_topLevelRoutingKeys`) рядом с ключами сна. Миграции нет.
- **Сборка:** `BuildSettings.wgBuildMax` (дефолт 5) → `lx.wg.build_max`.
  `0` пишется как `0` (KERNEL.md: SPEC 097, `0` = no cap). Ключ живёт в той же
  ветке, что `idle_suspend`: нет порога сна — нет блока `lx`. `lazy_build: true`
  остаётся константой `kLxWgLazyBuild`, `kLxWgBuildMax` удалена.
- **UI:** VPN Settings → System, раздел «WireGuard connections» (он уже был,
  §272), под «Suspend active-route tunnels» — «Built tunnels limit», выпадающий
  список `0 (no limit)` / 3 / 5 / 8 / 12. Строка гаснет (`dimmedWhenDisabled`,
  `onChanged: null`), пока «Suspend idle tunnels» = Off: ядро не примет
  `build_max` без `idle_suspend`. Смена → снэкбар «Applies on next connect.».
- Строки ru/zh добавлены в `assets/l10n/*/ui.json`.

## Отклонение от ТЗ

«Tunnel sleep mode» (`BackgroundMode`, пауза всего VPN при Doze/выключенном
экране) под WireGuard не перенесён: к WG-туннелям настройка отношения не имеет,
под заголовком WireGuard читалась бы неверно. Раздел WireGuard уже существовал
под именем «WireGuard connections» — заголовок не переименовывался (тексты не
меняем).

## Проверка

- `app/test/builder/build_config_test.dart`: настройка 0 → `build_max: 0`,
  настройка 8 → `8`, сон выключен → блока `lx` нет; старый кейс дефолта 5.
- Golden `test/fixtures/storage/golden/*.config*.json` не меняются: фикстуры без
  `wg_build_max` → дефолт 5, как у константы.
