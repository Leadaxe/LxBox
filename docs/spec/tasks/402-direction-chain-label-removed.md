# 402 — У Направления и цепочки одно имя: тег

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата старта | 2026-09-02 |
| Дата завершения | 2026-09-02 |
| Коммиты | см. ветку задачи |
| Связанные spec'ы | [features/125 configurable-directions](../features/125%20configurable-directions/spec.md), [tasks/393](393-masque-config-schema-migration.md), [tasks/274](274-detour-role-to-permission.md) |

Зеркало контракта singbox-launcher: **0.9.0** (снос `label` у Направления),
решение **D-082** (то же для цепочки) и **0.11.1** (masque `vhttp=auto`).
Репозиторий лаунчера не правится — только читается.

> **Часть A ОТМЕНЕНА решением владельца — см. [§405](405-direction-chain-label-mobile-only.md).**
> `label` у Направления и цепочки возвращён и живёт как поле, которое
> применяет только LxBox (контракт 0.12.4, решение D-094; колонка
> «Поддержка» в `docs/BACKUP.md` §2). Всё, что ниже описано в части A —
> снос поля, производный `displayLabel`, снятое поле Title в редакторах,
> `label` без эмиссии в бэкапе — **больше не действует**. Часть B (masque
> `vhttp=auto`) остаётся в силе.

## Проблема

### A. Два имени у одной сущности

У Направления и у цепочки было по два имени: `tag` — системный id, на который
ссылаются правила, `route_final`, `include[]`, позиции других цепочек и
detour-мишени; и `label` — то, что пользователь вводил и видел в списке.

На практике это означало, что в списке Направлений человек видит «Стриминг», а
в выпадашке целей правила — `vpn-2`, и связать одно с другим ему нечем. Тег при
этом переименовать нельзя (он immutable by design — иначе поедут все ссылки),
так что `label` был именем, которое ничего не именует для того, кто настраивает
маршрут.

Контракт 0.9.0 снёс поле: `direction.schema.json` держит
`additionalProperties: false`, и запись с `label` больше не проходит валидацию.
D-082 распространяет то же решение на цепочку — у лаунчера (D-079) чужой
`label` у `chains[]` и так не применялся и не писался.

Правило **не** распространяется на `label` узлов, пресетов и источников
(подписка / сервер / цепочка как запись списка источников): там ссылочного тега
в паре нет, отображаемое имя единственное, и переименовать источник, ничего не
сломав, можно.

### B. masque `vhttp=auto` не принимался

Ядро понимает `vhttp: auto` (h3 с откатом на h2) с lx.27, контракт закрепил это
в 0.11.1, а оба парсера LxBox знали ровно пару `{h3, h2}` и молча форсили `h3` —
с warning'ом на URI-пути и без него на singbox-JSON-пути. Мастер WARP при этом
`auto` в выпадашке уже предлагал: узел, созданный мастером, работал, а тот же
узел, экспортированный в URI и заимпортированный обратно, терял `auto`.

## Решение

### A. Снос `label`

**Модель.**
- `Direction.label` удалено (`app/lib/models/direction.dart`). `displayLabel`
  остался, но стал производным: `tag`, плюс ⚙-префикс при `isDetour`.
- `Direction.normalizeLabel` удалён целиком. До §274 ⚙ хранился В САМОМ
  `label` и нормализовался при смене флага; теперь маркер вычисляется над
  тегом и в данные не попадает. Дописать ⚙ в сам `tag` нельзя — маркер увёл бы
  тег из-под ссылок.
- `defaultLabelForTag` / `defaultDirectionLabel` / `directionNumberOf` удалены:
  вся машинерия дефолтных имён «VPN ①..VPN ⑩» существовала ради `label`.
  `kMaxDirections` осталась константой-ориентиром (лимитом на создание она
  перестала быть ещё в §393 A3).
- `SourceChain.label` и `SourceChain.displayLabel` удалены — имя цепочки — её
  `tag` (`app/lib/models/source_chain.dart`).
- `DefaultDirection.label` (`app/lib/models/parser_config.dart`) оставлено, но
  инертно: сид его больше не читает. Поле держит байт-совместимость шаблона
  `assets/wizard_template.json` и его l10n-overlay.

**Миграция чтения.** Отдельной миграции файла нет и не нужно:
`fromJson` обеих моделей ключ `label` **читает и отбрасывает** — именем
остаётся `tag`, — а `toJson` его не эмитит. Ключ отмирает на первой же записи. Тот же приём в `lx_backup.dart`: `label` остался в
`_knownDirectionKeys` / `_knownChainKeys`, чтобы бэкап старой версии или
лаунчера не поднимал warning про неизвестное поле — ключ законно был, его
читают и молча роняют.

**Экраны.**
- `direction_edit_screen.dart` — поле Title убрано; на его месте read-only
  строка с тегом (моноширинная, крупная — это теперь единственное имя) и
  подпись «Name is the tag — it is set once, at creation». Тогл «Use as detour»
  больше не переписывает поле имени.
- `chain_edit_screen.dart` — то же: Title убран, тег стал заголовком.
- `new_direction_dialog.dart` / `chain_edit/new_chain_dialog.dart` — второе
  поле убрано, `NewDirectionRequest` / `NewChainRequest` несут только `tag`.
  Диалог создания и был единственным местом, где тег вообще спрашивают.
- Списки и подписи (`routing_screen`, `home/widgets/node_list`,
  `subscriptions_screen/widgets/chains_section`, `chain_edit/chain_hop_targets`,
  `outbound_view_screen`, `subscription_detail_screen/tag_prefix_cascade`,
  `routing_screen/routing_screen_helpers`, `widgets/detour_target_picker`,
  `controllers/home_controller`, `services/dns/dns_controller`,
  `services/builder/chain_nodes`, `services/builder/build_config`) —
  везде показывается тег (у Направления — через `displayLabel`, ради ⚙).

**Storage / API.** `addDirection` / `addChain` и `DirectionMutations.add`
потеряли параметр `label`. Debug API: `POST /directions`, `POST /chains` и
PATCH обоих больше не принимают поле `label` — ключ в теле игнорируется;
текст отказа на попытку сменить `tag` переписан («системный id и единственное
имя»).

**Строки UI.** Из `assets/l10n/ru/ui.json` убраны осиротевшие ключи `Title`,
`optional — defaults to the tag` и `Remove "%1$s" (%2$s)? References to it fall
back to vpn-1.`; добавлены `Name is the tag — it is set once, at creation` и
однопараметрический `Remove "%s"? References to it fall back to vpn-1.`. Все
четыре чекера `app/tool/l10n/` проходят в `--strict`.

### B. masque `vhttp=auto`

- `services/parser/uri_parsers/masque_parser.dart` — допустимая тройка
  `{h3, h2, auto}`; всё вне неё по-прежнему форсится в `h3` с
  `MasqueVhttpInvalidWarning`. Parse-дефолт при отсутствии `vhttp` остался
  явным `h3`: «параметра нет» и «оператор выбрал auto» — разные вещи.
- `services/parser/json_parsers.dart` — та же тройка на singbox-JSON-пути
  (там форс всегда был молчаливым, это не менялось).
- `MasqueSpec.vhttp` возит значение как строку, а эмиттер
  (`node_spec_emit.dart`) кладёт его в конфиг дословно, так что `auto`
  доезжает до ядра без правок. Мастер WARP `auto` уже предлагал.
- Текст warning'а обновлён: «is not h3, h2 or auto», русский перевод — следом.

## Риски и edge cases

- **Пользователь теряет введённые имена.** Это цена решения, принятого
  контрактом: `label` из старого состояния читается и отбрасывается на первом
  же запуске. Отката не предусмотрено — данные не портятся, но и не
  восстанавливаются.
- **⚙ у detour-Направления.** Раньше маркер лежал в данных и мог оказаться
  двойным / стёртым руками; теперь он вычисляемый, и класс проблем закрыт по
  построению.
- **Бэкап.** Экспорт `label` у `directions[]` и `chains[]` не пишет вовсе —
  канон `direction.schema.json` его не знает. Импорт ключ терпит молча (см.
  выше). Корпус лаунчера это подтверждает: во входных файлах
  `chains_roundtrip.backup.json` и `unknown_keys_warned_import_continues.backup.json`
  `label` есть, а **ни в одном** `.expected.json` его нет.
- **Не покрыто:** переименование (см. ниже).

## Верификация

- `flutter analyze` по всему проекту (включая `test/`) — чисто по существу
  задачи. Остаются 19 ошибок `onReorder` / `onReorderItem`: они **предшествуют
  задаче** и вызваны версией SDK — коммит `ee3d5d1b` перевёл списки на
  `onReorderItem` из Flutter 3.47, а локальный SDK 3.41.6.
- Четыре l10n-чекера (`ui_check`, `template_check`, `hardcoded_check`,
  `kotlin_check`) — `--strict`, ноль находок.
- Device-проверка не проводилась.

## Нерешённое / follow-up

### Переименование Направления / цепочки — НЕ реализовано

Контракт формулирует: «переименование Направления = смена `tag` вместе со
всеми ссылками на него». В LxBox это **осталось нереализованным**, и тег
по-прежнему immutable после создания. Обоснование — цена: тег Направления или
цепочки хранится как ссылка в **десяти** независимых местах, и перенос обязан
пройти все, иначе переименование молча рвёт маршрут:

1. `rules[].outbound` у inline- и SRS-правил, плюс `varsValues['outbound']` у
   preset-правил, плюс legacy-ключ `target` на чтении (`models/custom_rule.dart`);
2. `route_final` (`settings_storage/network.dart`) и его буфер в
   `routing_screen/routing_srs_cache.dart`;
3. `Direction.include[]` — теги других Направлений;
4. `SourceChain.hops[]` — позиции, ссылающиеся на Направления, другие цепочки
   и узлы;
5. `detour_policy.override_detour` и `FolderMember.detour` у подписок,
   серверов и папок (`models/server_list.dart`);
6. `body['detour']` у inline-DNS-сервера и `varValues` у DNS-пресета с
   var-типом `outbound` (`models/dns_ref.dart`, `dns_server_edit/`);
7. бэкап `.lxbox` — `route.final`, `include`, тело `chain`, `outbound` правил,
   `detour_policy` (`services/lx_backup.dart`);
8. `kImportOutboundFallback` в `services/rule_transfer.dart`;
9. вся heal-машинерия (`_healDirectionRefs`, `_healDetourDirectionRefs`,
   `_healChainHops`, `_requireFreeChainTag`), которая сегодня умеет только
   «снять ссылку», а не «перенести»;
10. `ping_options.groups` — **map, ключами которого являются теги
    Направлений** (`settings_storage/network.dart`). У неё, в отличие от всех
    остальных мест, heal'а нет вовсе: на удалении Направления per-direction
    override молча осиротевает, а на переименовании потерялся бы так же тихо.

Это объём фичи, а не задачи-зеркала: нужен атомарный rename-путь через все
десять мест плюс проверка уникальности нового тега по общему пространству имён
Направлений и цепочек (включая `<tag>-auto`-двойников). До тех пор форма
честно говорит пользователю, что имя задаётся один раз — при создании.

Отдельным хвостом стоит **дыра в `ping_options.groups`**: она существует уже
сегодня, независимо от переименования, и заслуживает своей задачи.

### Тесты на переписывание

Компиляция чинилась минимально (снос аргумента / замена `.label` на `.tag`).
Осмысленного покрытия просят:

- `test/models/direction_test.dart` — из группы `Direction JSON round-trip`
  ушла проверка имени; удалены группы `§393 A3 — defaultLabelForTag` и
  `§198 — defaultDirectionLabel` вместе с функциями.
- `test/models/direction_detour_test.dart` — группы `§274 — displayLabel` и
  `§274 — normalizeLabel` заменены одной группой про производный ⚙; стоит
  перечитать её на полноту.
- `test/models/source_chain_test.dart` — проверка `displayLabel` заменена на
  проверку отбрасывания legacy-ключа.
- `test/migration/directions_migration_test.dart` — удалён тест
  «addDirection без label → дефолт с кружком»; несколько assert'ов на имена
  сняты.
- `test/services/backup_service_test.dart` — два assert'а на список имён
  переведены на теги; проверка «архив заменяет живой список» теперь опирается
  на теги, и её различающая сила упала.
- `test/contract/lx_backup_test.dart`, `test/contract/backup_corpus_test.dart`
  — assert'ы на `label` сняты; корпусный тест перестал проверять имя вовсе.

## Docs to update

- `docs/STORAGE.md` — `directions[]` / `chains[]`: `label` помечен снесённым и
  читаемым как игнорируемый legacy-ключ; раздел про ⚙-маркер переписан на
  производную форму. **Сделано.**
- `CHANGELOG.md` — user-visible: у Направлений и цепочек исчезло поле имени,
  masque принимает `vhttp=auto`. **Отложено до релиза.**
- `docs/api/debug-api-reference.md` — `POST /directions`, `POST /chains`,
  PATCH обоих: поле `label` больше не принимается. **Отложено до релиза.**
- `docs/ARCHITECTURE.md` — структурных изменений нет.
