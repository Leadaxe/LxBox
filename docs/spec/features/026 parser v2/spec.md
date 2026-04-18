# 026 — Parser v2: типизированные NodeSpec и упрощённый pipeline

| Поле | Значение |
|------|----------|
| Статус | Спека |
| Дата | 2026-04-18 |
| Зависимости | [`004`](../004%20subscription%20parser/spec.md), [`005`](../005%20config%20generator/spec.md), [`018`](../018%20detour%20server%20management/spec.md), [`docs/PROTOCOLS.md`](../../../PROTOCOLS.md) |

---

## Оглавление

- [Принципы](#принципы)
- [Контекст](#контекст)
- [§1. Контейнеры узлов — `ServerList`](#1-контейнеры-узлов--serverlist)
- [§2. Модель — `NodeSpec`](#2-модель--nodespec)
- [§3. Pipeline](#3-pipeline)
  - §3.1 Fetch
  - §3.2 Decode
  - §3.3 Parse
  - §3.4 Assemble
  - §3.5 Validate
- [§4. Round-trip](#4-round-trip)
- [§5. Структура файлов](#5-структура-файлов)
- [§6. Миграция](#6-миграция)
- [§7. Тестирование](#7-тестирование)
- [§8. UI impact](#8-ui-impact)
- [§9. Критерии приёмки](#9-критерии-приёмки)
- [§10. Риски](#10-риски)
- [§11. Решения](#11-решения)

---

## Принципы

Зафиксировано до начала имплементации — применяется к self-review каждого PR в рамках 026:

1. **Слои — только по логике.** Каждый слой существует ради конкретной задачи, не "для симметрии". Registry / Pipeline / Chain-of-Responsibility не добавляются, пока не выросла потребность.
2. **Без обёрток и адаптеров.** Заменяем `A` на `B` — `A` удаляется, callers переписываются. Никаких `LegacyAdapter`, `A.fromV2(B)`, мостиков.
3. **Никакого мусора после миграции.** Удаляем физически. `// TODO remove after v2`, `// deprecated`, остаточные ветки по feature-flag'у — вычищаются до нуля в Фазе 4.
4. **YAGNI.** Конкретный список шагов inline, одна реализация. Plugin-системы — только когда появится второй пользователь.
5. **Функции > классы.** Класс заводим, только если есть состояние, которое нужно хранить между вызовами (`ServerRegistry` — да, `BodyDecoder` — нет, `ParserRegistry` — нет).
6. **Sealed + exhaustive switch.** Любое ветвление по типу — sealed class + `switch` без `default`. Компилятор ловит пропуск при добавлении варианта.
7. **Immutability по умолчанию.** `freezed` для data-классов. Mutable — только там, где это структурно нужно (`NodeSpec.warnings`, `ServerList.nodes` при fetch — документируется явно).

---

## Контекст

Текущая реализация (v1):
- `app/lib/services/node_parser.dart` — ~1100 строк, парсинг URI + генерация sing-box JSON в одном файле.
- `app/lib/services/config_builder.dart` — ~550 строк, сборка итогового конфига + применение policies + post-processing.
- `app/lib/models/parsed_node.dart` — mutable bag: `Map<String,String> query` + `Map<String,dynamic> outbound` + `String warning`.
- `app/lib/models/proxy_source.dart` — плоская модель "подписка или вставка", совмещает URL и inline.

Конкретные боли:
- Нет типизации полей узла — только `Map<String,dynamic>`.
- Outbound vs endpoint определяется рантайм-фильтрацией `o['type'] == 'wireguard'` в ассемблере.
- Один warning на узел (`String`) — не типизирован, нельзя агрегировать.
- Парсинг и генерация нельзя тестировать независимо.
- `tagPrefix` есть в модели, но задаётся только из GetFree-пресетов, пользователь не видит.
- XHTTP-fallback сейчас в двух местах (VMess JSON parse + outbound build) — один из них после рефактора `_transportFromQuery` стал единой точкой, но это временно держится на одном helper'е.

Цель v2: типизированные модели, полиморфный emit (узел сам знает, куда — outbound или endpoint), функциональный pipeline без лишних абстракций.

---

## §1. Контейнеры узлов — `ServerList`

Узлы всегда живут внутри контейнера. Два типа контейнеров — от разных источников.

### 1.1 Sealed-иерархия

```dart
sealed class ServerList {
  String get id;                         // uuid, генерируется при создании
  String get name;                       // редактируемое
  bool get enabled;
  String get tagPrefix;                  // auto-generated, editable
  DetourPolicy get detourPolicy;
  List<NodeSpec> get nodes;
}

final class SubscriptionServers extends ServerList {
  final String url;
  final SubscriptionMeta? meta;          // subscription-userinfo, profile-title, expire
  final DateTime? lastUpdated;
  final int updateIntervalHours;         // auto из profile-update-interval
  // nodes — результат последнего fetch+parse, перезаписываются на refresh
}

final class UserServers extends ServerList {
  final UserSource origin;               // paste | file | qr | manual
  final DateTime createdAt;
  // nodes редактируются пользователем, refresh не делается
}
```

**Персистится:** `List<ServerList>` с дискриминатором `type` в JSON. Никакой `ServerRegistry` на диск не попадает.

### 1.2 Семантика

| | `SubscriptionServers` | `UserServers` |
|---|---|---|
| Lifecycle | fetch(url) → parse → nodes | parse(pastedText) → nodes |
| Refresh | ✅ manual + auto-interval | — |
| Редактировать ноду | ❌ (перезапишется) | ✅ |
| Add/remove ноду | ❌ | ✅ |
| Traffic quota | ✅ (из заголовков) | — |

`UserServers` создаётся **на каждую вставку**. Два разных paste'а = два разных `UserServers` (можно переименовать, удалить независимо).

### 1.3 `DetourPolicy`

```dart
class DetourPolicy {
  final bool registerDetourServers;      // default true
  final bool registerDetourInAuto;       // default false (см. 018)
  final bool useDetourServers;           // default true
  final String overrideDetour;           // '' = no override
}
```

`ServerList` хранит **политику**. `NodeSpec` хранит **факт** (`chained: NodeSpec?`). Политика применяется в `buildConfig` inline (см. §3.4), не в отдельном "transform-слое".

### 1.4 `tagPrefix`

Автогенерируется при создании `ServerList` (короткий hash от URL/`createdAt`, ~3 символа). Пустым не бывает. Редактируется в UI. Применяется в `ServerRegistry.allNodes` (см. §1.5) — рекурсивно к `tag` и `chained.tag`.

### 1.5 `ServerRegistry` — transient aggregator

```dart
class ServerRegistry {
  ServerRegistry(List<ServerList> lists);

  /// Плоский список всех узлов всех включённых списков,
  /// с применённым tagPrefix и разрешёнными коллизиями тегов.
  List<NodeSpec> get allNodes;

  NodeSpec? findByTag(String tag);        // линейный поиск O(n), приемлемо до ~10k узлов
}
```

Не сериализуется. Не хранит состояние между вызовами (пересоздаётся каждый раз, когда поменялся `List<ServerList>`). Единственное место, где:
- применяется `tagPrefix`
- разрешаются коллизии (`-1`, `-2` суффиксы)
- раздаются глобальные tag'и для Clash API и UI

**Сложность.** `findByTag` — линейный поиск по `allNodes`. Внутри может лениво строиться `Map<String, NodeSpec>` при первом вызове, если профайлинг покажет горячий путь. До ~10k узлов линейного достаточно.

### 1.6 UI

Один плоский список всех `ServerList` в экране Subscriptions (иконка слева различает тип). Pattern-match при рендере:

```dart
Widget tile(ServerList s) => switch (s) {
  SubscriptionServers() => _SubTile(...),   // 🌐 + update-кнопка
  UserServers()         => _UserTile(...),  // 🔗
};
```

### 1.7 Smart-Paste routing

- URL подписки → `SubscriptionServers`, fetch + parse.
- Одиночный proxy-URI / JSON outbound / JSON-array / WG INI → `UserServers(origin: paste)`.
- QR / File → `UserServers(origin: qr | file)`.

---

## §2. Модель — `NodeSpec`

### 2.1 Sealed-иерархия

```dart
sealed class NodeSpec {
  String get id;                         // uuid узла
  String get tag;                        // может быть перепрефикшен в Registry
  String get label;                      // display name
  String get server;
  int get port;
  String get rawUri;                     // исходный URI, для revert / debug
  NodeSpec? get chained;                 // detour, рекурсивно
  List<NodeWarning> get warnings;        // mutable — растёт при emit (см. 2.4)

  /// Полиморфная генерация sing-box entry.
  /// Реализация может дописать в `warnings` при fallback'ах.
  SingboxEntry emit(TemplateVars vars);

  /// Round-trip в URI. Инвариант: parseUri(spec.toUri()) ≈ spec (см. §4).
  String toUri();
}

final class VlessSpec extends NodeSpec { ... SingboxEntry emit() => Outbound(...); }
final class VmessSpec extends NodeSpec { ... => Outbound(...); }
final class TrojanSpec extends NodeSpec { ... => Outbound(...); }
final class ShadowsocksSpec extends NodeSpec { ... }
final class Hysteria2Spec extends NodeSpec { ... }
final class TuicSpec extends NodeSpec { ... }
final class SshSpec extends NodeSpec { ... }
final class SocksSpec extends NodeSpec { ... }
final class WireguardSpec extends NodeSpec { ... => Endpoint(...); }
```

Полиморфизм `emit()` убирает `if (type == 'wireguard')` в ассемблере.

### 2.2 `SingboxEntry`

```dart
sealed class SingboxEntry {
  Map<String, dynamic> get map;
}
final class Outbound extends SingboxEntry { ... }
final class Endpoint extends SingboxEntry { ... }
```

Ассемблер раскладывает по двум массивам через `switch (entry)`.

### 2.3 `TransportSpec`

```dart
sealed class TransportSpec {
  (Map<String, dynamic> map, List<NodeWarning> warnings) toSingbox(TemplateVars vars);
}

final class WsTransport(...) extends TransportSpec { ... }
final class GrpcTransport(...) extends TransportSpec { ... }
final class HttpTransport(...) extends TransportSpec { ... }      // h2 = HttpTransport
final class HttpUpgradeTransport(...) extends TransportSpec { ... }

final class XhttpTransport extends TransportSpec {
  // sing-box не поддерживает — см. PROTOCOLS.md §XHTTP transport fallback.
  @override toSingbox(vars) {
    final (m, _) = HttpUpgradeTransport(path, host).toSingbox(vars);
    return (m, [const UnsupportedTransportWarning('xhttp', 'httpupgrade')]);
  }
}
```

Компилятор не даст забыть XHTTP-fallback — это вариант sealed-типа.

### 2.4 `NodeWarning`

```dart
sealed class NodeWarning {
  const NodeWarning();
  String get message;                     // пока plain string на английском;
                                          // локализация — отдельным шагом, когда
                                          // появится i18n-infra в проекте
  WarningSeverity get severity;           // info | warning | error
}

final class UnsupportedTransportWarning(String name, String fallback) extends NodeWarning;
final class UnsupportedProtocolWarning(String scheme) extends NodeWarning;
final class MissingFieldWarning(String field) extends NodeWarning;
final class DeprecatedFlowWarning(String flow) extends NodeWarning;
final class InsecureTlsWarning() extends NodeWarning;
```

`NodeSpec.warnings` — mutable `List<NodeWarning>` (единственное mutable поле в freezed-spec). Парсер заполняет при конструировании; `emit` дописывает при fallback'ах. Это компромисс ради простоты: альтернатива — emit возвращает кортеж и ассемблер копирует spec через `copyWith`, что делает call sites неприятными.

Warnings не сериализуются — пересоздаются на каждом `parseUri` / `emit`.

---

## §3. Pipeline

Три функции верхнего уровня:

```dart
/// Fetch + decode + parse. Только для источников с body (URL, File, Clipboard, QR).
Future<ParseResult> parseFromSource(SubscriptionSource source);

/// Собрать sing-box JSON.
BuildResult buildConfig(
  ServerRegistry registry,
  WizardTemplate template,
  BuildSettings settings,
);

/// Round-trip: sing-box outbound/endpoint JSON → NodeSpec.
/// Используется в JSON-editor и для Smart-Paste одиночного singbox-entry.
NodeSpec? parseSingboxEntry(Map<String, dynamic> entry);
```

`ParseResult`, `BuildResult` — простые records/data-классы.

### 3.1 FETCH

```dart
sealed class SubscriptionSource {}
final class UrlSource(String url) extends SubscriptionSource;
final class FileSource(File file) extends SubscriptionSource;
final class ClipboardSource() extends SubscriptionSource;
final class InlineSource(String body) extends SubscriptionSource;
final class QrSource(String content) extends SubscriptionSource;

Future<FetchResult> fetch(SubscriptionSource source);

class FetchResult {
  final String body;
  final SubscriptionMeta? meta;           // только для UrlSource (HTTP заголовки)
}
```

### 3.2 DECODE

Одна функция, не throws. Exhaustive результат:

```dart
DecodedBody decode(String body);

sealed class DecodedBody {}
final class UriLines extends DecodedBody      { List<String> lines; int skippedComments; }
final class IniConfig extends DecodedBody     { String text; }
final class JsonConfig extends DecodedBody    { Object value; JsonFlavor flavor; }
final class DecodeFailure extends DecodedBody { String reason; String? sample; }

enum JsonFlavor { xrayArray, singboxOutbound, clashYaml, unknown }
```

Алгоритм:
1. Попробовать base64 (standard/url-safe × padded/unpadded). Успех + валидный UTF-8 → заменить body, перейти к шагу 2.
2. Trim начинается с `{` или `[`? Попробовать `jsonDecode`. По содержимому присвоить `JsonFlavor`.
3. Первая непустая строка = `[Interface]`? → `IniConfig`.
4. Иначе — разбить на строки, выкинуть пустые и комментарии (`#`, `//`, `;`). Если остались — `UriLines`.
5. Пусто или ничего не сработало → `DecodeFailure`.

### 3.3 PARSE

```dart
List<NodeSpec> parseAll(DecodedBody decoded) {
  return switch (decoded) {
    UriLines(lines: final ls)        => ls.map(parseUri).whereType<NodeSpec>().toList(),
    IniConfig(text: final t)         => [parseWireguardIni(t)].whereType<NodeSpec>().toList(),
    JsonConfig()                     => parseJson(decoded as JsonConfig),
    DecodeFailure()                  => const [],
  };
}

NodeSpec? parseUri(String uri) {
  final scheme = uri.split('://').first.toLowerCase();
  return switch (scheme) {
    'vless'               => parseVless(uri),
    'vmess'               => parseVmess(uri),
    'trojan'              => parseTrojan(uri),
    'ss'                  => parseShadowsocks(uri),
    'hysteria2' || 'hy2'  => parseHysteria2(uri),
    'tuic'                => parseTuic(uri),
    'ssh'                 => parseSsh(uri),
    'socks' || 'socks5'   => parseSocks(uri),
    'wg' || 'wireguard'   => parseWireguardUri(uri),
    _                     => null,
  };
}
```

Каждая `parseXxx` — отдельный файл, pure-функция `String → NodeSpec?`. Ошибки парсинга возвращают `null` (не throw) — caller при необходимости собирает причины.

**`NodeSpec.rawUri`** заполняется парсером из своего входа: для UriLines — сама строка URI; для IniConfig — конвертированный `wg://`-URI (исходный INI хранится в отдельном поле `WireguardSpec.rawIni` при необходимости); для JsonConfig — `jsonEncode` одного element-map (чтобы round-trip через copy/paste JSON работал).

JSON-ветка — `parseJson(JsonConfig j)`:
- `xrayArray` → каждый элемент через `parseXrayOutbound`.
- `singboxOutbound` → один entry через `parseSingboxEntry`.
- `clashYaml` → пока пустой список + `UnsupportedProtocolWarning('clash')`.
- `unknown` → пустой список.

INI → `parseWireguardIni` конвертирует в `wg://`-URI, потом вызывает `parseWireguardUri`.

### 3.4 ASSEMBLE

Одна функция `buildConfig(registry, template, settings) → BuildResult`. Порядок шагов внутри (все inline, без класс-ассемблера):

1. Склонировать `template.config`.
2. Пройти `registry.allNodes`:
   - Применить `DetourPolicy` конкретной ноды: `useDetourServers=false` → `chained = null`; `overrideDetour != ''` → заменить `chained`.
   - Если `chained != null` и ещё не эмитили этот detour-tag — `chained.emit(vars)` → добавить в соответствующий массив.
   - `node.emit(vars)` → разложить по `outbounds`/`endpoints`.
3. Сгенерировать preset-группы (`vpn-1`, `vpn-2`, `vpn-3`, `auto-proxy-out`) — логика из v1 `_buildPresetOutbounds`, но над `List<NodeSpec>` вместо `List<ParsedNode>`. Учёт `registerDetourServers`, `registerDetourInAuto`, `excluded tags` — inline.
4. Применить post-steps по порядку (все — plain-функции над `Map`):
   - `applyTlsFragmentFirstHop(config, settings)`
   - `randomizeClashApi(config)` (каждый раз новый port + secret)
   - `applyDnsFinal(config, settings)`
   - `applyAppRules(config, settings)`
5. `validateConfig(config)` → `ValidationResult`.
6. Вернуть `BuildResult(config, validation)`.

### 3.5 VALIDATE

Функция, не класс.

```dart
ValidationResult validateConfig(Map<String, dynamic> config);

sealed class ValidationIssue {
  Severity get severity;
}
final class DanglingOutboundRef(String rule, String tag) extends ValidationIssue;   // fatal
final class EmptyUrltestGroup(String tag) extends ValidationIssue;                  // fatal
final class InvalidDefault(String group, String tag) extends ValidationIssue;       // fatal
final class UnknownField(String path) extends ValidationIssue;                      // warn
```

Fatal → отказ запускать VPN, показываем в UI. Warn → debug log.

---

## §4. Round-trip

```
         parseUri(uri)
URI ───────────────────▶ NodeSpec ──spec.emit(vars)──▶ SingboxEntry (Map)
 ▲                         │                              │
 │                         │                              │
 └──── spec.toUri() ───────┘        parseSingboxEntry ────┘
```

**Use cases:**
- Copy URI в контекстном меню → `spec.toUri()`.
- View JSON (read-only) → `spec.emit(vars).map` с pretty-print.
- JSON editor: user редактирует map → `parseSingboxEntry(edited)` → новый `NodeSpec` → replace в `ServerList`.
- Revert override: при сбросе `overrideDetour` пересобираем emit из исходного spec.

**Инварианты (обязательны, тестами):**

| Инвариант | Тест |
|-----------|------|
| `parseUri(spec.toUri()) ≈ spec` (сравнение без `rawUri` и `warnings`) | `round_trip_uri_test.dart` |
| `parseSingboxEntry(spec.emit(vars).map) ≈ spec` | `round_trip_singbox_test.dart` |
| property-based: `parseUri(toUri(random(VlessSpec))) ≈ random(VlessSpec)` | `property_round_trip_test.dart` |

**Ограничения:**
- XHTTP после `emit` превращается в httpupgrade. Обратно `parseSingboxEntry` вернёт `HttpUpgradeTransport` — информация о xhttp потеряна. Если нужен оригинал — есть `NodeSpec.rawUri`.
- Legacy VMess (v2rayN base64 JSON) → эмитим в модерный `vmess://`. Обратно не конвертируем.

---

## §5. Структура файлов

```
lib/models/
├── server_list/
│   ├── server_list.dart                 # sealed + DetourPolicy + UserSource
│   ├── subscription_servers.dart
│   ├── user_servers.dart
│   └── subscription_meta.dart           # traffic + expire + title
├── node_spec/
│   ├── node_spec.dart                   # sealed NodeSpec
│   ├── vless_spec.dart
│   ├── vmess_spec.dart
│   ├── trojan_spec.dart
│   ├── shadowsocks_spec.dart
│   ├── hysteria2_spec.dart
│   ├── tuic_spec.dart
│   ├── ssh_spec.dart
│   ├── socks_spec.dart
│   └── wireguard_spec.dart
├── transport_spec.dart                  # sealed + toSingbox
├── tls_spec.dart                        # TlsSpec + RealitySpec
├── singbox_entry.dart                   # sealed Outbound | Endpoint
├── node_warning.dart                    # sealed NodeWarning
└── validation.dart                      # sealed ValidationIssue + Result

lib/services/
├── server_registry.dart                 # transient aggregator (§1.5)
├── subscription/
│   ├── sources.dart                     # sealed SubscriptionSource + fetch()
│   └── http_fetcher.dart                # HTTP GET + headers
├── parser/
│   ├── body_decoder.dart                # §3.2 function
│   ├── parse_all.dart                   # §3.3 top switch
│   ├── uri/
│   │   ├── vless.dart
│   │   ├── vmess.dart
│   │   ├── trojan.dart
│   │   ├── shadowsocks.dart
│   │   ├── hysteria2.dart
│   │   ├── tuic.dart
│   │   ├── ssh.dart
│   │   ├── socks.dart
│   │   └── wireguard.dart
│   ├── json/
│   │   ├── xray_outbound.dart           # один элемент Xray JSON
│   │   └── singbox_entry.dart           # parseSingboxEntry
│   ├── ini/
│   │   └── wireguard_ini.dart           # INI → wg:// → parseWireguardUri
│   └── transport.dart                   # Map → TransportSpec
├── assembler/
│   ├── build_config.dart                # §3.4 top function
│   ├── preset_groups.dart               # vpn-*/auto-proxy-out logic
│   ├── tls_fragment.dart                # post-step
│   ├── clash_api_randomizer.dart        # post-step
│   ├── dns_final.dart                   # post-step
│   └── app_rules.dart                   # post-step
└── validator.dart                       # §3.5 function
```

~10 файлов моделей, ~25 сервисных — каждый ≤150 строк. Никаких "registry/pipeline/context" классов.

---

## §6. Миграция

Strategy: **переписываем в отдельных файлах, переключаем один раз, старое удаляем.** Без feature-flag'а в релизе — v2 попадает либо работающим, либо не попадает (test coverage должен это гарантировать). Feature-flag используется только локально во время разработки для A/B сравнения.

### Фаза 0 — подготовка
- Собрать корпус тестовых URI / подписок в `test/fixtures/<protocol>/` (VLESS, VMess, Trojan, SS, Hysteria2, TUIC, SSH, SOCKS, WireGuard URI + INI, Xray JSON array, sing-box single outbound). Минимум 5 кейсов на протокол, включая edge-case'ы. Анонимизированные реальные подписки — в `test/fixtures/subscriptions/`.
- Добавить `sing-box` CLI в CI (GitHub Actions step) как toolchain-зависимость для §7.4. Если выполнимо — опциональный шаг; фичу `config check` нельзя запустить без бинарника.
- Настроить `build_runner` в CI: кеш `.dart_tool/build` между билдами.

### Фаза 1 — модели
- Ввести `NodeSpec`, `TransportSpec`, `TlsSpec`, `NodeWarning`, `SingboxEntry`, `ServerList`, `ServerRegistry`.
- Freezed + build_runner в CI.
- Тесты моделей: equality, copyWith, JSON serialisation.
- v1 не трогаем.

### Фаза 2 — парсеры + decoder
- Перенести логику из `node_parser.dart` в `lib/services/parser/uri/*.dart`.
- `body_decoder.dart`, `parse_all.dart`.
- **Новый протокол — TUIC v5.** В v1 отсутствует, добавляется с нуля: `parseTuic` + `TuicSpec` + `emit`. Корпус тест-URI для golden-fixtures.
- Parity-тесты: `v1.parse(uri).toJson == v2.parse(uri).emit().map` на корпусе URI из `test/fixtures/`. TUIC тестируется только в v2 (в v1 парсинга нет).
- v1 всё ещё активен для продакшна.

### Фаза 3 — assembler + validator
- `build_config.dart` + post-steps.
- Parity-тесты: v1 и v2 собирают конфиг из одних и тех же источников, `jsonDiff == {}`.
- Переключить `HomeController` / `SubscriptionController` на v2. v1 ещё в файлах, но не вызывается.

### Фаза 4 — удаление v1
- Физически удалить: `node_parser.dart`, `config_builder.dart`, `proxy_source.dart`, `models/parsed_node.dart`, `source_loader.dart`.
- `grep -rn "ParsedNode\|ProxySource\|_buildVMess\|_buildVLESS\|_transportFromQuery"` возвращает пусто.
- Никаких "deprecated" комментариев в остаточном коде.


---

## §7. Тестирование

### 7.1 Юнит
Каждый парсер + каждый `NodeSpec.emit` — свой тест. Корпус валидных и edge-case URI. Для каждого — золотой файл `test/fixtures/<protocol>/<case>.uri` + `<case>.expected.json`.

### 7.2 Round-trip
- `parseUri(spec.toUri()) ≈ spec`
- `parseSingboxEntry(spec.emit().map) ≈ spec`
- property-based на сгенерированных `NodeSpec`.

### 7.3 Parity v1↔v2
`test/parity/` — реальные подписки (анонимизированные), для каждой:
```dart
final v1 = oldBuild(parseV1(body));
final v2 = buildConfig(ServerRegistry([...]), template, settings);
expect(jsonDiff(v1, v2.singboxConfig), isEmpty);
```

### 7.4 Интеграция
End-to-end: source → parseFromSource → ServerRegistry → buildConfig → `sing-box check -c config.json` (CLI).

Требует установленного `sing-box` бинарника в CI — toolchain-шаг настраивается в Фазе 0. Локально — опционально (если бинарник не найден, шаг пропускается с warning).

---

## §8. UI impact

| Экран | Что меняется |
|-------|---------------|
| `SubscriptionsScreen` | читает `List<ServerList>`, рендерит через pattern-match (§1.6). Новая кнопка "Add servers" (UserServers). |
| `SubscriptionDetailScreen` | поля `SubscriptionServers.meta` (quota, expire). Warning-баннер типизирован (по классу `NodeWarning` иконка+цвет). |
| `NodeSettingsScreen` | работает через `spec.emit().map` ↔ `parseSingboxEntry(edited)`. Legacy `ParsedNode.outbound` не используется. |
| `HomeScreen` | node-list из Clash API — без изменений; при копировании/View JSON берёт `ServerRegistry.findByTag`. |
| `NodeFilterScreen` | без изменений (работает с тегами-строками). |
| `RoutingScreen` | без изменений. |

Warning-сообщения — `NodeWarning.message` plain-строкой. Локализация добавится отдельным рефактором, когда в проекте появится i18n-инфраструктура (пока её нет — все строки UI hardcoded en).

---

## §9. Критерии приёмки

- [ ] Sealed: `NodeSpec`, `TransportSpec`, `TlsSpec`, `NodeWarning`, `SingboxEntry`, `ServerList`, `SubscriptionSource`, `DecodedBody`, `ValidationIssue`.
- [ ] `WireguardSpec.emit() => Endpoint`, все остальные → `Outbound`. Никакой проверки `type == 'wireguard'` в ассемблере.
- [ ] `parseFromSource(UrlSource('https://...'))` → `ParseResult` с `nodes` и `meta`.
- [ ] `buildConfig(registry, template, settings)` возвращает `Map<String, dynamic>` + `ValidationResult`.
- [ ] Parity-тесты `v1 ↔ v2` на корпусе фикстур — `jsonDiff == {}`.
- [ ] Round-trip тесты для каждого типа `NodeSpec` (URI + singbox).
- [ ] XHTTP fallback живёт в `XhttpTransport.toSingbox` единственный раз; компилятор не даёт забыть за счёт sealed.
- [ ] После Фазы 4: `grep -rn "ParsedNode\|ProxySource"` → пусто.
- [ ] Новый протокол добавляется тремя шагами: новый `XxxSpec` + `parseXxx(uri)` + ветка в `parseUri` switch.
- [ ] TUIC v5 — реализован в рамках этой работы (`TuicSpec`, `parseTuic`, `emit → Outbound`). URI: `tuic://UUID:PASSWORD@host:port?congestion_control=...&udp_relay_mode=...&alpn=...&sni=...#label`. sing-box: [outbound docs](https://sing-box.sagernet.org/configuration/outbound/tuic/).

---

## §10. Риски

| Риск | Смягчение |
|------|-----------|
| Codegen build-step замедляет CI | Кешируем `.dart_tool/build` между билдами |
| Parity-тесты ловят расхождение на редком URI-формате | Фикстуры обновляются из реальных подписок, отдельный PR с багфиксом до Фазы 3 |
| ANR на больших подписках (1000+ нод) | Опционально — `compute()` Isolate для `parseAll`, не в scope v2 |
| Миграция `ProxySource` → `List<ServerList>` ломает существующие настройки пользователя | Одноразовая миграция в `SettingsStorage.load`: `ProxySource` → `SubscriptionServers` / `UserServers` (по наличию URL). Тест. |
| XHTTP в будущем поддержат в sing-box | `XhttpTransport.toSingbox` переделываем на прямой emit, `UnsupportedTransportWarning` убираем. Один коммит. |
| Нет фикстур / недостаточное покрытие перед фазой 2 | Блокирует parity-тесты v1↔v2. Собрать корпус в Фазе 0, это гейт на старт Фазы 2 |
| Нет `sing-box` бинарника в CI | Интеграционный тест §7.4 отключается. В Фазе 0 добавить install-step; при сбое — warn, не fail. Основное покрытие — юнит + parity |
| Нет i18n-инфраструктуры для warning'ов | `NodeWarning.message` — plain en-string в v2. Локализация — отдельным рефактором |

---

## §11. Решения

| # | Вопрос | Решение | Когда |
|---|--------|---------|-------|
| 1 | Freezed vs ручной sealed | freezed — экономит ~80 строк/класс на copyWith/==/hashCode/toJson | 2026-04-18 |
| 2 | Где живут detour-флаги | на `ServerList`, не на `NodeSpec`. Политика применяется inline в `buildConfig` | 2026-04-18 |
| 3 | Backward-compat для `ParsedNode` в `NodeSettingsScreen` | переписать сразу на `NodeSpec + parseSingboxEntry`, адаптер не делаем | 2026-04-18 |
| 4 | Один `UserServers` или список | `List<UserServers>`, один на каждую вставку/файл/QR | 2026-04-18 |
| 5 | `tagPrefix` default | автогенерируется при создании `ServerList`, редактируется в UI | 2026-04-18 |
| 6 | Pipelines / registries / transform-chain | не нужны. Функции + switch. Inline-шаги в `buildConfig` | 2026-04-18 |
| 7 | `ServerRegistry` | transient runtime-аггрегатор, не персистится | 2026-04-18 |
| 8 | `EmitContext` с begin/end | убран. Warnings в `NodeSpec.warnings` напрямую | 2026-04-18 |
| 9 | `warnings` mutable на freezed-классе | компромисс принят. Единственное mutable поле в spec'е, пересоздаётся на каждый parse/emit | 2026-04-18 |
| 10 | Feature-flag в релизе | нет. Релиз с v2 — релиз с v2. Flag только локально для dev-сравнения | 2026-04-18 |
| 11 | TUIC v5 | включаем в scope v2 (в Фазу 2). Новый протокол, в v1 отсутствует | 2026-04-18 |

---

## See also

- [`004 subscription parser`](../004%20subscription%20parser/spec.md) — legacy, заменяется этим
- [`005 config generator`](../005%20config%20generator/spec.md) — заменяется §3.4
- [`018 detour server management`](../018%20detour%20server%20management/spec.md) — `DetourPolicy` остаётся, применение inline
- [`020 security and dpi bypass`](../020%20security%20and%20dpi%20bypass/spec.md) — `tls_fragment.dart` в §5
- [`docs/PROTOCOLS.md`](../../../PROTOCOLS.md) — per-protocol URI + XHTTP fallback note
- [`docs/private/research/hiddify-comparison/REPORT.md`](../../../private/research/hiddify-comparison/REPORT.md) — референс типизации через freezed
