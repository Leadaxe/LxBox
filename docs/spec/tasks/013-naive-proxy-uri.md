# 013 — NaïveProxy outbound: URI parser + sing-box emit + share-URI

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата старта | 2026-04-25 |
| Дата завершения | 2026-04-25 |
| Коммиты | `86de2f4` feat(§037): NaïveProxy outbound — parser, emit, share-URI · `0b4db37` docs(§037): NaïveProxy в PROTOCOLS, READMEs, CHANGELOG, releases · `1d39e25` chore(§037): close #2 |
| Связанные spec'ы | [`037 naive proxy`](../features/037%20naive%20proxy/spec.md) |
| Связанные issue | [#2 add naive proxy support](https://github.com/Leadaxe/LxBox/issues/2) |

## Проблема

Юзеры запросили (issue #2 от @rsg245) поддержку **NaïveProxy** — Cronet-обёртки над HTTPS-прокси, изначально SagerNet, с de-facto URI-стандартом DuckSoft 2020 (`naive+https://...`). Проксирующая логика — обычный HTTP CONNECT через TLS, но Cronet-стек делает фингерпринт от Chromium (а не Go-default), что важно в средах с активным DPI/SNI-фильтрацией.

NekoBox / NaiveGUI / v2rayN / Hiddify уже пять лет живут с этим URI-форматом, юзер ожидает скопировать ссылку из подписки и вставить в L×Box.

Без поддержки парсер v2 ронял такие URI как `vmess`-неподобные → нода молча терялась, юзер видел 0 серверов в подписке.

## Диагностика

### Было ли уже всё в libbox?

Первый чек — поддерживает ли наш `libbox.aar` (1.12.x main variant, `com.github.singbox-android:libbox`) sing-box-овский `type: "naive"` outbound. Sing-box gate'ит naive за build-tag `with_naive_outbound` (см. `protocol/naive/outbound.go`).

Проверка `release/build_libbox.go` в singbox-android репо: для main-variant `sharedTags` включает `with_naive_outbound`, для `libbox-legacy` (Android API 21+, без Cronet-deps) — фильтрует. Мы юзаем main, поэтому **build-tag присутствует** и runtime-вызов `Libbox.newService(config)` принимает `type: naive` без падений. Никаких изменений на native-стороне не нужно — только Dart parser + emit.

Defensive guard'ы:
- `NaiveBuildTagWarning` — runtime-detect строки `"naive outbound is not included in this build, rebuild with -tags with_naive_outbound"` из `include/naive_outbound_stub.go`. На случай если будущий libbox-апгрейд молча перейдёт на legacy variant — пользователь увидит warning под нодой, не молчаливый «соединение не идёт».

### URI-формат

DuckSoft de-facto spec — `naive+https://[user[:pass]@]host[:port]/[?params][#label]`:

| Поле | Источник | Default |
|------|----------|---------|
| `host` | URI host (FQDN или IP, IPv6 в `[…]`) | required |
| `port` | URI port | `443` |
| `user`, `pass` | userinfo | optional, anonymous если пусто |
| `extra-headers` | query-param, CRLF-encoded HTTP headers | optional |
| `padding` | query-param `true|false` | silent-drop с warning'ом — sing-box outbound не поддерживает |
| `#fragment` | URL-decoded UTF-8, label узла | optional |

Тонкости которые поймали в тестах:
- userinfo может быть `user:pass`, `password-only` (без `:`), либо вообще отсутствовать
- IPv6 в `[…]`, нужен round-trip через `Uri.parse` который декодит автоматом
- fragment с UTF-8 emoji-флагом (`#%E2%9C%85%20DE` → `✅ DE`) — `Uri.decodeComponent` справляется
- `extra-headers` — каждая строка отделена URL-encoded `\r\n` (`%0D%0A`); ключи лексикографически сортируются перед эмиссией для стабильного round-trip'а
- query-key lookup case-insensitive (`PacketEncoding` тоже ловится — на случай если кто-то накастомит)

### sing-box outbound contract

Ограничения у `naive` outbound (`protocol/naive/outbound.go::NewOutbound`):
- **TLS**: только `enabled` + `server_name`. `alpn`, `utls`, `insecure`, `reality`, `min_version`, `cipher_suites`, `fragment` — отвергаются с error'ом. Парсер не эмитит их даже если в URI было.
- **Network/QUIC**: не эмитим в v1 — DuckSoft URI не несёт этих полей, naive QUIC-mode отложен.

## Решение

### Parser & emit

| Файл | Что |
|------|-----|
| [`uri_parsers.dart`](../../../app/lib/services/parser/uri_parsers.dart) | Новая ветка `naive+https://…` → `NodeSpec.naive(...)`. Dispatcher по `scheme.startsWith('naive+')`. Auth-варианты, `extra-headers` decode, `padding` silent-drop. |
| [`json_parsers.dart`](../../../app/lib/services/parser/json_parsers.dart) | Sing-box JSON entry с `"type": "naive"` парсится в `NodeSpec.naive`. Same TLS-ограничения. |
| [`uri_utils.dart`](../../../app/lib/services/parser/uri_utils.dart) | Helper'ы для CRLF-encoded headers (parse + emit + lex sort). |
| [`models/node_spec.dart`] | `NodeSpec.naive(...)` — sealed-вариант с auth/extra-headers/tls. |
| [`builder/build_config.dart`] | Эмит sing-box outbound `{"type": "naive", "server", "server_port", "username", "password", "tls": {...}, "extra_headers": {...}}`. |
| [`vpn/box_vpn_client.dart`] / native | Detect `NaiveBuildTagWarning` через runtime-error parsing — defensive только, на текущей libbox не сработает. |

### Tests

36 новых тестов в [`vless_test.dart`](../../../app/test/parser/vless_test.dart) ⇒ нет, в новом `naive_test.dart` (parser-19, emit/round-trip-17). Suite 373 → 409. Покрытие:
- три варианта auth (`user:pass`, `pass-only`, anonymous)
- IPv6 host
- `extra-headers` с одной/несколькими/CRLF-encoded headers
- UTF-8 fragment с emoji
- `padding=true|false` — silent drop + log warn
- Round-trip URI → NodeSpec → outbound JSON → URI равенство по канонической форме

### Документация

| Файл | Что |
|------|-----|
| [`docs/PROTOCOLS.md` §5.5 NaïveProxy](../../PROTOCOLS.md) | URI-формат, поля, ограничения TLS, build-tag note, ссылки на DuckSoft spec и sing-box outbound docs. |
| [`docs/spec/features/037 naive proxy/spec.md`](../features/037%20naive%20proxy/spec.md) | Полная спека — задача, build-tag verification, URI-формат, маппинг, defensive `NaiveBuildTagWarning`, тесты, out-of-scope. |
| `README.md` / `README_RU.md` / `RELEASE_NOTES.md` / `docs/releases/v1.6.0.md` / `CHANGELOG.md` | NaïveProxy упомянут как 10-й типизированный протокол, без APK-size impact (Cronet уже в bundled libbox). |

## Риски и edge cases

| Риск | Mitigation |
|------|-----------|
| Будущий libbox upgrade на legacy variant без `with_naive_outbound` | Runtime `NaiveBuildTagWarning` детектит точную error-строку из stub'а. CI можно дополнительно прогнать smoke-test на libbox версии. |
| URI с нестандартным `padding` параметром | Silent drop, warning в лог. Не ломаем парсинг ноды. |
| `extra-headers` с дублирующимися ключами | Берём последний (HTTP-семантика ближе к этому); тест покрывает. |
| Юзер кладёт `alpn=h3` в query | Parser игнорит, sing-box outbound его всё равно бы отверг — лучше тихо чистить чем падать. |

## Верификация

- 36 unit-тестов parser/emit/round-trip — passing.
- Полный suite 409 ✓ — нет регрессий в других protocols (vless/vmess/trojan/ss/hy2/tuic/ssh/socks/wg).
- APK-size diff ≈ 0 — `with_naive_outbound` уже в bundled libbox, новых нативных deps нет.
- Manual smoke на тестовой подписке с naive-нодой — VPN connects, traffic flows, pings green (юзеры issue #2 подтверждали).

## Нерешённое / follow-up

- **`network`/`udp_over_tcp`/`quic` поля** — не эмитятся, naive QUIC-mode отложен. Если в DuckSoft URI появится канон или sing-box добавит наш-релевантные поля — расширим парсер отдельной задачей.
- **Custom UTLS fingerprints / ALPN** — sing-box контракт это пока не пускает. Если sing-box уберёт ограничение — открывается следующая задача.
- **CI smoke на libbox с другим build-tag set'ом** — отложено как follow-up, ROI низкий пока libbox-android не дробит variants дальше.
