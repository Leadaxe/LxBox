# §512 — набор схем из реестра и синк контракта до 1.1.49

| | |
|---|---|
| **Статус** | **Released в v2.25.2** (24.09.2026). Влито в `develop` коммитом `4dada747` |
| **Дата** | 2026-09-24 |
| **Источник** | отчёт [§506](506-silent-parse-loss-reasons.md) («откуда диспетчер берёт список схем») + встречные задачи лаунчера `contract/TASKS_LXBOX.md` §43 (1.1.47), §44 (1.1.48), §45 (1.1.49) |
| **Зеркало контракта** | **1.1.46 → 1.1.49** (`app/contract.lock`: `source_sha=dfd01725`, sha256 `a174c6c7…`) |
| **Связанные** | [§506](506-silent-parse-loss-reasons.md) (причины вместо молчания), [§484](484-required-field-drop-reason.md), [§508](508-xhttp-sessionid-aliases.md), фичи [472](../features/472%20unified-parse-pipeline/spec.md), [480](../features/480%20registry-driven-mapper/spec.md) |
| **Ядро** | пин `v1.14.1-lx.8` (не менялся) |

## Проблема

§506 закрыл молчаливые потери, но назвал разрыв, который закрыть не мог:
**реестр уже нёс имена схем (`mappers.uri` → `detect.scheme_in`), а диспетчер
дублировал их литералами в трёх местах.** Поэтому `amneziawg` в `scheme_in`
контракта 1.1.48 сам по себе схему НЕ включал — строка по-прежнему падала бы в
`default` (теперь хотя бы с причиной).

Литералы жили в `kPipelineSchemes` (`mappers/uri_pipeline.dart`),
`_kWireguardSchemes` и `switch (scheme)` самого диспетчера, плюс четвёртая
копия — `_kSchemeToType`. Потребителей у списка три: сам диспетчер, страж
покрытия mapper-правил и `input_helpers.dart` (превью вставки).

## Что стало

### 1. Набор схем — из реестра

`registryUriSchemes()` (`uri_pipeline.dart`) — объединение `detect.scheme_in`
всех загруженных секций `mappers.uri`. `pipelineSchemes()` отдаёт его
**объединённым** с литеральным `kPipelineSchemes`, и это не подстраховка, а
норма: `wg://` реестр в `scheme_in` не объявляет **намеренно** (`wireguard.json`
→ note: «алиас `wg://` знает только Dart, Go `IsDirectLink` его не принимает —
разрыв»). Замена вместо объединения молча сняла бы живое написание, и это
выглядело бы следствием синка, а не решением владельца.

`registrySchemeType(scheme)` — написание → тип тела по той же секции;
спрашивается ПЕРВЫМ, литеральная `_kSchemeToType` осталась запасным путём.

| Потребитель | Было | Стало |
|---|---|---|
| `parseUri` маршрут конвейера | `kPipelineSchemes.contains` | `pipelineSchemes().contains` |
| `parseUri` ветка wireguard | `switch` + `_kWireguardSchemes` | `_wireguardSchemes()` — всё, что реестр переводит в тип `wireguard`; ветка `switch` снята |
| `parseUriViaPipeline` | `_kSchemeToType[scheme]` | `registrySchemeType(scheme) ?? _kSchemeToType[scheme]` |
| `isDirectLink` (вставка) | `kPipelineSchemes` | `pipelineSchemes()` |

Страж `engine_no_scheme_names` **не тронут и зелёный**: он грепает пакет
ДВИЖКА (`engine/`), а имена схем живут уровнем выше, у диспетчера — разделение
из §506 сохранено.

### 2. Служебные схемы — из реестра

`DocumentSource.serviceSchemes` + `serviceSchemeCode(line)` читают
`source_kinds.json` → `uri_lines.service_schemes` (контракт 1.1.48): набор
схем, обязательный хвост `routing/`, `action`, `code`. Литералы
`{incy, happ}` остались запасным путём.

Игнор перестал быть БЕЗЫМЯННЫМ: ставится info-код `service_record_ignored`.
Шума в UI это не даёт — шторка §500 показывает причины только когда узлов не
нашлось НИ ОДНОГО, а у живой подписки Happ они есть. Зато у пустой подписки
«команда панели» отличима от «потерянного узла».

### 3. Граница кодов непрочитанного (PARSING_PRINCIPLES §4.1, контракт 1.1.49)

| Ввод | Было | Стало |
|---|---|---|
| строка `xxx://` со схемой, которой не ведёт ни одна секция | `protocol_unsupported` | **`scheme_unsupported`** |
| форма секции не прочитала пейлоад (битый base64 vmess, обрезанный `vpn://`) | кода не было вовсе / `protocol_unsupported` | **`form_unrecognized`** |
| запись, чей ТИП неизвестен внутри опознанного тела | `protocol_unsupported` | без изменений |

`form_unrecognized` ставит ДВИЖОК (`runSection`, ветка «не сработала ни одна
форма»): только он различает «форма не опознана» и «обязательное значение не
нашлось» — второе уже давало `field_missing` (§484).

### 4. Конверт `dropped[]`: `index` и `ref` (§45.4)

- **`index`** — позиция элемента в нарезке `elements` вида источника. У
  одиночной ссылки всегда `0`; добавлен в раннер корпуса URI.
- **`ref` у построчного тела** — САМА СТРОКА, а не имя класса предупреждения
  (`_parseUriLines` проставляет `ownerTag`). Без этого кейс
  `uri_list/service_scheme_routing_ignored` сверить было нечем.

### 5. Род группы — по `genus.values` (§45.2)

`_canonScheme` раннера тел приводит `entry.type` узла-группы к схеме `group`
по таблице `genus.values` из `group.json`, а не литералом: `singbox_type`
группы записан через черту (`selector|urltest`), и обратного хода «тип →
схема» такая строка не даёт. Кейс `xray/balancer_group` позеленел, как и
обещала §45.2.

## Снятые оверлеи `contract_draft/`

Проверен КАЖДЫЙ (сверка `source`/`maps_to`/`when` с реестром 1.1.49):

| Оверлей | Решение |
|---|---|
| `uri/transports.json` → `blocks.uri.xhttp.sessionPlacement`, `sessionKey` | **СНЯТЫ**: контракт 1.1.47 привёз алиасы `sessionIDPlacement`/`sessionIDKey` ДОСЛОВНО тем же набором из 6 источников (сверено программно) |
| `uri/transports.json` → `blocks.xray.xhttp.sessionPlacement`, `sessionKey` | **ОСТАВЛЕНЫ**: у них на два источника больше — ПЛОСКАЯ форма (`xhttpSettings.sessionIDPlacement` без `extra`), а реестр объявил алиас только под `extra` |
| `uri/transports.json` → `blocks.uri.ws.eh` | **ОСТАВЛЕН**: 1.1.49 §45.3 снял только пометку `ext: mobile` (устаревшую документацию), а `round_trip: false` в записи ОСТАЛСЯ — то есть само отступление живо. Новый `impl` реестра прямо называет сторону, пишущую пару в query, расходящейся с нормой написания ссылки |
| `registry_mapper.schema.json` → `_awaitingContractSync` у `normalize` | **СНЯТА**: переезд `cidr_prefix`/`base64_std` в `body.fields` состоялся (проверено в `wireguard.json`) |
| `xray/{vless,trojan}.json`, `xray/socks.json` — хвосты про «`required` роняет узел молча» | **ПЕРЕПИСАНЫ**: с §484 причина называется кодом `field_missing`, а текст `{field}` движок берёт из `desc_en` |
| Шапки `xray/{vless,trojan}.json`, `uri/{tls,trojan,vless}.json` с номером контракта | **ПЕРЕФОРМУЛИРОВАНЫ** в «с контракта 1.1.x»: отступление длящееся, а не привязанное к версии |

Прочие оверлеи реестр по-прежнему не покрывает (13 механических секций
`singbox/*` нужны ради `detect`/`body_source`/`unknown_key`; `uri/wireguard`
несёт `form_from` написания схемы — решение владельца).

## Снятый мёртвый код

Проверено грепом по `lib` и `test`: вызовов в `lib` нет ни у одного.

- `Awg.fromQuery` и парная `Awg.writeQuery` (`node_spec.dart`) — вместе с ними
  ушли приватные `_iTagKeys`/`_masqueradeKeys` (мёртвая Dart-логика i1) и
  самоссылочный тест `round-trip writeQuery → fromQuery`, который проверял
  только то, что две мёртвые функции согласованы друг с другом. Живой путь
  AWG идёт движком — это стережёт соседний тест
  `round-trip share-URI: spec → toUri → parse`.
- `realityShortIdWouldDegrade`, `isTlsInsecure` (`uri_utils.dart`) — правила
  переехали в реестр (`tls.json` → `reality.short_id`, код `tls_insecure`).

## Исправлен `app/tool/sync_contract.sh`

`trap 'rm -rf "$tmp"' EXIT` ставился ВНУТРИ функции поверх её `local tmp`: к
моменту выхода локальной переменной уже нет, и под `set -u` ловушка печатала
`line 269: tmp: unbound variable`, а временный каталог не удалялся вовсе.
Переменная поднята на уровень скрипта (`SYNC_TMP`), ловушка одна и стоит там же.

## Прогон четырёх живых входов (`decode` + `parseAll`)

| Вход | Результат | Проверено |
|---|---|---|
| **A** `vpn://` с голым `.conf` | **1 узел** (wireguard) | AWG3-поля и identity — тесты §506 |
| **B** одиночный Xray | **1 узел** (vless) | REALITY + `encryption: mlkem768x25519plus…` дословно |
| **C** подписка из 19 конфигов | **19 узлов** (15 vless, 3 hysteria2, 1 группа) | у всех трёх hysteria2 `up_mbps: 100`, `down_mbps: 300`, `obfs: {type: salamander, password}` |
| **D** смешанное тело | **12 узлов** (4 vless + 4 amneziawg + 4 vpn) | `incy://` → info-код `service_record_ignored`, без шума в UI |

До задачи вход D давал 8 узлов: четыре строки `amneziawg://` терялись.

## Известные расхождения корпуса (ожидаемо красные)

Механизма «известный красный» у раннеров нет — кейсы остаются красными, как
принято, и названы здесь.

1. **`body/singbox/list_non_string_items`** — нестроковый элемент списка
   (`tls.alpn: [443, "h2"]`): у нас после §510 M1 снимается только ЭЛЕМЕНТ
   (`tls_alpn_item_invalid`, `hysteria2_server_ports_item_invalid`), лаунчер
   снимает поле целиком (`type_invalid`). **Наше поведение — решение
   владельца** (§45.6 п.2, «снимать только плохой элемент»); реестр догонит в
   1.1.50, и код менять НЕ НАДО.
2. **`uri/wireguard/amneziawg_scheme_full_name`** — тело узла, метка, схема и
   оба кода предупреждений совпадают ДОСЛОВНО; расходится единственное поле —
   `value` у `wgconf_dns_ignored`: у нас `"1.1.1.1, 1.0.0.1"`, у лаунчера
   `"1.1.1.1,+1.0.0.1"`. Это ЭХО снятого значения в диагностике, а не тело:
   `+` в query движок читает пробелом по норме form-encoding (§0.4 FROZEN),
   а литеральным — только у полей `format: base64*` (`plus_literal`). `dns`
   таким полем не является. Цель задачи (узел со всеми полями) достигнута.
3. **`uri/vmess/not_base64_rejected`** — ждёт `field_missing`, у нас
   `form_unrecognized`. Оба входа кейсов-соседей (`not-base64` и
   `invalid-base64!!!`) декодируются в двоичный мусор ОДИНАКОВО, то есть
   различить их нашей стороной нечем, а соседний кейс `invalid_base64` ждёт
   как раз `form_unrecognized`. Ожидание первого ведёт на старый тест LxBox —
   похоже на несведённость самого корпуса; **вопрос лаунчеру**.
4. **`uri/naive/empty_host_rejected`** (ждёт `field_missing`),
   `body/xray/{hysteria_v1_skipped,malformed_stream,unsupported_protocol,vless_encryption_junk}`
   — красные ДО этой задачи (сверено на чистом дереве `origin/develop`), к
   синку отношения не имеют. У `vless_encryption_junk` расходится `ref`: у
   нас тег `proxy`, в ожидании выведенный из `remarks` `enc-junk`.

## Долги

- **Ответ лаунчеру по §44 п.2** (он просил его прямо): список схем у нас
  теперь ДИКТУЕТ РЕЕСТР — выносить схемы в отдельный файл реестра не нужно.
  Плюс сказать про `wg://`: написание живо только у нас, и `scheme_in` его не
  объявляет.
- **Ответ по §45.5 п.(c)** — у нас поэлементно (см. расхождение 1); нужен
  номер контракта 1.1.50, чтобы обе стороны ввели норму одним номером.
- **`ws.ed`/`ws.eh` в query** (§45.3): реестр объявляет `round_trip: false`,
  наш эмиттер пару пишет. Либо снимать, либо заводить дельтой — отдельное
  решение, тело живых узлов не затрагивает.
- `sessionIDLength`/`sessionIDTable` не маппятся намеренно (§43).
- Заголовки подписки `Routing:` / `Routing-Enable:` контрактом не описаны
  (SPEC 061 у лаунчера); правило §512 закрывает только строку ТЕЛА.

## Тесты

`app/test/parser/task_512_registry_schemes_test.dart` (14 тестов):

- **набор схем**: реестр отвечает непустым набором; `amneziawg` в нём и
  `registrySchemeType` даёт `wireguard`; рабочий набор ШИРЕ каждой из сторон
  (снимок разрыва по `wg`); классификатор вставки берёт тот же набор.
- **`amneziawg://`**: узел, а не отбраковка; h1–h4 диапазонами, i1,
  `header_protection_key`, `pre_shared_key`, порт; **identity равна той же
  ссылке с `awg://`**; четыре строки в теле → четыре узла; `dns` из query в
  тело не едет и даёт `wgconf_dns_ignored`.
- **служебные схемы**: info-код `service_record_ignored` с severity из
  реестра; живая подписка — узлы есть, строка не мешает.
- **формы живых входов**: полоса hysteria2 с суффиксом → 100/300 плюс
  salamander из `finalmask`; одиночный конфиг Xray → узел; смешанное тело D.

Правлены тесты §506: схемой «незнакомой» больше не может быть `amneziawg`
(взята `nosuchproto`), код у неё `scheme_unsupported`, служебные строки ждут
info-код вместо полного молчания, плюс новый тест «служебная схема БЕЗ хвоста
`routing/` тихого игнора не заслуживает».

## Критерии приёмки

- [x] Зеркало контракта 1.1.49, `contract.lock` пересчитан, оба зеркала
  (`assets/contract`, `docs/contract`) обновлены одним синком.
- [x] Набор схем строится из `scheme_in` реестра; `amneziawg://` работает без
  литерала; `engine_no_scheme_names` зелёный.
- [x] Каждый оверлей `contract_draft/` проверен; снятые названы, оставленные
  обоснованы.
- [x] Входы A–D дают 1 / 1 / 19 / 12 узлов; у hysteria2 полоса и obfs на месте.
- [x] Стражи `before_480_identity_snapshot`, `engine_emit_shape`,
  `golden_config`, `engine_no_scheme_names`, `registry_sync` зелёные;
  `flutter analyze` чистый; 4 l10n-чекера зелёные.
- [x] Красные кейсы корпуса названы с причиной и разделены на «решение
  владельца», «вопрос лаунчеру» и «красные до задачи».
