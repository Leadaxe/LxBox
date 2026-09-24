# 542 — `lx.wg.lazy_build` и `lx.wg.build_max` в настройки

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
`0` = без потолка; дополнение владельца — `lazy_build` тоже тумблером.

## Что сделано

- **Storage:** top-level ключи `wg_lazy_build` (`bool`, дефолт `true`) и
  `wg_build_max` (`int`, дефолт `5`, отсутствие или мусор → `5`),
  `SettingsStorage.get/saveWgLazyBuild`, `get/saveWgBuildMax`,
  config-significant (`markConfigDirty`). Оба в `allowedTopLevelKeys` и в
  экспорте бэкапа (`_topLevelRoutingKeys`) рядом с ключами сна. Миграции нет.
- **Сборка:** `BuildSettings.wgLazyBuild` (дефолт true) и `wgBuildMax`
  (дефолт 5). Константы `kLxWgLazyBuild` / `kLxWgBuildMax` удалены. Оба ключа
  живут в ветке `idle_suspend`: нет порога сна — нет блока `lx`.
  `lazy_build` включён → `lazy_build: true` + `build_max: N`; `0` пишется как
  `0` (KERNEL.md: SPEC 097, `0` = no cap). `lazy_build` выключен → не пишутся
  ни `lazy_build`, ни `build_max`.
- **Почему `build_max` не пишется без `lazy_build`.** Ядро `build_max`
  принимает и без `lazy_build` (§536: ключ формально самостоятелен), но в UI
  бюджет — часть ленивой сборки и гаснет вместе с тумблером. Погашенный пункт
  не должен действовать молча (урок §277), поэтому и в конфиг он не идёт.
- **UI:** VPN Settings → System, раздел «WireGuard connections» (он уже был,
  §272), под «Suspend active-route tunnels»: тумблер «Lazy tunnel build» и
  ниже «Built tunnels limit» — выпадающий список `0 (no limit)` / 3 / 5 / 8 /
  12. Тумблер disabled, пока «Suspend idle tunnels» = Off (ядро не примет
  `lazy_build` без `idle_suspend`); лимит disabled ещё и при выключенном
  тумблере (`dimmedWhenDisabled`, `onChanged: null`). Смена → снэкбар
  «Applies on next connect.».
- Строки ru/zh добавлены в `assets/l10n/*/ui.json`.

## Отклонение от ТЗ

«Tunnel sleep mode» (`BackgroundMode`, пауза всего VPN при Doze/выключенном
экране) под WireGuard не перенесён: к WG-туннелям настройка отношения не имеет,
под заголовком WireGuard читалась бы неверно. Раздел WireGuard уже существовал
под именем «WireGuard connections» — заголовок не переименовывался (тексты не
меняем).

## Проверка

- `app/test/builder/build_config_test.dart`: настройка 0 → `build_max: 0`,
  настройка 8 → `8`, сон выключен → блока `lx` нет, lazy выключен → нет
  `lazy_build` и `build_max`; старый кейс дефолтов (true, 5).
- Golden `test/fixtures/storage/golden/*.config*.json` не меняются: фикстуры без
  `wg_lazy_build` / `wg_build_max` → дефолты true / 5, как у констант.
