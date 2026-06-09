# 097 — AWG2 (AmneziaWG 2.0) + смена ядра на `sing-box-lx`

| Поле | Значение |
|------|----------|
| Тип | Feature (новый протокол-вариант + смена bundled-ядра) |
| Статус | **DRAFT / на согласование** — код НЕ начат (spec-first) |
| Источник | Юзер: «готовимся к смене ядра», fork [`Leadaxe/sing-box-lx@lx`](https://github.com/Leadaxe/sing-box-lx/blob/lx/README.ru.md) |
| Зависит от | §019 (wireguard endpoint), §026 (parser v2), §012 (native VPN) |

## 1. Контекст

Fork `sing-box-lx` (ветка `lx`) добавляет к upstream sing-box:
- **AWG2 (AmneziaWG 2.0)** — обфускация WireGuard. Поля **продвинуты прямо в
  `WireGuardEndpointOptions`** (не отдельный outbound-тип, не per-peer — на
  уровне endpoint'а).
- **XHTTP** transport (Xray-совместимый «splithttp» поверх Reality/TLS/h2c).

LxBox сейчас бандлит ядро как **prebuilt Maven AAR** —
`com.github.singbox-android:libbox:1.13.11` (единственный пин в
`app/android/app/build.gradle.kts:123`). «Смена ядра» = заменить этот артефакт
на libbox из `sing-box-lx`. Это **prerequisite** для AWG2/XHTTP: app-side
парсинг/эмит бесполезны, если ядро не понимает поля.

## 2. Что такое AWG2 — поля

Все поля — **config-only** (не согласуются по сети), **должны совпадать**
client+server, чувствительны к регистру. Уровень — **endpoint** (рядом с
`private_key`/`address`/`peers`/`mtu`).

| Поле | Тип | Назначение | Версия |
|------|-----|-----------|--------|
| `jc`, `jmin`, `jmax` | int | jitter (кол-во/границы junk-пакетов) | AWG v1 |
| `s1`, `s2`, `s3`, `s4` | int | packet split | AWG v1 |
| `h1`, `h2`, `h3`, `h4` | int | header obfuscation (magic headers) | AWG v1 |
| `i1`, `i2`, `i3`, `i4`, `i5` | string | CPS decoy-пакеты, напр. `"<b 0x...><r 12>"` | **AWG v2.0** |

Пример endpoint'а (из README fork'а):

```jsonc
{
  "type": "wireguard", "tag": "...", "address": ["..."], "private_key": "...",
  "peers": [ { "address": "...", "port": 51820, "public_key": "...", "allowed_ips": ["0.0.0.0/0"] } ],
  "jc": 10, "jmin": 50, "jmax": 100,
  "s1": 20, "s2": 20, "s3": 60, "s4": 60,
  "h1": 1, "h2": 2, "h3": 3, "h4": 4,
  "i1": "<b 0x...><r 12>", "i2": "", "i3": "", "i4": "", "i5": ""
}
```

> **NB:** уровень полей (endpoint vs per-peer) взят из README fork'а
> («WireGuardEndpointOptions»). Перед реализацией — **подтвердить по исходнику
> fork'а** (Go-структура), см. open question Q2.

## 3. Архитектурная развязка (как ложится на код)

WireGuard в LxBox — **единственный** протокол, эмитящийся в `endpoints[]`, не
`outbounds[]` (sealed `SingboxEntry` → `Endpoint`). AWG2-поля идут в тот же
endpoint-map на верхнем уровне — естественно для текущего `emitWireguard`.

Текущая модель (`lib/models/node_spec.dart`):
- `WireguardSpec { privateKey, localAddresses, peers[], mtu, rawIni }` (endpoint).
- `WireguardPeer { publicKey, preSharedKey, endpointHost, endpointPort, allowedIps, persistentKeepalive }`.
- `emit()` → `emitWireguard()` (`node_spec_emit.dart`) → `Endpoint(map)`.

**Проблема round-trip (важно):** сейчас неизвестные/extra-ключи endpoint'а
**молча теряются** при парсинге (parse → model только известные поля → emit).
AWG2 без явной поддержки не переживёт `parse→build`.

## 4. Фазы

### Phase 0 — Смена ядра (`sing-box-lx` libbox) — PREREQUISITE

Самый большой неизвестный. Варианты получения артефакта:
- **(0a)** fork опубликован как Maven/jitpack-артефакт → сменить строку
  `build.gradle.kts:123` (напр. `com.github.Leadaxe.sing-box-lx:libbox:<tag>` +
  при необходимости репозиторий jitpack). **Минимальный путь.**
- **(0b)** fork НЕ опубликован → нужен **локальный build libbox.aar** через
  `gomobile bind` из Go-исходников fork'а + CI-шаг + хранение артефакта. Большой
  объём (Go toolchain, gomobile, CI). См. Q1.

Native-мост (`VpnPlugin.kt` / `BoxService.kt`: `cs.startOrReloadService(json,
OverrideOptions())`) и `ConfigManager` **прозрачны** к payload'у — AWG2-поля
проходят как часть JSON-строки **без изменений Kotlin-кода**, ЕСЛИ ABI
`OverrideOptions`/libbox не сломан новой версией (Q4). `getCoreVersion` уже
читает `Libbox.version()` — добавить отображение версии ядра в UI/Debug.

**Output Phase 0:** APK с fork-ядром, `Libbox.version()` подтверждает fork,
существующие конфиги (vless/wg/…) работают как раньше (regression-gate).

### Phase 1 — Data layer AWG2 (parse → model → emit → round-trip)

**Модель** (`node_spec.dart`): добавить опциональный value-object на
`WireguardSpec` (endpoint-level), `null` = обычный WG:

```dart
/// §097 — AmneziaWG2 обфускация (endpoint-level, config-only). null = plain WG.
class Awg {
  final int? jc, jmin, jmax;          // jitter
  final int? s1, s2, s3, s4;          // split
  final int? h1, h2, h3, h4;          // header obfuscation
  final String? i1, i2, i3, i4, i5;   // v2.0 CPS decoy
  const Awg({...});
  bool get isEmpty => /* все null */;
  factory Awg.fromEndpointJson(Map<String,dynamic> m) => ...; // читает ключи
  void writeInto(Map<String,dynamic> m) { if (jc != null) m['jc']=jc; ... }
}
// WireguardSpec += final Awg? awg;
```

**Альтернатива (Q5):** вместо типизованного `Awg` — сохранять **произвольные
неизвестные endpoint-ключи** в `Map extraOptions` (forward-proof к будущим полям
fork'а), типизация только для UI. Рекомендация: типизованный `Awg` для MVP
(валидация + UI + тесты), `extraOptions` — follow-up если fork часто меняет схему.

**Parse:**
| Источник | Файл | Что добавить |
|---|---|---|
| JSON endpoint | `parser/json_parsers.dart` (`'wireguard'` case) | `Awg.fromEndpointJson(entry)` с верхнего уровня |
| `wireguard://` URI | `parser/uri_parsers/wireguard_parser.dart` | query-параметры `jc/jmin/jmax/s1..s4/h1..h4/i1..i5` |
| INI (`_iniToUri`) | `parser/ini_parser.dart` | `[Interface]` ключи `Jc/Jmin/Jmax/S1..S4/H1..H4/I1..I5` (case-insensitive) → query |

**Emit** (`node_spec_emit.dart`):
- `emitWireguard`: после сборки `map` — `s.awg?.writeInto(map)` (top-level,
  только non-null).
- `toUriWireguard`: добавить AWG2 в query (round-trip; см. Q3 про длину URI).

**Тесты:** `round_trip_test` (URI/INI/JSON × AWG2 → parse→emit→parse идемпотентно),
`build_config_test` (endpoint содержит AWG2-поля), фикстура
`singbox_wg_endpoint_awg2.json`.

### Phase 2 — UI

- **MVP (2a, рекомендуется):** **JSON-only**. `node_settings_screen` уже имеет
  JSON-таб (полный endpoint редактируется как есть). После Phase 1 (parse/emit
  сохраняют поля) AWG2 уже редактируется через JSON-таб. `add_server_wizard`
  Paste-URI/JSON — работает heuristic'ом. **Нужен только** парс/эмит (Phase 1).
  Detour-ряд: чекбокс-enable + `!` (независим, ON по умолчанию) + лейбл
  по `!` (Hide/Only) — снятие галки лейбл НЕ меняет (вкл/выкл = чекбокс+чип).
- **2b (follow-up):** выделенная сворачиваемая секция «AmneziaWG2» в
  `node_settings` Settings-табе с полями jc/jmin/jmax, s1-s4, h1-h4, i1-i5 +
  bidirectional sync с JSON-табом. Делать по фидбеку.
- **Лейбл (опц.):** `protoLabel` → `'WG'`; можно `'AWG2'` когда `awg != null`
  (требует прокинуть признак в `NodeViewItem`/`ParsedConfig`). Defer до 2b.

### Phase 3 — XHTTP — ВЫПОЛНЕНО ✅ (по образцу singbox-launcher SPEC 071)

`XhttpTransport` (`transport_spec.dart`) расширен полями Xray splithttp
(`mode`/`xPaddingBytes`/`noGrpcHeader`/`headers`) и теперь эмитит **нативный**
`type:"xhttp"` (без fallback в httpupgrade / без `UnsupportedTransportWarning`).
- **parse:** `parseTransport` (URI, camelCase Xray + snake sing-box: `xPaddingBytes`/
  `x_padding_bytes`, `noGRPCHeader`/`no_grpc_header`); `_transportFromSingbox`
  (sing-box JSON); `_xrayTransportFromStream` (Xray `xhttpSettings`).
- **emit/round-trip:** `XhttpTransport.toSingbox` → endpoint transport-map;
  `transportToQuery` → share-URI. `httpupgrade` остаётся **отдельным** типом.
- **Тесты:** `test/parser/xhttp_test.dart` (8) + обновлены vless/node_spec/
  pipeline_e2e (раньше ждали fallback-warning → теперь нативный xhttp). 860 green.
- **NB:** как AWG — на стоковом ядре (CI без `with_xhttp`) конфиг с `type=xhttp`
  отвергается; фича «спит» до релиза fork-ядра.

## 5. Validation (Phase 1)

`builder/validator.dart` сейчас не валидирует схему полей (unknown-ключи
допускаются) — AWG2 пройдёт. Клиентская валидация (UI/parse): диапазоны (Q6),
напр. `jmin ≤ jmax`, `jc ≥ 0`. На MVP — мягко (warning), не блок.

## 6. Docs to update

`PROTOCOLS.md` (§WireGuard 642-699: AWG2-поля, URI/INI-формат, endpoint-схема,
config-only/must-match), `ARCHITECTURE.md` (AWG2 = WG+обфускация, версия ядра =
fork), `BUILD.md`/`RELEASE_PROCESS.md` (если Phase 0 = локальный libbox build),
`CHANGELOG`. STORAGE/TEMPLATE — без изменений (поля живут в `raw_body`/node JSON).

## 7. Open questions (решить до реализации)

- **Q1 (крит):** `sing-box-lx` libbox — **опубликованный артефакт** (jitpack/
  GitHub Packages) или **локальный gomobile-build**? Определяет объём Phase 0.
- **Q2:** AWG2-поля endpoint-level (per README) — подтвердить по Go-исходнику
  fork'а (не per-peer).
- **Q3:** AWG2 в `wireguard://` URI — 16 query-параметров делают ссылку длинной.
  (a) всё в query; (b) опираться на `raw_body` JSON и НЕ кодировать в URI;
  (c) фрагмент. Влияет на `toUriWireguard`.
- **Q4:** новая версия libbox не ломает ABI `OverrideOptions`/MethodChannel?
- **Q5:** типизованный `Awg` vs `extraOptions`-preserve-unknown (forward-proof).
- **Q6:** диапазоны/дефолты полей (для валидации); формат `i1-i5` (валидируем
  DSL `<b 0x..><r N>` или принимаем любую строку — рекомендую любую строку).
- **Q7:** на какой sing-box-версии базируется fork (для совместимости схемы:
  endpoints[] появились в 1.11, текущий пин 1.13.11)?
- **Q8:** UI — JSON-only MVP (2a) ок, или сразу выделенные поля (2b)?

## 7b. Phase 0 — ВЫПОЛНЕНО ✅ (dev-build, 2026-06-09)

Юзер дал `libbox-aar.zip` (= **локальный AAR**, ответ на Q1: НЕ published Maven).
Внутри: `libbox.aar` (modern, minSdk 23, 4 ABI) + `libbox-legacy.aar` (minSdk 21).
Используем **modern** (legacy = fallback для старых устройств — Q7-смежное).

**Факты (из `strings` arm64 `libbox.so`):**
- версия ядра **`1.13.13-lx.1-94c7702c`** (`Libbox.version()` это вернёт);
- build-теги: `with_gvisor,with_quic,with_wireguard,with_utls,with_naive_outbound,with_clash_api,with_xhttp,with_awg`;
- присутствуют `option.AmneziaWGOptions` (AWG2) и `option.V2RayXHTTPOptions`/`v2rayxhttp` (XHTTP).

**Интеграция (DEV-ONLY, НЕ коммитим):**
- AAR → `app/android/app/libs/libbox.aar` (gitignored, 73MB);
- `build.gradle.kts:123` Maven-строка → `implementation(files("libs/libbox.aar"))`
  (закомментирована старая; вернуть для стокового ядра). CI остаётся на Maven.
- Собрано: vc 2726, APK 28.9MB (arm64 `.so` 51MB vs ~55-66 у 1.13.11); **Kotlin
  `VpnPlugin`/`BoxService` скомпилировались без правок** → libbox API совместим
  (Q4 ✅). Установлено + verified.

**Остаётся:** Phase 1 (app-side AWG2-поля parse/emit) — сейчас новое ядро
**работает на обычных конфигах**, но AWG2-поля app-парсер всё ещё дропает.
Для интеграции в CI/release — опубликовать fork-AAR (jitpack/GH Packages) или
git-lfs/CI-fetch (отдельное решение).

## 7c. Phase 1 — ВЫПОЛНЕНО ✅ (2026-06-09, по образцу singbox-launcher SPEC 073)

Сквозной проход AWG-полей в Dart-модели (pure-Dart, мержится независимо от
core-swap; «спит» на стоковом ядре, активна на lx).

- **Модель** (`node_spec.dart`): класс `Awg{fields: Map<String,Object>}` —
  числовые (`numKeys`: jc/jmin/jmax/s1–s4/h1–h4) хранятся как `int`, `i1`–`i5`
  (`strKeys`) как `String` (регистр сохранён). `WireguardSpec.awg` (null = WG).
  `fromQuery`/`fromJson`/`writeInto`/`writeQuery`.
- **Parse:** URI (`wireguard_parser` → `Awg.fromQuery`), JSON
  (`json_parsers` wireguard-case → `Awg.fromJson`), INI (`ini_parser`: AWG-ключи
  из `[Interface]` → query → `Awg.fromQuery`; rebuild для `rawIni` теперь
  копирует `awg`). Алиас **`awg://`** (`uri_parsers` dispatcher → WG-путь).
- **Emit:** `emitWireguard` → `awg.writeInto(map)` (корень endpoint, числа →
  JSON number); `toUriWireguard` → `awg.writeQuery(q)` (round-trip).
- **Forward-compat:** битое число в URI (`jc=abc`) → поле пропущено, парс не
  падает. Обычный WG без AWG → `awg == null` (backward-compatible).
- **UI:** через Raw-JSON в node_settings уже работает (emit/parse несут AWG).
  Выделенная форма (Фаза 5 в 073) — опц. follow-up.
- **Тесты:** `test/parser/awg_test.dart` — 10 кейсов (parse URI/JSON/INI, awg://,
  emit type-fidelity `jc:10` number, round-trip + `jc=0`, регистр `i*`). 853 green.

**Конец-в-конец:** с локальным lx-ядром (Phase 0) AWG-узел теперь
парсится → эмитится → ядро понимает. Для CI/release остаётся опубликовать fork-AAR.

## 8. Phasing-вывод

Минимальный путь к рабочему AWG2: **Phase 0 (0a если артефакт есть) → Phase 1 →
Phase 2a (JSON-only)**. XHTTP (Phase 3) и UI-поля (2b) — follow-up. Без Phase 0
остальное бессмысленно, поэтому **Q1 — первый вопрос к тебе**.
