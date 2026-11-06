# 717 — Ссылки `tt://` (AdGuard TrustTunnel deep-link) → узел `trusttunnel`

| Field | Value |
|-------|-------|
| Status | Done (итерация 1: разбор ссылки; Share-энкодер, подписка и финальные коды — после записи лаунчера §157) |
| Start date | 2026-11-04 |
| Source | issue #194 (вставка `tt://` из буфера не распознаётся); решение владельца: «поддержка формата tt://, с ним в паре сделать поддержку ссылок» |
| Related specs | §698 (узел `trusttunnel` из реестра, тип без своей модели), §585/§586 (`UnknownTypeSpec`), §562 (имена схем только из реестра); контракт — запрос лаунчеру `TASKS_LXBOX.md` §157 |

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
