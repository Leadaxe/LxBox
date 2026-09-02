# §401 — Бэкап = сериализация состояния (контракт 0.11.0 + решения 0.12)

**Тип:** schema cleanup / зеркалирование контракта
**Область:** `services/lx_backup.dart`, `screens/backup_screen.dart`
**Связано:** §393 (прошлая спека бэкапа, `features/393 directions`), §400
(`disabled`-ключи по тегу), §302 (import rules), §234 (папки), §112 контракта
(identity = тег)
**Источник:** `singbox-launcher/contract/docs/BACKUP_PRINCIPLES.md` (П1–П7),
`contract/docs/BACKUP.md` (0.11.0), SPEC 114 лаунчера; решения 0.12 D-082
(label) и D-083 (per-source identity), предложение D-08x (папки)

---

## 1. Что меняется

Контракт 0.11.0 объявил файл бэкапа **сериализацией состояния** (П1). Три
следствия, ради которых переписывается вся обвязка:

- экспорт — чистая функция состояния: два неотличимых состояния дают
  неотличимые файлы;
- состояние после импорта неотличимо от настроенного руками — теневых полей
  «на провоз» нет;
- `import(export(x))` в том же приложении = `x`, без посредников-карманов.

Механизм `extensions` **упразднён целиком** (П3). Он был прямым отрицанием
П1: провозимый блоб — это состояние-призрак, которое протухает, когда
каноническую часть правят на другой стороне, и делает экспорт нечистой
функцией. Непонятое теперь отбрасывается с предупреждением (П3/П6), а не
провозится.

Легаси-путей чтения нет (П4): схема одна, текущая. Старый файл 0.10.x
разбирается тем же общим правилом — общие поля применяются, `extensions` и
прочее незнакомое даёт warning.

---

## 2. Инвентаризация: что LxBox клал в `extensions.lxbox` и `_backup_fields`

Решения: **(а)** уже есть в схеме 0.11 — писать/читать верхним уровнем;
**(б)** поле по решениям 0.12; **(в)** отбросить с warning.

### 2.1 Корень файла

| Было (0.10.0) | Решение | Стало (0.11.0) |
|---|---|---|
| `extensions.<чужое приложение>` — блоб чужой стороны, хранился в `SettingsStorage.lx_backup_extensions` и возвращался в файл | **(в)** | не читается, не хранится, не пишется. На импорте — `backup_extensions_dropped` (один на файл) |
| `extensions.lxbox` — свой корневой карман (по факту всегда пустой: своё применялось полями) | **(в)** | ключ `extensions` в экспорт не пишется вовсе |

### 2.2 `subscriptions[]`

| Было (0.10.0) | Решение | Стало |
|---|---|---|
| `extensions.lxbox.id` | **(а)** | `subscriptions[].id` — поле схемы |
| `extensions.lxbox.type` (`'subscription'`) | **(в)** | не пишется: секция сама себя определяет |
| `extensions.lxbox.import_rules` + `import_rules_enabled` (§302) | **(в)** | mobile-only без дома в схеме → `backup_local_only_dropped` на ЭКСПОРТЕ |
| `extensions.lxbox.identity_override` | **(б)** D-083 | `subscriptions[].identity` — объект `{user_agent, send_hwid, hwid, device_os, ver_os, device_model}` |
| `extensions.lxbox.on_update_action` | **(в)** | `backup_local_only_dropped` |
| `extensions.lxbox.detour_policy` | **(в)** | `backup_local_only_dropped` |
| `_backup_fields` (чужие поля с прошлого импорта: `skip`, `max_nodes`, `outbounds`, `fold`, `detour_*`…) | **(в)** | механизм снесён; на импорте неизвестное даёт `backup_unknown_field` |
| `label` | остаётся | имя ИСТОЧНИКА, а не узла — D-082 его не трогает |
| `tag.prefix` | **(а)** | как было |
| `tag.postfix` / `tag.mask` | **(в)** | у нас применить нечем; на импорте `backup_unknown_field` их не ловит (ключи объявлены схемой) — пишем как есть, читаем только `prefix` |
| `update.interval_hours` | **(а)** | как было |
| `disabled` | **(а)** | ключи копируются как есть — тег или legacy 64-hex (§400, `IDENTITY.md` §5.1) |
| `skip` (наш boolean) | **(в)** | у нас применять нечем — **не пишем и не читаем**. Массив фильтров лаунчера отбрасывается с `backup_field_type_mismatch` |
| `detour` объектом (наш старый формат) | **(в)** | не пишем; на импорте — обычный неизвестный ключ (`backup_unknown_field`): в схеме 0.11 `detour` не объявлен вовсе, его место заняли `detour_tag` + `detour_node_*` |
| `exclude_from_global`, `expose_group_tags_to_global` (входящие) | **(в)** | `backup_source_flag_dropped` |

### 2.3 `servers[]`

| Было (0.10.0) | Решение | Стало |
|---|---|---|
| `extensions.lxbox.id`, `type`, `tag_prefix`, `detour_policy` | **(в)** | `id` не переносим (у папки/сервера он локальный), остальное → `backup_local_only_dropped` |
| `extensions.lxbox.origin`, `created_at` (UserServer) | **(в)** | диагностические, дома в схеме нет → в перечень `backup_local_only_dropped` не включаются (не пользовательская настройка) |
| `extensions.lxbox.members` (FolderServers) | **(б)** D-08x | каждый член едет ОТДЕЛЬНОЙ записью `servers[]` с полем `folder: "<имя папки>"` |
| `extensions.lxbox.ping_url` / `ping_timeout_ms` (§284) | **(в)** | `backup_local_only_dropped` на экспорте папки |
| `label` | **(б)** D-082 | экспорт НЕ пишет. Импорт: legacy-вход — у сервера без `node_tag` label становится именем записи, иначе `backup_label_dropped` |
| `uri` / `config_json` | **(а)** | как было; у папки — по записи на члена |
| `enabled` | **(а)** | как было; у члена папки — его собственный toggle |
| `detour` объектом | **(в)** | не пишем; на импорте → `backup_unknown_field`, как у подписки |

### 2.4 `chains[]`

| Было (0.10.0) | Решение | Стало |
|---|---|---|
| `label` | **(б)** D-082 | экспорт не пишет; импорт игнорирует, при `label != tag` → `backup_label_dropped` |
| `tag`, `enabled`, `chain` | **(а)** | как было |

### 2.5 `directions[]`

| Было (0.10.0) | Решение | Стало |
|---|---|---|
| `label` | **(в)** | контракт 0.9.0 отменил его: не пишем, при чтении игнорируем |

### 2.6 `rules[]`

| Было (0.10.0) | Решение | Стало |
|---|---|---|
| `extensions.lxbox.{packages, wifiSsids, wifiBssids, inbounds, ipIsPrivate, sourceIpCidrs, sourceIpIsPrivate}` | **(в)** | mobile-only матчеры → `backup_local_only_dropped` на экспорте правила |
| `extensions.lxbox.json` (тело `kind=json`) | **(в)** | без тела правило не восстановимо: на ЭКСПОРТЕ `backup_local_only_dropped` (наша настройка не поехала), на ИМПОРТЕ `backup_unknown_field` — потеря случилась на чужом экспорте, и код тот же, что у любого необрабатываемого `kind` (корпус `unknown_rule_kind_skipped`) |
| `extensions.lxbox._backup_fields` + `CustomRule.backupFields` | **(в)** | механизм снесён |
| `kind`, `name`, `enabled`, `num`, `outbound`, `ref`, `vars`, `match`, `dns`, `resolve` | **(а)** | как было (`dns`/`resolve` — наши поля таблицы §2, лаунчер их отбрасывает у себя) |

### 2.7 `dns`

| Было (0.10.0) | Решение | Стало |
|---|---|---|
| `dns.servers[].extensions.lxbox` / `dns.rules[].extensions.lxbox` | **(в)** | не пишем |
| «чужие» записи (`kind` вне канона), хранившиеся сырыми для re-export | **(в)** | не хранятся: `backup_dns_entry_skipped` на импорте, `backup_local_only_dropped` на экспорте |

### 2.8 `warp[]` (контракт 0.12.2, D-091/D-092)

Карман `extensions.lxbox` дожил в `warp[]` дольше остальных секций: полям
MASQUE-узла (`sni`, `idle_timeout`) в схеме 0.11 дома не было. Контракт 0.12.2
их объявил поимённо с пометкой `extension: mobile`, и карман снят и здесь —
целиком, вместе с чтением.

| Было (0.11.x) | Решение | Стало (0.12.2) |
|---|---|---|
| `warp[].extensions.lxbox.sni` | **(а)** | `warp[].sni` плоско в записи; необязательное — пишется только когда задано |
| `warp[].extensions.lxbox.idle_timeout` | **(а)** | `warp[].idle_timeout` плоско, та же необязательность; строка длительности (`"30s"`) |
| `warp[].extensions.lxbox.keep_alive` | **(а)** | `warp[].keep_alive` плоско — открытая часть секции (`additionalProperties`, «snake_case поля самой регистрации») |
| `warp[].extensions.lxbox.awg` (§126), `.endpoint` | **(а)** | `warp[].awg` / `warp[].endpoint` плоско, там же |
| чтение кармана на импорте | **(в)** | снято: старый файл с карманом читается общим правилом — `extensions` любой глубины даёт один `backup_extensions_dropped` на файл. Регистрация из такой записи применяется, `sni`/`idle_timeout` теряются |

Схема объявляет `sni` и `idle_timeout` в `warp[]`, поэтому у лаунчера они
попадают под правило «чужое ОБЪЯВЛЕННОЕ игнорируется молча»: он их не
применяет (SNI берёт из пула на сборке конфига, таймаут ставит UI), но
провозит сырым JSON до следующего экспорта — предупреждения не будет ни у
одной стороны. Все пять ключей внесены в таблицу обхода `_warpKeys`, иначе
собственный экспорт возвращался бы с `backup_unknown_field`.

Коды `backup_dns_entry_skipped` и `backup_warp_skipped` контракт завёл в
`registry/backup_warnings.json` — долговой список `_notYetInRegistry` в
sync-тесте реестра снят.

---

## 3. Предупреждения

Новые коды (константы рядом с существующими `kWarn*` в `lx_backup.dart`):

| Код | Где ставится | Detail |
|---|---|---|
| `backup_extensions_dropped` | импорт | ОДИН на файл, перечень затронутых записей: `<file root>, subscriptions[https://…]` |
| `backup_field_type_mismatch` | импорт | полный путь: `subscriptions[https://…].skip`. Только `skip` — единственная коллизия ТИПА объявленного ключа между 0.10.x и 0.11 |
| `backup_source_flag_dropped` | импорт | `subscriptions[https://…].exclude_from_global` |
| `backup_label_dropped` | импорт | тег записи, у которой подпись разошлась |
| `backup_source_identity_dropped` | импорт | `<label подписки>: key1, key2` |
| `backup_local_only_dropped` | ЭКСПОРТ | `<имя сущности>: field1, field2` — один на сущность |

Код `backup_local_only_dropped` один на обе стороны и оба направления: он
означает «настройка есть только у этой стороны, дома в общей схеме ей нет».
`backup_source_identity_dropped` остаётся узким — только про ключи объекта
`identity`.

Реестр кодов бэкапа лаунчер выносит в отдельный файл
`contract/registry/backup_warnings.json` (сейчас они лежат в общем
`warnings.json`). На код LxBox это не влияет — константы объявлены у нас.

Старые коды остаются: `backup_unknown_outbound`, `backup_final_dropped`,
`backup_unknown_preset`, `backup_var_skipped`, `backup_unknown_field`,
`backup_direction_exists`, `backup_chain_exists`, `backup_dns_entry_skipped`,
`backup_warp_skipped`.

**`backup_unknown_field`** переезжает с «только корень + directions + chains»
на обход ВСЕЙ глубины файла (эталон — `core/backup/file.go:scanUnknown`): путь
пишется целиком (`subscriptions[https://…].outbounds[vpn-1].key`), иначе
предупреждение не с чем сопоставить. Дедуп по полному пути: один ключ — одно
предупреждение.

### 3.1 Почему `extensions` — отдельный код, а не `backup_unknown_field`

`extensions` был не «лишним ключом», а карманом с произвольным содержимым.
Перечислять его внутренности по одной значило бы утопить пользователя в
списке вместо объяснения. Отсюда — один warning на файл с перечнем ЗАПИСЕЙ.

### 3.2 Почему `skip` — отдельный код

Ключ знакомый, разошёлся его ТИП: boolean у LxBox 0.10.x против массива
фильтров у 0.11.0. Пользователю важно различать «такого поля тут нет» и
«поле есть, но значение записано по-другому». Строгий разбор ронял бы весь
файл — то есть терял бы всё прочее молча, вопреки П6.

---

## 4. Папки (D-08x, предложено лаунчеру)

Схема не знает контейнеров. Решение: **каждый член FolderServers едет
отдельной записью `servers[]`** (`uri` или `config_json`, плюс `enabled`) с
необязательным полем `folder: "<имя папки>"`.

На импорте записи с одинаковым `folder` собираются в одну `FolderServers`
(создаётся, если такой ещё нет). Порядок членов — порядок записей файла.

Настройки самой папки в файл не едут: `ping_url`, `ping_timeout_ms` (§284),
`tag_prefix`, `detour_policy`, а также per-member `detour` (§237). Warning
`backup_local_only_dropped` — ОДИН на папку и только тогда, когда эти
настройки у неё реально заданы: предупреждать о неустановленном значило бы
шуметь на каждой папке подряд.

---

## 5. Per-source identity (D-083, контракт 0.12)

`subscriptions[].identity` — необязательный объект. Ключи схемы:
`user_agent`, `send_hwid`, `hwid`, `device_os`, `ver_os`, `device_model`,
`hash_device_model`. Все необязательные.

**Экспорт.** Объект пишется, только когда у подписки задан override
(`ServerList.identity != null`). Пустые строки не пишутся: у настройки
«не задано» и «задано пустым» значат разное, и пустышка в каждом файле
отличала бы два одинаковых состояния (П1). `hash_device_model` у нас нет —
не пишем.

**Импорт.** Наши шесть ключей применяются в `SubscriptionIdentityOverride`.
Всё остальное (`hash_device_model` и любое незнакомое) отбрасывается с
`backup_source_identity_dropped`, detail — `<label подписки>: key1, key2`,
ключи в порядке схемы, затем чужие по алфавиту (текст обязан быть
воспроизводимым: два импорта одного файла дают один текст).

Общий обход неизвестных ключей внутрь `identity` НЕ спускается — иначе одна
потеря давала бы два предупреждения.

Экспорт пишет объект уже сейчас, до синка контракта: копия схемы в
`app/contract` отстаёт, но состояние она не определяет.

---

## 6. Режим импорта

Один — **replace** (BACKUP.md §9). Прежний merge удалён: он не был достижим
ни из одного UI. Дедуп внутри файла остаётся: занятый тег Направления или
цепочки пропускается с warning.

В UI LxBox отдельного выбора режима не было — правки в `backup_screen.dart`
не требуется, кроме показа detail предупреждений.

---

## 7. Цена разрыва

Файл, снятый LxBox 0.10.x, читается — общие поля применяются, — но всё, что
лежало в `extensions.lxbox`, теряется: папки (состав), import-rules,
identity-override, mobile-only матчеры правил, тела `kind=json`, чужие
DNS-записи. Это задокументированная цена (П4), а не баг: обо всём сказано
предупреждением.

Правильный путь переноса — снять бэкап новой версией: она пишет то же самое
общими полями схемы, и roundtrip снова тождественен.

---

## 8. Что удаляется из кода

- `kLxAppLxBox` — только как имя приложения в `exported_by.app`; как ключ
  кармана больше нигде;
- `kLxBackupFieldsKey`, `_restoreBackupFields`, `_splitEntityExtensions`;
- `LxSubscription.ownExtensions` / `foreignExtensions` / `unknownFields`;
- `LxServer.ownExtensions` / `foreignExtensions` / `unknownFields`;
- `LxDnsRef.ownExtensions`, `LxDns.foreignServerEntries` /
  `foreignRuleEntries`;
- `LxBackupFile.foreignExtensions`;
- параметр `foreignExtensions` у `buildLxBackup`;
- `SettingsStorage.getLxBackupExtensions` / `setLxBackupExtensions` и ключ
  хранения `lx_backup_extensions` (§221: ключ снимается ИЗ ОБОИХ мест —
  allowlist и export);
- `CustomRule.backupFields` / `backupFieldsKey` / `backupFieldsJson` /
  `backupFieldsFromJson` — транзитный груз на правиле.

`Direction.label` и `SourceChain.label` удаляются отдельной задачей; здесь
`lx_backup.dart` просто перестаёт к ним обращаться.

---

## 9. Docs to update

- `CHANGELOG.md` — секция Unreleased: механизм `extensions` упразднён, бэкап
  0.10.x читается с потерями; папки едут записями `servers[]`; per-source
  identity переносится.
- `docs/STORAGE.md` — не трогаем: форма хранения настроек не меняется, снят
  только служебный ключ `lx_backup_extensions` (он не описан отдельной
  строкой хранения).
- `app/contract/` — синк на 0.11.0/0.12.0 делает координатор после коммита
  лаунчера; `tool/sync_contract.sh` этой задачей не запускается.

---

## 10. Критерии приёмки

1. Экспорт не пишет ключ `extensions` ни на корне, ни внутри записей —
   проверяется поиском строки в результате.
2. `extensions` на любой глубине входного файла даёт ровно ОДИН
   `backup_extensions_dropped` с перечнем записей.
3. Неизвестный ключ любой глубины даёт `backup_unknown_field` с полным путём.
4. `subscriptions[].skip` массивом (или нашим boolean 0.10.x) →
   `backup_field_type_mismatch`, остальные поля записи и весь остальной файл
   применяются. Объектный `detour` при этом даёт `backup_unknown_field`, а не
   type-mismatch: он в схеме не объявлен.
5. `exclude_from_global` / `expose_group_tags_to_global` → один
   `backup_source_flag_dropped` на ключ.
6. `label` у `servers[]` без `node_tag` становится именем записи молча; при
   расхождении с тегом — `backup_label_dropped`. У `chains[]` — всегда
   игнорируется, при расхождении с тегом warning. У `directions[]` —
   игнорируется молча (снят контрактом 0.9.0).
7. Папка из N членов даёт N записей `servers[]` с одинаковым `folder`; импорт
   собирает их обратно в одну папку.
8. Подписка с override пишет `identity`; неизвестные ключи объекта на импорте
   дают один `backup_source_identity_dropped` на подписку.
9. Экспорт сущности с mobile-only настройками даёт один
   `backup_local_only_dropped` с перечнем полей.
10. `flutter analyze` чистый.

## 11. Открытые вопросы

- Поле `folder` у `servers[]` предложено лаунчеру, но в его схему ещё не
  вошло. До синка контракта LxBox пишет его односторонне; лаунчер отбросит
  его как неизвестный ключ с `backup_unknown_field` — это ожидаемо и
  соответствует П3.
- `hash_device_model` схема 0.12 объявляет, у LxBox такой настройки нет.
  Отбрасывается на импорте наравне с незнакомыми ключами.

## Device-проверка (02.09.2026, эмулятор AVD LxBox_test, API 34 arm64)

Статус: **DEVICE-VERIFIED** на сборке 2.21.0-dev.17.

| Шаг | Наблюдение |
|---|---|
| Экспорт | `extensions` нет нигде; у `servers[]`/`chains[]` нет `label`, у подписки `label` есть (имя источника); `disabled` с тег-ключами в unix seconds; `subscriptions[0].identity` с шестью ключами, `hash_device_model` отсутствует; члены папки — отдельные `servers[]` с `folder` |
| Предупреждения экспорта | ровно одно: `<url подписки>: import_rules, import_rules_enabled`; папка без настроек предупреждения не даёт |
| Импорт своего файла после удаления папки, сброса identity и отметок | папка собрана по `folder`, identity вернулась (шесть ключей дословно), отметки `Alpha`/`Alpha-2`/`Epsilon` применились |
| Импорт legacy-файла с `extensions` на корне, у подписки и у сервера | импорт успешен, ровно один `backup_extensions_dropped` с перечнем трёх мест |

Вскрытое и исправленное: подписка, совпавшая по URL, получала только доливку отметок — настройки файла (identity, имя, префикс, интервал, enabled) не применялись (П1); исправлено выносом слияния в `mergeBackupSubscriptions`. Строка карточки «Transfer to desktop» обещала упразднённый провоз чужого — переписана.
