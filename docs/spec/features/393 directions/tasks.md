# TASKS 393 — Directions

Нормативка: [`spec.md`](spec.md). Порядок фаз обязателен; каждая фаза
кончается зелёными `flutter analyze` + `flutter test` (3340+).

## Фаза A — модель Direction (рефакторинг Channel, полная чистота)

Решение оператора 24.08.2026: «полная чистота, без хвостов» — переименование
СКВОЗНОЕ: класс, файлы, колл-сайты (БЕЗ typedef-моста), UI-тексты, debug API
и storage-ключ. Единственный допустимый хвост — read-side миграция
легаси-ключей (без неё существующие установки теряют каналы). Downgrade на
сборку до миграции пере-сеет Направления из шаблона — принято осознанно.

- [x] A1. Сквозное переименование домена: `lib/models/channel.dart` →
      `direction.dart` (`Direction`, `DirectionAuto`, `ChannelHealResult` →
      `DirectionHealResult` и т.д.), ВСЕ колл-сайты сразу (lib/ + test/),
      файлы `channel_*.dart`/`channels.dart` → `direction_*.dart`/
      `directions.dart` (git mv), UI-тексты EN «Direction/Directions» (L8),
      debug API `/channels/*` → `/directions/*` без алиасов (dev-only API).
      НЕ ТРОГАТЬ IPC/сетевые каналы: `MethodChannel`/`EventChannel`,
      `cc_channel.dart`, `platform_channels.dart` — сетевой смысл слова
      остаётся (решение оператора о терминологии)
- [x] A2. Storage: ключ `channels` → `directions`, маркер `channels_migrated`
      → `directions_migrated`; one-shot миграция channels→directions с
      УДАЛЕНИЕМ легаси-ключей; порядок restore→migrate (внутренний бэкап
      восстанавливает старый файл со старыми ключами → миграция обязана
      отработать ПОСЛЕ restore); allowlist `backup_service.dart`: экспорт
      только новых ключей, restore принимает и легаси-пару (единственный
      хвост). Тесты: fresh-seed, migrate, restore-старого-файла→migrate,
      round-trip нового
- [x] A3. `include` (List<String> тегов Направлений, только стоящих ВЫШЕ по
      списку — антицикл) + произвольные теги: `nextDirectionTag` по образцу
      лаунчера `configtypes.NextDirectionTag` (vpn-N без верхней границы;
      лимит `kMaxChannels`=10 снять для новых); существующие vpn-N легальны;
      tag immutable после создания
- [x] A4. Граф-санитайзер (порт `core/build/outbound_graph_sanitize.go`
      лаунчера, НЕ две частные проверки). Разведка 24.08 (скаут sanitizer):
      место — новый post-step `post_steps/sanitize_outbound_graph.dart`,
      вызов в `build_config.dart` между `:536` (healInvalidReality) и
      `:544` (validateConfig) — последняя точка, где виден весь граф.
      Фикспойнт (лимит len*4+8, выход по !changed) по
      `config['outbounds']+config['endpoints']`:
      - висячий detour → снять ключ (ПОГЛОЩАЕТ `heal_dangling_detours.dart`
        — старый вызов `:486` снять, иначе двойные warnings);
      - члены-призраки состава selector/urltest → исключить (сегодня
        состав фиксируется в `_buildChannelGroups:696-703` и никем не
        пересматривается — латентно до первого heal'а, дропающего ноду,
        и станет горячим с chain);
      - `default` вне состава → заменить на kept[0] с warning (сейчас
        `:747` молча НЕ ставит — семантика обратная эталону
        `outbound_graph_sanitize.go:216-221`); default=block от
        emptyFallback (`:739`) не перетирать;
      - узел с detour на канал со своим участием → вон из состава,
        detour сохранить (fail-open; эталон `detour_group_cycle.go:50-77`),
        точка — `nodesFor` `build_config.dart:658-666` (L2);
      - кольца по любым рёбрам: ПОЛИТИКА ПРИВЕДЕНА К ЛАУНЧЕРУ — рвать
        замыкающее ребро по типу (`breakDependencyCycle`, эталон
        `:348-365`) и деградировать с warning; §254-fatal валидатора
        остаётся ПОСЛЕДНИМ рубежом для неразруленного (корпус direction/
        нормативно требует деградации — `chain_cycle_excluded_from_
        direction.expected.json`). Детекция уже готова: `_cyclicNodes`
        `validator.dart:339-405`;
      - пустое Направление → block: УЖЕ ПРАВИЛЬНО (`:709-740`,
        байт-в-байт `empty_direction_blocks.expected.json`) — закрепить
        раннером A5, не сломать

      СДЕЛАНО. Расхождения с эталоном (осознанные, закрыты тестами):
      1. правило 4 считает «входит в состав» по СТРУКТУРНЫМ рёбрам (вглубь
         вложенных групп и auto-двойников), а не только прямым совпадением
         как `detour_group_cycle.go` (там состав группы — плоский список
         нод, у мобилы селектор Направления держит `<tag>-auto`). Дальше по
         detour'ам ЧУЖИХ узлов НЕ идёт: транзитивная версия выбрасывала из
         состава весь невиновный флот кейса §254 и уводила Направление в
         block вместо снятия одного detour'а у виноватой ноды;
      2. правило 5 выбирает рвущееся ребро по §254-минимальности
         (`_cyclicGraphNodes` + scoring), а не «первое замыкающее из DFS»
         эталона — по той же причине;
      3. §254-fatal валидатора не удалён: остался последним рубежом на
         кольца, где ни одно removable-ребро не разваливает цикл.
- [x] A5. Раннер корпуса `contract/corpus/direction/` (55 файлов уже
      синхронизированы) в `app/test/contract/` по образцу
      `contract_test.dart` (тот читает только corpus/uri). Не-chain кейсы
      сразу: empty_direction_blocks, default_filter_first_match,
      auto_twin_excludes_group_nodes, disabled_direction_skipped,
      empty_pool_no_warning; chain_* — skip со ссылкой на фазу C

      СДЕЛАНО: `app/test/contract/direction_corpus_test.dart` — 16 зелёных,
      11 именованных скипов (6 `chain_*` → TODO(§393 C), 5 `fold_*` → na,
      фаза E). Гоняет НАСТОЯЩИЙ `buildConfig` и сверяет группы из готового
      `config['outbounds']` — позиционно, порядок групп и составов
      нормативен. `magic` переводит служебные теги корпуса в теги мобилы
      (`block-out` → `block`).

      Что пришлось починить в СБОРКЕ (фикстура нормативна):
      1. `<tag>-auto` эмитится ПЕРЕД своим селектором (было наоборот) —
         README корпуса «сначала auto-группа, потом само Направление»,
         эталон `direction_twins.go:105-114`;
      2. `default` Направления с автовыбором = его двойник, когда
         `defaultFilter` ничего не поймал (не ставился вовсе) — эталон
         `outbound_generator.go:676-682`, кейсы `auto_twin_emitted_and_
         default` / `auto_twin_default_yields_to_explicit`.

      Спорная фикстура (одна, задокументирована в раннере
      `_groupsNotComparable`): `empty_pool_no_warning` ждёт `groups: []`,
      но это АВАРИЯ СБОРКИ лаунчера (при нулевом пуле
      `GenerateOutboundsFromParserConfig` возвращает «no nodes parsed from
      any source», Go-раннер печатает пустой список от `res == nil`), а не
      свойство модели. У мобилы такого обрыва нет и быть не должно:
      Направление — цель `route.rules[].outbound`. Мобила применяет ту же
      политику, которую корпус объявляет верной в `empty_direction_blocks`
      (§201/§274): `[block, direct-out]` с `default=block`. Раннер сверяет
      названную кейсом частность (README корпуса:52 — отсутствие
      предупреждения) и структуру по правилу LxBox, с причиной в reason.

      Не нормативны и сняты с обеих сторон: `interrupt_exist_connections`
      и `passive_check` (шаблонные, README корпуса это оговаривает);
      `url`/`interval`/`tolerance`/`idle_timeout` двойника сверяются, только
      если ожидание их НАЗЫВАЕТ (у мобилы `DirectionAuto` не-nullable, у
      лаунчера omitempty). Порядок КЛЮЧЕЙ внутри группы не нормативен —
      Go сравнивает `MarshalIndent` от map, где ключи отсортированы.
- [x] A6. Болезнь мобилы: смена `tag_prefix` подписки не каскадирует
      (`subscription_detail_screen.dart:796`, `folder_detail_screen.dart:1520`)
      и молча обнуляет regex `nodeFilter` каналов, написанный под старый
      префикс (диагностика только постфактум-SnackBar `build_config:721`).
      Минимум: предупреждение в момент правки префикса при литеральном
      вхождении старого префикса в фильтры; однозначные вхождения —
      переписать (образец `clearDetourChannelRefs`, `server_list.dart:646`),
      неоднозначные не угадывать

## Фаза B — LX Backup: Направления + инварианты §1–§3 (падающий контрактный тест)

Разведка 24.08 (скаут backup): мобильный LX Backup — полуфабрикат.
Применяются ТОЛЬКО rules[] (`backup_screen.dart:417`); vars, route.final,
subscriptions, foreignExtensions разбираются, показываются в диалоге и
выбрасываются; servers[] экспортируется пустой оболочкой (без uri/config_json);
warp[] и dns не реализованы ни в одну сторону (молчаливая потеря — прямое
нарушение §1/§3 BACKUP.md); per-entity `extensions.<app>` и непонятые поля
записей не переживают round-trip; Dart-раннер игнорирует поля ожиданий
`disabled_hashes` и `directions`, которые Go-раннер проверяет
(`corpus_test.go:205-221`, `:271-309`).
- [x] B1. `lib/services/lx_backup.dart`: разбор `directions[]` ПЕРВЫМИ
      (канон → Direction), теги пополняют known до разбора правил;
      занятый тег → warning `backup_direction_exists`, не применяется
- [x] B2. Экспорт: Directions → `directions[]` (канон; фильтр ТЕЛОМ regex)
- [x] B3. Раннер `test/contract/backup_corpus_test.dart`: сверка
      `directions[]` из expected (tag/label/filter/include_direct/has_auto)
- [x] B4. `directions_created_on_import` зелёный → закоммитить
      `app/contract.lock` (до этого lock НЕ коммитить)
- [x] B5. UI restore: создание Направлений при импорте (backup_service)

      СДЕЛАНО, но точка иная, чем предполагала эта строка: не
      `backup_service.dart` (он про ВНУТРЕННИЙ бэкап — allowlist ключей
      storage), а `backup_screen.dart` — путь импорта именно LX Backup.
      Направления применяются ПЕРВЫМИ, до правил (иначе `rules[].outbound`
      метит в несуществующую цель и правило приезжает выключенным), через
      `DirectionMutations.bulkReplace` дополнением В КОНЕЦ — существующие
      не перезаписываются, инвариант «vpn-1 есть и включён» цел, `include[]`
      приехавших (ссылки только вверх) остаётся осмысленным. Гейт
      `directionTagConflict` на пути `bulkReplace` отсекает служебные теги и
      тёзок чужих `<tag>-auto`, которых парсер не ловит. Те же Направления
      добавлены в `knownOutbounds` при разборе и в экспорт.
- [ ] B6. Довести импорт до применения: vars, route.final, subscriptions
      (сейчас `backup_screen.dart:417` пишет только rules)
- [ ] B7. foreignExtensions: ключ хранения (BACKUP.md:12 «LxBox — новый
      ключ allowlist»), сохранение на импорте, возврат в
      `buildLxBackup(foreignExtensions:)` при экспорте — сейчас круг
      launcher→LxBox→launcher теряет `extensions.launcher` целиком

      ПОДТВЕРЖДЕНО ЗАМЕРОМ (24.08): парсер блоб забирает
      (`lx_backup.dart:402`), но до экспорта он не доходит — UI зовёт
      `buildLxBackup` БЕЗ `foreignExtensions` (`backup_screen.dart:320`), и
      на выходе `extensions` = null. Хранилища под чужие блобы нет ни
      одного. Тесты дыру не ловят: проверяют только парсер
      (`lx_backup_test.dart:110`), с непустым `foreignExtensions`
      `buildLxBackup` не вызывается нигде — нужен round-trip именно через
      эту пару вызовов.

      После C9 цепочки к этому пункту отношения не имеют (едут своей
      секцией), но сам провоз чужих блобов остаётся обязательным —
      инвариант lossless §1 общий.
- [ ] B8. warp[] в обе стороны: `WarpAccount.toJson`/`MasqueAccount.toJson`
      уже есть (`services/warp/`), дискриминатор `type: wg|masque`,
      merge не перетирает живую регистрацию (эталон `import.go:595-630`);
      + фикстура warp_roundtrip в корпус (сейчас 0 из 8 кейсов)
- [ ] B9. dns-секция в обе стороны (kind template|preset|user, final,
      strategy; эталон `import.go:523-593` — лаунчер этот же баг уже
      признал и исправил)
- [ ] B10. Достроить subscriptions[]/servers[]: экспорт disabled-хешей,
      detour, max_nodes, skip, tag.postfix/mask, update.auto; servers —
      uri/config_json (сейчас пустая оболочка `lx_backup.dart:199-205`);
      импорт с разбором полей вместо сырого Map
- [ ] B11. Per-entity `extensions.<app>` + непонятые поля записей
      (dns/resolve правил) — переживают round-trip (эталон
      `import.go:288-322`, `_backup_fields`); корпус-кейс на re-export
- [ ] B12. Раннер: читать `disabled_hashes` и `directions` из ожиданий
      (паритет с Go); поправить `corpus/backup/README.md:14` — указан
      несуществующий раннер

## Фаза C — цепочки (SPEC 110 мобилы)
- [x] C1. Модель `SourceChain` (hops в порядке ПАКЕТА, idle_timeout,
      strip_evasion, strip, rewrite) — канон `source_chain.schema.json`

      СДЕЛАНО: `app/lib/models/source_chain.dart`. `strip_evasion` —
      nullable ради ТРЁХЗНАЧНОСТИ (нет ключа = умолчание ядра true, false =
      явное выключение); каталог `strip` закрыт четырьмя ключами и эмитится
      в порядке каталога, а не порядка Map. `rewrite` хранит `null`-значения
      дословно: в RFC 7396 это «удалить ключ», и «чистка пустого» сменила бы
      патч на обратный по смыслу. Там же порты `ChainEmitError` и
      `ChainOutboundObject` лаунчера.
- [x] C2. Хранение: цепочки в настройках (отдельный список; НЕ узлы подписки)

      СДЕЛАНО: `app/lib/services/settings_storage/chains.dart` (part по
      образцу `directions.dart`), ключ `chains` в `allowedTopLevelKeys` и в
      категории `routing` внутреннего бэкапа. Миграции НЕТ намеренно: ключ
      новый, «нет `chains`» и «все удалены» — одно состояние (в отличие от
      `directions`, где пустой список значил бы потерю роутинга).
      `deleteChain` НЕ вычищает позиции других цепочек — асимметрия с
      `include` Направлений: снятие позиции превращает маршрут в ДРУГОЙ
      маршрут, и билдер обязан деградировать цепочку целиком, а не подменять
      её молча. LX Backup цепочек не переносит — TODO(§393 B-хвост/C9) в
      `lx_backup.dart`.

      УТОЧНЕНО (24.08, C9): «лаунчер тоже не кладёт» — неверно, он кладёт их
      блобом `extensions.launcher.chains`. Раздела в контракте
      действительно нет, и заводится он именно в C9 — корневой `chains[]`.
- [x] C3. Сборка: цепочка → узел `type: chain` (raw-объект, как
      `ChainOutboundObject` лаунчера); разрешение после загрузки всех
      источников; ссылка на цепочку только ВЫШЕ по списку

      СДЕЛАНО: `app/lib/services/builder/chain_nodes.dart` (`resolveChains`),
      вызов в `build_config.dart` ПОСЛЕ цикла `list.build(ctx)` и ДО
      `_buildDirectionGroups`; узлы уходят в `outbounds` между узлами
      подписок и группами Направлений, теги — в конец `selectorTags` (пул
      отбора). Порядок фикстур корпуса воспроизведён.
- [x] C4. **T9/L6**: канал не берёт цепочку, идущую через него (транзитивно)

      СДЕЛАНО: `chainPassesThrough` + `dropChainsThroughDirection`
      (`chain_nodes.dart`), вызов в `_buildDirectionGroups` ПОСЛЕ фильтра —
      фильтр про цепочки не знает и знать не должен. Плюс заглушки правил
      3–4 санитайзера заменены реализацией (`sanitize_outbound_graph.dart`,
      правила 6 и 7 его нумерации): висячий хоп дропает ЦЕПОЧКУ целиком,
      `pruneChainLeavesUnderGroups` вычищает цепочки из листьев группы,
      стоящей позицией ≥1. `_isChain` отделён от `_isGroup` — общий ключ
      `outbounds[]` у них значит разное. Кольца: `_EdgeKind.chainHop` рвётся
      дропом цепочки, а не снятием позиции.
- [x] C5. Гейт по `Libbox.version()` ≥ 1.14.0-lx.27-rc.5: без поддержки
      цепочка не эмитится, warning `chain_unsupported_by_core` (реестр)

      СДЕЛАНО: `app/lib/services/builder/core_chain_capability.dart`.
      Мобила читает версию ядра через `VpnPlugin.getCoreVersion` →
      `Libbox.version()` → `constant.Version` (ldflags от git-тега,
      `build_shared/tag.go`) — списка тегов сборки libbox наружу не отдаёт,
      поэтому шов один: версия. Парсер `-lx.N[-rc.M]` честный (строковое
      сравнение ставило бы `rc.10` перед `rc.5`), финальный релиз старше
      своих rc, хвост `-g<hash>` игнорируется. Fail-open на пустой/кривой/
      апстримной строке. Гейт живёт в СБОРКЕ (`BuildSettings.coreVersion`,
      кэш `CoreVersionCache` на сессию), не в UI.
- [x] C6. Валидация формы (L4!): ≥2 позиций, дубли, самоссылка, вложенная
      только позицией 0, strip-каталог 4 ключа, utls+reality; детур
      позиции 0 = предупреждение, позиций ≥1 = справка (spec.md, референсы)

      СДЕЛАНО: `app/lib/screens/chain_edit/chain_form_validation.dart` —
      чистый модуль (ни виджетов, ни storage), порт `conflicts()` лаунчера
      плюс инварианты ядра, которые форме нужны РАНЬШЕ сборки. Находка несёт
      машинный КОД ([ChainIssueCode]) и УРОВЕНЬ: `blocking` запирает
      сохранение, `warning`/`info` — нет. Детур разведён по позициям (0 =
      предупреждение «путь длиннее показанного», ≥1 = справка «ядро
      перезапишет»), потерянные позиции — предупреждение с перечнем, и только
      при готовом снимке целей (иначе рабочая цепочка красилась бы красным до
      первой сборки). `stripsUtls` повторяет лестницу ядра: точечная галка >
      общий `strip_evasion` > умолчание каталога. Кандидаты позиций —
      `chain_hop_candidate.dart` + `chain_hop_targets.dart` (источник
      ОКОНЧАТЕЛЬНЫХ тегов — последний собранный конфиг `HomeState.configModel`,
      оттуда же reality/detour). Тесты — по инварианту на кейс, по кодам, не
      по текстам.
- [x] C7. UI: экран цепочки (список позиций, порядок пакета подписан,
      «+» из существующих целей, Advanced со strip)

      СДЕЛАНО: `app/lib/screens/chain_edit_screen.dart` (идиома
      `direction_edit_screen`: push + PopScope back-guard + AppBar
      delete/save; кнопка сохранения ЗАПЕРТА блокирующей находкой — §393 L4).
      Позиции только выбором из существующих целей (bottom-sheet пикер,
      занятые исключены), порядок пакета подписан над списком, перестановка
      стрелками. Advanced: idle_timeout, strip_evasion, каталог strip
      ТРЁХЗНАЧНЫМИ галками (не тронута = умолчание ядра — иначе «как у ядра»
      и «я так решил» стали бы неотличимы). `rewrite` формой не правится (по
      C1: урезанная форма молча потеряла бы произвольный патч), но переживает
      round-trip. Точка входа — «Add hop chain…» в overflow-меню экрана
      источников (`subscriptions_screen.dart`), создание через
      `new_chain_dialog.dart` (тег спрашиваем ДО создания — он immutable),
      список — `subscriptions_screen/widgets/chains_section.dart` (тег +
      число хопов; секции нет, пока нет цепочек). Правка/удаление/тумблер
      зовут `_regenerateAndSave` — цепочка это узел конфига.
- [~] C8. Раннер корпуса `contract/corpus/direction/` в Dart (кейсы
      chain_* и fold_* — сейчас раннера нет вовсе)

      ЧАСТИЧНО (попутно к C3–C5): раннер существует с A5; шесть кейсов
      `chain_*` РАСКРЫТЫ и зелёные — вход читает `chains[]` и
      `core_supports_chain`, выход сверяет и записи `type: chain`; добавлены
      предикаты кодов `chain_unsupported_by_core` / `chain_hop_missing` /
      `chain_cycle_through_direction`. `fold_*` остаются na (фаза E закрыта).
      Открытым остаётся то, что от C8 ещё требуется сверх этого.
- [x] C9. Бэкап: цепочка в `extensions.lxbox`? НЕТ — она в каноне источника;
      решить перенос (лаунчер пока цепочки в бэкап не кладёт — сверить и
      сделать одинаково, скорее всего доп. раздел контракта)

      РЕШЕНО (24.08), делается: доп. раздел контракта — корневая секция
      `chains[]` в `backup.schema.json`, поле `chain` через `$ref` на
      `source_chain.schema.json`. Обе стороны пишут и читают её оттуда.

      Сверка с лаунчером дала не то, что предполагал этот пункт: цепочки он
      в бэкап УЖЕ кладёт — блобом `extensions.launcher.chains`
      (`core/backup/export.go:64`, разбор `importLauncherChains`
      `import.go:490`), и `BACKUP.md §2` это узаконил. Место неверное:
      `extensions.<app>` по определению схемы — «непереносимое, per-app», а
      цепочка описана ОБЩИМ каноном обеих сторон, и модель LxBox совпадает с
      `configtypes.SourceChain` один в один. Провозить её вслепую или писать
      в ЧУЖОЙ карман (не будучи лаунчером) — ложь о происхождении данных.

      Ключ merge — `tag` (у лаунчера это `Source.Label` = `TagMask`,
      `sync_to_connections.go:77`). Тег НЕ стабилен: переименование
      (`ChainEditContext.originalTag`) и `allocateTag` на сборке его меняют,
      а стабильного id нет ни у кого (`Source.ID` уезжает в блоб пустым —
      проверено дампом экспорта). Поэтому в `BACKUP.md` идут обе цены:
      переименованная цепочка приедет второй записью, случайные тёзки
      склеятся; занятый тег даёт warning ВСЕГДА, даже когда «своя сильнее».
      Заводить `id` в канон отложено — отдельной задачей, если дубли станут
      болью.

      СТОРОНА ЛАУНЧЕРА СДЕЛАНА (24.08): `singbox-launcher/develop`, коммиты
      `e916cb6` (контракт, схема v1.2, VERSION 0.7.0) и `28311be` (Go).
      Задание — `localworkspace/task-launcher-chains-backup.md`.

      Две мои посылки в задании оказались неверны, итог другой:
      - **Legacy-фоллбэк ЕСТЬ.** «Релиза не было» — неверно: коммит
        `8beebf3` (цепочки в `extensions.launcher`) входит в теги v1.5.0 и
        v1.5.1, UI цепочек там тоже есть, файлы старого формата в природе
        возможны. Лаунчер ПИШЕТ только в секцию, но `extensions.launcher.
        chains` ЧИТАЕТ как приватный fallback (в BACKUP.md §2 помечено
        Legacy). Нас не касается: блоб провозим как любой чужой, разбирать
        его НЕ надо.
      - **`label` лаунчер провозит, а не игнорирует.** Моё «игнорирует при
        чтении» противоречило самому инварианту задачи: транзит
        LxBox→лаунчер→LxBox терял бы `label`. Он игнорирует его
        семантически, но возвращает через механизм непонятых полей записи.
        Пишем `label` только когда непусто и != тега.

      Контракт (готовое, синхронизировать ресинком):
      - warning занятого тега — `backup_chain_exists`, ставится ВСЕГДА;
        реестр `backup_*`-кодов живёт в BACKUP.md, не в
        `registry/warnings.json` (прецедент не менялся);
      - поле ожиданий корпуса — `chains`: список `{tag, label?, chain}`,
        `chain` сверяется deep-equal канона (включая `null` внутри
        `rewrite`), число записей строго;
      - кейсы: `chains_roundtrip` (все поля канона, `rewrite` с `null`,
        чужой `label`, правило метит в тег цепочки из того же файла и
        приходит РАБОЧИМ) и `chain_tag_duplicate` (два одинаковых тега в
        одном файле: вторая пропущена + warning). Мой исходный кейс
        «тег занят СВОЕЙ цепочкой» корпусом невыразим — у раннеров нет
        pre-state, импорт идёт в пустоту; merge-с-локальной покрывается
        юнит-тестом (у Go — `TestImportChainTagBusy`, у нас нужен
        зеркальный).

      ОСТАЛОСЬ НА LxBox: ресинк контракта от этих коммитов; разбор и сборка
      `chains[]` в `lx_backup.dart`; UI в `backup_screen.dart` (экспорт
      `getChains()`, импорт с merge по тегу, число цепочек в диалоге);
      раннер `backup_corpus_test.dart` под поле `chains`; зеркальный
      юнит-тест на занятый тег. Блокер: `lx_backup.dart` держит другая
      сессия (незакоммиченные B7–B11) — браться после её коммита.

## Фаза D — реактивность движка шаблонов
- [ ] D1. Аудит: лаунчер перерисовывает строку настроек по зависимостям
      условия (`ui/configurator/tabs/settings_reactive.go` + reactive-тест);
      Dart: `services/builder/if_engine.dart` + экран настроек шаблона —
      выяснить, перестраивается ли весь экран
- [ ] D2. Если нет — зависимости условий по переменным, точечный rebuild
      (ValueListenable / выборочный setState)
- [ ] D3. Выключенная строка гасит подпись (visible связь галка→поля)
- [ ] D4. Load-валидация тела `#enable`: ветка `if (k.startsWith('#'))
      continue` (`if_engine.dart:600-604`) глотает `#enable` — опечатка в
      имени var / оба and+or / скаляр грузятся молча (fail-closed спасает
      от TRUE-вливания, но узел молча исчезает). Проверка `k == enableKey`
      ПЕРЕД веткой, тем же кодом, что предикаты `#if`
- [ ] D5. Контрактный рубеж load-валидации: раннер
      `template_contract_test.dart` не зовёт `validateIfConstructs` вовсе
      — согласовать с лаунчером формат load-reject-фикстур (контрактная
      задача ОБЕИХ сторон; Go после 6d43114 в той же ситуации)

## Фаза E — свёртка подписки в группу (SPEC 108 мобилы) — ЗАКРЫТО (na)

Решение оператора 24.08.2026: свёртка подписки в группу на мобиле НЕ НУЖНА.
Обоснование из разведки: три из четырёх старых флагов лаунчера мобиле не
нужны, S3/S4 (группы подписок — не цели правил) выполняются by design
(`routing_screen_helpers.dart:50-61`), длинный селектор канала — приемлем.
Порт-план (SubscriptionFold, разворот на сборке, §322-взаимодействие)
сохранён в истории этого файла на случай пересмотра. Единственный живой
остаток той разведки — болезнь смены `tag_prefix` — живёт отдельно как A6
и от свёртки не зависит.

## Проверка
- [ ] `flutter analyze` 0 issues, `flutter test` зелёный целиком
- [ ] Контрактные тесты 426+ зелёные, lock закоммичен
- [ ] APK на устройство → подтверждение оператора (правило AGENTS.md)
