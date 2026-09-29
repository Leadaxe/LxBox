# §590 — Удалить мёртвый код по решениям аудита 588

| Поле | Значение |
|------|----------|
| Тип | R (рефакторинг) |
| Статус | N (new) |
| Фича | [001-SUBSCRIPTIONS](../features/001-SUBSCRIPTIONS/FEATURE.ru.md), [005-DNS](../features/005-DNS/FEATURE.ru.md), [015-WARP](../features/015-WARP/FEATURE.ru.md), [016-DPI_HARDENING](../features/016-DPI_HARDENING/FEATURE.ru.md), [020-APP_SHELL](../features/020-APP_SHELL/FEATURE.ru.md), [017-BACKUP_AND_STORAGE](../features/017-BACKUP_AND_STORAGE/FEATURE.ru.md) (ключи хранения), [024-TEMPLATE](../features/024-TEMPLATE/FEATURE.ru.md) (`parser_config`) |
| Дата | 2026-09-29 |
| Связанные | [588](588-spec-kit-revision-audit.md) — вопросы 2, 4, 7, 58, 62, 70 |

## Решение

Владелец 2026-09-29 принял правило по умолчанию для находок аудита 588:
**мёртвый код удалять**, старые спеки без кода закрывать как не планируемые.
Эта задача — удаляющая часть. Поведение для пользователя не меняется ни в одном
пункте; фичи уже отражают решения (границы «не планируется» и поправленные
формулировки в 001, 005, 015).

Мёртвость каждого пункта проверена `grep` по `app/lib` и `app/test`
2026-09-29: вызовов из кода приложения нет, только из тестов (или вовсе нет).
Перед правкой повторить `grep` — код мог измениться.

## Что удалить

### 1. Обновление подписок по интервалу при Start (вопрос 4, §010F)

**Что.** Остаток §010F: проверка «прошёл ли интервал с последнего глобального
обновления» и отметка времени этого обновления. Никто не вызывает
`shouldRefreshSubscriptions`, никто не пишет `last_global_update` кроме теста;
подписки обновляет автообновление по своим триггерам (001 · auto-update).

**Где.**

- `app/lib/services/settings_storage.dart` — статические
  `getLastGlobalUpdate`, `setLastGlobalUpdate`, `parseReloadInterval`,
  `shouldRefreshSubscriptions` и заголовок блока «Last global update timestamp».
- `app/lib/services/settings_storage/sources_rules.dart` — `_getLastGlobalUpdate`,
  `_setLastGlobalUpdate`, `_parseReloadInterval`, `_shouldRefreshSubscriptions`
  и их заголовок.
- Ключ хранения `last_global_update`: allowlist в
  `app/lib/services/settings_storage.dart` (набор ключей около строки 172) и
  `_topLevelAppKeys` в `app/lib/services/backup_service.dart`.

**Ключ хранения — осторожно.** Ключ лежит в файлах хранения и бэкапах
существующих пользователей. Простое удаление из allowlist превратит его в
«неизвестный ключ» при импорте старого бэкапа (класс §349, «N unknown keys
skipped»). Варианты: (а) оставить ключ в allowlist с пометкой «legacy, не
пишется и не читается» — как `enabled_groups`; (б) снять его разовой миграцией
хранения и молча отбрасывать при импорте. Выбрать (а), если нет причины для (б).

**Тесты.** `app/test/services/config_dirty_flag_test.dart`, тест «не-config
сейверы (sort/ping/timestamp) НЕ поднимают флаг»: убрать шаг с
`setLastGlobalUpdate` (два оставшихся сейвера проверку держат). Фикстуру
`app/test/fixtures/storage/rich_v0.json` не трогать — это вход миграции, ключ
в нём законен; если выбран вариант (б), проверить golden-тесты миграции
(`app/test/storage_migration/`).

**Документы.** `docs/STORAGE.md` — строки про `last_global_update` (дерево,
пример документа, таблица ключей) пометить legacy или убрать по выбранному
варианту; `docs/ARCHITECTURE.md` — перечень ключей App settings.

**Риск.** Низкий в коде; средний на совместимости бэкапа — см. выше.

### 1b. Модель `parser_config` шаблона (следствие вопросов 4 и 76)

**Что.** `WizardTemplate.parserConfig` (`ParserConfigBlock` с `version` и
`reload`) читается из шаблона, но в `app/lib` его никто не читает: `reload`
кормил только удаляемый пункт 1, миграций по `version` нет и не будет
(вопрос 76, `docs/TEMPLATE.md` уже поправлен).

**Где.** `app/lib/models/parser_config.dart` — поле `parserConfig`
конструктора `WizardTemplate`, его заполнение в `fromJson`, класс
`ParserConfigBlock`.

**Тесты.** Конструируют `ParserConfigBlock()` для обязательного параметра:
`app/test/services/core_reject_retag_test.dart`,
`app/test/services/node_link_registry_test.dart` — убрать аргумент.

**Не трогать.** Ключ `parser_config` в `app/assets/wizard_template.json`
остаётся (форма шаблона; снимать его — отдельное решение с оглядкой на
лаунчер). `docs/TEMPLATE.md` уже говорит «не используется приложением».
`docs/ARCHITECTURE.md` — строки про `parser_config` («version + reload
interval») поправить.

**Риск.** Низкий. Пункт можно отложить, если 1 делается отдельно.

### 2. Поле `enabled` у записи пресета в DNS-правилах (вопрос 2)

**Что.** У записи DNS-правила вида «пресет» есть своё `enabled`, но оно
мёртвое с §257: вкл/выкл DNS пресета — переменная `dns_enable` пресета,
запись — только якорь позиции группы (§117). UI тайла для записи пресета не
рисует (группа рисуется `DnsMirrorTile`), сборка с группой зеркал `enabled`
записи не читает.

**Где.**

- `app/lib/models/dns_ref.dart` — `DnsRulePreset`: поле `enabled`, параметр
  конструктора, `copyWith`, `withEnabled`, `==`, `hashCode`. Базовый
  `DnsRuleRef` требует `enabled` / `withEnabled`: у пресета — константа `true`
  и `withEnabled`, возвращающий ту же запись (или вынести `enabled` из базы в
  три других вида — на выбор исполнителя, без изменения остальных видов).
- `app/lib/services/builder/post_steps/dns_rules.dart` — legacy-ветка без
  группы зеркал (`if (!entry.enabled) continue;` у записи пресета) и
  `DnsRulePreset(presetId: pid, enabled: true)` при досеве якоря. Перед
  удалением проверки убедиться, что legacy-ветка (вызов без `dnsMirrors`)
  не достижима из сборки с непустыми `extraDnsRulesByPresetId`; иначе
  поведение ветки для записи с `enabled: false` сменится с «не эмитить» на
  «эмитить».
- Чтение: `app/lib/models/codec/dns_record.dart` (`dnsRuleFromRecord`,
  `case 'preset'`), `app/lib/services/lx_backup.dart` (читатель формата 0.x,
  `case 'preset'` около строки 2176),
  `app/lib/services/storage_migration/legacy_form_v0.dart` (`case 'preset'`) —
  перестать передавать `enabled`.
- Запись: `app/lib/models/codec/dns_record.dart` (`dnsRuleToRecord`, ветка
  `DnsRulePreset`).

**Форма файла не меняется.** `enabled` — поле контракта у записи DNS-правила
(`BackupField(BackupRecord.dnsRule, 'enabled', …)` в
`app/lib/services/lx_backup_slice.dart`), бэкап общий с лаунчером
(`app/test/fixtures/lx_backup/launcher_v8_export10.json`). Поэтому кодек
продолжает писать `"enabled": true` у записи пресета и игнорирует значение при
чтении. Иначе поменяются байты хранения и бэкапа и golden-фикстуры.

**Тесты.** Убрать аргумент `enabled: true` у `DnsRulePreset(...)`:
`app/test/services/lx_backup_slice_test.dart`,
`app/test/services/rule_transfer_format1_test.dart`,
`app/test/services/dns/dns_backup_merge_test.dart`,
`app/test/services/builder/rule_dns_mirror_test.dart`. Проверить тесты
legacy-ветки сборки без группы зеркал (`app/test/builder/`, `app/test/services/builder/`) —
если какой-то проверяет выключенную запись пресета, он удаляется вместе с
веткой. Добавить юнит: запись пресета с `"enabled": false` в хранении читается,
DNS пресета по-прежнему управляется `dns_enable`.

**Документы.** `docs/STORAGE.md`, раздел `dns.rules[i]`: абзац «⚠ §257 …
`enabled` is dead» заменить на «у записи пресета `enabled` пишется всегда
`true` и не читается».

**Риск.** Средний: много точек касания и общий с лаунчером формат. Критерий —
байты хранения и бэкапа не меняются (golden-тесты зелёные без правки фикстур).

### 3. UA источника выше глобального (вопрос 7, §118F)

**Что.** `UrlSource.userAgent` — задуманный в §118F UA отдельного источника,
который перекрывает глобальный. Ни один вызов `UrlSource(...)` в `app/lib` и
`app/test` его не передаёт; свой UA подписки живёт в слепке Custom-режима
(`identity.userAgent`), и он работает.

**Где.** `app/lib/services/subscription/sources.dart` — поле `userAgent` и
параметр конструктора `UrlSource`, деструктуризация `userAgent: final ua` в
`_fetch` и `ua ??` в вычислении UA режима Default; комментарий «UA =
per-source > глобальный override > брендированный» → «глобальный override >
брендированный».

**Тесты.** Нет. `app/test/subscription/sources_test.dart` остаётся зелёным.

**Риск.** Нулевой.

### 4. Вариации вокруг живого IP в сканере WARP (вопрос 58)

**Что.** Вторая фаза сканера endpoint'ов из исследования 132: генерация
вариаций вокруг найденного живого IP. Интерфейс и Debug API её не вызывают.

**Где.** `app/lib/services/warp/scan/candidate_generator.dart` — методы
`variations` и `_variationOne`; шапку файла («Фаза 2 — вариации вокруг
живого IP (метод [variations])») сократить до первой фазы. Общие помощники
(`_pickWgPort`, `_pickMasquePort`, `_randomAwg`, `_protocols`, `_pick`)
остаются — ими пользуется первая фаза.

**Тесты.** `app/test/warp/scan/candidate_generator_test.dart` — удалить группу
`variations (фаза 2)`.

**Риск.** Нулевой.

### 5. Мёртвые поля `TemplateVars` (вопрос 62)

**Что.** `TemplateVars` передаётся в `emit` каждого узла, но ни одно его поле
никем не читается: фрагментация пишется другим путём (016 · фрагментация
TLS). `tlsFragment` и `tlsRecordFragment` заполняются в сборке и не читаются;
`muxEnabled` и `sniOverride` не заполняются и не читаются.

**Где.**

- `app/lib/models/template_vars.dart` — четыре поля и параметры конструктора.
  Класс и `TemplateVars.empty` остаются: это сигнатура `emit`/`emitRaw`
  (`app/lib/models/node_spec.dart`), её снятие — отдельный рефакторинг вне
  этой задачи.
- `app/lib/services/builder/build_config.dart` — построение `TemplateVars(
  tlsFragment: …, tlsRecordFragment: …)` заменить на `TemplateVars.empty`.
- `app/lib/models/emit_context.dart` — комментарий «взять глобальные флаги
  (tls_fragment и пр.) — `vars`» поправить.

**Тесты.** Ссылок на поля в `app/test` нет.

**Риск.** Нулевой. Контроль: конфиг сборки на фикстурах (golden сборки) не
меняется.

### 6. Повтор загрузки ленты поддержки каждые 30 с (вопрос 70)

**Что.** В показе ленты «поддержи автора» есть бэкофф 30 с «до первого
успеха» (§356). После §422 загрузка ленты при неудаче сети отдаёт кэш или
копию из сборки и практически не возвращает «пусто», поэтому повтор не
срабатывает.

**Где.** `app/lib/screens/home_screen.dart` — поле `_supportNextFetchAt` и
блок бэкоффа в `_maybeShowSupport` с комментарием «§356 — fetch до первого
успеха, с бэкоффом 30с».

**Как не ухудшить.** Не заменять блок на «загружать, пока `_supportFeed ==
null`»: `_maybeShowSupport` зовётся примерно раз в секунду при поднятом
туннеле, и при пустом ответе (битый ассет) это будет запрос каждую секунду.
Нужна одна попытка загрузки за процесс (флаг «уже загружали»).

**Тесты.** Виджет-тестов на бэкофф нет; `app/test/services/support_message_test.dart`
проверяет сервис и не меняется.

**Риск.** Низкий.

## Не входит

- Вопросы 9 и 10 аудита (схемы hysteria v1, код `max_nodes_exceeded`): реестр
  контракта общий с лаунчером и приезжает только синком, локально не
  правится; вопросы остаются открытыми в 588.
- Снятие параметра `TemplateVars` из сигнатуры `emit` — отдельный рефакторинг.
- Ключ `parser_config` в `wizard_template.json`.

## Критерии приёмки

- Каждый пункт 1–6 удалён; `grep` по удалённым символам в `app/lib` и
  `app/test` пуст.
- Поведение для пользователя не меняется; байты хранения, бэкапа и собранного
  конфига на фикстурах не меняются (golden-тесты зелёные без правки
  фикстур).
- Старый файл хранения и старый бэкап с `last_global_update` и с `enabled` у
  записи пресета импортируются без новых предупреждений.
- Документы из пунктов 1, 1b, 2 поправлены.
- CI: `flutter analyze`, `flutter test`.
