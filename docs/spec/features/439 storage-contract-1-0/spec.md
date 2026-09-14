# 439 — Хранение LxBox в форме контракта 1.0

| Поле | Значение |
|------|----------|
| Статус | Спека, кода нет |
| Дата | 2026-09-14 |
| Релиз | 2.23.3, вместе с чтением и записью LX Backup 1.0 ([§438](../../tasks/438-lx-backup-1-0-read-write.md)) |
| Триггер | решение владельца 14.09.2026 (вечер): релиз с бэкапом 1.0 поверх старой формы хранения не выпускается |
| Норма | `app/contract/docs/ONE_NAMESPACE.md` §1–§3; `docs/BACKUP.md` §1, §2, §4, §6, §9; `schema/backup.schema.json`; `docs/NODE_SECTIONS.md` §1 |
| Эталон | лаунчер, SPEC 127 волна 1: `core/state/migration_v7_to_v8.go`, `core/state/load_router.go` (копия `<path>.v7.bak` до миграции), `core/state/testdata/v8_roundtrip.json`; писатель `core/backup/export10.go` |
| Связанные | [§435](../435%20node-sections-tailscale/spec.md) (кодек записей), [§417](../417%20workspaces/spec.md) (слоты), §393 (цепочки, Направления), §366 (TTL srs), §225 (json-правило), §294 (модель DNS-ссылок), §159 (allowlist), §072 (атомарная запись), §396 (файл правил), §243 (имя одиночного сервера) |

## 0. Что и зачем

После §438 у LxBox три формы одних и тех же сущностей: форма хранения
2.23.2 (`server_lists`, `chains`, `custom_rules`, `dns_options`), форма файла
1.0 и переводчик между ними в `lib/services/lx_backup.dart` (экспорт —
`_subscription10ToJson`, `_server10ToJson`, `_folder10ToJson`,
`_chain10ToJson`, `_rule10ToJson`, `_dns10ToJson`) и
`lib/services/dns/dns_backup.dart` (`dnsToBackup`). ONE_NAMESPACE §3
записывает перевод хранения LxBox в цену контракта, `record_codec.dart`
написан как будущий корневой парсер («волна 4» в его комментариях).

**Цель.** `lxbox_settings.json` хранит источники, цепочки, правила и
DNS-записи теми же записями, что файл 1.0. Экспорт LX Backup — срез хранения
плюс тонкий слой BACKUP §1. `config.json`, собранный из одного состояния до
и после миграции, совпадает байт в байт.

**Нецели 2.23.3.**

- Истина узла — `body`, заморозка разобранного тела и кнопка Regen
  (ONE_NAMESPACE §1). Вопрос В1.
- Направления в каноне `direction.schema.json`, DNS-скаляры из `vars` в
  `dns{}`, `route_final` в `route{}`: тонкий слой по BACKUP §1, перевод
  остаётся.
- Слияние внутреннего бэкапа (`BackupService`) с LX Backup.
- `enabled_groups` и `PUT /settings/enabled_groups`.

## 1. Ключи хранения

### 1.1 Верхний уровень

| Ключ сейчас | После | Основание |
|---|---|---|
| `server_lists[]` (`type: subscription\|user\|folder`) | `sources[]` (`kind: subscription\|server\|folder`) | ONE_NAMESPACE §1 «Контейнеры», BACKUP §2 |
| `chains[]` | записи `kind: chain` в хвосте `sources[]`; поле `order` исчезает | BACKUP §4: порядок записей нормативен |
| `custom_rules[]` | `rules[]` | BACKUP §2 `rules[]` |
| `dns_options{servers[], rules[], rules_json}` | `dns{servers[], rules[]}`; `rules_json` удаляется | BACKUP §2 `dns`; `rules_json` не читается с §061 |
| — | `storage_version: 1` | признак формы, §3.1 |
| `vars` (в том числе `dns_final`, `dns_strategy`, `dns_default_domain_resolver`) | без изменений | переменные шаблона; в файл — тонкий слой |
| `directions[]`, `directions_migrated` | без изменений | тонкий слой |
| `route_final`, `ping_options` | без изменений | тонкий слой (`route.final`, бюджеты Направлений §409) |
| `warp_account`, `masque_account` | без изменений | тонкий слой (`warp[]`) |
| `route_idle_suspend`, `route_idle_suspend_reachable`, `urltest_passive_check`, `tun_apps`, `vpn_mode`, `native_prefs`, `interrupt_connections_on_switch`, `node_sort_mode`, `node_manual_order`, `profiler_retention_sec`, `last_global_update`, `presets_migrated`, `enabled_groups` | без изменений | local-only, в LX Backup не едут |
| `excluded_nodes`, `preset_ids_remapped`; остатки §159 `proxy_sources`, `app_rules`, `enabled_rules`, `rule_outbounds`, `node_overrides`, `show_detour_servers`, `vars.auto_rebuild`; `channels`, `channels_migrated` | удаляются миграцией | читателей нет (§125-cleanup, §229, §159); пара `channels` — переименование §393 A2, уходит в ту же миграцию |

`SettingsStorage.allowedTopLevelKeys`: `+sources`, `+rules`, `+dns`,
`+storage_version`; `−server_lists`, `−chains`, `−custom_rules`,
`−dns_options`, `−excluded_nodes`, `−preset_ids_remapped`.

### 1.2 Записи

Колонка «Чьё»: **К** — поле контракта 1.0; **L** — поле LxBox рядом с
`body` (ONE_NAMESPACE §1 разрешает local-only расширения записи). Что с
полями L делает экспорт — 1.3.

**Подписка** (`SubscriptionServers`)

| Модель | Сейчас | После | Чьё |
|---|---|---|---|
| — | `type: subscription` | `kind: subscription` | К |
| `id`, `name`, `enabled`, `url` | те же | те же | К |
| `tagPrefix` | `tag_prefix` | `tag_policy{prefix}`, префикс с разделителем (`"PR "`) | К |
| `identity` | `identity` | `identity`, форма та же | К |
| `updateIntervalHours` | `update_interval_hours` | `update{interval_hours}` | К |
| `disabledHashes` | `disabled_hashes{идентичность: ISO-8601}` | `disabled{идентичность: unix seconds}` | К |
| `detourPolicy` | `detour_policy` | `detour_policy`, не пишется при умолчаниях | L |
| `importRules`, `importRulesEnabled`, `onUpdateAction` | `import_rules`, `import_rules_enabled`, `on_update_action` | те же | L |
| `meta`, `lastUpdated`, `lastUpdateAttempt`, `lastUpdateStatus`, `lastNodeCount`, `consecutiveFails` | `meta`, `last_updated`, `last_update_attempt`, `last_update_status`, `last_node_count`, `consecutive_fails` | те же | L, рантайм |
| `nodes` | не хранится (`sub_cache/`) | не хранится | — |

**Одиночный сервер** (`UserServer`)

| Модель | Сейчас | После | Чьё |
|---|---|---|---|
| — | `type: user` | `kind: server` | К |
| `id`, `enabled` | те же | те же | К |
| тег разобранного узла | нет (живёт во фрагменте `raw_body`) | `tag`, пишется из разобранного узла (2.3, п. 1) | К |
| `rawBody` | `raw_body` (строка) | `origin{kind: uri\|wg_ini\|json, raw}` | К |
| `detourPolicy.overrideDetour` | `detour_policy.override_detour` | `detour{folder_id?, tag}` — NodeLink (6.4, D-112) | К |
| прочие флаги `detourPolicy` | `detour_policy` | `detour_policy` без `override_detour` | L |
| `tagPrefix` | `tag_prefix` | `tag_policy{prefix}`, только непустой | L |
| `sections` | `sections` | `sections` | К |
| `name` | `name` (с §243 всегда `''`) | не пишется | — |
| `origin` (`paste\|file\|qr\|manual`) | `origin` (строка) | не пишется: имя занято контрактом, поле write-only (§219) | — |
| `createdAt` | `created_at` | не пишется: читателей нет | — |

**Папка** (`FolderServers`) и член (`FolderMember`)

| Модель | Сейчас | После | Чьё |
|---|---|---|---|
| — | `type: folder` | `kind: folder` | К |
| `id`, `name`, `enabled` | те же | те же | К |
| `tagPrefix` | `tag_prefix` | `tag_policy{prefix}` с разделителем | К |
| `members[]` | `members[]` | `nodes[]` | К |
| `detourPolicy` | `detour_policy` | `detour_policy` | L |
| `pingUrl`, `pingTimeoutMs` | `ping_url`, `ping_timeout_ms` | те же | L |
| `createdAt` | `created_at` | не пишется | — |
| член: узел разобран / нет | — | `kind: server` / `kind: unsupported` + `reason` | К |
| член: `node.tag` | нет | `tag` | К |
| член: `raw` | `raw` | `origin{kind, raw}` | К |
| член: `enabled`, `sections` | те же | те же | К |
| член: `detour` | `detour` (строка) | `detour{tag}` | К |

**Цепочка** (`SourceChain`)

| Модель | Сейчас (`chains[]`) | После | Чьё |
|---|---|---|---|
| — | — | `kind: chain` | К |
| `tag`, `enabled` | те же | те же | К |
| `hops` | `hops[]` строки | `hops[{tag}]` | К |
| `idleTimeout`, `stripEvasion`, `strip`, `rewrite` | `idle_timeout`, `strip_evasion`, `strip`, `rewrite` | `body{type: chain, idle_timeout, strip_evasion, strip, rewrite}` | К |
| `label` | `label` | `label` | L |
| `order` | `order` | нет: место — индекс в `sources[]` | — |

**Правило маршрута** (`CustomRule`, кодек `ruleToRecord`/`ruleFromRecord`)

| Модель | Сейчас | После | Чьё |
|---|---|---|---|
| `kind` | `inline\|srs\|preset\|json` | `inline\|srs\|preset`; `json` → `inline` + `verbatim: true` (2.3, п. 3) | К / L |
| `id`, `name`, `enabled`, `orderNum` | `id`, `name`, `enabled`, `num` | те же | К |
| матчеры `domains`, `domainSuffixes`, `domainKeywords`, `ipCidrs`, `ports`, `portRanges`, `packages`, `protocols`, `network`, `ipIsPrivate`, `sourceIpCidrs`, `sourceIpIsPrivate`, `inbounds`, `wifiSsids`, `wifiBssids` + `outbound` | те же ключи camelCase | `body` с ключами sing-box (`domain`, `domain_suffix`, … `outbound` или `action: reject`) | К |
| `srsUrls` | `srsUrl` + `srsUrls` (при 2+) | `refs[]` | К |
| `updateIntervalHours` (srs, §366) | `updateIntervalHours` | `update_interval_hours`, не пишется при умолчании | L, новое в кодеке |
| `presetId`, `varsValues` | `presetId`, `varsValues` | `ref`, `vars` | К |
| `json` (текст) | `json` | `body` (объект) | К |
| `dns`, `resolve` | те же | те же, формы не меняются | L, объявлены в схеме |

**DNS-сервер** (`DnsServerRef`)

| Вид | Сейчас | После |
|---|---|---|
| inline | `{enabled, kind: inline, tag, body, description?}` | `{kind: user, tag, enabled, body, description?}` |
| preset | `{enabled, kind: preset, tag, description?}` | `{kind: preset, ref: "<preset_id>:<tag>", enabled, description?}` |
| template | `{enabled, kind: template, tag, varValues?, description?}` | `{kind: template, tag, enabled, vars?, description?}` |

**DNS-правило** (`DnsRuleRef`)

| Вид | Сейчас | После |
|---|---|---|
| inline | `{kind: inline, name, rule, enabled?}` | `{kind: user, name, enabled, body}` — `enabled` пишется всегда |
| preset | `{kind: preset, presetId, enabled}` | `{kind: preset, ref, enabled}` |
| srs | `{kind: srs, name, id, body?}` | без изменений (вид LxBox) |
| template | `{kind: template, name}` | без изменений (вид LxBox) |

Фрагмент хранения после миграции:

```jsonc
{
  "storage_version": 1,
  "sources": [
    { "kind": "subscription", "id": "…", "name": "Proton", "enabled": true,
      "url": "https://…", "tag_policy": { "prefix": "PR " },
      "update": { "interval_hours": 24 }, "disabled": { "NL-42": 1784368800 },
      "import_rules": [ … ], "last_update_status": "ok", "last_node_count": 12 },
    { "kind": "server", "id": "…", "tag": "Tokyo", "enabled": true,
      "origin": { "kind": "uri", "raw": "vless://…#Tokyo" },
      "detour": { "tag": "vpn-2" }, "sections": { … } },
    { "kind": "folder", "id": "…", "name": "Личные", "enabled": true,
      "tag_policy": { "prefix": "F " }, "ping_url": "http://1.1.1.1/cdn-cgi/trace",
      "nodes": [
        { "kind": "server", "tag": "Alpha", "enabled": true,
          "origin": { "kind": "uri", "raw": "vless://…#Alpha" }, "detour": { "tag": "Jump" } },
        { "kind": "unsupported", "enabled": true,
          "origin": { "kind": "uri", "raw": "foo://…" }, "reason": "…" } ] },
    { "kind": "chain", "tag": "chain-1", "enabled": true, "label": "Work",
      "body": { "type": "chain", "idle_timeout": "5m" },
      "hops": [ { "tag": "PR NL-1" }, { "tag": "Tokyo" } ] }
  ],
  "rules": [
    { "kind": "inline", "id": "…", "name": "ads", "enabled": true, "num": 1000,
      "body": { "domain_suffix": ["ads.example"], "action": "reject" } },
    { "kind": "inline", "id": "…", "name": "raw", "enabled": true, "num": 1001,
      "verbatim": true, "body": { "action": "sniff", "inbound": ["tun-in"] } },
    { "kind": "srs", "id": "…", "name": "ru", "enabled": true, "num": 1010,
      "refs": ["https://…/a.srs"], "update_interval_hours": 24,
      "body": { "outbound": "direct-out" } }
  ],
  "dns": {
    "servers": [ { "kind": "preset", "ref": "ru-direct:yandex_udp", "enabled": true } ],
    "rules": [ { "kind": "user", "name": "corp", "enabled": true,
                 "body": { "domain_suffix": [".corp"], "server": "my-doh" } } ]
  }
}
```

### 1.3 Поля LxBox без дома в 1.0

| Данные | Где в хранении | Экспорт LX Backup |
|---|---|---|
| `import_rules`, `import_rules_enabled`, `on_update_action` подписки | поля записи подписки | срезаются, `backup_local_only_dropped` (как 438) |
| `detour_policy` подписки и папки; флаги `detour_policy` сервера кроме `override_detour` | поле записи | срезаются, `backup_local_only_dropped` |
| `tag_policy` одиночного сервера | поле записи | срезается, `backup_local_only_dropped` |
| `ping_url`, `ping_timeout_ms` папки | поля записи папки | срезаются, `backup_local_only_dropped` |
| `label` цепочки | поле записи цепочки | срезается, `backup_local_only_dropped` |
| `meta`, `last_*`, `consecutive_fails` подписки | поля записи | срезаются молча (BACKUP §2: рантайм машины) |
| `verbatim` правила | поле записи | срезается молча: тело едет, настройки пользователя в маркере нет |
| `update_interval_hours` srs-правила | поле записи | срезается, `backup_local_only_dropped`. 438 теряет его молча — исправляется здесь |
| `description` DNS-сервера, `vars` template-сервера | поля записи | срезаются, `backup_local_only_dropped` (как 438) |
| DNS-правила `kind: srs` | запись вида LxBox | не пишутся, `backup_local_only_dropped` (как 438) |
| DNS-правила `kind: template` | запись вида LxBox | не пишутся молча (как 438) |
| префикс тегов с разделителем | `tag_policy.prefix` = префикс модели + пробел | как есть |
| `detour`, `hops[]` | NodeLink `{folder_id?, tag}` в записи | как есть (6.4, D-112) |
| `origin` одиночного сервера (`paste\|manual`) | не хранится | — |

Правило экспорта одно: поле L, отличающееся от умолчания, срезается и
называется одним `backup_local_only_dropped` на сущность; рантайм и
маркер срезаются молча.

## 2. Подход к коду

### 2.1 Вывод по главной идее

Идея «модели и их потребители остаются, меняется JSON-сериализация»
**подтверждается для источников, цепочек и правил** и **не подтверждается
для DNS**: у DNS нет модели у потребителей, резолвер, сборка и экраны
работают на сырых `List<Map>` (2.4).

Довод за идею. Модели не меняются, поэтому миграция идёт через них:
`legacy-читатель (нынешние тела fromJson, перенесённые без правок) →
модели → кодек записей`. Это буквально «прочитать кодом 2.23.2, записать
кодом 2.23.3» в одном процессе. Совпадение `config.json` сводится к двум
проверяемым свойствам:

1. legacy-читатель — перенесённый код, а не переписанный;
2. `fromRecord(toRecord(x))` восстанавливает ту же модель для каждого `x`
   (проверка на фикстурах и golden-конфиг, §5).

Лаунчер мигрировал по сырому документу (`migrateV7DocToV8`), потому что у
него сменились сами типы. У LxBox типы остаются, и миграция через модели
дешевле и надёжнее.

### 2.2 Кодеки

| Модуль | Что | Кто зовёт |
|---|---|---|
| `lib/models/record_codec.dart` | действующая форма: `ruleToRecord`/`ruleFromRecord`, `dnsServerToRecord`/`dnsServerFromRecord`, `dnsRuleToRecord`/`dnsRuleFromRecord`; новые `sourceToRecord`/`sourceFromRecord` (подписка, сервер, папка, член), `chainToRecord`/`chainFromRecord` | `toJson`/`fromJson` моделей делегируют сюда; `SettingsStorage`; чтение 1.0 в `lx_backup.dart`; `rule_transfer.dart`; `NodeSections` |
| `lib/services/storage_migration/legacy_form_v0.dart` (новый) | замороженные читатели формы 2.23.2: тела нынешних `ServerList.fromJson` (с подтипами и `FolderMember.fromJson`), `CustomRule.fromJson` (с подтипами), `SourceChain.fromJson`, `DnsServerRef.fromJson`, `DnsRuleRef.fromJson` — перенос без правок | только миграция и входы старой формы (3.4) |
| `lib/services/storage_migration/migrate_storage.dart` (новый) | `migrateStorageDoc(Map doc, {Map<String, String> presetIdByDnsServerTag})` → новый документ + отчёт; чистая функция | `_load()`, `_replaceRaw`, `BackupService.applyImport`, Debug `POST /backup/import` |

Старые имена полей после 2.23.3 живут только в `legacy_form_v0.dart` и
только на чтении — то же правило, что у legacy-входа 0.x в бэкапе
(ONE_NAMESPACE §3).

### 2.3 Где смены сериализации мало

| # | Расхождение | Решение в 2.23.3 |
|---|---|---|
| 1 | `UserServer.rawBody`, `FolderMember.raw` — текст; узел перечитывается из текста на каждой загрузке. В 1.0 истина — `body` | хранится `origin{kind, raw}`; `kind` выводится из текста правилом `_origin10` (JSON-объект → `json`, `IniConfig` → `wg_ini`, иначе `uri`); `body` не хранится; `tag` пишется из разобранного узла и на чтении не применяется (расхождение с текстом — строка в AppLog, побеждает текст). Заморозка тела — В1 |
| 2 | `UserServer` с несколькими узлами в `raw_body` (записи до §368) | остаётся одной записью `server`: `origin.raw` целиком, `tag` первого узла, как пишет экспорт 438. В папку не превращается: поменялся бы конфиг. Счётчик таких записей — в отчёте миграции |
| 3 | вид `json` (§225) снят в 1.0. Тело, которое модель умеет выразить, прочиталось бы как `CustomRuleInline` и ушло бы в конфиг через headless `rule_set` — конфиг изменится | запись `inline` + поле `verbatim: true`: объект → `body`; массив → по записи на элемент (`<имя>`, `<имя> #2`, …; первая держит `id`, `num` общий) — В2; нечитаемый текст → `verbatim: true` без `body` (сборка пропускает пустое тело так же, как битый текст сейчас), текст — в отчёт миграции и в `.v0.bak`. Редактор после 439 массив не сохраняет (В2) |
| 4 | `method: drop`, `action` кроме `reject`, логические правила, `rule_set` в теле — типизированная модель их не держит | модель не расширяется: такие тела на импорте 1.0 уже становятся `CustomRuleJson` (438), в хранении это `verbatim: true` |
| 5 | preset-сервер DNS: в 1.0 `ref = "<preset_id>:<tag>"`, модель знает только тег | `DnsServerPreset.presetId` (новое поле). Заполняет автообнаружение `resolveDnsServersList` (пресет известен в момент добавления) и миграция (`presetIdByDnsServerTag` по шаблону). Пресет не найден — `ref` = тег, дальше orphan-cleanup как сейчас |
| 6 | DNS: потребители читают сырые `Map`, смена `DnsServerRef.toJson` до них не доходит | словарь меняется у всех потребителей (2.4): `inline` → `user`, `rule` → `body`, `presetId` → `ref`, `varValues` → `vars`. **Ловушка:** `resolveDnsRulesList` молча выбрасывает `kind: user` как наследие §033, `resolveDnsServersList` выбрасывает незнакомый вид — и оба сохраняют результат. Один пропущенный сайт стирает DNS-записи пользователя. Ветки «legacy ignore» удаляются, тест держит записи всех видов 1.0 через оба резолвера |
| 7 | цепочки — отдельный ключ с `order`; в 1.0 — члены общего `sources[]`. Экран рисует цепочки после всех записей контроллера (`subscriptions_screen.dart`, `_rows`), `_setChains` нумерует от длины `server_lists` | записи цепочек идут хвостом `sources[]` в своём порядке. `SourceChain.order`, `_sortChainsByOrder`, `migrateChainOrderIfNeeded` и их вызовы (`main.dart`, `workspace_controller.dart`, `backup_service.dart`, `handlers/backup.dart`) снимаются. `saveServerLists` переписывает часть без цепочек, `setChains` — часть цепочек. Цепочка членом папки (1.0) у LxBox не заводится: импорт по-прежнему даёт `backup_source_kind_unsupported` |
| 8 | `hops`, `detour` в модели — финальные теги конфига; в 1.0 — `{folder_id?, tag}` | **Решение владельца 14.09 (D-112, 6.4): модель переходит на NodeLink.** `DetourPolicy.overrideDetour`, `FolderMember.detour`, `SourceChain.hops` хранят `{folder_id?, tag}`: у члена папки `folder_id` обязателен, `tag` — сырой тег узла внутри папки (до `tag_policy`/префикса); у корневой ссылки `folder_id` пуст. Финальный тег вычисляет только сборка конфига. Миграция v0 резолвит финальный тег в NodeLink по состоянию до миграции; `_LinkIndex` удаляется вместе с переводчиком (волна C) |
| 9 | префикс тегов: у контракта разделитель внутри префикса, у модели — снаружи | кодек дописывает один пробел на записи и снимает ровно один хвостовой пробел на чтении (не `trimRight`, как читатель 438): префикс с пробелами, заданный через Debug API, не теряется |
| 10 | `disabled_hashes` — ISO-8601 с миллисекундами, `disabled` — unix seconds | точность до секунды; TTL-очистка (от 24 ч до месяца) разницы не видит |
| 11 | TTL srs-правила (§366) кодек не знает | новое поле `update_interval_hours`; экспорт называет потерю |
| 12 | нормализации кодека, безвредные для бэкапа и потерянные для хранения: `_optString` режет пробелы у `name`, `id`, `description`, пустой `description` → нет поля; `ports` с нечислом отбрасывает `intPorts` | путь хранения не режет строки (имя srs-правила — тег `rule_set` в конфиге); нечисловые `ports` отбрасываются — сборка их и сейчас не эмитит, число — в отчёте миграции |
| 13 | `CustomRule.toJson()` — не только хранение: сравнение в `isDirty` (`custom_rule_edit/edit_controller.dart`), JSON-вкладка редактора (`tabs/view_tab.dart`), файл правил (`rule_transfer.dart`), носитель патча `PATCH /rules/{id}` (ключи `domainSuffixes`…) | всё на форму записей; файл правил → `format: 2`, `format: 1` читает legacy-читатель; `PATCH /rules/{id}` патчит модель через `copyWith` по виду; снаружи Debug API (`serializeCustomRule`, snake_case) не меняется |
| 14 | `SourceChain.toJson()` — ответ `GET /chains` («storage shape») | ответ остаётся каноном `source_chain.schema.json` без `order` (`toCanonJson()`); хранение — через кодек |

### 2.4 Кто читает сырое хранение мимо моделей

Grep по `server_lists`, `custom_rules`, `dns_options`, `chains`,
`getDnsServers`, `getDnsRulesList`, `saveDnsServers`, `saveDnsRulesList`:

| Место | Что читает | Правка |
|---|---|---|
| `lib/services/settings_storage/sources_rules.dart` | `server_lists`, `custom_rules` | `sources`, `rules` через кодек |
| `lib/services/settings_storage/chains.dart` | `chains`, длину `server_lists` | хвост `sources[]`, без `order` |
| `lib/services/settings_storage/network.dart` | `dns_options.servers/rules/rules_json` | `dns.servers/rules`; `_saveDnsRules` удаляется |
| `lib/services/settings_storage.dart` | allowlist, `saveDnsRules` (`@Deprecated`) | ключи 1.1; устаревший API удаляется |
| `lib/services/backup_service.dart` | `server_lists` (категория, счётчики, слияние по `id`), `custom_rules` (счётчик), `chains`/`dns_options` в `_topLevelRoutingKeys` | фильтр `sources[]` по `kind` (цепочка → Routing, прочее → Server lists), `rules`/`dns` → Routing, `storage_version` пишется всегда; блок без версии мигрирует до фильтра |
| `lib/services/debug/serializers/storage.dart` | `server_lists[].url/nodes/rawBody/members`. Ключа `rawBody` в хранении нет (там `raw_body`) — длина одиночного сервера сейчас не скрывается | `sources[].url` маской, `nodes[]` → счётчик, `origin.raw` → длина |
| `lib/services/debug/handlers/backup.dart` | `storage` целиком | блок без версии мигрирует; `normalizeLegacyDirectionKeys` уходит в миграцию |
| `lib/services/debug/handlers/settings.dart` | DNS PUT: kind-ref, pre-§043 full-body, строка `rules` | только форма записей, прочее — 400 (3.4) |
| DNS-потребители: `lib/screens/dns_settings_screen.dart`, `…/dns_settings_screen/dns_server_resolver.dart`, `…/widgets/dns_rule_tile.dart`, `…/user_rule_editor_sheet.dart`, `lib/screens/dns_server_edit/edit_controller.dart`, `lib/screens/routing_screen.dart`, `lib/screens/custom_rule_edit/edit_controller.dart`, `lib/services/builder/post_steps/dns_servers.dart`, `…/dns_rules.dart`, `lib/services/builder/build_config.dart`, `lib/services/dns/dns_controller.dart`, `lib/services/dns/dns_backup.dart`, `lib/services/rule_transfer.dart` | сырые записи `dns_options` | словарь записей (2.3, п. 6); миграция форм до §044 (`_migrateLegacyDnsServers`) удаляется |
| `lib/services/lx_backup.dart` (`decoded['chains']`) | секция файла 0.12, не хранение | не трогается |
| Kotlin (`app/android/app/src/main/kotlin/…`) | `lxbox_settings.json` не читает: упоминания только в комментариях `L10n.kt`, `BootReceiver.kt` (`app_language` приходит зеркалом §189) | — |
| Automation §047 | контроллеры и геттеры флагов `SettingsStorage` | — |
| `lib/services/dump_builder.dart` | модели (`getServerLists`) | — |

### 2.5 Слои и зоны ответственности

Решение 14.09.2026, сверено с лаунчером: у него (1) и (2) те же, (3) и (4)
нет, и это его долг. Двойное представление state и модели мастера
(`wizard_model.go` + синхронизаторы) не повторяем.

| Слой | Модуль | Отвечает за | Не делает |
|---|---|---|---|
| 1. Файл | `settings_storage.dart` (ядро), `storage_migration/**` | атомарное чтение и запись документа, `storage_version`, миграция, `.v0.bak` | не знает полей записей |
| 2. Кодек | `models/record_codec.dart` | модель ↔ запись 1.0, чистые функции; один на хранение, бэкап, файл правил и Debug API. **Терпимое чтение**: нормализация формы на чтении (файлы приходят от лаунчера и старых версий), незнакомые ключи `body` не теряются | не ходит в хранение, не держит инварианты между записями |
| 3. Модели | `lib/models/**` | неизменяемые значения, `==`/`hashCode`, `copyWith`; `NodeLink {folderId, tag}` | не сериализуют себя как рабочий формат, не знают о хранении |
| 4. Репозитории | `settings_storage/<сущность>.dart` | типизированный get/save по сущности; инварианты на записи: ось правил, ссылки DNS, реестр ссылок на узлы | не строят конфиг, не рисуют |
| 5. Сервисы | резолвер NodeLink, резолверы DNS, слияние импорта §16.2, срез бэкапа, файл правил | логика над моделями через репозитории | не читают сырой документ |
| 6. Потребители | сборка, контроллеры и экраны, Debug API, Automation | только модели и сервисы; JSON наружу — через кодек или сериализаторы API | без сырых `Map` из хранения |

**NodeLink (D-112, как у лаунчера).**

- **Запись** хранит только `{folder_id, tag}`, кэша финального тега нет.
  Пустой `folder_id` — корневое пространство финальных имён: верхний узел,
  Направление, служебный тег шаблона.
- **Резолв** — только на сборке, вторым проходом, когда финальные теги всех
  источников известны (у лаунчера `core/config/nodelink_resolve.go`:
  `byFolder[id][raw]`, `byRootTag`). Превью экрана строит тот же пул
  производно, это кэш экрана, а не поле записи.
- **`tag_policy`** (префикс папки) резолвится лениво, чинить нечего.
- **Реестр ссылок на записи** (слой 4, один на все носители: detour
  источника, detour члена, `hops`). Переименование и перенос узла переписывают
  ссылки сразу. Удаление их гасит. Переименование корневого узла тоже
  переписывает: у лаунчера оно пока гасит, это старая норма.
- **Сборка — вторая линия защиты.** detour и хопы fail-closed: носитель
  деградирует с предупреждением и молча напрямую не уходит. Кольца тоже
  fail-closed.
- **UI.** Видимое поведение при удалении и переименовании не меняется без
  вопроса владельцу (правило 14.09).

**Бэкап** — срез хранения тем же кодеком (слой 5).

- **Срез** снимает кэш и рантайм (`nodes[]` подписки, статусы).
- **Тонкий слой** остаётся в согласованных местах BACKUP §1.
- **Поля записей** в срезе перечислены явно. Проверка конца этапа сверяет
  набор ключей записи хранения с набором среза, чтобы новое поле не
  потерялось молча (у лаунчера `Source10` и тест наборов).
- **Импорт:** 0.x и 1.0 читаются в одну форму, путь слияния один. `folder_id`
  в ссылках переписывается по карте ремапа папок.

## 3. Миграция

### 3.1 Признак и порядок

Признак — ключ `storage_version`. Нет ключа — форма 2.23.2. Миграция
запускается, если версии нет или хотя бы один legacy-ключ (`server_lists`,
`chains`, `custom_rules`, `dns_options`) присутствует; без legacy-ключей
только ставится `storage_version: 1`.

Точка запуска — `_load()` в `lib/services/settings_storage/io.dart`, сразу
после разбора основного файла или `.bak`, до записи в `_cache`. Это
единственная точка, через которую проходят старт (`main.dart`: первое
чтение — `bootstrapAndSyncNativePrefs`), загрузка слота Workspaces
(`clearCache` → `_load`) и тесты. Как у лаунчера `Load`: миграция внутри
чтения, а не отдельным вызовом, который кто-то забудет.

Шаги:

1. Разобрать документ (как сейчас: основной файл → `.bak` → `{}`).
2. `presetIdByDnsServerTag` из `TemplateLoader.load()`; ошибка загрузки
   шаблона не валит миграцию — preset-серверы получают `ref` = тег (2.3, п. 5).
3. `migrateStorageDoc`: legacy-читатели → модели → кодек; удаление мёртвых
   ключей (1.1); переименование `channels`/`channels_migrated`, если
   `directions` нет; `storage_version: 1`.
4. Записать копию исходных байтов `lxbox_settings.json.v0.bak`, только если
   её ещё нет (tmp + rename; существующая копия — самый первый исходник, её
   не перетираем).
5. Записать новый документ `_atomicSave` (§072: tmp с flush + rename).
6. `_cache` = новый документ; отчёт — одной строкой info в AppLog, потери
   (битые записи, нечитаемые json-правила, нечисловые порты, формы DNS старше
   §044) — warning с именами.

`configDirty` миграция не поднимает: конфиг от неё не меняется.

### 3.2 Атомарность, сбой, повтор

| Сбой | Что на диске | Следующий старт |
|---|---|---|
| до шага 4 | старый файл | миграция заново |
| между 4 и 5 | старый файл + `.v0.bak` | миграция заново, копия не перезаписывается |
| внутри rename шага 5 | старый или новый файл (rename атомарен) | заново или ничего |
| после 5 | новый файл; `.bak` = старый файл (его сделал `_atomicSave`) | ничего; если основной файл потом побьётся до следующей записи, `_load` восстановит `.bak` старой формы и мигрирует его снова |

Идемпотентность: документ с `storage_version: 1` и без legacy-ключей не
трогается. `migrateStorageDoc(migrateStorageDoc(x)) == migrateStorageDoc(x)`
— тест.

Версия есть и legacy-ключи тоже (2.23.2 поверх данных 2.23.3 без удаления, 3.5):
legacy-ключи отбрасываются с warning, записи в `sources`/`rules`/`dns`
остаются. Слияния нет: единственный законный источник второй копии —
откат, и её данные устарели.

`storage_version` больше известной: документ читается как текущий,
незнакомые ключи верхнего уровня сохраняются при записи (как сейчас),
строка error в AppLog.

### 3.3 Workspaces (§417)

Слот хранит копию `lxbox_settings.json` в `workspaces/<имя>/`.
`WorkspaceStore._performLoad` копирует сцену в слот `current`, затем слот
цели в сцену; дальше `_reloadStateFromDisk` → `clearCache` → `_load()`, и
рабочая копия мигрирует шагом 3.1.

Копия исходника у слота: `.v0.bak` рядом с рабочим файлом уже может
существовать (от первой миграции), и шаг 4 копию слота не запишет. Поэтому
`_performLoad` перед копированием проверяет файл слота-цели: нет
`storage_version` — копирует его в
`workspaces/<имя>/lxbox_settings.json.v0.bak` (только если копии нет).
`kSlotEntries` перечисляет файлы поимённо, копия в сцену не попадёт.

Спящие слоты не мигрируют до загрузки: их никто не читает. `Save as` пишет
слот уже в новой форме.

### 3.4 Входы старой формы

| Вход | Решение |
|---|---|
| `lxbox_settings.json` на диске | миграция в `_load()` |
| слот Workspaces | миграция при загрузке + копия в папке слота (3.3) |
| внутренний бэкап (`app: lxbox`, `kind: backup`, блок `storage`) из 2.23.2 и раньше | `BackupService.applyImport` и `restore_backup.dart`: `migrateStorageDoc` над блоком до категорийного фильтра; превью (`import_preview_dialog.dart`) считает по мигрированному блоку |
| LX Backup `lx_backup: 1` | legacy-декодер 0.x (438) без изменений |
| LX Backup `lx_backup: 2` | декодер 1.0; записи разбирает кодек хранения |
| файл правил `kind: rules`, `format: 1` (§396) | legacy-читатель правил и DNS-записей; экспорт пишет `format: 2` |
| `POST /backup/import` | блок `storage` без версии принимается и мигрирует; в ответе `applied.migrated: true` и отчёт |
| `GET /backup/export?include=storage` | новая форма со `storage_version` |
| `PUT /settings/dns_options/servers` | только форма записей (`kind: user\|preset\|template`); kind-ref `inline` и pre-§043 full-body — 400 с образцом формы записи |
| `PUT /settings/dns_options/rules` | только массив записей; kind-ref `inline`/`presetId` — 400; строковая ветка (`rules_json`) удаляется |
| `POST /rules`, `PATCH /rules/{id}` | собственная схема API не меняется |
| `GET/POST/PATCH /chains` | канон без `order` |
| `PUT /config` | хранение не читает, без изменений |
| `GET /state/storage` | новая форма, скраббер по новым путям |

Пути URL (`/settings/dns_options/*`) не переименовываются: это адреса API,
а не ключи файла.

### 3.5 Откат на 2.23.2

Android не ставит APK с младшим versionCode поверх установленного (Google
Play, F-Droid, APK с GitHub); удаление стирает данные приложения вместе с
`.v0.bak`. Для пользователя откат — это чистая 2.23.2 и восстановление из
файла.

| Сценарий | Что видит пользователь |
|---|---|
| чистая 2.23.2 + внутренний бэкап, снятый на 2.23.2 или раньше | восстановление как раньше |
| чистая 2.23.2 + внутренний бэкап 2.23.3 | allowlist 2.23.2 отбрасывает `sources`, `rules`, `dns`, `storage_version` (снэкбар о пропущенных ключах): нет источников, цепочек, правил и DNS-записей; Направления, `vars`, аккаунты WARP, режимы на месте |
| чистая 2.23.2 + LX Backup 1.0 | отказ целиком: «новее поддерживаемого» |
| 2.23.2 поверх данных 2.23.3 без удаления (`adb install -r -d` на стенде) | `_getServerLists` не находит `server_lists`: пустой список; правил нет; DNS досеивается из шаблона. Новые ключи 2.23.2 не трогает и перезаписывает вместе с `_cache`. Возврат на 2.23.3 — 3.2, «версия есть и legacy-ключи тоже» |

Решение: основной файл старых ключей не держит; `.v0.bak` остаётся на
устройстве, пока приложение установлено (один файл настроек, удаление —
отдельной задачей через несколько релизов). Для стендов и опытных
пользователей — `GET /backup/export?include=storage&from=v0_bak`: копия в
конверте внутреннего бэкапа, который 2.23.2 принимает `POST /backup/import`
(состояние на момент миграции). Кнопки в UI нет (В3). Release notes 2.23.3:
откат на 2.23.2 не поддерживается, бэкап 2.23.3 версией 2.23.2 не читается.

## 4. Бэкап после миграции

### 4.1 Что остаётся в `lx_backup.dart` и что уходит

| Часть | Сейчас (438) | После |
|---|---|---|
| `sources[]` на экспорте | `_subscription10ToJson`, `_server10ToJson`, `_folder10ToJson`, `_chain10ToJson`, `_identityToJson`, `_prefixToContract` | записи хранения (`sourceToRecord`, `chainToRecord`) + срез полей L по таблице 1.3; NodeLink из записи как есть; `body` для JSON-исходника с одним outbound (`_origin10`, пока В1) |
| `rules[]` на экспорте | `_rule10ToJson` (json → inline, массив по записям) | записи хранения; срез `verbatim` и `update_interval_hours`; `verbatim` без `body` не пишется, `backup_local_only_dropped` |
| `dns` на экспорте | `dnsToBackup` → `LxDns` → `_dns10ToJson`, `_presetServerRecord`; экран экспорта грузит шаблон ради `preset_id` | записи `dns.servers/rules` + три скаляра из `vars`; срез `description` и `vars` сервера; `srs`/`template`-правила — как 1.3. Шаблон экрану экспорта больше не нужен: `preset_id` в записи |
| предупреждения экспорта | `_noteLocalOnly` в каждом писателе | один срез по таблице полей: срезанное поле L, отличное от умолчания, → одно `backup_local_only_dropped` на сущность |
| тонкий слой | `_directionToJson`, переносимые `vars`, `route.final`, `warp[]` | без изменений |
| чтение 0.x | `_parse0x` | без изменений |
| чтение 1.0 | `_parse10`: свой разбор источников, кодек для правил и DNS | записи источников тоже разбирает кодек хранения (`sourceFromRecord`, `chainFromRecord`); промежуточные `LxSubscription`/`LxServer`/`LxFolder` остаются, их же даёт декодер 0.x |
| слияние §9 | `mergeBackupSubscriptions`, `mergeBackupServers`, `resolveBackupChainHops`, `renumberBackupAxis`, `applyDnsBackup` | без изменений по смыслу; `applyDnsBackup` пишет записи в словаре 1.0 |

Внутренний бэкап (`BackupService`) — снимок хранения; после миграции он
сам несёт форму 1.0 и отдельной работы, кроме категорий (2.4), не требует.

### 4.2 Инварианты и проверка

| Инвариант | Проверка |
|---|---|
| `config.json` из одного состояния до и после миграции совпадает байт в байт | golden: в волне 0 текущий код собирает конфиг из фикстуры хранения 2.23.2 и пишет эталон; после 439 тест грузит ту же фикстуру (миграция в `_load`), собирает и сравнивает байты. Поля, которые меняются между двумя сборками одного состояния на текущем коде, определяются двойной сборкой в волне 0 и исключаются из сравнения явным списком |
| LX Backup из того же состояния не меняется | golden экспорта 1.0 из волны 0; после 439 — тот же файл, кроме `exported_at` и `exported_by.version`. Ожидаемые расхождения перечислены в тесте: `id` у второй и следующих записей разделённого json-массива, новое предупреждение о TTL srs (в файл не входит) |
| миграция идемпотентна | `migrateStorageDoc` дважды = один раз; повторный старт не пишет файл |
| `fromRecord(toRecord(x))` = `x` | кодек: подписка со всеми полями L, сервер с `sections` и `detour`, папка с `unsupported`-членом и префиксом с пробелом, цепочка с `rewrite`, правила всех видов (json-объект, массив, нечитаемый текст, srs с TTL и двумя `refs`, preset с `vars`), DNS всех видов (preset с `presetId`, template с `vars`, srs- и template-правила) — сравнение по `toRecord` и по сборке |
| `import(export(x))` = `x` | существующий `lx_backup_roundtrip_test.dart` на мигрированном состоянии |
| DNS-записи переживают резолверы | `resolveDnsServersList`/`resolveDnsRulesList` над записями всех видов 1.0: состав и порядок не меняются, файл не перезаписывается |

## 5. Тесты и проверка на устройстве

### 5.1 Затронутые тесты

Грубый счёт grep по `app/test` (282 файла, 4209 тестов):

| Признак | Файлов |
|---|---|
| `fromJson` изменяемых моделей (`CustomRule*`, `ServerList`, `UserServer`, `FolderServers`, `FolderMember`, `SubscriptionServers`, `SourceChain`, `DnsServerRef`, `DnsRuleRef`) | 19 |
| сеттеры и геттеры хранения `saveServerLists`, `saveCustomRules`, `setChains`, `getDnsServers`, `getDnsRulesList`, `saveDnsServers`, `saveDnsRulesList` | 13 |
| литералы старых ключей: `'server_lists'` 6, `'custom_rules'` 3, `'dns_options'` 4, `'chains'` 6, `'members'` 2, `'srsUrl'` 3, `'presetId'` 7, `'varValues'` 4 | ~20 (с пересечениями) |
| `'rule':` в DNS-записях | до 14, часть — не DNS |

Итого 35–45 файлов. Снимков настоящего хранения 2.23.2 в
`app/test/fixtures/` нет: там только `lx_backup/launcher_v8_export10.json`.

### 5.2 Новые тесты и фикстуры

| Файл | Что |
|---|---|
| `test/fixtures/storage/v2_23_2_rich.lxbox_settings.json` | синтетика: каждый вид записи и каждое поле L из 1.2, мёртвые ключи, `channels` без `directions`, `UserServer` с двумя узлами, json-правила (объект, массив, битый текст, ключи `//`), srs с TTL, порты с нечислом, префикс с пробелом |
| `test/fixtures/storage/v2_23_2_avd.lxbox_settings.json` | снимок стенда `LxBox_test` через `GET /backup/export?include=storage` на 2.23.2; URL, ключи и токены заменены |
| `test/fixtures/storage/sub_cache/…` | тела подписок фикстур |
| `test/fixtures/storage/*.config.golden.json`, `*.lx_backup.golden.json` | эталоны волны 0 |
| `test/storage_migration/migrate_storage_test.dart` | шаги 3.1, мёртвые ключи, отчёт, идемпотентность, `.v0.bak` один раз, сбой между шагами 4 и 5 (старый файл + копия), версия и legacy-ключи вместе, версия выше известной |
| `test/storage_migration/config_identity_test.dart` | golden конфига и LX Backup (4.2) |
| `test/models/record_codec_sources_test.dart` | круг кодека источников и цепочек; правила и DNS — дополнения к существующим тестам кодека |
| `test/services/builder/dns_resolvers_record_kinds_test.dart` | записи всех видов через оба резолвера |
| `test/services/backup_service_legacy_test.dart` | внутренний бэкап 2.23.2 → конфиг = golden; категории по `sources[].kind` |
| `test/services/rule_transfer_format1_test.dart` | файл правил `format: 1` |
| `test/services/debug/backup_import_legacy_test.dart`, `dns_put_legacy_rejected_test.dart` | 3.4 |
| `test/services/workspace_legacy_slot_load_test.dart` | загрузка слота старой формы и копия в папке слота (рядом с `workspace_store_test.dart`) |

Прогон перед коммитом: `flutter analyze` по всему проекту и `flutter test`
(CI analyze = весь проект), четыре l10n-чекера pre-flight.

### 5.3 Сценарий на AVD `LxBox_test`

Установка APK — только с разрешения владельца. Если у эмулятора нет сети,
первым делом проверить VPN на хосте. Токен Debug API на AVD свой.

1. На 2.23.2 (релизный APK) собрать состояние: подписка с `import_rules` и
   отметками `disabled`; файловая подписка; одиночные серверы URI, WG-INI,
   JSON, Tailscale с `sections`; папка с префиксом, `ping_url`, личным
   detour члена и нечитаемым членом; две цепочки, вторая ссылается на
   первую; правила inline, srs с двумя `refs` и своим TTL, preset с
   `vars`, json-объект, json-массив; DNS: user-сервер, template-сервер с
   `vars`, preset-серверы, DNS-правила user, srs, preset; второй слот
   Workspaces со своим составом.
2. Эталон до: `POST /action/rebuild-config` дважды → `GET /config` (оба
   раза, разброс между сборками); `GET /backup/export?include=storage`;
   экспорт LX Backup из экрана бэкапа; `GET /state/storage`.
3. `adb install -r` сборки 2.23.3 поверх, без удаления.
4. Первый старт: `GET /state/storage` — `storage_version: 1`, legacy-ключей
   нет; `GET /backup/export?include=storage&from=v0_bak` — байты равны
   экспорту шага 2.
5. `GET /config` без пересборки, затем `POST /action/rebuild-config` →
   `GET /config`: оба совпадают с эталоном шага 2 за вычетом разброса.
6. Экспорт LX Backup — сравнить с шагом 2 (ожидаемые расхождения 4.2).
7. Экраны: источники (порядок, цепочки внизу), папка, Routing (порядок оси,
   json-правило открывается), DNS (все записи на месте после входа и выхода).
8. Загрузить второй слот: `GET /state/storage` — мигрировал, конфиг
   собирается; вернуться в первый слот.
9. Внутренний бэкап шага 2 восстановить в режиме replace → `GET /config` =
   эталон.
10. VPN: подключение, трафик через узел из папки и через цепочку.

## 6. План работ

### 6.1 Волны

**Решение владельца (14.09.2026, вечер): сначала граница хранения, потом
формат.** Файл хранения читается в модели ровно в одном месте; сборка
конфига, экраны, бэкап, файл правил и Debug API работают только с моделями.
Смена формы на 1.0 после этого — правка кодека и миграция; экспорт LX Backup
становится срезом хранения, переводчик 438 удаляется, а не переделывается.
Первые волны не меняют ни формат файла, ни конфиг: golden из волны 0
остаётся зелёным на каждой из них.

| Волна | Что | Часы | Зависит | Файлы (за волной) |
|---|---|---|---|---|
| 0 | golden на текущем коде: фикстуры хранения (синтетическая богатая + снятая с AVD), `config.json` из каждой, LX Backup-экспорт и импорт; снимок AVD | 3 | — | `test/fixtures/storage/**`, `test/storage_migration/golden_*` |
| A1 | граница DNS: все потребители сырых записей `dns_options` переходят на модели `DnsServerRef`/`DnsRuleRef` через один API хранения (`settings_storage/network.dart`); ветки «legacy ignore» в резолверах, выбрасывающие незнакомые виды с сохранением, удаляются; формат файла тот же | 8 | 0 | DNS-потребители из 2.4 кроме `dns_backup.dart`, `rule_transfer.dart`; `lib/services/settings_storage/network.dart`; их тесты |
| A2 | граница остальных сущностей: `toJson()` моделей перестаёт быть рабочим форматом (сравнение в `isDirty`, JSON-вкладка редактора, носитель `PATCH /rules`, файл правил) — вместо него равенство моделей / явный кодек; всё чтение `server_lists`/`custom_rules`/`chains` — только через `settings_storage/*`; формат файла тот же | 5 | 0 | `lib/screens/custom_rule_edit/**`, `lib/services/rule_transfer.dart`, `lib/services/debug/handlers/rules.dart`, `lib/services/settings_storage/{sources_rules,chains}.dart`, их тесты |
| A3 | Debug API и бэкап-сервис на моделях: скраббер `/state/storage` (баг `rawBody`), `handlers/backup.dart`, `handlers/settings.dart` DNS PUT, `backup_service.dart` категории | 3 | A1, A2 | `lib/services/debug/**`, `lib/services/backup_service.dart` |
| B | форма 1.0 в кодеке для всех сущностей (2.3), `legacy_form_v0.dart`, ключи хранения `sources`/`rules`/`dns`, `storage_version`, миграция в `_load` + `.v0.bak`, слоты Workspaces; NodeLink в моделях (`detour`, `detour` члена, `hops`) с резолвом в финальный тег при сборке, пикеры и Debug API на NodeLink, миграция финальных тегов в NodeLink (2.3 п. 8) | 18 | A3 | `lib/models/**`, `lib/services/settings_storage*`, `lib/services/storage_migration/**`, `lib/services/workspaces/**`, `lib/main.dart` |
| C | экспорт LX Backup = срез хранения + тонкий слой; импорт 1.0 через кодек; удаление переводчика 438 и `_LinkIndex`; файл правил `format: 2`; `dns_backup.dart` | 5 | B | `lib/services/{lx_backup,rule_transfer}.dart`, `lib/services/dns/dns_backup.dart`, `lib/screens/backup_screen*`, `lib/screens/home/restore_backup.dart`, `test/contract/lx_backup*` |
| D | зачистка тестов, analyze, l10n, доки, статус спеки | 6 | C | `test/**`, `docs/**`, `CHANGELOG.md` |
| E | AVD (5.3): установка поверх 2.23.2, `/config` до/после, импорт файла лаунчера 1.0, экспорт → импорт | 3 | D | — |

Итого **~51 ч** (NodeLink +6 ч к волне B). A1 и A2 параллельно в отдельных worktree (файлы не
пересекаются); остальное последовательно. Порядок влития:
0 → A1, A2 → A3 → B → C → D → E. Checkout общий: в коммит только свои файлы
поимённо, перед `git add` смотреть `git diff`.

### 6.2 Риски

| Риск | Мера |
|---|---|
| пропущенный DNS-потребитель стирает DNS-записи пользователя (резолвер выбрасывает `kind: user` и сохраняет) | ветки «legacy ignore» удаляются; тест записей всех видов через оба резолвера; grep словаря в чек-листе ревью волны 3 |
| кодек теряет поле, которое сборка использует (обрезка имени srs, префикс с пробелом, TTL) | golden конфига на двух фикстурах, одна снята с живого стенда |
| откат на 2.23.2 фактически невозможен без потери данных | release notes; `.v0.bak` и `from=v0_bak` для стендов; В3 |
| слот Workspaces §417 не проверен на устройстве и до 439 | шаг 8 сценария; тест загрузки слота старой формы |
| шаблон на раннем `_load()` (до `LocaleController.bootstrap`) | `preset_id` и теги DNS от локали не зависят; ошибка загрузки шаблона → `ref` = тег, резолвер доводит |
| скрипты и агенты шлют в `PUT /settings/dns_options/*` старые формы или читают `server_lists` из `/state/storage` | 400 с образцом формы; раздел в `debug-api-reference.md` |
| разделение json-массива меняет число правил и имена | В2; одна запись в отчёте миграции на правило |
| объём диффа в общем checkout (≈60 файлов `lib/`, ≈40 `test/`) | волны в worktree, влитие по порядку 6.1 |

### 6.3 Вопросы владельцу

- **В1.** В 2.23.3 истина узла остаётся текстом (`origin.raw` перечитывается на загрузке, как сейчас), а `body` как истина с кнопкой Regen — отдельной задачей после релиза? Рекомендация: да; заморозка тела меняет конфиг после правок парсера и требует UI.
- **В2.** json-правило массивом миграция делит на N правил (`имя`, `имя #2`, как экспорт 438), редактор массив больше не сохраняет. Согласны?
- **В3.** Кнопки «экспорт в формате 2.23.2» в UI нет; откат — переустановка и файл, снятый на 2.23.2. Согласны?

**Ответы владельца (14.09.2026, вечер):**

- **В1 — да.** В 2.23.3 истина узла — текст исходника. «Тело как истина» с
  кнопкой Regen — отдельная задача после релиза, с требованиями владельца:
  тело можно править до Regen, и оно живёт на отдельной вкладке редактора
  узла.
- **В2 — да, при одинаковой логике у лаунчера.** Лаунчер принял норму
  14.09: запись правила = один объект sing-box в `body`; массив на входе
  раскладывается на `имя`, `имя #2`… с общим `enabled` и `num` подряд;
  не-объект или битый JSON отбрасывается с существующим предупреждением;
  редактор массив не сохраняет. У лаунчера legacy-импорт 0.x `kind: json`
  начнёт разворачиваться патчем после 1.6.0.
- **В3 — да**, кнопки старого экспорта нет. Старые бэкапы (0.x, в том числе
  снятые на 2.23.2 и лаунчером до 1.6.0) 2.23.3 читает: legacy-декодер 0.x
  остаётся. Не работает только обратный путь — 2.23.2 не читает файл 2.23.3.

### 6.4 Вопросы лаунчеру

- **Л1.** `{tag: <финальный тег члена папки или узла подписки>}` без `folder_id` лаунчер резолвит в «корневом пространстве финальных тегов» (BACKUP §4, §6)? Если да, `_LinkIndex` на экспорте LxBox снимается.
- **Л2.** Поля записи LxBox из 1.3 (`detour_policy`, `import_rules`, `ping_url`, `label` цепочки, `update_interval_hours`, `verbatim`, `description`) объявить в схеме с поддержкой «LxBox» (молчаливый игнор, BACKUP §1), чтобы экспорт стал ровно записью хранения, — или экспорт срезает их с `backup_local_only_dropped`, как сейчас?

**Ответы лаунчера (14.09.2026):**

- **Л1 — да, в 1.6.0.** Ссылку без `folder_id` на член папки лаунчер
  нормализует при импорте 1.0 уже в 1.6.0 (решение владельца: выпуск 1.6.0
  отложен, фикс и норма «одно правило — одно тело» входят в него, D-111).
  2.23.3 выходит не раньше 1.6.0, поэтому `_LinkIndex` на экспорте LxBox
  **снимается**: хранение и экспорт пишут `{tag: <финальный тег>}`. Кейс
  корпуса `legacy_012_json_rule_array` прогоняется нашим раннером после
  синка.
- **Л2 — объявляют.** Поля LxBox из §1.3, которые являются настройками (не
  кэш, не рантайм, не секреты), станут необязательными полями схемы с
  поддержкой «LxBox»; лаунчер игнорирует их молча (D-092, без
  `backup_unknown_field`). Нужен точный список под TASKS_LXBOX §16.7: имя,
  где, тип, смысл. Список отдаётся после волны кодека и моделей, когда
  зафиксированы имена полей записи; тогда экспорт перестаёт срезать эти поля и
  `backup_local_only_dropped` на них не эмитится.

**Решение владельца 14.09.2026 (поздно вечером, через лаунчер) — NodeLink,
D-112.** Ссылка на узел во всех проектах — `{folder_id, tag}`, не финальный
тег. У ссылки на член папки `folder_id` обязателен, `tag` — сырой тег узла
внутри папки (до `tag_policy`/префикса); у корневого узла `folder_id` пуст,
`tag` — его тег. Касается detour узла и папки, `hops` цепочки, состава
auto-группы — в хранении, бэкапе и API. Вывод ответа Л1 «хранение пишет
`{tag: <финальный тег>}`» **отменён**: хранение LxBox переходит на NodeLink
напрямую (2.3, п. 8; волна B). Норма — `contract/docs/NODE_LINK.md` и задача
`## 17` лаунчера (резолв, пустой `folder_id` внутри папки, fail-closed,
переименование/перенос/смена `tag_policy`, ремап id при импорте); хэш ждём.

Ссылки на узлы в модели LxBox (отправлено лаунчеру 14.09):
`DetourPolicy.overrideDetour` на любом источнике (сервер, папка, подписка),
`FolderMember.detour`, `SourceChain.hops` (позицией может быть и группа
подписки, Направление, служебный тег, другая цепочка). Не ссылки:
`ExplicitMembers.keys` auto-группы (identity-ключи
`protocol|server|port|credential`), `RuleMembers` и
`Direction.node_filter/default_filter` (regex по финальному тегу),
`Direction.include` (теги Направлений), outbound правил, `route_final`, detour
DNS-серверов (только Направления, direct, reject), `import_rules`
(JSONPath над emit-JSON), `disabled_hashes` (хэш узла). По финальному тегу в
рантайме, вне хранения: Intent `SWITCH_NODE`, выбор узла в Направлении,
Debug API `/folders/{id}/members/{index}`. Открыто до NODE_LINK.md: как
NodeLink адресует узел подписки и не-узловые позиции `hops`.

## 7. Файлы к правке

Новые:

- `app/lib/services/storage_migration/legacy_form_v0.dart`
- `app/lib/services/storage_migration/migrate_storage.dart`
- `app/test/fixtures/storage/**`
- `app/test/storage_migration/migrate_storage_test.dart`, `config_identity_test.dart`
- `app/test/models/record_codec_sources_test.dart`
- `app/test/services/builder/dns_resolvers_record_kinds_test.dart`
- `app/test/services/backup_service_legacy_test.dart`, `app/test/services/rule_transfer_format1_test.dart`
- `app/test/services/debug/backup_import_legacy_test.dart`, `dns_put_legacy_rejected_test.dart`
- `app/test/services/workspace_legacy_slot_load_test.dart`

Модели и кодек:

- `app/lib/models/record_codec.dart`
- `app/lib/models/server_list.dart`
- `app/lib/models/custom_rule.dart`
- `app/lib/models/dns_ref.dart`
- `app/lib/models/source_chain.dart`

Хранение и старт:

- `app/lib/services/settings_storage.dart`
- `app/lib/services/settings_storage/io.dart`, `sources_rules.dart`, `chains.dart`, `network.dart`, `backup_tun.dart`, `directions.dart`
- `app/lib/services/workspaces/workspace_store.dart`, `workspace_controller.dart`
- `app/lib/main.dart`

DNS:

- `app/lib/screens/dns_settings_screen.dart`
- `app/lib/screens/dns_settings_screen/dns_server_resolver.dart`, `widgets/dns_rule_tile.dart`, `user_rule_editor_sheet.dart`
- `app/lib/screens/dns_server_edit/edit_controller.dart`
- `app/lib/screens/routing_screen.dart`
- `app/lib/screens/custom_rule_edit/edit_controller.dart` (DNS-серверы для опции правила; `jsonError` — запрет массива; `isDirty`), `tabs/view_tab.dart`
- `app/lib/services/builder/post_steps/dns_servers.dart`, `dns_rules.dart`
- `app/lib/services/builder/build_config.dart`
- `app/lib/services/dns/dns_controller.dart`

Бэкапы и перенос:

- `app/lib/services/lx_backup.dart`
- `app/lib/services/dns/dns_backup.dart`
- `app/lib/services/backup_service.dart`
- `app/lib/services/rule_transfer.dart`
- `app/lib/screens/backup_screen.dart`, `backup_screen/import_preview_dialog.dart`
- `app/lib/screens/home/restore_backup.dart`
- `app/lib/screens/subscriptions_screen.dart` (перестановка цепочек без `order`)

Debug API:

- `app/lib/services/debug/serializers/storage.dart`
- `app/lib/services/debug/handlers/backup.dart`, `settings.dart`, `rules.dart`, `chains.dart`, `help.dart`

Тесты: 35–45 существующих файлов (5.1).

## Docs to update

| Файл | Что |
|---|---|
| `docs/STORAGE.md` | дерево файла и разделы `server_lists`, `custom_rules`, `dns_options`, `chains` → `sources`, `rules`, `dns`; `storage_version`; `.v0.bak` в «Disk layout»; «Legacy and removed keys» — ключи 2.23.2 и мёртвые ключи; «Debug API exposure» — скраббер |
| `docs/ARCHITECTURE.md` | список one-shot миграций (`SettingsStorage`): §439 вместо миграции порядка цепочек и форм DNS до §044; строка `record_codec.dart` — корневой кодек хранения; Feature Specs — строка 439 |
| `docs/api/debug-api-reference.md` | `/state/storage`, `/backup/export` (`from=v0_bak`), `/backup/import` (миграция), `PUT /settings/dns_options/*` (только форма записей), `/chains` без `order`; bash-примеры |
| `docs/spec/features/README.md` | строка индекса 439 |
| `docs/spec/tasks/438-lx-backup-1-0-read-write.md` | ссылка: переводчик экспорта заменён срезом хранения |
| `CHANGELOG.md` | Unreleased: Changed — форма хранения, файл правил `format: 2`, Debug API; Removed — `rules_json`, строковый `PUT /settings/dns_options/rules` |
| `RELEASE_NOTES.md`, `docs/releases/v2.23.3.md` | на бампе: откат на 2.23.2 не поддерживается, бэкапы 2.23.3 версия 2.23.2 не читает |
| `app/contract/TASKS_LXBOX.md` | не править у себя: вопросы Л1, Л2 — ответом лаунчеру по обычному пути синка контракта |
