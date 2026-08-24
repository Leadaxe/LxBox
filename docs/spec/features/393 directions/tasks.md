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
- [ ] A4. Граф-санитайзер (порт `core/build/outbound_graph_sanitize.go`
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
- [ ] A5. Раннер корпуса `contract/corpus/direction/` (55 файлов уже
      синхронизированы) в `app/test/contract/` по образцу
      `contract_test.dart` (тот читает только corpus/uri). Не-chain кейсы
      сразу: empty_direction_blocks, default_filter_first_match,
      auto_twin_excludes_group_nodes, disabled_direction_skipped,
      empty_pool_no_warning; chain_* — skip со ссылкой на фазу C
- [ ] A6. Болезнь мобилы: смена `tag_prefix` подписки не каскадирует
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
- [ ] B1. `lib/services/lx_backup.dart`: разбор `directions[]` ПЕРВЫМИ
      (канон → Direction), теги пополняют known до разбора правил;
      занятый тег → warning `backup_direction_exists`, не применяется
- [ ] B2. Экспорт: Directions → `directions[]` (канон; фильтр ТЕЛОМ regex)
- [ ] B3. Раннер `test/contract/backup_corpus_test.dart`: сверка
      `directions[]` из expected (tag/label/filter/include_direct/has_auto)
- [ ] B4. `directions_created_on_import` зелёный → закоммитить
      `app/contract.lock` (до этого lock НЕ коммитить)
- [ ] B5. UI restore: создание Направлений при импорте (backup_service)
- [ ] B6. Довести импорт до применения: vars, route.final, subscriptions
      (сейчас `backup_screen.dart:417` пишет только rules)
- [ ] B7. foreignExtensions: ключ хранения (BACKUP.md:12 «LxBox — новый
      ключ allowlist»), сохранение на импорте, возврат в
      `buildLxBackup(foreignExtensions:)` при экспорте — сейчас круг
      launcher→LxBox→launcher теряет `extensions.launcher` целиком
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
- [ ] C1. Модель `SourceChain` (hops в порядке ПАКЕТА, idle_timeout,
      strip_evasion, strip, rewrite) — канон `source_chain.schema.json`
- [ ] C2. Хранение: цепочки в настройках (отдельный список; НЕ узлы подписки)
- [ ] C3. Сборка: цепочка → узел `type: chain` (raw-объект, как
      `ChainOutboundObject` лаунчера); разрешение после загрузки всех
      источников; ссылка на цепочку только ВЫШЕ по списку
- [ ] C4. **T9/L6**: канал не берёт цепочку, идущую через него (транзитивно)
- [ ] C5. Гейт по `Libbox.version()` ≥ 1.14.0-lx.27-rc.5: без поддержки
      цепочка не эмитится, warning `chain_unsupported_by_core` (реестр)
- [ ] C6. Валидация формы (L4!): ≥2 позиций, дубли, самоссылка, вложенная
      только позицией 0, strip-каталог 4 ключа, utls+reality; детур
      позиции 0 = предупреждение, позиций ≥1 = справка (spec.md, референсы)
- [ ] C7. UI: экран цепочки (список позиций, порядок пакета подписан,
      «+» из существующих целей, Advanced со strip)
- [ ] C8. Раннер корпуса `contract/corpus/direction/` в Dart (кейсы
      chain_* и fold_* — сейчас раннера нет вовсе)
- [ ] C9. Бэкап: цепочка в `extensions.lxbox`? НЕТ — она в каноне источника;
      решить перенос (лаунчер пока цепочки в бэкап не кладёт — сверить и
      сделать одинаково, скорее всего доп. раздел контракта)

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
