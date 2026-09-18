# §463 — корпус контракта W2c: объектные warnings и правила §24.2

| | |
|---|---|
| **Статус** | Сделано |
| **Дата** | 2026-09-18 |
| **Источник** | контракт W2c (`singbox-launcher` develop `ccb33731`) |
| **Связанные** | §459 (правила §24.2 до конвейера), §460 (реестр контракта в приложении), контракт §24.2/§24.6, CANON §6/§7 |

## Проблема

Лаунчер довёл конвейер узла до всех входов (W2c/W3/W4) и пересобрал корпус:
47 изменённых и 29 новых файлов под `contract/corpus`. Две группы расхождений
доехали до нас красным тестом.

**Первая — форма.** Контракт 1.1.0 (CANON §6) сменил `warnings[]` со списка
строк-кодов на список объектов `{code, path?, value?, params?}`. Все 54
предупреждения корпуса переписаны объектами; наш раннер строил список строк и
падал на 36 кейсах ровно по форме записи, не по существу.

**Вторая — поведение.** Новые ожидания нормируют правила, которые ядро пина
проверило `sing-box check`: пустой `server` у naive, битое percent-кодирование
в `transport.path`, одинокий `jmin` без `jmax`, пустой `reality.short_id`.
Каждое из них — вердикт B (фатал на весь конфиг), то есть узел, который мы
пропускали, оставлял человека без VPN целиком, а не только без этого узла.

## Решение

### 1. Синк контракта

`app/contract/` (копия вне git), зеркало `app/assets/contract/` и
`app/contract.lock` пересняты с `develop` лаунчера, коммит
`ccb337315d4d3fdba3af46efd06710b947a640e5`. Снимок брался
`git archive develop contract` во временный каталог — грязное дерево лаунчера
в копию не попало. Поля под хеш источника в `contract.lock` нет (`source=` —
путь), поэтому коммит записан здесь.

### 2. Раннер: объектные warnings (CANON §6)

`test/contract/contract_test.dart` строит `warnings[]` объектами. Правило
сравнения — зеркало Go-раннера (`core/config/contract_test.go`,
`normalizeWarningsForCompare`): нормативен ровно тот объём, который объявило
ожидание.

- `code` — всегда;
- `path` — только если ожидание его назвало;
- `value` — только если ожидание его назвало;
- ожидание строкой (`"tls_insecure"`) читается по-прежнему и сверяется только
  по коду.

`RegistryWarning` отдаёт `{code, path, value, params}` как есть (`secret`-поля
уже приходят как `***` от санитайзера). Рукописные классы отдают `{code}` плюс
`path`/`value` там, где поле класса и есть путь: `DeprecatedFlowWarning` →
`path: flow`, `AwgHeaderInvalidWarning` → `path` из имени поля. Остальным
классам путь не приписывался: выдуманный путь хуже отсутствующего, а ожидания
корпуса его и не требуют.

### 3. Правила §24.2 и §24.6

Разбор 39 падений: 33 — форма записи, 6 — поведение.

Разбор 39 падений URI-корпуса: **33 — форма записи** (чинится раннером),
**6 — поведение**. Body-раннер был зелёным с самого начала: он сверяет состав
узлов, а не коды.

Правил категории (в) — тех, что требуют санитайзера разбора с путём и потому
уехали бы в per-app override, — **не нашлось ни одного**. Override не заведён
ни один: корпус зелёный целиком. Это важно и по второй причине — `app/contract/`
в `.gitignore` и пересобирается `rm -rf` при каждом синке, так что override там
не коммитится и не переживает следующий синк; заводить его можно только в
репозитории лаунчера.

### Поведение

| Правило | Было | Стало | Файл |
|---|---|---|---|
| §24.6 naive пустой host | узел жил с `server: ""`; ядро валит весь конфиг | узел отбраковывается | `naive_parser.dart:40` |
| §24.6 `transport.path` с битым `%zz` | путь уезжал в тело; ядро валит весь конфиг на `url.Parse` | поле снимается, `type_invalid` с путём и значением | `uri_utils.dart:410`, `transport.dart:156` + 5 веток |
| §24.6 `jmin` без `jmax` | `jmin` оставался; ядро валит весь конфиг | снимается, `awg_header_invalid` с `path: jmin`; узел остаётся AWG | `node_spec.dart:981`, `wireguard_parser.dart:139-153` |
| §24.6 пустой `reality.short_id` | писался `""` | ключ опускается | `tls_spec.dart:264-271` |
| 7.1 `hellorandom*` | `hellorandomized*`→`randomized`, голый `hellorandom`→`chrome` | весь префикс → `random` | `utls_fingerprint.dart:101` |
| 7.5 anytls мусорный SNI | уезжал как есть, рукопожатие мертво | имя без `.` и `:` → адрес сервера | `anytls_parser.dart:44-47` |
| 7.7 TUIC дефолты | — | уже верно: `cubic`/`["h3"]` не пишутся | `tuic_parser.dart:30, 43-46` |
| 7.8 TUIC `udp_relay_mode` мусор | подменялся на `native` | снимается, `tuic_udp_relay_mode_invalid` | `tuic_parser.dart:40, 69-74, 116` |
| 7.9 пустой пароль anytls/tuic | — | уже верно: узел дропается | `anytls_parser.dart:23`, `tuic_parser.dart:18` |
| 7.10 ss legacy stream-шифры | узел дропался молча | набор = 18 методов ядра, узел живёт с info `ss_method_legacy` | `uri_utils.dart:521, 537`, `shadowsocks_parser.dart:95-98` |
| 7.13 Xray `splithttp` | не опознавался — узел без транспорта | алиас `xhttp`, читается и `splithttpSettings` | `transport.dart:129`, `json_parsers.dart:979, 1595` |
| 7.15 socks password-only | userinfo снималось целиком, пароль терялся | `:pass@` | `node_spec_emit.dart:596-607` |
| 7.16 ssh `private_key` | уезжал в ссылку «Copy link» | действие отказывает и объясняет | `node_actions.dart:168-185` |
| 7.17 WG MTU 1408 | — | уже верно: поле не пишется, дефолт ставит ядро | `wireguard_parser.dart:125-132` |
| 7.18 WG-ключи не 32 байта | — | уже верно на обоих входах: узел дропается | `uri_utils.dart:128-132` |

**7.16 — отступление от буквы правила.** Контракт говорит «не эмитить
`private_key` в share-URI». Буквально снять ключ из `toUri()` нельзя: у нас тот
же текст — форма ХРАНЕНИЯ узла (`rawBody`, инвариант
`parseUri(spec.toUri()) ≈ spec`), и вырезание уничтожило бы ключ при первой же
перезагрузке. Поэтому граница проведена там, где она содержательно и есть — на
действии «Copy link»: как у лаунчера (`ErrShareURINotSupported`), отказ
объявляется, а не подменяется урезанной ссылкой.

**7.3 (naive одиночный userinfo = password) не делалось** — согласованная дата
одновременной правки обеих сторон 24.09.2026.

### Порядок кодов

CANON §6 требует порядка `body.order`, но ожидание `junk_pair_with_body`
(единственный многокодовый URI-кейс) нормирует
`packet_encoding` → `tls.reality.short_id` → `flow`, то есть обход URI-парсера
лаунчера, — сам кейс это и оговаривает как временное до W2d. Наш обход выровнен
под него: разбор `packetEncoding` поднят ДО разбора TLS (читает только query,
от TLS не зависит), код `flow_deprecated` ставится последним.

## Проверка

- `flutter analyze` — `No issues found!`
- `dart run tool/l10n/{template_check,ui_check,hardcoded_check,kotlin_check}.dart --strict` — 0 failures, 0 warnings во всех четырёх
- `dart run tool/check_contract_lock.dart` — копия совпадает с lock, зеркало `assets/contract/` совпадает с копией
- `flutter test` — **4966 passed / 15 skipped**, красных нет
- корпус контракта: **324 passed / 9 skipped** (309 URI + 24 тела; skip — схемы
  с `extension` чужой стороны, парсера у нас нет по контракту), **0 override**
- goldens `test/fixtures/storage/golden/*` — не изменились

Четыре теста приложения, утверждавших прежнее поведение, переписаны под новое:
`uri_naive_test.dart` (пустой host), `awg_test.dart` (одинокий `jmin`; в
INI-фикстуру добавлен `Jmax`), `reality_key_share_test.dart` (пустой
`short_id`), `utls_fingerprint_test.dart` (`hellorandom*`). Новый набор —
`test/parser/contract_24_2_rules_test.dart`, 16 тестов на правила §24.2/§24.6.

## Docs

- `docs/GUARDS.md` — 12 новых строк гардов (слои 1 и 3); пункт 8 «Открытые
  вопросы» про `xhttp_uplink_header_placement_reset` закрыт: лаунчер принял наш
  гард в W2c, кейс зелёный с обеих сторон
- `docs/PROTOCOLS.md` — Shadowsocks (18 методов, девять legacy отдельным
  списком с объяснением риска), TUIC (`udp_relay_mode`/`congestion_control`),
  AnyTLS (мусорный SNI), NaïveProxy (пустой host), VLESS и XHTTP (`splithttp`)
- `CHANGELOG.md` → Unreleased → Fixed (7 записей) и Changed (4 записи)
- `docs/spec/features/460 contract-registry-bundle/spec.md` — раздел «Что из W2
  закрыл §463»: конформанс с объектными warnings закрыт целиком, перечислено
  оставшееся на W2
