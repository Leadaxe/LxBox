# §513 — Документация после ревью v2.25.1

| | |
|---|---|
| **Статус** | Готово: две мелочи кода, DIAGNOSTICS, `/help`, debug-api-reference, GUARDS, ARCHITECTURE, спеки 472/478/480/493/505/506. Находки по PROTOCOLS и оверлеям `contract_draft/**` переданы в §512 |
| **Дата** | 2026-09-24 |
| **Источник** | аудит документации и целостности релиза v2.25.0 / v2.25.1 (разделы 1–5, сверка `docs/*.md` с кодом), дерево `c1e669d1`. Перед правкой каждое утверждение перепроверено по `develop` `5150ac74` — после аудита влиты §506, §510, §511 |
| **Связанные** | §510 (M2: любой Stop гасит прогон страховки, L1: сверка `/help` с роутером), §494 (долги Debug API), §484 (`field_missing`), §485 (снятые классы предупреждений), §481, §501, §502, §505, фичи [472](../features/472%20unified-parse-pipeline/spec.md), [478](../features/478%20core-rejected-node-auto-disable/spec.md), [480](../features/480%20registry-driven-mapper/spec.md) |

## Docs to update

- [DIAGNOSTICS.md](../../DIAGNOSTICS.md) — страховка через Debug API
- [debug-api-reference.md](../../api/debug-api-reference.md), `/help`
  (`app/lib/services/debug/handlers/help.dart`)
- [GUARDS.md](../../GUARDS.md), [ARCHITECTURE.md](../../ARCHITECTURE.md)
- спеки 472, 478, 480, 493, 505, 506, [tasks/README.md](README.md)
- [CHANGELOG.md](../../../CHANGELOG.md) — 2.25.0 (порт Xray) и Unreleased

## Что было

После релизов v2.25.0 / v2.25.1 аудит нашёл, что доки описывают код
нескольких прошлых итераций: страховка в DIAGNOSTICS отвечала синхронно,
`/help` обещал поле `details`, которого сервер не шлёт, GUARDS ссылался на
классы предупреждений, снятые в §485, и на номера строк в парсерах, ставших
однострочными обёртками конвейера. Две спеки жили под номером 505, одна —
с устаревшим описанием реализации. Счёт красных кейсов корпуса расходился
между фичей 480 и задачей 493. Три долга после релиза были записаны только
в отчёте ревью 506, без адреса в спеке фичи.

## Что сделано

### Код

| Утверждение аудита | Реальность на `5150ac74` | Правка |
|---|---|---|
| `_xrayIdentity`, ветка `hysteria`: `?? 443`, хотя секция требует порт | подтверждено (`json_parsers.dart`) | порт не задан или `<= 0` → синонима нет, как у vless/trojan/ss. Тест «hysteria без порта: узла нет, синонима у тега нет» в `json_parsers_test.dart`: красный на прежнем файле, зелёный после |
| `nodeSpecForConfigTag` (`source_lookup.dart`) в `lib/` не вызывается | подтверждено, только `home_node_warnings_test.dart` | функция **снята**. Тест проверял не самостоятельную логику, а тот же обход «префикс записи → bare-тег», который главный экран делает через `storedNodeOfEmittedTag`, — переписан на него (узел тот же объект, вердиктов нет). Оставлять копию обхода с `@visibleForTesting` значило бы тестировать код, которого нет на боевом пути |

### Debug API

| Утверждение | Реальность | Правка |
|---|---|---|
| DIAGNOSTICS: «these three write endpoints» | в таблице их шесть, с правкой — семь | «the write endpoints below» |
| DIAGNOSTICS: `prompt` → 409 без вопроса | `keep` без вопроса ставится в очередь (`queued:true`), очередь чистится концом прогона; 409 только у `stop` | строка переписана |
| DIAGNOSTICS: нет `POST /core_reject/reset` | есть с §494, 409 при идущем прогоне; сбрасывает `phase`, `round`, `disabled`, `outcome`, `error` | строка добавлена |
| DIAGNOSTICS: `guard=true` отвечает итогом | асинхронно `{ok, action, guard:true, started:true, async:true}`, итог — `GET /core_reject`, 409 при идущем прогоне | строка переписана |
| DIAGNOSTICS: check-config только по конфигу на диске | с телом проверяет присланный JSON | дописано |
| §510 M2 — новое поведение | любой Stop (Debug API, кнопка, плитка QS, Intent API, Locale) гасит прогон: `stopped_by_user`, финального старта нет; Stop в шторке живёт только в фазе реального старта | абзац в DIAGNOSTICS, строка `stop-vpn` в debug-api-reference |
| `/help`: конверт `{"error":{…,"details":{…}}}` | `details` не шлётся; у отказа `POST /subs` (400) верхнеуровневый `dropped[]` | обе формы `/help`: конверт без `details`, упомянут `dropped` |
| `/help` json: `level` = `error,warn,…`, пример `level=error,warn` | `warn` → 400, принимается `warning` | исправлено в json и примере (текст уже был верен) |
| `/help` `/state/vpn`: `battery_whitelisted`, нет `current_session_allow_bypass` | ключи `is_ignoring_battery_optimizations`, `current_session_allow_bypass` | исправлено в обеих формах |
| `/help` `POST /subs` без отказа | 400 + `dropped[]` (§500) | добавлено в обе формы |
| debug-api-reference: Index без Backup и Diagnostics | разделы есть | добавлены в Index |
| debug-api-reference: `/files/oom` `file=` без `connections.json` | принимается (сервер берёт любой basename) | добавлено |
| debug-api-reference: конверт ошибки | верен, про `dropped` не сказано в «Common errors» | абзац про отсутствие `details` и `dropped` |

### GUARDS

| Строки (было) | Что было | Правка |
|---|---|---|
| 357–358, 373, 593 | `RealityShortIdInvalidWarning`, `InsecureTlsWarning`, `DeprecatedFlowWarning` | коды реестра `reality_short_id_invalid`, `tls_insecure`, `flow_deprecated` с секциями `tls.json` / `protocols/vless.json`; пометка «класс снят в §485» |
| 814–815 | четыре класса «объявлены, не используются» | остался только `NaiveBuildTagWarning`, три сняты в §485 |
| 476 | битые AWG `jc…s4` снимаются молча | снимаются с кодом `awg_header_invalid` (`s3`/`s4` — `awg3_field_invalid`), §481 |
| 477–479 | своп диапазона и i1 в `node_spec.dart:685…736`; «глубже не валидируем» | своп — `normalize: range_order` реестра; i1 против id/ip/ib — `when` записей маппера и `conflicts` тела; границы uint32 и пересечение `h1`–`h4` теперь судит реестр (`awg_range`, `ranges_disjoint` → `awg_headers_overlap`) |
| 340, 368–369, 442–443, 448, 468, 480–482, 486, 594, 596–597 | номера строк в обёртках `*_parser.dart`, `ini_parser.dart`, `uri_parsers.dart`, `node_spec_emit.dart` | каждая ссылка → секция реестра или реальная строка |

По ходу сверки ссылок у части этих строк устарело само **содержание**, и
оставить его значило бы вписать новую ссылку под неверное утверждение.
Исправлено по коду и реестру: длинная ссылка и незнакомая схема больше не
молчат (`uri_too_long`, `protocol_unsupported`, §506); `encryption` VLESS
проверяется по форме и роняет узел (`vless_encryption_invalid`), а не
«намеренно не валидируется»; naive с пустым хостом отбраковывается
(`field_missing`), строка противоречила соседней; `preshared_key`
принимается алиасом; исключение внутри парсера выделено в отдельную
строку.

### ARCHITECTURE

- `body_decoder`: вид источника из `source_kinds.json` реестра (рукописный
  запасной путь без реестра), `JsonFlavor` снят в §483.
- `amnezia_link` в таблице видов: маппер `conf`, без повторного опознания —
  сверено с `app/assets/contract/registry/source_kinds.json`.
- `source_kinds.json` живёт в вендоренном реестре, копии в
  `contract_draft/` нет; `sources.json` — запасное имя загрузчика.
- `node_spec_emit.dart`: `toUri()` через эмиттер движка
  (`uriViaEngineRequired`), рукописный только `toUriTailscale`.
- NodeRow (оба описания): значок старшего уровня §502 перед протоколом.

### Спеки

- **505.** `505-home-badge-cold-start.md` слит в
  `505-home-node-badge-user-server.md` (симптом холодного старта — в «Что
  было», критерий — в приёмку, порядок источников по коду: хранилище через
  `storedNodeOfEmittedTag`, карта сборки — запасной путь) и удалён. Ссылка
  в CHANGELOG убрана, в 506 и `tasks/README.md` записан факт слияния.
- **478.** «Вкладка Notifications» → «секция уведомлений внизу вкладки
  Diagnostics» (§501) в четырёх местах; путь `AppCoreRejectHost` →
  `app/lib/services/core_reject/core_reject_host.dart`. Разделы «Как
  сделано», обновлённые §510, кроме этих строк не трогались.
- **472.** §8.1: `typedef UriMapper` с шага 4 — `Function(String uri)`
  (§10.1).
- **480 / 493, счёт красных корпуса.** Установлен прогоном: `app/contract`
  восстановлен `bash app/tool/sync_contract.sh` из lock (1.1.46,
  `7e2945bf`), гонялись **только** кейсы, названные в 480, и два tuic
  (`--name` у `body_contract_test.dart` и `contract_test.dart`). Красных
  шесть: `naive/empty_host_rejected`, `xray/balancer_group`,
  `xray/malformed_stream`, `xray/unsupported_protocol`,
  `xray/hysteria_v1_skipped`, `xray/vless_encryption_junk`. Прав был 493
  («naive + пять `xray/*`»); `xray/vless_default_port` и оба tuic зелёные.
  Попутно: `xray/hysteria_v1_skipped` красный по **составу узлов** (корпус
  ждёт узел hysteria v1, у нас узла нет), а не по `dropped[]`, как было
  записано. Поимённый список — 480 §12 «Осталось красным», остальные места
  ссылаются туда.
- **Долги без владельца** (`dropped[]` + index, Q133-61, `contract_draft/singbox/*`
  → реестр) — новый §16 фичи 480, в 506 у каждого пункта стрелка туда.
  Отдельных задач не заводилось.

### CHANGELOG

- 2.25.0, пункт про порт Xray: причина отбраковки видна кодом
  `field_missing` (§484).
- Unreleased → Internal: hysteria без порта, снятый `nodeSpecForConfigTag`,
  строка про документацию.

## Не сделано и почему

**Передано в §512** (файлы вне этой задачи):

- `docs/PROTOCOLS.md`: `uri_parsers.dart` как «форматы всех 12 протоколов»
  (это диспетчер, нет anytls); «as does `toUriNaive`» (функции нет, naive
  эмитит движок); `node_spec_emit` как реализация `toUri()`;
  `InsecureTlsWarning` и соседи (:914) → коды реестра.
- `app/assets/contract_draft/xray/{vless,trojan}.json` (`_divergence_resolved`)
  и `xray/socks.json` (`_why`): обоснования пишут, что `required` роняет узел
  молча, — после §484 причина называется кодом `field_missing`.
- `app/assets/contract_draft/registry_mapper.schema.json:244`: протухшая
  `_awaitingContractSync` про `cidr_prefix` / `base64_std` в `body.fields`.
- Следующий синк контракта 1.1.47 (`--to 11d5cbc9`) и снятие оверлея §508.

**Замечено по ходу, не входило в задачу:**

- `Awg.fromQuery` (`node_spec.dart`) в `lib/` не вызывается — только
  `awg_test.dart`; вместе с ним мёртвое подавление id/ip/ib при i1 в Dart
  (боевое — записи маппера реестра). Без вызовов в `lib/` также
  `realityShortIdWouldDegrade`, `isTlsInsecure` (`uri_utils.dart`).
- `_xrayIdentity`, ветка hysteria, читает только `settings.address/port`,
  а маппер секции берёт и `settings.servers[0].*`: у элемента в форме
  `servers[]` синонима нет вовсе. Ложного ключа это не даёт, только пропуск.
- `bash app/tool/sync_contract.sh` в режиме восстановления отработал, но на
  выходе печатает `line 269: tmp: unbound variable`: `trap … EXIT` ссылается
  на `local tmp` функции, который к выходу скрипта уже вне области видимости
  (`set -u`), и временный каталог с копией контракта не удаляется.

## Проверки

- `flutter analyze` (весь проект): `No issues found!`
- `dart run tool/docs/parity_check.dart`: `failures: 0, warnings: 0`
- `dart run tool/l10n/hardcoded_check.dart --strict`: `failures: 0, warnings: 0`
- `flutter test test/parser/json_parsers_test.dart`: All tests passed (новый
  кейс красный на прежнем `json_parsers.dart`)
- `flutter test test/screens/home/home_node_warnings_test.dart`: All tests passed
- `flutter test test/services/debug/help_json_test.dart`: All tests passed
- `flutter test test/contract/docs_mirror_test.dart`: All tests passed
- Корпус: только названные кейсы (см. «Спеки → 480 / 493»); полный прогон — CI.
