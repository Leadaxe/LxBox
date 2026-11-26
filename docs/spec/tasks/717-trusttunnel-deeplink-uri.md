# 717 — Ссылки `tt://` (AdGuard TrustTunnel deep-link) → узел `trusttunnel`

| Field | Value |
|-------|-------|
| Status | Done (итерация 1: разбор ссылки; итерация 2, 21.11.2026: контракт 1.1.175 — секция реестра, табличный кодек `tlv`, обратный ход, финальные коды; итерация 3, 21.11.2026: контракт 1.1.176 — подписка TrustTunnel; вкладка формы узла в Add server не делалась) |
| Start date | 2026-11-04 |
| Source | issue #194 (вставка `tt://` из буфера не распознаётся); решение владельца: «поддержка формата tt://, с ним в паре сделать поддержку ссылок» |
| Related specs | §698 (узел `trusttunnel` из реестра, тип без своей модели), §585/§586 (`UnknownTypeSpec`), §562 (имена схем только из реестра); контракт — запрос лаунчеру `TASKS_LXBOX.md` §157, ответ §177 (контракт 1.1.175, `MAPPER_ENGINE.md` §4a), §178 (контракт 1.1.176, `MAPPER_ENGINE.md` §2.1) |

## Problem

`parseUri` строит карту схем из `mappers.uri.detect.scheme_in` реестра
(`uri_pipeline.dart`), у записи `trusttunnel.json` секции `uri` нет →
`registrySchemeType('tt')` даёт `null`, строка не считается ссылкой
(`isDirectLink`), в буфере обмена и подписках она игнорируется с
`scheme_unsupported`.

Формат ссылки — не URL. `tt://?<payload>`: authority и путь пустые, payload —
base64url без padding над бинарным TLV (tag и длина — QUIC-varint RFC 9000
§16, не LEB128: `varint.rs` референса; затем значение). Референс — крейт `deeplink` репозитория
<https://github.com/TrustTunnel/TrustTunnel> (`deeplink/src/{types,encode,decode}.rs`);
текстовой спеки у AdGuard нет. Теги и обязательные поля — в §157 контракта
(п. 3–4). Движок `mappers.uri` декларативно TLV не читает: нужен именованный
декодер, как `ini` у WireGuard.

Отдельное ограничение, не этой задачи: Android AAR ядра собран без
`with_trusttunnel` (KERNEL.md, lx.21+), узел типа `trusttunnel` в конфиге ядро
отвергает целиком, и его выключает страховка core-rejected по имени. Разбор
ссылки это не отменяет — ссылка должна становиться узлом независимо от ядра
(решение владельца 29.10.2026 «в новых лаунчерах будут новые ядра», §137).

## Solution

1. **Декодер `tt_deeplink`** в движке (`lib/services/parser/engine/decoders.dart`,
   имя регистрируется рядом с `ini`/`json`): вход — строка payload после
   `base64url` над `scope: query`, точнее байты; выход — объект пространства
   `tt`:
   - `version` int; строки `hostname`, `custom_sni`, `username`, `password`,
     `name`, `client_random_prefix`, `client_random_auth_key`,
     `subscription_url` (ключа нет, если тега нет); `addresses` string[]
     (тег `0x02` повторяется); `has_ipv6`, `skip_verification`, `anti_dpi`
     bool; `upstream_protocol` `"http2"`/`"http3"` (нет тега = http2);
     `certificate` — PEM-строка (DER из ссылки → `-----BEGIN CERTIFICATE-----`
     + base64 по 64 символа + `-----END CERTIFICATE-----`); `dns_upstreams`
     string[] (значение тега — последовательность varint-длина + UTF-8).
   - Производные от первого адреса: `server`, `server_port` (host:port,
     IPv6 в скобках → без скобок).
   - Неизвестный tag пропускается. Битый base64, обрыв TLV, `version` > 2 —
     отказ декодера → узел снимается с кодом `tt_deeplink_invalid`.
2. **Секция реестра** — черновик `assets/contract_draft/uri/trusttunnel.json`
   (механизм `kDraftFiles`, `draft_sections.dart`; подхватывается, пока реестр
   лаунчера не привёз свою). `detect.scheme_in: ["tt"]`, форма `deeplink`
   `decode: [{"decoder":"base64url","scope":"query"}, "tt_deeplink"]`,
   `space: "tt"`, `body_source: "uri"`. `params` читают `tt.<ключ>`:
   - `server`, `server_port` ← производные; `username`, `password`;
   - `quic` ← `upstream_protocol == "http3"` (sets);
   - `tls.enabled: true`; `tls.server_name` ← `custom_sni`, иначе `hostname`;
     `tls.insecure` ← `skip_verification`; `tls.certificate` ← `certificate`;
   - label ← `name`, fallback `{scheme}-{server}-{server_port}`.
   Чего в теле `trusttunnel` нет — снимается мягко (узел живёт), код
   `tt_field_unsupported` с параметром `field`: `has_ipv6`, `anti_dpi`,
   `client_random_prefix`, `client_random_auth_key`, `dns_upstreams`, адреса
   со второго. `subscription_url` при полном узле — мягкий
   `tt_subscription_ignored`. Только `subscription_url` без полей узла —
   узел снимается, `tt_subscription_only`. Коды — в черновик `warnings`
   тем же механизмом (или ближайшим существующим), финальные имена придут с
   записью лаунчера; при синке переименовать.
3. **Узел.** Тело после санитайзера идёт в `parseSingboxEntry`, который для
   `trusttunnel` даёт `null` (`json_parsers.dart`, `kAppSingboxNodeTypes`).
   В `_runPipeline` (`uri_pipeline.dart`) добавить откат: тип известен
   реестру и без модели → `UnknownTypeSpec` (вынести конструктор из
   `_ownUnknownTypeNode` в `singbox_config.dart` в общую функцию).
   `rawSource` узла — исходная ссылка `tt://…`, не JSON (иначе `toUri()`
   отдаст JSON). Санитайзер уже снимает узел без `username`/`password`
   (`field_missing`, §698) — не дублировать.
4. **Share («Copy link»).** `UnknownTypeSpec.toUri()` отдаёт `rawSource`;
   для узла, созданного из `tt://`, этого достаточно (ссылка хранится как
   есть). Полноценный энкодер TLV из тела (узел `trusttunnel` из JSON →
   `tt://`) и `emit.share_uri: true` — после записи лаунчера, по его форме
   (порядок тегов — §157 «Эмит»); в этой итерации декодер пишется так, чтобы
   энкодер был его зеркалом (varint/TLV-хелперы общие, PEM↔DER в одном месте).
5. **Распознавание.** `pipelineSchemes()` подхватит `tt` из черновика сам →
   `isDirectLink`, анализ буфера (`clipboard_analysis.dart`), построчный
   разбор списков (`parse_all.dart`) и подписки работают без правок. Проверить
   `engine_no_scheme_names_test.dart`: имя `tt` в Dart-коде не появляется.
6. **Подписка TrustTunnel** (`subscription_url` → GET с Basic-auth → JSON-объект
   `version: 1`, те же поля, `address` одной строкой) — **не в этой задаче**,
   вторая очередь после контракта.

## Файлы

- `app/lib/services/parser/tt_deeplink.dart` (новый) — QUIC-varint
  (`readVarint`/`writeVarint`), TLV (`encodeTlv`, `encodeStringArray`),
  DER↔PEM (`derToPem`/`pemToDer`), `splitHostPort`, `decodeTtPayload` →
  объект либо `TtFailure.invalid|subscriptionOnly`. Без имени схемы.
- `app/lib/services/parser/engine/decoders.dart` — константа имени декодера
  `kTtDeeplinkDecoder`; `engine/section.dart` — имя в списке декодеров (doc).
- `app/lib/services/parser/engine/interpreter.dart` — ветка `space: json`
  `_selectForm`: шаг `tt_deeplink` (`_namedDecoderStep`,
  `_decodeTtDeeplinkStep`), коды отказа из шага формы в `dropped.reason`
  (только если ни одна форма не ответила).
- `app/assets/contract_draft/uri/trusttunnel.json` (новый) — полная секция
  `mappers.uri`; `mappers/draft_sections.dart` — `'trusttunnel'` в
  `kDraftFiles`.
- `app/lib/services/parser/singbox_config.dart` — общий
  `unknownTypeNodeFromBody` (из `_ownUnknownTypeNode`);
  `mappers/uri_pipeline.dart` — откат `_registryTypeNode` после
  `parseSingboxEntry`.
- `app/test/parser/tt_deeplink_test.dart` (новый);
  `app/test/parser/engine_no_scheme_names_test.dart` — `tt`, `trusttunnel` в
  списке написаний-литералов диспетчера.
- `docs/USER_GUIDE.md` / `docs/contract/protocols/trusttunnel.md` — после
  записи лаунчера (генерируемый документ не править руками).

## Проверка

Тест `app/test/parser/tt_deeplink_test.dart` (ссылки собираются тестовым
энкодером в самом тесте, значения из `deeplink/tests/roundtrip.rs` —
`vpn.example.com`, `1.2.3.4:443`, `alice`/`s3cr3t`, `Example VPN`):

1. Полный узел http2 без сертификата → `UnknownTypeSpec` типа `trusttunnel`:
   `server 1.2.3.4`, `server_port 443`, `username`, `password`,
   `tls.server_name vpn.example.com`, `quic` отсутствует/false, тег
   `Example VPN`, предупреждений нет; `toUri()` == исходная ссылка.
2. http3 + `custom_sni` + DER-сертификат + `skip_verification` → `quic: true`,
   `tls.server_name` = custom_sni, `tls.insecure: true`, `tls.certificate` —
   PEM с правильным base64.
3. Два адреса (v4 + `[2001:db8::1]:8443`) + `dns_upstreams` + `anti_dpi` +
   `client_random_prefix` → узел по первому адресу, мягкие
   `tt_field_unsupported` по каждому полю, узел жив.
4. Только `subscription_url` → узел снят, `tt_subscription_only`.
5. Битый base64 / обрыв TLV / `version` 3 → снят, `tt_deeplink_invalid`.
6. Без `password` → снят `field_missing` (путь §698).
7. `isDirectLink('tt://?…')` true; `engine_no_scheme_names_test` зелёный.

Корпус `contract/corpus/uri/tt/` появится с записью лаунчера (§157) — тогда
прогон `test/contract/contract_test.dart`.

## Итог

Сделано (Solution п. 1–5, Проверка п. 1–7), рабочее дерево, без коммита.

- **Декодер** `tt_deeplink` — единственный шаг `decode` формы `deeplink`
  (`space: json`, не `tt`): сам снимает ведущий `?` и base64url (ленивый
  `_RunDecode.bytes`, четыре алфавита) и разбирает TLV. Отступление от
  п. 1/2: шага `{"decoder":"base64url","scope":"query"}` перед ним нет —
  общий шаг base64 отдаёт ТЕКСТ (UTF-8), а байты TLV и DER в нём не живут;
  scope `query` лексер для ссылки без authority не поддерживает, и вводить
  его ради одного формата не стал. Пространство — обычное `json`
  (источники `json.<ключ>`), как у формы-контейнера vmess: отдельный
  `space: tt` потребовал бы второй ветки чтения источников при той же
  грамматике.
- **Varint — QUIC (RFC 9000), не LEB128**, как стояло в Problem (исправлено):
  `varint.rs` референса. Tag тоже varint. bool — строго `0x00`/`0x01`,
  протокол — `0x01`/`0x02`, иначе отказ; не-UTF-8 строка — отказ.
- **Объект пространства** — отступление от п. 1: вместо `addresses[]` —
  `address` (первый) + производные `server`/`server_port` + `extra_addresses`
  (со второго, только если есть); булевы `has_ipv6`/`anti_dpi`/
  `skip_verification` кладутся только при значении, отличном от умолчания
  формата (иначе каждая ссылка с явным `has_ipv6=true` шумела бы кодом).
- **Коды** — черновика `warnings` механизм не поддерживает
  (`registry.dart` читает только `registry/warnings.json`), взяты
  существующие; имена кодов отказа объявлены в ШАГЕ формы
  (`on_invalid.code`, `on_subscription_only.code`), при синке переименование
  — правка JSON, не кода:
  - `tt_deeplink_invalid` → `form_unrecognized`;
  - `tt_subscription_only` → `service_record_ignored` (параметр `scheme`);
  - `tt_field_unsupported` и `tt_subscription_ignored` → `uri_param_unknown`
    (`query_name` = имя поля) через `unknown_key` секции, `action: drop` — в
    тело не едут. Поля, которые секция не читает, называются автоматически,
    без перечня.
- **Узел**: `parseSingboxEntry` → `null` для `trusttunnel` → откат
  `_registryTypeNode` в `_runPipeline` (тип известен реестру и без модели) →
  `UnknownTypeSpec` через общий `unknownTypeNodeFromBody`; `rawSource` —
  исходная ссылка, `toUri()` её и отдаёт (Copy link). Тег-фолбэк —
  `trusttunnel-<server>-<port>`.
- **Страж** `engine_no_scheme_names_test`: `tt`/`trusttunnel` добавлены в
  литералы диспетчера; в Dart-коде имени схемы нет.
- Локально: `flutter test` двух своих файлов — зелёные (12 + 2);
  `flutter analyze` по изменённым файлам — 0 замечаний.
- **Не проверено**: полный прогон (CI) — в частности тесты, обходящие
  черновики (`mapper_sections_w4_test`, `document_registry_test`,
  `engine_w4_protocols_test`) и корпус; эмулятор/вставка из буфера на
  устройстве; энкодер Share из тела и подписка (п. 6) — не делались по ТЗ.

**04.11.2026, CI.** Коммиты b9c6a09a (код), 8e397ebb (`_delta_id`
`D533-tt-deeplink-form` у записей черновика — `draft_overlays_have_delta_id_test`),
0fed7a36 (ключи-пометки `_…` не попадают в `defaults`/`scheme_sets` секции —
иначе `_delta_id` уезжал в тело и давал `unknown_key`). CI run 41905642962 на
0fed7a36 зелёный (7587 тестов). Эмулятор не проверялся: на Android AAR без
`with_trusttunnel` узел всё равно выключит страховка core-rejected.
Запрос лаунчеру — `TASKS_LXBOX.md` §157 (dad60135, f6f169b3: varint QUIC, не
LEB128).

## Итерация 2 — контракт 1.1.175 (21.11.2026)

Лаунчер ответил на §157 разделом `TASKS_LXBOX.md` §177: секция `mappers.uri`
записи `trusttunnel` приехала реестром (коммит лаунчера `370e81a4`). Текст
выше описывает итерацию 1; там, где он расходится с этим разделом, действует
этот раздел.

### Что изменилось по существу

- **Декодера под схему нет.** `tt_deeplink` и файл
  `lib/services/parser/tt_deeplink.dart` сняты. Формат раскрывает табличный
  примитив `tlv` (`lib/services/parser/engine/tlv.dart`) по диалекту секции
  `mappers.uri.tlv`: место пейлоада (`in`), обёртка base64url, QUIC-varint,
  таблица полей с типами `varint` / `string` / `bool` / `enum` /
  `string_list` / `der_pem` / `hostport`, умолчания формата. Кодек не знает
  ни одного тега. Диалект — поле `MapperSection.tlv`; шаг формы —
  `"decode": ["tlv"]`, пространство `json`.
- **Черновик снят целиком**: `assets/contract_draft/uri/trusttunnel.json`
  удалён, `'trusttunnel'` убран из `kDraftFiles`.
- **`tls.server_name` ← `hostname`, не `custom_sni`** (решение владельца,
  §177 п. 2): у клиента AdGuard `custom_sni` — SNI, а сертификат сверяется с
  `hostname`; у ядра имя одно. `custom_sni` снимается с
  `tt_field_unsupported`.
- **Объект контейнера** (отличия от итерации 1): `upstream_protocol` только
  `http3` (`http2` — умолчание формата, в объект не кладётся); `certificate`
  — блок PEM на каждый DER-сертификат цепочки, блоки через `\n`, без
  хвостового перевода строки; тег `0x10 tls_profile` (`enum`, `chrome` —
  умолчание); строка не UTF-8 — U+FFFD на серию битых байтов, а не отказ;
  `subscription_url` не `https://` — контейнер не прочитан; пустой контейнер
  — пустой объект и `field_missing`; ссылка-подписка — объект с одним
  `subscription_url`, а снимает её запись-селектор `subscription_only`.
- **`tls_profile` → uTLS**: `chrome_canary` → `chrome`, `safari`, `firefox`,
  `okhttp` → `android`; `openssl` / `boringssl` uTLS не включают; при `http3`
  запись молчит с кодом (ядро не совмещает uTLS с QUIC).
- **Коды** — финальные, тексты из `registry/warnings.json`:
  `tt_field_unsupported` (warning, параметр `field`),
  `tt_subscription_ignored` (info), `tt_subscription_only` (error, узел снят);
  битый контейнер — `form_unrecognized`; нет адреса, порта или пароля —
  `field_missing`. `uri_param_unknown` и `service_record_ignored` для `tt://`
  больше не ставятся.
- **Обратный ход** — `emit.container: "tlv"`: объект собирается по
  `emit.json_map` (ссылка — путь тела, `$label`, `$param.<запись>`, литерал
  `=…`, цепочка через `|` — первая давшая значение), сериализуется диалектом
  в порядке `emit.param_order`; значение, равное умолчанию формата, не
  пишется.

### Правки движка, общие для всех секций

- `maps_to: null` + `value_map` + `on_invalid: {action: drop}` у селектора:
  промах таблицы снимает узел кодом, как у записи с путём (раньше код
  ставился предупреждением, узел жил).
- `value_map` → `null` больше не применяет `implies` записи (семантика Go
  `linkmap/exec.go`; у `tls_profile: openssl` иначе появлялся пустой
  `tls.utls.enabled`).
- `on_present` / `on_when_false` несут объявленные `params` в предупреждение.
- Форма с пространством `json` отдаёт фрагмент ссылки источником `fragment`
  (метка после `#` у контейнера).
- Узел без своей модели из ссылки: метка — как в ссылке (пустая, если имени
  нет), тег — фолбэк `<тип>-<адрес>-<порт>`; раньше фолбэк подставлялся и в
  метку.

### Файлы

- `app/lib/services/parser/engine/tlv.dart` (новый) — кодек; сюда переехали
  `readVarint`, `writeVarint`, `encodeTlv`, `encodeStringArray`,
  `splitHostPort`, DER↔PEM.
- `app/lib/services/parser/engine/section.dart` — `MapperSection.tlv`;
  `interpreter.dart` — шаг `tlv`, правки движка выше; `emitter.dart` —
  `_emitTlv`, `_containerValue`, `_paramSpelling`.
- `app/lib/services/parser/singbox_config.dart`,
  `mappers/uri_pipeline.dart` — тег и метка узла без модели.
- `app/test/parser/tt_deeplink_test.dart` — переписан;
  `app/test/contract/template_contract_test.dart` — раннер читает
  `sections[]` (кейс 1.1.174, приехал тем же синком).
- Синк: `app/contract/`, `app/assets/contract/`, `docs/contract/`,
  `app/contract.lock`.

### Проверка

- Корпус `contract/corpus/uri/trusttunnel/` — 30 из 30
  (`test/contract/contract_test.dart`).
- Побайтный паритет обратного хода (ссылка из тела равна исходной) на
  `http2_basic`, `ipv6_address`, `cert_chain_two`, `tls_profile_firefox`,
  `tls_profile_okhttp` — группа 8 `tt_deeplink_test.dart`.
- `flutter analyze` — без замечаний; адресный прогон тестов движка, реестра
  и корпусов (URI, шаблон) — зелёный.

### Не сделано

- Подписка TrustTunnel — сделана итерацией 3 (ниже).
- Share у узла `trusttunnel`, пришедшего из sing-box JSON:
  `UnknownTypeSpec.toUri()` по-прежнему отдаёт `rawSource` (у узла из ссылки
  это сама ссылка). Движковый эмит готов, к `toUri()` не подключён.
- Задачи §176 (контракт 1.1.174) кроме чтения `sections[]` раннером: отказ
  загрузки шаблона с `sections` и корневым `vars` вместе, подтверждение
  списка общих `id` — отдельная задача.
- Устройство и эмулятор не проверялись.

## Итерация 3 — контракт 1.1.176, подписка TrustTunnel (21.11.2026)

`TASKS_LXBOX.md` §178, коммит лаунчера `05097fe5`.

- **Ответ подписки.** Узел TrustTunnel отдаёт по адресу подписки один объект
  JSON с теми же ключами, что у полей контейнера ссылки. Вид источника
  `trusttunnel_endpoint_json` (`registry/source_kinds.json`) объявляет
  распаковщик `container_link`: объект печатается ссылкой `tt://?…` тем же
  кодеком, что обратный ход (`container.omit` снимается, `container.set`
  пишется поверх, порядок — `emit.param_order` секции), текст уходит на
  повторный детект и читается списком из одной ссылки. Узел и коды — те же,
  что у ссылки; происхождение узла — эта ссылка. Объект диалектом не
  выражается (значение не того типа) — вид не распакован.
  Код: `engine/document.dart` — объектная оболочка в `detect`
  (`JsonUnwrapper`, `DocumentSource.container`); `body_decoder.dart` —
  `_containerLink`.
- **Ссылка-указатель.** Ссылка `tt://` с одним `subscription_url` по-прежнему
  не узел (`tt_subscription_only`), но код несёт адрес в параметре
  `subscription_url`: движок кладёт отвергнутое селектором значение в первый
  параметр, объявленный кодом (`ContractRegistry.declaredParams`).
  `subscriptionUrlOfLink` (`subscription/input_helpers.dart`) узнаёт указатель
  по ИМЕНИ параметра, не по схеме. `SubscriptionController.addFromInput`
  (вставка, QR, поле ввода) заводит по адресу подписку; превью буфера
  (`clipboard_analysis.dart`) показывает её подпиской. В списке ссылок и в
  теле чужой подписки строка остаётся отказом с кодом.
- **Basic Auth.** `basicAuthHeader` (`subscription/sources.dart`): логин и
  пароль из userinfo адреса уходят заголовком `Authorization: Basic`,
  percent-экранирование снято. Заголовок ставится явно: клиент `dart:io`
  ставит его сам, но кодирует userinfo как написано, и пароль с `@`, `:`, `%`
  уходил бы искажённым. Текст HTTP-ошибки пишется без userinfo.
- **Форма узла.** Модель формы по `body.form` реестра у LxBox общая
  (`registry_form.dart`) — корпус `form/trusttunnel_form.json` проходит без
  правок. Экранная форма у LxBox одна, под OpenConnect
  (`widgets/openconnect_form.dart`: подписи полей и вкладка Add server);
  общего экрана «форма по реестру для любого типа» нет. Вкладка TrustTunnel
  в Add server не делалась — нужны подписи полей и решение владельца о
  вкладке.

### Проверка

- `contract/corpus/body/trusttunnel/` — 2 из 2
  (`test/contract/body_contract_test.dart`).
- `contract/corpus/form/trusttunnel_form.json` — 2 из 2
  (`test/contract/form_corpus_test.dart`).
- `contract/corpus/uri/trusttunnel/` — 30 из 30.
- `app/test/parser/tt_subscription_test.dart` — распаковка ответа, указатель,
  заголовок Basic у загрузчика, пароль не попадает в текст ошибки.
- Живой узел TrustTunnel с подпиской не проверялся; устройство и эмулятор не
  проверялись.

## Итерация 4 — Share узла из sing-box JSON (22.11.2026)

Хвост итераций 2–3: узел `trusttunnel`, пришедший записью `endpoints[]`
конфига, а не ссылкой, по «Copy link» отдавал текст записи JSON.

- **Причина.** `toUri()` у узла — одновременно форма хранения (`rawBody`).
  У узла без своей модели (`UnknownTypeSpec`) это исходный текст: ссылка у
  узла из ссылки, объект JSON у узла из конфига. Менять `toUri()` нельзя —
  хранение перешло бы на ссылку и потеряло поля, которых формат не несёт.
- **Решение.** У `NodeSpec` появился `shareUri()` — то, что отдаёт «Copy link»
  и `GET /nodes/link`; у всех моделей он равен `toUri()`. `UnknownTypeSpec`
  с хранением-объектом собирает ссылку движком по секции реестра своего типа
  (`uriViaEngine`: `emit.container`, `form_from`, `param_order`, `json_map`).
  Нет секции с обратным ходом либо тело форматом не выражается — остаётся
  текст записи, как было. Узел из ссылки или из подписки TrustTunnel отдаёт
  исходную ссылку без изменений. Имя в ссылке — метка узла, у записи конфига
  это её тег.
- **Движок.** Ссылки `json_map` — цепочка `a|b`, литерал `=…`, `$label`,
  `$param.<запись>` — читаются одним правилом у обоих контейнеров: бинарного
  `tlv` и JSON (раньше контейнер JSON понимал только путь тела).

### Файлы

- `app/lib/models/node_spec.dart` — `shareUri()`.
- `app/lib/screens/home/node_actions.dart`,
  `app/lib/services/debug/handlers/nodes.dart` — берут `shareUri()`.
- `app/lib/services/parser/engine/emitter.dart` — общие ссылки `json_map` в
  контейнере JSON.
- `app/test/parser/tt_deeplink_test.dart` — группы 9 и 10.

### Проверка

- Ссылка, собранная из JSON-узла, равна эталону байт в байт на пяти кейсах
  `TestContractTLVEmitByteParity` лаунчера: `http2_basic`, `ipv6_address`,
  `cert_chain_two`, `tls_profile_firefox`, `tls_profile_okhttp`.
- Круг по корпусу `uri/trusttunnel`: каждый разобранный кейс → JSON-узел →
  ссылка → разбор, тело и метка совпадают.
- Запись `endpoints[]` через разбор конфига: хранение остаётся объектом,
  ссылка несёт тег записи именем.
- Экран, устройство и эмулятор не проверялись.
