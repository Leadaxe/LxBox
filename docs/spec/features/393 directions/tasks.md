# TASKS 393 — Directions

Нормативка: [`spec.md`](spec.md). Порядок фаз обязателен; каждая фаза
кончается зелёными `flutter analyze` + `flutter test` (3340+).

## Фаза A — модель Direction (рефакторинг Channel)
- [ ] A1. `lib/models/direction.dart`: класс `Direction` = текущий `Channel`
      + поле `include` (List<String> тегов Направлений-опций, только
      стоящие ВЫШЕ по списку). `lib/models/channel.dart` → реэкспорт +
      `@Deprecated typedef Channel = Direction` (27 файлов едут через
      алиас, миграция колл-сайтов — постепенно в A5)
- [ ] A2. Произвольные теги: снять жёсткость `vpn-1..10` для НОВЫХ записей
      (`kMaxChannels` — пересмотреть; `nextDirectionTag` по образцу
      лаунчера `configtypes.NextDirectionTag`); существующие vpn-N легальны;
      tag остаётся immutable после создания
- [ ] A3. Storage: ключ `channels` НЕ менять (L7); чтение/запись `include`;
      миграция не нужна (новое поле опционально)
- [ ] A4. Сборка (`services/builder/server_list_build.dart`):
      - include[] в состав селектора (выше по списку — антицикл);
      - **L1**: `default`/`options.default` вне состава → ключ снять с
        warning (порт болезни лаунчера);
      - **L2**: узел с detour на этот же канал → исключить из состава
        (порт `detour_group_cycle`)
- [ ] A5. Переименование в коде: колл-сайты Channel→Direction (sed по lib/,
      тесты через алиас), UI-тексты «Channels»→«Directions» (EN, L8)
- [ ] A6. Debug API / автоматизация: пути с channel — проверить, алиасы
      сохранить

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
