# 441 — Значения переменных в записи: шаблонный DNS-сервер и пресет правила

| Поле | Значение |
|------|----------|
| Статус | Реализовано в ветке `wave-441-vars`. Синк контракта 1.0.2, корпус, L7, форма второй линии fail-closed по норме, Н11 и порядок импорта §5.5 — [§443](443-contract-1-0-2-spec129.md) |
| Дата | 2026-09-15 |
| Норма | SPEC 129 лаунчера «Значения переменных живут в записи» (`SPECS/129-F-N-DNS_TEMPLATE_VARS`, контракт 1.0.2), §11 L1–L9 |
| Связанные | [§439](../features/439%20storage-contract-1-0/spec.md) (слои §2.5, форма `dns.servers[].vars`), [§438](438-lx-backup-1-0-read-write.md) (LX Backup 1.0), §419 (лечение `dns.final`), §117 (template-серверы DNS), §265 (ref-переменные пресетов) |

## Решения владельца 15.09.2026

- **Н4.** Значение, равное `default_value` объявления в шаблоне своей
  стороны, не пишется: ни в хранение, ни в файл. Выбор умолчания в UI —
  сброс к шаблону. Цена: закрепить текущее умолчание против его будущей
  смены нельзя.
- **Н2.** Имя, которого шаблон своей стороны у носителя не объявил,
  снимается: на импорте — с `backup_var_skipped {reason: undeclared}`, в
  хранении — молча при следующей записи.
- **Оба носителя сразу:** `dns.servers[kind=template].vars` и
  `rules[kind=preset].vars`.
- **Fail-closed, две линии.** Импорт выключает DNS-сервер с неизвестной
  целью маршрута (Н9). Сборка не эмитит сервер с висячим `detour` (Н10),
  а DNS-правило на такой сервер становится `action: reject` (§13 п. 4).

Согласовано с лаунчером сверх черновика: наложение `vars` по именам (§13
п. 1), `backup_dns_entry_skipped` для тега вне шаблона (п. 2), параметры
кодов `backup_var_skipped {name, record, reason}` и
`backup_unknown_outbound {rule?|server?, outbound}` (п. 3), подрезка
значений (Н3), Н9 на совпавшей записи применяет значение и выключает
сервер, `dns_server`-значения на импорте не проверяются.

## Что сделано

| # | Где | Что |
|---|---|---|
| L1, L2, L8 | `lib/services/record_vars.dart` (слой 5) | Объявления из шаблона (`RecordVarDecls.fromTemplate`) и из JSON фикстуры корпуса (`fromJson`: `dns_options.servers`, `presets`/`selectable_rules`, алиас `default`). Нормализация Н2/Н3/Н4 одной функцией для двух носителей. Кодек записей не тронут |
| | репозиторий `saveDnsServers`, `saveCustomRules` | Нормализация молча на каждой записи: редакторы, резолвер DNS, Debug API, файл правил, импорт. Неизменённая запись пишется прежними байтами |
| | миграция 2.23.2 (`migrateStorageDoc`, параметр `recordVars`) | Записи 1.0 пишутся уже без умолчаний; вызовы `_load`, `replaceRaw`, внутренний бэкап, Debug `POST /backup/import` |
| | редакторы DNS-сервера и правила-пресета, `selectableRuleToCustom` | Выбор значения, равного умолчанию, снимает ключ; поля те же |
| L3 | декодер LX Backup (`_parseVars`) | Н8: корневое `dns_<tag>_<var>` против объявленных пар `(tag, var)`, самый длинный тег; перенос в запись сервера файла до слияния. Причины: `not_portable`, `superseded`, `no_record`. Файлы 1.0 и 0.x одним правилом; `vars` ссылки 0.12 теперь читаются |
| L4 | `applyDnsBackup` | §5.2: запись была — `enabled` локальный, `vars` наложением по именам файла, затем Н2 (предупреждение за имена файла) и Н4; записи не было — из файла, затем Н2/Н4. Template-сервер вне шаблона — `backup_dns_entry_skipped` в декодере |
| L5 | `applyDnsBackup` + план импорта | Н9 по единому списку целей D-117: у затронутых записей переменная типа `outbound` или `body.detour` вне списка → `enabled: false`, `backup_unknown_outbound`, значение остаётся. Нет списка — не режется |
| | `planLxBackupImport` | Слияние DNS и нормализация пресетов перенесены в план: превью показывает те же предупреждения, что запишет импорт; раннер корпуса берёт DNS из плана |
| | экспорт (`dnsToBackup`, `buildLxBackup`) | Нормализация копии молча: хранение, не записанное после обновления шаблона, уезжает без умолчаний |
| L6 | `resolveDnsServersBodies`, `normalizeDnsDetour` | Н10: сервер с висячим `detour` после подстановки не эмитится, warning сборки; `direct-out` снимается как раньше; член DNS-группы выпадает с причиной `dangling detour` |
| | `post_steps/heal_detour_dropped_dns.dart` | Одно место политики ссылок на выпавший сервер: DNS-правила → `action: reject` (поля маршрута сняты); `dns.final`, `route.default_domain_resolver`, `servers[].domain_resolver` — замена политикой §419 (умолчание шаблона, иначе первый пригодный), без записи в хранение. Форма по норме (`final` → заглушка `reject`, резолверы узлов, IP-адрес, группы) — §443 |
| | `resolveTemplateDnsServerBody` | `@name`, не объявленный сервером, не подставляется: ключ выпадает, warning сборки |
| L9 | заголовок `dns_backup.dart` | Переписан: `vars` и `description` сервера едут, нормы SPEC 129 |
| корпус | `test/contract/backup_corpus_test.dart` | Читает `<case>.template.json`; у кейса с фикстурой отсутствие `vars` в ожидании записи = «ожидаем пусто» |

## Отклонения

- **`outbound` у пресета законен без объявления.** Сборка LxBox читает
  `vars.outbound` у любого пресета как универсальную замену цели
  (Block Ads → Направление). Снятие по Н2 изменило бы конфиг. Объявлен —
  умолчание снимается по Н4; не объявлен — значение остаётся.
- **Пустое значение необязательной переменной пресета** (`— (none)`) после
  Н3 равно отсутствию ключа и даёт умолчание. В шаблоне таких переменных с
  непустым умолчанием, выбираемых в UI, нет (`fakeip.rule_enable` скрыта).
- **Замены резолверов не персистятся** для выпавшего сервера (в отличие от
  §419): выбор пользователя цел, вернётся Направление — вернётся сервер.
  Форму лаунчер доопределил в SPEC 129 Н10 (`dns.final` снимается с
  заглушкой `reject`), LxBox повторил её в §443.

## Ссылки на Направление в значениях и Л5 (волна 441b)

SPEC 129 §6, D-113/D-114: значение переменной типа `outbound` в записи —
одиночная цель по имени того же класса, что цель правила, `route.final` и
detour DNS. Решение владельца D-114: при удалении цели оно обрабатывается так
же, как при удалении Направления.

| Операция | Что со значением | Где |
|---|---|---|
| удаление и выключение Направления | тег и `<тег>-auto` → `vpn-1`, как `outbound` правила; затем Н4 (у `google_dot`/`cloudflare_dot` `vpn-1` — умолчание, ключ снимается) | `_healDirectionRefs` (`settings_storage/directions.dart`) |
| переименование | тег → новый, `<тег>-auto` → `<новый>-auto`, затем Н4 | `directionRefRetarget(rename: true)`; у LxBox тег Направления неизменяем (Debug API `PATCH` — 400), вызывающего нет |
| detour DNS (волна 441c) | `body.detour` пользовательского сервера (`kind: user`) в корневом `dns.servers` и в `sections.dns.servers` одиночного сервера и членов папки — те же операции, Н4 не применяется | `retargetDnsServerDetour` (`models/dns_ref.dart`), `retargetSectionsDnsDetours` (`models/server_list.dart`); зеркало секций в `_entries` контроллера — `syncSectionsDnsDetourRefsHealed`, зовёт `DirectionMutations` при `dnsServers > 0` |

- Имена-цели берутся из объявления шаблона: у template-сервера DNS —
  переменные `type: outbound`, сервер вне шаблона — ключ `outbound` по имени;
  у пресета — `outbound` всегда (универсальная замена цели) плюс объявленные
  `type: outbound`. Переменные других типов не трогаются, даже если значение
  совпало с тегом. Функции — `record_vars.dart`
  (`retargetDnsServerOutboundVars`, `retargetPresetOutboundVars`).
- Счётчик: `DirectionHealResult.dnsServers` — число DNS-серверов (template
  с переменной-целью, user с `body.detour`, корневых и секционных).
  Пресет с переменной-целью считается в `rules` (одно на правило).
  SnackBar: «N DNS server(s) switched to vpn-1», Debug API —
  `healed.dns_servers` в ответах `POST`/`PATCH`/`DELETE /directions`.
- Без лечения сервер с удалённой целью выпадал на сборке (Н10), его правила
  становились отказом. Н10 остаётся второй линией для значений из чужого
  файла и ручной правки.

**Л5.** В файле 1.0 `vars` — поле только `kind: template`. У `user` и
`preset` (корневые `dns.servers` и `sections.dns.servers` узла) обход
неизвестных ключей называет его `backup_unknown_field`
(`dns.servers[my-doh].vars`); кодек ключ не читает, в хранение он не
попадает. Раньше `vars` числился объявленным полем для всех видов и
игнорировался молча. Файлы 0.x не затронуты: там `vars` у ссылки DNS
разрешён формой `DNSRef` для всех видов.

## Эталоны

- `golden/*.config.json`, `*.config_warnings.json`, `*.backup_roundtrip.json`,
  `*.storage_roundtrip.json` — без изменений (нормализация идёт в миграции,
  конфиг из тех же данных не меняется).
- `golden/rich_v0.backup.json`: сняты `google_udp.vars.outbound=direct-out`,
  у `ru-direct` — `outbound=direct-out`, `force_ipv4=true`.
- `golden/avd_v0.backup.json`: сняты `google_udp.vars.outbound=direct-out`,
  `cloudflare_udp.vars.dns_ip=1.1.1.1`.

## Проверка

- Тесты: `test/services/record_vars_test.dart` (нормы, писатели, все пресеты
  шаблона — умолчания в `vars` разворачиваются как пустые `vars`),
  `test/services/dns/dns_template_vars_import_test.dart` (Н8, §5.2, Н9,
  сценарий кейса §9.1 с умолчаниями лаунчера),
  `test/builder/dns_detour_fail_closed_test.dart` (Н10 на `rich_v0` и
  `avd_v0`; удаление `vpn-3` лечит `vars.outbound` у `google_dot`, сервер
  остаётся в конфиге). 441b: перепись целей и Н4 —
  `record_vars_test.dart`, Л5 — `dns_template_vars_import_test.dart`.
  441c: detour DNS (корневой, секции, зеркало контроллера, выключение,
  переименование) — `test/subscription/detour_direction_resync_test.dart`.
- Конфиг `avd_v0` с выпавшим `google_udp` (правило → reject, резолверы
  вылечены) проходит `sing-box check` (бинарь `sing-box-lx` от 14.09, HEAD
  `v1.14.0-lx.39-6`).

## Нерешённое

- Закрыто в [§443](443-contract-1-0-2-spec129.md): синк контракта 1.0.2,
  прогон кейса `v10_dns_template_vars`, снятие `_pendingPortableVars` (L7).
