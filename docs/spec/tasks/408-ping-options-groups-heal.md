# 408 — Осиротевшие ключи `ping_options.groups`

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата старта | 2026-09-03 |
| Дата завершения | 2026-09-03 |
| Коммиты | см. ветку задачи |
| Связанные spec'ы | [tasks/040 per-group ping settings](040-per-group-ping-test-settings.md), [tasks/402](402-direction-chain-label-removed.md), [tasks/393](393-masque-config-schema-migration.md), [features/125 configurable-directions](../features/125%20configurable-directions/spec.md) |

Дыра найдена в §402 при пересчёте мест, где хранится ссылка на тег
Направления, и там же отложена отдельной задачей: она предсуществующая и от
переименования не зависит.

## Факты

`ping_options` (§040) — секция storage с настройками пинга и URLTest:

```jsonc
{
  "url":        "https://…",   // глобальный URL
  "timeout_ms": 10000,          // глобальный бюджет
  "presets":   [ … ],           // готовые URL из шаблона
  "groups": {                   // per-direction override'ы
    "<directionTag>": { "url": "…"?, "timeout_ms": <int>? }
  }
}
```

Resolve chain в `HomeController`: `groups[tag]` → корень секции → дефолт
шаблона (`pingUrlFor` / `pingTimeoutFor`,
`app/lib/controllers/home_controller/ping_orchestration.dart`).

**Ключи карты — теги Направлений.** Пишут её ровно два входа:

- диалог «Ping settings» (long-press по кнопке reload,
  `app/lib/screens/home/home_menus.dart`) — ключом кладётся
  `controller.state.selectedGroup`. Это селектор из выпадашки, а он приходит
  из `HomeState.selectorGroupTags` (`app/lib/models/home_state.dart`) —
  ТОЛЬКО группы типа `selector`. Билдер эмитит selector ровно по одному на
  Направление, с `tag == direction.tag` (`build_config.dart`), поэтому через
  UI в ключах не бывает ни цепочек (они не группы вовсе, а payload-outbound'ы),
  ни auto-двойников (`<tag>-auto` — urltest, в `selectorGroupTags` не входит);
- Debug API `PUT /settings/ping_options/groups/{tag}` и `PUT
  /settings/ping_options` целиком (`services/debug/handlers/settings.dart`) —
  тег не валидируют вовсе, кладут что дали. Тем же путём произвольный ключ
  приезжает из правленного бэкапа: `ping_options` в allowlist'е §221 и
  восстанавливается секцией целиком.

Отсюда практическое правило: **живым считается тег существующего Направления
ИЛИ его двойник `<tag>-auto`** — та же формулировка «ссылки на Направление»,
что у `_healDirectionRefs` и `_healDetourDirectionRefs` (§248).

## Что было

У четырёх остальных родов ссылки на тег Направления heal есть, и он один и тот
же по форме — при удалении Направления ссылка снимается в той же транзакции:

| Род ссылки | Где живёт | Heal |
|---|---|---|
| `route_final`, `rules[].outbound` | `route_final`, `custom_rules` | `_healDirectionRefs` → `vpn-1` |
| `override_detour`, `FolderMember.detour` | `server_lists` | `_healDetourDirectionRefs` → `''` |
| `Direction.include[]` | сам список Направлений | `clearIncludeDirectionRefs` |
| позиции цепочек | `chains` | `healChainHops` (§393 D2) |
| **`ping_options.groups[<tag>]`** | `ping_options` | **нет** |

Пятая строка heal'а не имела вовсе. Последствия:

1. запись переживала удаление Направления и лежала в storage мёртвым грузом —
   попадая заодно в бэкап и в `/state/storage`;
2. создание нового Направления с тем же тегом (`vpn-3` освобождается при
   удалении и выдаётся следующим `nextDirectionTag`) молча наследовало чужие
   URL и timeout: пользователь видит в диалоге группу-режим с посторонним
   адресом, которого никогда не задавал.

Пункт 2 — единственное, что дыра успевала сделать видимым; всё остальное
копилось тихо.

## Что стало

**Инвариант: ключами `ping_options.groups` бывают только живые теги.**

### 1. Heal при удалении

`_healPingOptionsGroupRefs(tag)`
(`app/lib/services/settings_storage/directions.dart`) снимает ключи `tag` и
`<tag>-auto`. Зовётся из `_deleteDirection` рядом с остальными heal'ами, до
общего `_save()` — та же транзакция, `flush: false`, одна запись на диск.

**Только на удалении.** Ни disable, ни снятие detour-флага override не трогают
— асимметрия та же, что у `include` (§393 A3): выключение обратимо,
Направление остаётся в списке, его строка ping-настроек осмысленна, и
включение обратно обязано вернуть ровно то, что было. Удаление необратимо
(Решение B §202) — возвращать нечему.

**Счётчика наружу heal не даёт** и в `DirectionHealResult` не входит.
Остальные четыре рода меняют МАРШРУТ — правило поехало на `vpn-1`, detour
сброшен, опция вычеркнута, хоп снят, — и про это пользователю говорят
SnackBar'ом. Ping-override — настройка ИЗМЕРЕНИЯ узлов удалённого Направления;
строка «сброшен 1 ping-override» о сущности, которой больше нет, была бы
шумом в том же SnackBar'е.

### 2. Чистка накопленных сирот

Новый heal чинит будущие удаления и не видит того, что уже лежит: у любого,
кто когда-либо удалил Направление с персональными URL/timeout, ключ в storage
до сих пор.

`_pruneOrphanPingGroups(data)` живёт **внутри `_migrateDirectionsIfNeeded`** —
во всех четырёх её ветках, после того как список Направлений в `data` приведён
к финальному виду (включая seed и `_ensureRequiredDirection`).

Почему там, а не отдельной one-shot миграцией со своим guard-ключом:

- `_migrateDirectionsIfNeeded` — ЕДИНСТВЕННАЯ точка, через которую проходят
  ВСЕ пути загрузки состава: старт (`main.dart`), restore внутреннего бэкапа
  (`BackupService.applyImport`), Debug API `/backup/import`,
  `routing_srs_cache`. Ровно по этой причине там же закреплён инвариант
  «`vpn-1` существует» (`_ensureRequiredDirection`, §393 A3);
- отдельный guard был бы вреден: сироту приносит и восстановленный архив, а
  one-shot с guard'ом отработал бы один раз до restore и больше никогда.

**Гонки «сущность ещё не загружена» нет.** `directions` и `ping_options` лежат
в одном файле `lxbox_settings.json` и читаются одним `_load()`; на момент
вызова список Направлений в `data` уже финальный. Отдельного источника
Направлений, который подъезжает позже, не существует — цепочки и подписки
ключами карты быть не могут (см. «Факты»).

Проверка идёт по сырым данным (`map['tag']`, без `Direction.fromJson`), как в
`_ensureRequiredDirection`, и возвращает `true` только если что-то снято —
вызывающий решает, писать ли на диск. Самый частый путь (карты `groups` нет
вовсе) выходит на первой проверке и не порождает записи.

Ветка 3 миграции («мигрировано-и-пусто»: Направлений нет осознанно) снимает
карту целиком — осиротело всё.

### 3. Общая точка удаления ключей

`_dropPingGroupKeys(opts, doomed)`
(`app/lib/services/settings_storage/network.dart`) — снять ключи по предикату,
мутируя `opts` на месте. Через неё теперь ходят все трое: `_clearGroupPing`
(§040), heal и чистка сирот.

Пустая карта `groups` удаляется целиком, а не остаётся `{}` — приём был в
`_clearGroupPing` с §040, здесь просто вынесен в общее место. Причина: ключ
`ping_options` попадает в бэкап и в `/state/storage`, и пустой контейнер там
читался бы как «override'ы были и все сброшены», хотя состояние ровно то же,
что до первого override'а.

## Точки heal

| Файл | Что |
|---|---|
| `app/lib/services/settings_storage/network.dart` | `_dropPingGroupKeys` — общее удаление ключей по предикату; `_clearGroupPing` переписан на неё |
| `app/lib/services/settings_storage/directions.dart` | `_healPingOptionsGroupRefs` — heal при удалении Направления; вызов в `_deleteDirection` (до общего `_save()`) |
| `app/lib/services/settings_storage/directions.dart` | `_pruneOrphanPingGroups` — чистка сирот; вызовы во всех четырёх ветках `_migrateDirectionsIfNeeded` |

## Тесты

`app/test/migration/direction_heal_refs_test.dart`, группа
`§408 — ping_options.groups` (12 тестов). Проверяется файл на диске, не кеш:
heal обязан доезжать до `lxbox_settings.json` тем же `_save()`, что и
остальные четыре рода.

- delete снимает ключ Направления и не трогает чужой; глобальные
  `url`/`timeout_ms` не задеты;
- delete снимает ключ auto-двойника `<tag>-auto`;
- последний ключ ушёл → карта `groups` снимается целиком, секция
  `ping_options` остаётся (в ней глобальные значения);
- disable override НЕ трогает;
- миграция снимает сироту (`vpn-9`), живых не трогает;
- миграция считает живым `<tag>-auto` живого Направления и снимает
  `<tag>-auto` мёртвого;
- миграция не трогает override выключенного Направления;
- все ключи живые → файл не переписан (байт-в-байт);
- ветка «мигрировано-и-пусто» → карта уходит целиком;
- ветка seed (чистая установка) → сирота из восстановленного бэкапа снята, а
  тег, который seed завёл, остался живым;
- ветка легаси-списка `channels` → сироты снимаются там же;
- `clearGroupPing` (§040) по-прежнему снимает ровно один ключ.

## Docs to update

- [`docs/STORAGE.md`](../../STORAGE.md) — секция `ping_options`: инвариант
  ключей, heal, чистка. **Сделано.**
- [`CHANGELOG.md`](../../../CHANGELOG.md) — entry в `Unreleased`. **Сделано.**
- `docs/api/debug-api-reference.md` — не требуется: routes и их семантика не
  менялись.
- `docs/ARCHITECTURE.md` — не требуется: новых подсистем и контрактов нет.

## Нерешённое

Переименование Направления по-прежнему не реализовано (§402). Когда дойдёт до
него, `ping_options.groups` — десятое место, которое обязано пережить перенос
тега, и общая точка `_dropPingGroupKeys` там не поможет: нужен rename ключа, а
не его снятие.

Debug API `PUT /settings/ping_options/groups/{tag}` тег не валидирует, и
записать в карту несуществующее Направление по-прежнему можно. Осознанно:
Debug API — root by design, а следующая же загрузка состава такую запись
уберёт как сироту.
