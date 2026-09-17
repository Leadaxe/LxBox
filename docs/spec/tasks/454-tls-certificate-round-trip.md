# 454 — TLS-поля тела узла (`certificate` и соседи) теряются при разборе; источник узла из JSON

| Поле | Значение |
|------|----------|
| Статус | Реализовано, тесты зелёные; DEVICE-PENDING (naive с самоподписанным CA) |
| Дата старта | 2026-09-17 |
| Коммиты | `386f1985` (rawUri → rawSource), `28b2d19c` (источник узла из JSON), `76af5cc8` (TLS-allowlist) — ветка `feat/454-tls-allowlist-raw-source`; продолжение — §455 (`4b776f04`) |
| Источник | [issue #140](https://github.com/Leadaxe/LxBox/issues/140) (zolg); контракт лаунчера `TASKS_LXBOX.md` §22 — норма allowlist TLS-полей, ответ LxBox «А» 17.09.2026; лаунчер закрыл свою сторону в develop `189bdd4f`, `7f2feafe` |
| Ядро | `option/tls.go:110-135` — `OutboundTLSOptions`; naive принимает только `enabled`/`server_name`/`certificate(_path)`/`ech` — `protocol/naive/outbound.go:45-116`; `libbox.CheckConfig` — `experimental/libbox/config.go:50` |
| Связанные | §281 (naive: TLS срезан), §103/D-078 (пин), §282 (QUIC-strip utls/reality), §320 (`ech_ignored`), §302 (источник узла для UI), §243 (INI: тег во фрагменте синтетического wg://), §453 (прецедент sing-box-only поля), §283 (identity-хеш), §439 (истина узла — текст источника), §455 (вкладки Source/JSON — следующая задача) |

## Проблема

Пользователь вписывает во вкладку «Outbound JSON» naive-узла блок
`tls.certificate` (свой корневой CA в PEM), жмёт Save — поле исчезает. Через
глобальный редактор конфига поле живёт и работает, но редактор узла его не
показывает и при следующем Save снова затирает.

Две причины, обе не про naive.

**1. Модель TLS знала меньше, чем ядро.** `TlsSpec` держал шесть полей;
`_tlsFromSingbox` читал только их и отбрасывал остальное молча для всех
протоколов: `certificate`, `certificate_path`, `disable_sni`, версии,
`cipher_suites`, `curve_preferences`, `client_*`, `fragment*`, `kernel_*`.
Пин `certificate_public_key_sha256` из JSON не читался вовсе (только из
`pinSHA256=` hysteria2-URI). Для naive поверх этого `_naiveTlsFromSingbox`
оставлял только `enabled`+`server_name` (§281 — защита от alpn/utls/reality,
которые ядро отвергает фаталом), хотя `certificate(_path)` ядро на naive
принимает. Вкладка JSON показывает `emit()` модели, Save пишет этот текст в
`origin.raw` поверх оригинала — так поле терялось не в хранении, а в
редакторе. Хуже: без своего CA узел на самоподписанном сертификате не
поднимается вовсе, а `insecure` naive тоже отвергает (`outbound.go:51`).

**2. Узел из JSON не нёс своего источника.** Хранение и бэкап держат текст
записи как пришёл (`origin.raw`, у члена папки то же поле — форма одна), но
узел в памяти получал `rawUri = ''` (sing-box JSON) или заглушку
`xray://<tag>` (Xray). Настоящий источник жил во втором поле `sourceCompact`
(§302) и читался только экраном подписки. Везде, где узлу нужен собственный
текст — переезд в папку (`memberRawFor`, `subscription_controller.dart:1230`,
`:1549`, `:1600`, `:2071`), «Copy link» (`node_actions.dart:168`) — он
пересобирался через `toUri()` и терял всё, чего в URI нет.

Лаунчер воспроизвёл потерю №1 у себя на sing-box-импорте (эмиттер из семи
полей) и зафиксировал норму: **allowlist = `OutboundTLSOptions` ядра**,
Listable-поля в форме прибытия, `ech` и неизвестное не эмитятся
(TASKS_LXBOX §22).

## Решение

### 1. `rawUri` → `rawSource` (коммит `386f1985`)

Механическое переименование поля `NodeSpec` (104 вхождения в `lib/`, 49 в
`test/`, 9 спек). Поле перестаёт быть «URI» ровно в тот момент, когда JSON-узлы
начинают хранить в нём объект; старое имя лгало бы. В хранение и контракт
поле не пишется.

### 2. Источник узла из JSON (коммит `28b2d19c`)

`sourceCompact` слит в `rawSource`: источник у узла один.

| Откуда узел | `rawSource` |
|---|---|
| URI-строка | сама строка (как было) |
| sing-box JSON (одиночный entry, массив, целый конфиг) | его объект outbound'а в pretty-JSON — **оригинал**, до подмены тега лейблом (`parseSingboxEntry(entry, {rawSource})`; `singbox_config.dart` передаёт `_prettyJson(ob)`) |
| Xray JSON | его объект outbound'а (было — заглушка `xray://<tag>`) |
| группа из sing-box-конфига | её объект (`AutoSelectSpec.rawSource`, новый параметр конструктора и `copyWith`) |
| WG из INI | **синтетический wg:// с тегом во фрагменте** (§243) — им узел хранится (`rawBody` одиночного WG-сервера) и переживает рестарт с именем файла; сам INI-текст в `WireguardSpec.rawIni`, экран подписки показывает его |
| группы приложения (§208, папки) | пусто, текста нет |

`sourceExtended` (весь элемент провайдера с dns/inbounds/routing) остаётся
отдельным mutable-полем, пишется только когда отличается от `rawSource`.

Следствие: `memberRawFor` для узла из JSON находит источник, который парсится
ровно в одну ноду, и хранит его как есть. Переезд в папку и «Copy link»
больше не проходят через `toUri()` у JSON-узлов. Отдельного вопроса
«URI-форма для PEM» (первый черновик, В1) больше нет.

### 3. TLS-allowlist по структуре ядра

`TlsSpec` остаётся моделью (вариант А контракта): на ней стоят гейты — REALITY
по валидному pbk §169, fp-словарь §281, QUIC-strip §282, short_id §343,
naive-фильтр. Типизированные поля не множатся: добавлена **сквозная карта**
остальных ключей allowlist'а.

[`tls_spec.dart`](../../../app/lib/models/tls_spec.dart):

- `kTlsPassthroughKeys` — 16 ключей в порядке структуры ядра: `disable_sni`,
  `min_version`, `max_version`, `cipher_suites`, `curve_preferences`,
  `certificate`, `certificate_path`, `client_certificate`,
  `client_certificate_path`, `client_key`, `client_key_path`, `fragment`,
  `fragment_fallback_delay`, `record_fragment`, `kernel_tx`, `kernel_rx`.
  `kTlsListableKeys` (строка или массив), `kTlsBoolKeys` (только `true`).
- `TlsSpec.passthrough: Map<String, Object>` — значения в форме прибытия;
  `copyWith`, `==`/`hashCode` (deep) учитывают карту. Заодно в равенство
  вошёл пин `certificatePublicKeySha256` (D-078; не сравнивался — упущение).
- Эмит `_toSingbox` — один порядок `_kTlsEmitOrder` для типизированных и
  сквозных: `enabled, server_name, alpn, insecure, disable_sni, min_version,
  max_version, cipher_suites, curve_preferences, certificate,
  certificate_path, certificate_public_key_sha256, client_certificate,
  client_certificate_path, client_key, client_key_path, fragment,
  fragment_fallback_delay, record_fragment, kernel_tx, kernel_rx, utls,
  reality`. Отступление от структуры ядра одно: `alpn` перед `insecure` —
  ради байт-в-байт паритета эмита узлов без новых полей (тест parity в
  `tls_passthrough_test`). Identity-хеш §283 сортирует ключи
  (`deepSortKeys`), порядку безразличен. QUIC-эмит (`toSingboxForQuic`)
  сквозные ключи пропускает: сертификаты и версии на hy2/tuic валидны.

[`json_parsers.dart`](../../../app/lib/services/parser/json_parsers.dart):

- `tlsPassthroughFromSingbox(Map raw)` — guard «деградируй поле, не конфиг»:
  Listable — непустая строка или массив строк (пустые элементы отброшены);
  строки — непустые; bool — только `true`. Не тот тип (число вместо PEM,
  объект вместо строки, `false`) — ключ отброшен молча, узел жив.
  `Listable[string]` с мусором ронял бы decode всего конфига в ядре.
- `_tlsFromSingbox` читает `passthrough` и пин `certificate_public_key_sha256`
  (строка или массив).
- `_naiveTlsFromSingbox` пропускает из карты только
  `kNaiveTlsPassthroughKeys` = `certificate`, `certificate_path`
  (`outbound.go:108-116`); остальное ядро на naive отвергает фаталом. Пин
  naive молча не читает (в коде ядра не используется) — срезан, чтобы не
  обещать пиннинг, которого нет. Паритет с `naiveTLSKeys` лаунчера
  (`core/config/outbound_tls_emit.go`, develop `7f2feafe`).
- `ech` — не читается и не эмитится: ядро без `with_ech` (D-006), LxBox
  вычищает с кодом `ech_ignored` (§320). Неизвестные ключи — отбрасываются.
  `kernel_tx/rx` — Android = Linux, проходят.

Xray JSON (`_xrayTlsFromStream`) не трогался: у Xray нет аналога trust-root в
`tlsSettings`.

### Что НЕ трогалось

- UI формы узла — полей нет; вкладка JSON показывает поля сама. Редактор
  Source/JSON — отдельная задача §455 (решения владельца 17.09: JSON только
  чтение с кнопкой Edit → предупреждение → `origin` становится `json`,
  правка в Source; `origin.kind: json` уходит в ядро дословно с проверкой
  `CheckConfig`; `body` = кеш, не хранится).
- identity-хеш §283 — у узлов без новых полей emit прежний. У узла с
  сертификатом хеш меняется (раньше поле в emit не попадало) — правка сути.
- backup allowlist §221 — узел хранится текстом, новых ключей хранения нет.
- `certificate` + `certificate_public_key_sha256` вместе — ядро считает
  конфликтом; ошибка данных пользователя, эмиттер не вмешивается (норма
  лаунчера п.5).

## Проверка

- [`test/parser/tls_passthrough_test.dart`](../../../app/test/parser/tls_passthrough_test.dart):
  naive из issue → `certificate` строкой, порядок `enabled, server_name,
  certificate`; массив → массив, `certificate_path`; мусорные naive-поля
  (insecure/alpn/min_version/disable_sni/fragment/kernel_tx/пин/utls/
  client_certificate) срезаны до трёх ключей — ожидание совпадает с узлом
  `naive-junk-tls` корпуса лаунчера `outbound_array_tls_fields`;
  `rawSource` naive-узла = его объект; vless со всеми 16 сквозными ключами +
  пин — порядок структуры ядра, строка/массив в форме прибытия; не тот тип →
  поле отброшено; `ech`/`foo` не проходят; parity без новых полей байт в
  байт; hysteria2 (QUIC) — `certificate` проходит, `utls` срезан; `==` с
  пином и картой.
- `test/parser/singbox_config_test.dart` — источник = сам outbound
  (`rawSource`), расширенный = конфиг.
- `flutter analyze` чист по всему проекту; `flutter test` зелёный.
- Устройство (PENDING): naive-узел с самоподписанным CA — после Save вкладка
  показывает `certificate`, running config ядра (§311) содержит его,
  соединение поднимается без `insecure`.

## Docs to update

- `docs/GUARDS.md` — строки naive TLS (1.5 и 2.1) уточнены; новые строки 2.1:
  passthrough-ключ не того типа → поле отброшено; ключ вне
  `OutboundTLSOptions`/`ech` → отброшен. Сделано.
- `docs/PROTOCOLS.md` — naive «Behaviour Notes»; 10 «Notes»: абзац «TLS
  block (§454)» с allowlist'ом и порядком эмита. Сделано.
- `CHANGELOG.md` → Unreleased / Fixed, две записи (TLS-поля; источник узла
  из JSON). Сделано.
- Контракт лаунчера `TASKS_LXBOX.md` §22 — ответ А записан 17.09.2026;
  статус LxBox после влития в develop. Упоминание `rawUri` в §20 контракта
  устарело (поле переименовано) — сообщить сессии лаунчера.
