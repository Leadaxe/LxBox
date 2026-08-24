# TASKS 393 — Directions

Нормативка: [`spec.md`](spec.md). Порядок фаз обязателен; каждая фаза
кончается зелёными `flutter analyze` + `flutter test` (3340+).

## Фаза A — модель Direction (рефакторинг Channel, полная чистота)

Решение оператора 24.08.2026: «полная чистота, без хвостов» — переименование
СКВОЗНОЕ: класс, файлы, колл-сайты (БЕЗ typedef-моста), UI-тексты, debug API
и storage-ключ. Единственный допустимый хвост — read-side миграция
легаси-ключей (без неё существующие установки теряют каналы). Downgrade на
сборку до миграции пере-сеет Направления из шаблона — принято осознанно.

- [ ] A1. Сквозное переименование домена: `lib/models/channel.dart` →
      `direction.dart` (`Direction`, `DirectionAuto`, `ChannelHealResult` →
      `DirectionHealResult` и т.д.), ВСЕ колл-сайты сразу (lib/ + test/),
      файлы `channel_*.dart`/`channels.dart` → `direction_*.dart`/
      `directions.dart` (git mv), UI-тексты EN «Direction/Directions» (L8),
      debug API `/channels/*` → `/directions/*` без алиасов (dev-only API).
      НЕ ТРОГАТЬ IPC/сетевые каналы: `MethodChannel`/`EventChannel`,
      `cc_channel.dart`, `platform_channels.dart` — сетевой смысл слова
      остаётся (решение оператора о терминологии)
- [ ] A2. Storage: ключ `channels` → `directions`, маркер `channels_migrated`
      → `directions_migrated`; one-shot миграция channels→directions с
      УДАЛЕНИЕМ легаси-ключей; порядок restore→migrate (внутренний бэкап
      восстанавливает старый файл со старыми ключами → миграция обязана
      отработать ПОСЛЕ restore); allowlist `backup_service.dart`: экспорт
      только новых ключей, restore принимает и легаси-пару (единственный
      хвост). Тесты: fresh-seed, migrate, restore-старого-файла→migrate,
      round-trip нового
- [ ] A3. `include` (List<String> тегов Направлений, только стоящих ВЫШЕ по
      списку — антицикл) + произвольные теги: `nextDirectionTag` по образцу
      лаунчера `configtypes.NextDirectionTag` (vpn-N без верхней границы;
      лимит `kMaxChannels`=10 снять для новых); существующие vpn-N легальны;
      tag immutable после создания
- [ ] A4. Граф-санитайзер (порт `core/build/outbound_graph_sanitize.go`
      лаунчера, НЕ две частные проверки): финальный фикспойнт-проход по
      всем рёбрам outbound-графа (member/detour; в фазе C добавятся позиции
      цепочек): висячие ссылки, кросс-рёберные кольца, пустеющие группы,
      `default`/`options.default` вне состава (L1), узел с detour на группу
      со своим участием (L2), ПУСТОЕ Направление → block (трафик не идёт
      мимо VPN). Деградация элемента с warning, не отказ всего конфига

## Фаза B — Направления в LX Backup (падающий контрактный тест)
- [ ] B1. `lib/services/lx_backup.dart`: разбор `directions[]` ПЕРВЫМИ
      (канон → Direction), теги пополняют known до разбора правил;
      занятый тег → warning `backup_direction_exists`, не применяется
- [ ] B2. Экспорт: Directions → `directions[]` (канон; фильтр ТЕЛОМ regex)
- [ ] B3. Раннер `test/contract/backup_corpus_test.dart`: сверка
      `directions[]` из expected (tag/label/filter/include_direct/has_auto)
- [ ] B4. `directions_created_on_import` зелёный → закоммитить
      `app/contract.lock` (до этого lock НЕ коммитить)
- [ ] B5. UI restore: создание Направлений при импорте (backup_service)

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

## Проверка
- [ ] `flutter analyze` 0 issues, `flutter test` зелёный целиком
- [ ] Контрактные тесты 426+ зелёные, lock закоммичен
- [ ] APK на устройство → подтверждение оператора (правило AGENTS.md)
