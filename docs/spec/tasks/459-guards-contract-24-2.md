# 459 — Guard-фиксы по контракту §24.2 до единого конвейера

| Поле | Значение |
|------|----------|
| Статус | Реализовано, тесты зелёные (4872) |
| Дата старта | 2026-09-18 |
| Коммиты | `fix(459): guard-фиксы по контракту §24.2` (develop, 18.09.2026) |
| Источник | Контракт 1.1.0, `TASKS_LXBOX.md` §24.2 (целевые правила, обоснованы прогоном `sing-box check` на пине lx.4) и §24.4 (ответы владельца 18.09: все 14 пунктов приняты). Здесь — те, что с вердиктом B (мусор роняет ВЕСЬ конфиг) и ложная посылка про ECH; остальное — с фичей реестра |
| Ядро | `v1.14.1-lx.4`: `protocol/vmess/outbound.go`, `sing-vmess` (security), `transport/v2rayxhttp/client.go:49-51` + `meta.go:25-28,159` (xhttp enum'ы), `option/tls.go:235-241` (`OutboundECHOptions`), `common/tls/ech_tag_stub.go` (тег `with_ech` устарел, ECH компилируется всегда) |
| Связанные | §454 (TLS-allowlist — исключение `ech` было ошибкой), §457 (`key_share`), §320 (`ech_ignored` — остаётся только для URI `ech=`), §217/§416 (xhttp guard'ы в эмите — единая воронка), §321 (Xray `-udp443`) |

## Правила (по номерам §24.2)

### 7.11 vmess `security` — enum ядра

Ядро принимает ровно `auto, none, zero, aes-128-cfb, aes-128-gcm,
chacha20-poly1305`. Сейчас `normalizeVmessSecurity`
([`uri_utils.dart:450`](../../../app/lib/services/parser/uri_utils.dart))
пропускает `aes-128-ctr` (нет в ядре — фатал на весь конфиг) и превращает
`aes-128-cfb` в `auto` (рабочий метод теряется).

Целевое (реестр `protocols/vmess.json` → `body.fields.security`): `trim` +
`lower`; enum из шести; алиас `chacha20-ietf-poly1305` → `chacha20-poly1305`;
пусто/`null`/`undefined` → `auto`; иное (в т.ч. `aes-128-ctr`) → `auto` с
записью в лог `AppLog.I.warning` (код реестра `type_invalid`; класс
`NodeWarning` под него появится с фичей реестра — не заводить сейчас).
Одна функция обслуживает URI (v2rayN JSON, `scy`), sing-box JSON и Xray JSON —
проверить, что все три ветки идут через неё.

### 7.14 xhttp `mode` / `x_padding_placement` / `x_padding_method` — enum ядра

Сейчас в эмите `TransportSpec` (`transport_spec.dart:225-275`) через
`putEnum` гейтится только `seq_placement`; `mode`, `x_padding_placement`,
`x_padding_method` уходят как есть — мусор фатален (`meta.go:159` и
аналоги). Целевое: те же `putEnum` с `XhttpParamResetWarning(key,
invalidEnumValue)` (существующий класс, код `xhttp_param_reset`):

| Поле | Enum (case-sensitive, как в ядре) |
|---|---|
| `mode` | `auto`, `packet-up`, `stream-up`, `stream-one` |
| `x_padding_placement` | `cookie`, `header`, `query`, `queryInHeader` |
| `x_padding_method` | `repeat-x`, `tokenish` |

Пустое = не задано, ключ не пишется (как сейчас). Регистр НЕ нормализуем:
`queryInHeader` только camelCase. Гейт в эмите — единственная воронка для
URI, sing-box JSON, Xray JSON и редактора (как §416 для
`uplink_data_placement`).

### 7.2 ECH — `tls.ech{}` из sing-box JSON пропускать

Посылка D-006 «ядро без `with_ech`» ложна: `ech_tag_stub.go` объявляет тег
устаревшим, ECH собран всегда, `tls.ech` проходит `sing-box check`. §454
исключил `ech` из allowlist'а на этой посылке — ошибка.

Целевое:
- `kTlsPassthroughKeys` получает `ech` — **объект** (новый тип для
  passthrough: принимается `Map`, хранится и эмитится как есть; поля
  `enabled`, `config` (Listable), `config_path`, `query_server_name` — состав
  задаёт ядро, приложение внутрь не смотрит). Не-объект → отброшен молча
  (guard как у остальных). Позиция в эмите — по структуре
  `OutboundTLSOptions` (`option/tls.go:110-135`, найти место `ECH` среди
  соседей и вставить в `_kTlsEmitOrder` там же).
- naive принимает ECH (`protocol/naive/outbound.go:142-150`) —
  `kNaiveTlsPassthroughKeys` += `ech`.
- QUIC-типы (hy2/tuic): ECH на std-TLS валиден — проходит (как остальные
  сквозные).
- URI `ech=` Xray-формы — по-прежнему снимается с `ech_ignored`
  (`warnEchIgnored`, §320): ключ чужой (public_name ≠ SNI), handshake
  умирает. Текст предупреждения проверить — не должен утверждать «ядро без
  ECH»; если утверждает, исправить формулировку на «параметр Xray-формы не
  переносится» (строка UI → словари ru/zh).
- Доки: `tls_spec.dart` doc-комментарий (убрать «ядро без with_ech»),
  `GUARDS.md` (строка про `ech` в 2.1 — переписать: JSON проходит, URI
  снимается), `PROTOCOLS.md` абзац «TLS block (§454)» (ech в списке
  passthrough, URI-исключение), `KERNEL.md` если упоминает `with_ech`,
  спека §454 — пометка «ech: пересмотрено §459».

### 7.12 `key_share` — `trim` + `lower`

Сейчас строго `hybrid`/`classical`, `"Hybrid"` теряется молча. Целевое
(реестр `tls.json` → `body.fields.reality.fields.key_share`, `normalize:
trim_lower`): `trim().toLowerCase()`, затем enum; мусор → снять (лог, код
`reality_key_share_invalid`). Обе точки — `_realityKeyShare` (JSON) и
`realityKeyShareFromQuery` (URI). Тест `reality_key_share_test`: `"Hybrid"`
теперь принимается как `hybrid`; `"x"`, число — по-прежнему отброшены.

### 7.4 `xtls-rprx-vision-udp443` — порт не переписывать

Сейчас (`json_parsers.dart:524-530, 598-605`, `vless_parser.dart:32-36`)
суффикс `-udp443` нормализуется в `xtls-rprx-vision` + `packet_encoding:
xudp` **и переписывает порт узла на 443** (комментарий «vision-udp443
переписывает порт»). Порт — свойство узла: узел `…:8443` становился
недозваниваемым. Целевое: нормализация flow и `packet_encoding` остаётся,
порт не трогается ни в одной из трёх веток. Тесты, ожидающие 443, —
исправить на исходный порт.

## Что нашлось при реализации

- 7.14: `x_padding_placement` и `x_padding_method` уже шли через `putEnum`
  (§217) — добить оставалось только `mode`. Чтобы ключ не уехал в конец
  карты, объявление `putEnum` поднято выше блока `host`/`x_padding_bytes`;
  порядок эмита прежний.
- 7.4: URI-ветка (`vless_parser.dart`) порт и так не трогала — перезапись
  жила только в Xray-JSON (`_xrayVlessToSpec` и зеркало в `_xrayIdentity`).
  sing-box-ветка суффикс `-udp443` не разворачивает вовсе (поведение
  прежнее, в §24.2 не заявлено).
- 7.2: текст `EchIgnoredWarning` про ядро без ECH не утверждал — он говорит
  про публичный пробник в ссылке. Формулировка верна, словари ru/zh не
  трогались.
- Корпус контракта: кейсы `-udp443` берут узел на порту 443, расхождения с
  §24.2 не возникло — per-app override не понадобился.

## Что НЕ входит

- Классы `NodeWarning` под коды реестра (`type_invalid`,
  `reality_key_share_invalid`, `unknown_key` …) и `warnings[]` с `path` —
  фича реестра (бандлинг + генерация, решение владельца 18.09).
- 7.1, 7.5, 7.7–7.10, 7.13, 7.15–7.18 — вердикт не B или требуют схемы
  реестра; идут с фичей.
- 7.3 (naive userinfo) — синхронная правка с лаунчером **24.09.2026**,
  отдельной задачей в тот день.

## Проверка

- `test/parser/vmess_security_test.dart` (или в существующем vmess-тесте):
  `aes-128-ctr` → `auto`; `AES-128-CFB` → `aes-128-cfb`; `chacha20-ietf-poly1305`
  → `chacha20-poly1305`; пусто → `auto`; через URI v2rayN `scy`, sing-box
  JSON, Xray JSON.
- xhttp: `mode: "PACKET-UP"` → ключа нет + `XhttpParamResetWarning`;
  `x_padding_placement: "queryinheader"` → снят; `queryInHeader` → проходит;
  `x_padding_method: "fixed"` → снят; `repeat-x` → проходит.
- ECH: sing-box vless с `tls.ech{enabled, config:[…]}` → emit содержит объект
  как есть, позиция по структуре; naive с `ech` → проходит; `ech: "x"` →
  отброшен; URI `ech=` → снят с `ech_ignored`, как раньше.
- `key_share`: `"Hybrid"`/`" classical "` → нормализованы; мусор → нет ключа.
- `-udp443`: URI `…@h:8443?flow=xtls-rprx-vision-udp443` → порт 8443,
  flow vision, `packet_encoding: xudp`; то же для sing-box и Xray JSON.
- `flutter analyze`, `flutter test`, четыре l10n-чекера.
- Контракт: корпус `contract/corpus` — прогнать `test/contract/`; кейсы,
  ожидания которых расходятся с §24.2 (например `-udp443` → 443), получают
  per-app override со ссылкой на пункт §24.2 (норма 24.3.3) до прихода
  обновлённых `expected.json` от лаунчера (W2c).

## Docs to update

- `docs/GUARDS.md` — 1.4/2.1/3: строки vmess `security` (coerce auto), xhttp
  три поля (drop + `xhttp_param_reset`), `ech` (переписать), `key_share`
  (normalize), `-udp443` (порт не трогается).
- `docs/PROTOCOLS.md` — VMess «Parsed Parameters» (security enum), XHTTP
  (enum'ы трёх полей), TLS block (ech), VLESS flow (`-udp443` без порта).
- `CHANGELOG.md` → Unreleased / Fixed.
- Контракт `TASKS_LXBOX.md` §24.5 (зеркало ответов у лаунчера) — статус
  LxBox после влития.
