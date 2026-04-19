# 026 — Parser v2: типизированные NodeSpec и трёхслойный pipeline

| Поле | Значение |
|------|----------|
| Статус | **Реализовано и в продакшене** (2026-04-18) |
| Дата | 2026-04-18 |
| Зависимости | [`docs/PROTOCOLS.md`](../../../PROTOCOLS.md), [`004`](../004%20subscription%20parser/spec.md) (заменено), [`005`](../005%20config%20generator/spec.md) (заменено), [`018`](../018%20detour%20server%20management/spec.md), [`020`](../020%20security%20and%20dpi%20bypass/spec.md) |

## Прогресс

| Фаза | Статус |
|------|--------|
| 0 — fixtures + pubspec + docs deprecation | ✅ |
| 1 — модели (sealed NodeSpec/ServerList/Transport/TLS/Warning/…) | ✅ |
| 2 — парсеры, body_decoder, emit/toUri, TUIC v5, round-trip | ✅ |
| 3 — builder (`ServerList.build` + `buildConfig`), validator, миграция, controller | ✅ |
| 4 — физическое удаление v1 (node_parser, config_builder, source_loader, xray_json_parser, subscription_fetcher/decoder, parsed_node, proxy_source) | ✅ |
| 5 — post-refactor рефактор до 3-слойной архитектуры (EmitContext/NodeEntries, удаление ServerRegistry) | ✅ |

**Тесты:** 106/106. Debug + release APK собираются (release ≈ 71 MB).
**LOC:** `lib/` = 13843; `models/` 2115; `services/` 3579. v1 удалено ≈ 2700 LOC.

---

## Принципы (зафиксированы при старте, все соблюдены)

1. **Слои только по логике.** Каждый слой — ради конкретной задачи, не «для симметрии». Registry / Chain-of-Responsibility не добавляются, пока нет второго пользователя.
2. **Без обёрток и адаптеров.** Заменяем `A` на `B` — `A` удаляется, callers переписываются.
3. **Никакого мусора после миграции.** Удаляем физически. `// TODO remove`, `// deprecated`, feature-flag ветки — вычищены до нуля.
4. **YAGNI.** Inline-шаги, одна реализация.
5. **Функции > классы.** Класс — только при необходимости состояния.
6. **Sealed + exhaustive switch.** Любое ветвление по типу — sealed + `switch` без `default`.
7. **Immutability по умолчанию.** Mutable — только где структурно необходимо (`NodeSpec.warnings`, `ServerList.nodes` при refresh).

---

## Архитектура — 3 слоя

```
UI / Controller
        │  SubscriptionEntry.list (ServerList), SubscriptionController.generateConfig()
        ▼
buildConfig(lists, settings, {template?})         — оркестратор
        │  создаёт _BuildCtx : EmitContext,
        │  загружает template (TemplateLoader), мержит vars, randomize clash_api,
        │  для каждого list → list.build(ctx),
        │  post-steps (selectableRules, appRules, tlsFragment, customDns),
        │  validateConfig, BuildResult.
        ▼
ServerList.build(ctx)                              — политика подписки
        │  skipDetour = !useDetourServers || overrideDetour != '',
        │  for server in nodes:
        │    raw = server.getEntries(ctx, skipDetour),
        │    allocateTag с tagPrefix (сначала detours, потом main),
        │    patch map['detour'] (override / remove / chain),
        │    ctx.addEntry(each), addToSelectorTagList(main + policy detours),
        │    addToAutoList(main + policy detours).
        ▼
NodeSpec.getEntries(ctx, skipDetour)               — чистая трансформация
        │  emit(ctx.vars) → SingboxEntry,
        │  если chained != null и !skipDetour — recurse,
        │  возвращает NodeEntries{main, detours[]}.
```

**Ключевые контракты:**
- `NodeSpec` не знает про `ServerList`, `tagPrefix`, детур-политику. `list` back-ref отсутствует.
- `EmitContext` — абстракция, реализуемая `_BuildCtx` в `buildConfig`. Единственное место, где живёт `taken`-set для уникализации тегов. `_taken` преднаполнен `{'direct-out', 'dns-out', 'block-out'}` — сервисные теги шаблона никогда не конфликтнут с пользовательскими.
- `SingboxEntry.tag` — живой getter из `map['tag']`. Регистрируем **entry** в ctx, а не строку: post-step может переименовать тэг, preset-группы подхватят.
- Формат prefixed-тега — `"<tagPrefix> <tag>"` (через пробел), т.е. `"BL: 🇩🇪 Germany"`. Коллизии → суффиксы `-1`, `-2`, … (`BL: Frankfurt`, `BL: Frankfurt-1`). Fixed в `server_list_build.dart::_withPrefix`.

---

## §1. `ServerList` (контейнер подписки)

Код: `lib/models/server_list.dart`.

```dart
sealed class ServerList {
  final String id;                 // uuid, стабилен на всём жизненном цикле
  final String name;               // редактируемое
  final bool enabled;
  final String tagPrefix;          // пользовательская строка (по умолчанию '')
  final DetourPolicy detourPolicy;
  final List<NodeSpec> nodes;      // mutable-bag: перезаписывается на refresh/reparse

  String get type;                 // 'subscription' | 'user' — JSON-дискриминатор
  Map<String, dynamic> toJson();
  static ServerList fromJson(Map<String, dynamic> j);
}

final class SubscriptionServers extends ServerList {
  final String url;
  final SubscriptionMeta? meta;    // profile-title, traffic, expire, support-url, web-page
  final DateTime? lastUpdated;
  final int updateIntervalHours;
  final int lastNodeCount;
  // copyWith(...) — для refresh, rename, policy-change
}

final class UserServers extends ServerList {
  final UserSource origin;         // paste | file | qr | manual
  final DateTime createdAt;
  final String rawBody;            // оригинал (для reparse)
}

class DetourPolicy {
  final bool registerDetourServers = false;   // ⚙ в proxy-группах — по умолчанию off (user feedback)
  final bool registerDetourInAuto  = false;   // ⚙ в auto-proxy-out (urltest)
  final bool useDetourServers      = true;
  final String overrideDetour      = '';       // '' = no override
}
```

**Персистится на диск** через `SettingsStorage` (ключ `server_lists` в `lxbox_settings.json`). `nodes` не сохраняется в JSON — восстанавливается из `HttpCache` (тело подписки) при запуске app (`_rehydrateFromCache`).

---

## §2. `NodeSpec` (сервер, не нода)

Код: `lib/models/node_spec.dart` + `node_spec_emit.dart` + `node_entries.dart`.

Именование: в UI/подписке «сервер» = `NodeSpec`; в sing-box «нода» = `SingboxEntry` (outbound/endpoint). Один `NodeSpec` → 1–2 `SingboxEntry`.

```dart
sealed class NodeSpec {
  final String id, tag, label, server, rawUri;
  final int port;
  final NodeSpec? chained;                 // опциональный детур-сервер
  final List<NodeWarning> warnings;        // mutable-bag

  SingboxEntry emit(TemplateVars vars);    // чистая функция spec → map
  String toUri();                          // canonical URI, round-trip
  String get protocol;
  NodeEntries getEntries(EmitContext? ctx, {bool skipDetour = false});
}

// 9 вариантов — каждый со своим emit/toUri:
final class VlessSpec        extends NodeSpec { String uuid, flow, encryption, packetEncoding; TlsSpec tls; TransportSpec? transport; }
final class VmessSpec        extends NodeSpec { String uuid, security, packetEncoding; int alterId; TlsSpec tls; TransportSpec? transport; }
final class TrojanSpec       extends NodeSpec { String password; TlsSpec tls; TransportSpec? transport; }
final class ShadowsocksSpec  extends NodeSpec { String method, password, plugin, pluginOpts; }
final class Hysteria2Spec    extends NodeSpec { String password, obfs, obfsPassword; TlsSpec tls; int? upMbps, downMbps; }
final class TuicSpec         extends NodeSpec { String uuid, password, congestionControl, udpRelayMode; bool zeroRtt; TlsSpec tls; }
final class SshSpec          extends NodeSpec { String user, password, privateKey, privateKeyPassphrase; List<String> hostKey, hostKeyAlgorithms; }
final class SocksSpec        extends NodeSpec { String version, username, password; }
final class WireguardSpec    extends NodeSpec { String privateKey; List<String> localAddresses; List<WireguardPeer> peers; int? mtu; String? rawIni; }
```

**`SingboxEntry`** — sealed `Outbound | Endpoint`. `WireguardSpec.emit()` возвращает `Endpoint`, остальные — `Outbound`. Builder раскладывает через sealed-switch, без runtime-проверки `type == 'wireguard'`.

### 2.1 `NodeEntries` — результат `getEntries`

```dart
class NodeEntries {
  final SingboxEntry main;
  final List<SingboxEntry> detours;
  Iterable<SingboxEntry> get all sync* { yield main; yield* detours; }
}
```

Именованная структура (не позиционный `List`): защита от опечаток «[0] главный».

### 2.2 `TransportSpec` (sealed, `transport_spec.dart`)

`Ws | Grpc | Http | HttpUpgrade | Xhttp`. Каждый variant сам знает `toSingbox(vars)`. `Xhttp` в `toSingbox` делегирует `HttpUpgrade` и возвращает `UnsupportedTransportWarning('xhttp', 'httpupgrade')` — компилятор не даёт забыть fallback.

### 2.3 `NodeWarning` (sealed, `node_warning.dart`)

`UnsupportedTransportWarning | UnsupportedProtocolWarning | MissingFieldWarning | DeprecatedFlowWarning | InsecureTlsWarning`.
`warnings` — единственное mutable поле на spec'е. Парсер заполняет при конструировании; `emit` дописывает при fallback'ах. UI рендерит по `severity` (info/warning/error).

### 2.4 `EmitContext` (абстракт, `emit_context.dart`)

```dart
abstract class EmitContext {
  TemplateVars get vars;
  String allocateTag(String baseTag);
  void addEntry(SingboxEntry entry);
  void addToSelectorTagList(SingboxEntry entry);  // → vpn-1/2/3
  void addToAutoList(SingboxEntry entry);          // → auto-proxy-out (urltest)
}
```

Реализация — `_BuildCtx` в `build_config.dart`.

---

## §3. Pipeline

Верхнеуровневые функции:

```dart
// fetch + decode + parse. В т.ч. извлекает inline pseudo-headers (# profile-title:)
// и мержит с HTTP-заголовками.
Future<ParseResult> parseFromSource(SubscriptionSource source, {http.Client? client});

// Прямой HTTP GET без декода — для UI Source-вкладки.
Future<FetchResult> fetchRaw(SubscriptionSource source, {http.Client? client});

// Единственная точка сборки sing-box конфига.
Future<BuildResult> buildConfig({
  required List<ServerList> lists,
  BuildSettings settings = const BuildSettings(),
  WizardTemplate? template,   // override для тестов; прод → TemplateLoader.load()
});

// sing-box outbound/endpoint Map → NodeSpec (для round-trip / JSON editor).
NodeSpec? parseSingboxEntry(Map<String, dynamic> entry);
```

### §3.1 Fetch

Код: `lib/services/subscription/sources.dart`.

```dart
sealed class SubscriptionSource { }
final class UrlSource        (String url, {userAgent, timeout}) extends SubscriptionSource;
final class FileSource       (File file)                         extends SubscriptionSource;
final class ClipboardSource  (String contents)                   extends SubscriptionSource;
final class InlineSource     (String body)                       extends SubscriptionSource;
final class QrSource         (String content)                    extends SubscriptionSource;
```

`UrlSource` — default UA `SubscriptionParserClient` (некоторые сервера выбирают формат тела по UA; `ClashForAndroid/*` триггерит YAML, `SubscriptionParserClient` — URI-list). Default timeout 9с; `_fetch` делает **2 попытки с паузой 2с** между (cap ≈ 20с). Ретрай — против transient'ов мобильной сети (DNS/RST/DDoS-guard challenge).

`FetchResult.headers` — сырые HTTP response headers. `profile-title: base64:...` автоматически декодируется в `_decodeBase64Title`.

**Fallback-цепочка имени подписки**: `profile-title` → `content-disposition` → `list.name` (уже установленное).
Если провайдер не ставит кастомный `profile-title`, но отдаёт стандартный RFC 6266 `Content-Disposition: attachment; filename="..."` (Marzban / 3x-ui / XrayR делают это автоматически), `_parseContentDispositionFilename` извлекает имя. Поддерживаются `filename="…"`, `filename=…` без кавычек, и RFC 5987 `filename*=UTF-8''<percent-encoded>` для юникода. Расширения `.txt/.yaml/.yml/.json/.conf` срезаются.

**Inline pseudo-headers**: `parseFromSource` сканирует первые `# key: value` / `// key: value` / `; key: value` строки тела. Принимает только «подписочные» ключи (`profile-title`, `profile-update-interval`, `profile-web-page-url`, `support-url`, `subscription-userinfo`, `content-disposition`). HTTP-headers первичны; inline как fallback.

### §3.2 Decode

Код: `lib/services/parser/body_decoder.dart`.

```dart
sealed class DecodedBody { }
final class UriLines      (List<String> lines, int skippedComments) extends DecodedBody;
final class IniConfig     (String text)                             extends DecodedBody;
final class JsonConfig    (Object value, JsonFlavor flavor)         extends DecodedBody;
final class DecodeFailure (String reason, String? sample)           extends DecodedBody;

enum JsonFlavor { xrayArray, singboxOutbound, clashYaml, unknown }
```

Алгоритм:
1. Если body похож на base64 — раскодировать (4 варианта: standard/url-safe × padded/unpadded). Успех + валидный UTF-8 → заменить body.
2. `trim` начинается с `{`/`[` → `jsonDecode` + `JsonFlavor`.
3. Первая непустая не-comment строка `[Interface]` + есть `[Peer]` → `IniConfig`.
4. Иначе — строки: `#`/`//`/`;` считаются комментариями; остаток → `UriLines`.
5. Пусто → `DecodeFailure`.

`clashYaml` **в текущей реализации не парсится** — возвращает пустой список узлов. Обходится на уровне UA (см. §3.1).

### §3.3 Parse

Код: `lib/services/parser/{uri_parsers,json_parsers,ini_parser,parse_all,transport,uri_utils}.dart`.

Топ-switch по схеме:
```dart
NodeSpec? parseUri(String uri) => switch (scheme) {
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
```

`parseAll(DecodedBody)` диспатчит по типу: `UriLines → parseUri` per-line; `IniConfig → parseWireguardIni`; `JsonConfig` → `xrayArray` через `parseXrayOutbound` / `singboxOutbound` через `parseSingboxEntry`.

Парсеры — pure, ошибки возвращают `null` (не throw). SIP003 plugin split (`plugin=name;k=v;…`) — в `parseShadowsocks`.

### §3.4 Assemble

Код: `lib/services/builder/{build_config,post_steps,validator}.dart` + `services/template_loader.dart`.

Шаги внутри `buildConfig`:

1. `template ??= await TemplateLoader.load()`.
2. Merge `template.vars` (defaults) + `settings.userVars` → `vars`. Рандомизация `clash_api` (порт 49152-65535) и `clash_secret` (32 hex), если defaults (:9090 / пустой). Сгенерированное записывается в `result.generatedVars` — controller персистит назад в `SettingsStorage`.
3. Deep-copy `template.config`, `_substituteVars` на `@var`-ссылки.
4. Убрать `sniff`-rule если `sniff_enabled=false`.
5. Создать `_BuildCtx(tvars)` — реализация `EmitContext`.
6. `for list in lists: list.build(ctx)` — подписка сама применяет политику и регистрирует entries.
7. `_buildPresetGroups(presets, enabledGroups, selectorTags, autoTags, excludedNodes, vars)` — vpn-1/2/3 (selector) + auto-proxy-out (urltest). Теги берутся из `ctx.selectorEntries` / `ctx.autoEntries`.
8. Склеить `config['outbounds']` = `baseOutbounds` + `ctx.outbounds` + preset-группы. `config['endpoints']` = `baseEndpoints` + `ctx.endpoints`.
9. Post-steps: `applySelectableRules` → `applyAppRules` → `route.final` override → `applyTlsFragment` → `applyCustomDns`.
10. `validateConfig(config)` → `ValidationResult`.
11. Вернуть `BuildResult { configJson, config, validation, emitWarnings, generatedVars }`.

#### §3.4.1 Инвариант TLS Fragment

`tls.fragment` / `tls.record_fragment` ставится **только на outbound'ы без поля `detour`** — т.е. на first-hop с устройства.

**Почему.** TLS fragment — клиентский приём обхода локального DPI: режет ClientHello на мелкие TLS-records, чтобы SNI-шаблон не собрался ровно. DPI видит **только первый** TLS-handshake с устройства. Если у узла есть `detour`, он — inner hop; его TLS уходит внутри туннеля первого хопа, DPI его не видит.

Нарушение инварианта:
- **Бесполезность** — inner handshake не видит никто.
- **Разрыв цепочки** — REALITY / kcp чувствительны к формату TLS-records.
- **Двойная фрагментация** — inner handshake попадает в уже-фрагментированные TCP-пакеты первого хопа; повторная фрагментация → хаос MTU.

Реализация — `post_steps.dart::applyTlsFragment`:
```dart
for (final ob in outbounds) {
  if (ob.containsKey('detour')) continue;  // inner hop — skip
  final tls = ob['tls'];
  if (tls is! Map || tls['enabled'] != true) continue;
  if (fragment) tls['fragment'] = true;
  if (recordFragment) tls['record_fragment'] = true;
  tls['fragment_fallback_delay'] = fallbackDelay;
}
```

#### §3.4.2 HTTP-кэш + offline rehydrate

Код: `lib/services/subscription/http_cache.dart`.

- `HttpCache.save(url, body, headers)` — на каждом успешном fetch пишет сырое body и headers в `app_support/sub_cache/<url-hash>`.
- `SubscriptionController._rehydrateFromCache` на `init` проходит по `SubscriptionServers` с пустыми `nodes`, читает body, `decode → parseAll`, заливает в `list.nodes`. Статус помечает `(cached)`.
- **Почему body, а не parsed-JSON**: одна истина (parsed — derived view); фиксы парсера автоматически долетают до старых подписок; Source-вкладка и так нужна body; re-parse 150 узлов ≤50ms.

### §3.5 Validate

Код: `lib/services/builder/validator.dart`.

```dart
ValidationResult validateConfig(Map<String, dynamic> config);

sealed class ValidationIssue {
  Severity get severity;    // fatal | warn
  String get message;
}
final class DanglingOutboundRef (String rule, String tag) extends ValidationIssue; // fatal
final class EmptyUrltestGroup   (String tag)              extends ValidationIssue; // fatal
final class InvalidDefault      (String group, String tag) extends ValidationIssue; // fatal
final class UnknownField        (String path)             extends ValidationIssue; // warn
```

Fatal → controller отказывается запускать VPN (в текущем UI только логируется в AppLog).

---

## §4. Round-trip

```
URI ─parseUri─▶ NodeSpec ─emit(vars)─▶ SingboxEntry(Map)
 ▲                                        │
 └─── spec.toUri() ──────── parseSingboxEntry(map) ──┘
```

Инварианты (тесты `test/parser/round_trip_test.dart`):
- `parseUri(spec.toUri()) ≈ spec` — сравнение без `id`, `rawUri`, `warnings`.
- `parseSingboxEntry(spec.emit(vars).map) ≈ spec`.

**Ограничения:**
- XHTTP после `emit` → `httpupgrade`. Обратный `parseSingboxEntry` вернёт `HttpUpgradeTransport` — инфа о `xhttp` потеряна (есть `spec.rawUri`).
- Legacy VMess (v2rayN base64 JSON) → эмитим в модерный `vmess://`. Обратно не конвертируем.

---

## §5. Раскладка файлов (фактическая)

```
lib/
├── controllers/
│   ├── subscription_controller.dart      # SubscriptionEntry façade + _rehydrate + generate
│   └── home_controller.dart
├── models/
│   ├── server_list.dart                   # sealed ServerList + DetourPolicy + UserSource
│   ├── subscription_meta.dart
│   ├── node_spec.dart                     # sealed NodeSpec + 9 variants (+ NodeEntries deps)
│   ├── node_spec_emit.dart                # emit/toUri реализации per protocol
│   ├── node_entries.dart                  # {main, detours[]}
│   ├── emit_context.dart                  # abstract EmitContext
│   ├── singbox_entry.dart                 # sealed Outbound | Endpoint + .tag getter
│   ├── transport_spec.dart                # sealed 5 variants + toSingbox
│   ├── tls_spec.dart                      # TlsSpec + RealitySpec
│   ├── node_warning.dart                  # sealed 5 variants
│   ├── validation.dart                    # sealed ValidationIssue + ValidationResult
│   ├── template_vars.dart
│   ├── debug_entry.dart                   # AppLog DTO
│   └── (home_state.dart, tunnel_status.dart, parser_config.dart — existing)
├── services/
│   ├── app_log.dart                       # глобальный логгер (debug/info/warning/error)
│   ├── dump_builder.dart                  # config + log + subs + vars → JSON
│   ├── download_saver.dart                # /sdcard/Download/lxbox-dump/*
│   ├── template_loader.dart
│   ├── settings_storage.dart              # server_lists, vars, dns, rules, …
│   ├── parser/
│   │   ├── uri_parsers.dart               # 9 parse{Vless,…}(String) → NodeSpec?
│   │   ├── json_parsers.dart              # parseXrayOutbound + parseSingboxEntry
│   │   ├── ini_parser.dart                # WG INI → wg:// → parseWireguardUri
│   │   ├── body_decoder.dart              # base64/JSON/INI/URI-lines
│   │   ├── parse_all.dart                 # DecodedBody → List<NodeSpec>
│   │   ├── transport.dart                 # query → TransportSpec
│   │   └── uri_utils.dart
│   ├── subscription/
│   │   ├── sources.dart                   # SubscriptionSource + parseFromSource + fetchRaw
│   │   ├── input_helpers.dart             # isSubscriptionUrl / isWireGuardConfig / isDirectLink
│   │   └── http_cache.dart                # body + headers кэш на диске
│   ├── get_free_loader.dart               # (existing) «Get Free VPN» presets из assets/get_free.json
│   ├── rule_set_downloader.dart           # (existing) .srs rule-sets кэш для селектабельных правил
│   ├── clash_api_client.dart              # (existing) REST-клиент Clash API (connections/proxies/delay)
│   ├── url_launcher.dart                  # (existing) утилитка на `url_launcher`
│   ├── builder/
│   │   ├── build_config.dart              # buildConfig + _BuildCtx + _buildPresetGroups
│   │   ├── server_list_build.dart         # extension ServerList.build(ctx)
│   │   ├── post_steps.dart                # applySelectableRules/AppRules/TlsFragment/CustomDns
│   │   └── validator.dart
│   └── migration/
│       └── proxy_source_migration.dart    # proxy_sources → server_lists (v1 → v2)
└── screens/ (UI, адаптированы под SubscriptionEntry)
```

---

## §6. Миграция (выполнено)

Стратегия: переписали в новых файлах, переключили один раз, v1 удалили. Без feature-flag в релизе.

- **Фаза 0** — собраны фикстуры (`app/test/fixtures/`, 37 файлов), обновлён `pubspec.yaml`, добавлен TUIC раздел в `docs/PROTOCOLS.md`, deprecation-баннеры на 004/005/018.
- **Фаза 1** — модели sealed, тесты equality/JSON round-trip.
- **Фаза 2** — парсеры всех 9 протоколов (включая новый TUIC v5), `body_decoder`, `emit`/`toUri`, round-trip, parity v1↔v2.
- **Фаза 3** — builder, validator, миграция `ProxySource → ServerList` в `SettingsStorage.getServerLists`, controllers переведены на v2, UI-экраны адаптированы через façade `SubscriptionEntry`.
- **Фаза 4** — удалены `node_parser.dart` (1100 LOC), `config_builder.dart` (550), `source_loader.dart` (235), `subscription_fetcher.dart`, `subscription_decoder.dart`, `xray_json_parser.dart` (435), `models/parsed_node.dart`, `models/proxy_source.dart`. `grep ParsedNode|ProxySource|NodeParser|ConfigBuilder` по `lib/` — только комментарии в `proxy_source_migration.dart` (легитимно).
- **Фаза 5 (post-refactor)** — первоначальный inline-dedup в `buildConfig` + `ServerRegistry` заменены на 3-слойную архитектуру (`EmitContext` + `ServerList.build(ctx)` + `NodeSpec.getEntries`). `ServerRegistry` физически удалён.

### 6.1 Миграция настроек пользователя

`SettingsStorage.getServerLists()` при первом чтении:
- Если есть ключ `server_lists` — читает v2 напрямую.
- Если только `proxy_sources` (v1) — конвертирует через `migrateProxySources` (`services/migration/proxy_source_migration.dart`): URL → `SubscriptionServers`, inline → `UserServers(paste)`, переносит detour-флаги, meta-поля, `lastUpdated`. Пишет в `server_lists`, удаляет `proxy_sources`. Одноразово.

---

## §7. Тестирование (106 тестов)

### 7.1 Модели
`test/models/*` — equality, `copyWith`, JSON round-trip `ServerList`, exhaustive switch компилируется на всех 9 `NodeSpec` variants, `NodeWarning` severity mapping.

### 7.2 Парсеры (per-protocol + fixtures)
`test/parser/*` — каждый парсер + emit на corpus URI в `test/fixtures/<protocol>/`. Round-trip `parseUri(spec.toUri()) ≈ spec` на всех 9 variants. Отдельные тесты TUIC, VLESS Reality, INI, JSON (xray, singbox), body_decoder (base64, INI, URI list, Xray array, singbox outbound, comment-only, empty).

### 7.3 Builder
`test/builder/*`:
- `build_config_test.dart` — smoke (2 vless → 2 outbounds + vpn-1 + auto), WG → endpoints, tls_fragment только first-hop, dedup тэгов `BL: Frankfurt-1/-2` с префиксом, `clash_api` randomize в `generatedVars`, configJson валиден.
- `validator_test.dart` — dangling refs (fatal), empty urltest (fatal), invalid selector default (fatal), endpoint tag ссылки.

### 7.4 End-to-end pipeline
`test/pipeline_e2e_test.dart` — `InlineSource(body)` → `parseFromSource` → `UserServers` → `buildConfig(lists, {template})` → проверка preset-групп, disabled list ignored, XHTTP warning пролетает до `result.emitWarnings`.

### 7.5 Subscription
`test/subscription/*` — InlineSource URI list / base64 / QR, inline pseudo-headers (`# profile-title:` → `meta.profileTitle`).

### 7.6 Migration
`test/migration/proxy_source_migration_test.dart` — URL → Sub, inline → User(paste), detour defaults preserve, JSON round-trip.

### 7.7 Parity v1↔v2
**Удалено** в Фазе 4 вместе с v1. На этапе Фаз 2-3 тесты подтвердили эквивалентность outbound-JSON на корпусе фикстур, после чего контракт переходит на fixtures-golden + round-trip.

---

## §8. UI impact

| Экран | Что |
|-------|-----|
| `SubscriptionsScreen` | `List<SubscriptionEntry>`, чип `+N⚙` над nodeCount если есть chained. «Add servers» через smart-paste → `UserServers`. |
| `SubscriptionDetailScreen` | Tabs: Nodes / Settings / Source. Settings: редактор `tagPrefix`, `DetourPolicy` toggles, override-picker. Source: живой HTTP GET (`fetchRaw`), важные headers сразу + «показать все». Warning-баннер по `NodeWarning.severity`. |
| `NodeSettingsScreen` | Работает через `spec.emit(TemplateVars.empty).map` для view/edit JSON; `parseSingboxEntry(edited)` для save. |
| `RoutingScreen` | Облачко rule-set кликабельное (параллельный download N×9s, cap ~20с), error красный, cached зелёный. Post-steps в buildConfig перестраивает конфиг. |
| `DebugScreen` | `AppLog.I` с фильтрами severity + source. Кнопка «📤 Dump» — `DumpBuilder.build()` собирает `{config, vars, server_lists, debug_log}` в `/tmp/lxbox-dump-<ts>.json`, открывает системный share-диалог. |
| `HomeScreen` | Без изменений поверх парсера. |
| `StatsScreen` | Group по `chains.first` из Clash connections — детур отображается как `node via ⚙ detour`. |

Warning-тексты — plain en-string (i18n-инфры в проекте нет).

---

## §9. Критерии приёмки

- [x] Sealed на всех местах ветвления: `NodeSpec`, `TransportSpec`, `TlsSpec*`, `NodeWarning`, `SingboxEntry`, `ServerList`, `SubscriptionSource`, `DecodedBody`, `ValidationIssue`.
- [x] `WireguardSpec.emit()` → `Endpoint`, остальные → `Outbound`. В builder'е `switch(entry)` по sealed, без `type == 'wireguard'`.
- [x] `parseFromSource(UrlSource)` → `ParseResult{nodes, meta, rawBody, headers}`.
- [x] `buildConfig({lists, settings, template?})` → `Future<BuildResult>` с `configJson`, `validation`, `emitWarnings`, `generatedVars`.
- [x] Round-trip `parseUri(spec.toUri()) ≈ spec` для 9 вариантов + `parseSingboxEntry(emit().map) ≈ spec`.
- [x] XHTTP fallback — `XhttpTransport.toSingbox()` единственный раз, sealed-switch не даёт забыть.
- [x] После Фазы 4: `grep ParsedNode\|ProxySource` в `lib/` — только комментарии в миграционном файле.
- [x] Новый протокол: добавление = `XxxSpec` + `parseXxx` + `emitXxx`/`toUriXxx` + ветка в `parseUri` switch. Остальное компилятор ловит как пропущенный sealed-case. *(Edge-case: если протокол эмитит не-Outbound и не-Endpoint, потребуется новый вариант в sealed `SingboxEntry`. На 2026-04-18 ни один не требует — все укладываются в Outbound/Endpoint.)*
- [x] TUIC v5 — реализован: `TuicSpec`, `parseTuic`, `emitTuic → Outbound`. URI `tuic://UUID:PASSWORD@host:port?congestion_control=…&udp_relay_mode=…&alpn=…&sni=…#label`.
- [x] Дедуп тэгов + `tagPrefix` — единственная точка `ctx.allocateTag(base)` в `_BuildCtx`, вызывается из `ServerList.build`. `base` = `prefix + tag` если `tagPrefix != ''`, иначе `tag`.
- [x] TLS fragment инвариант — только first-hop (§3.4.1).
- [x] Offline-rehydrate — `HttpCache.save` на каждом fetch, `_rehydrateFromCache` на init.
- [x] Retry fetch — 2 попытки × 9s + 2s пауза, cap ≈ 20s.
- [x] `profile-title: base64:...` декодируется.
- [x] Inline pseudo-headers (`# profile-title:` и др.) извлекаются из тела и мержатся с HTTP-headers.
- [x] `Content-Disposition` fallback для имени — `filename="…"` / `filename=…` / RFC 5987 `filename*=UTF-8''…`, срез расширений `.txt/.yaml/.yml/.json/.conf`.
- [x] SIP003 plugin split — `?plugin=name;k=v;…` корректно делится на `plugin` / `plugin_opts`.

---

## §10. Риски и пост-мортем

| Риск (плановый) | Факт |
|-----------------|------|
| Codegen build-step замедляет CI | freezed не использовали — остались ручные sealed. Codegen-времени = 0. |
| Parity-тесты ловят расхождение | В Фазах 2-3 ловили 3-4 тонких случая (h2→http, flow=xtls-rprx-vision-udp443, Reality без transport). Исправлено до удаления v1. |
| ANR на 1000+ нодах | 150-200 нод парсятся <50ms. Lazy rehydrate в фоне пока не нужен (YAGNI). |
| `ProxySource → ServerList` ломает юзер-настройки | Покрыто тестом `proxy_source_migration_test.dart`; в проде миграция сработала без потерь. |
| XHTTP в будущем поддержат в sing-box | `XhttpTransport.toSingbox` переписать на прямой emit — один коммит. |
| YAML-подписки (Clash) | Не поддержаны парсером. Обходится через UA `SubscriptionParserClient` — сервер отдаёт URI-list. Документировано в §3.1. |
| Liberty / DDoS-guard серверы на мобильной сети | Решено retry (2 попытки × 9s + 2s). |

---

## §11. Ключевые решения

| # | Вопрос | Решение |
|---|--------|---------|
| 1 | Freezed vs ручной sealed | **Ручной sealed** — freezed добавили в pubspec, но в итоге не использовали: для методов-heavy `NodeSpec` (emit/toUri/getEntries) freezed даёт меньше чем стоит codegen complexity. |
| 2 | Где живут detour-флаги | На `ServerList.detourPolicy`. Применяются в `ServerList.build(ctx)`. `NodeSpec` не знает о подписке. |
| 3 | `ServerRegistry` | Сначала был как thin wrapper, потом переведён в полноценного владельца дедупа, потом **удалён** — логика переехала в `ServerList.build(ctx)` с аллокатором `ctx.allocateTag`. |
| 4 | `NodeSpec.list` back-ref | Отвергнут — узел не знает о своём контейнере. `list` передаётся только через `assemble(list, ctx)` (факт.: узел использует `ctx.vars`, остальное знает `ServerList`). |
| 5 | sink vs `List<SingboxEntry>` из `getEntries` | `NodeEntries{main, detours[]}` — именованная структура, не позиционный список. Sink-паттерн (`ctx.add(entry)` на узле) был в промежуточной версии, отвергнут как усложнение. |
| 6 | Feature-flag в релизе | Нет. v2 либо работает, либо не релизится. |
| 7 | `warnings` mutable на spec | Оставлено — единственное mutable поле в иерархии, пересоздаётся на каждом parse/emit. |
| 8 | `registerDetourServers` default | Поменяли с `true` → `false` по юзер-фидбеку (лишние ⚙ в proxy-группах). Existing подписки сохраняют свои сохранённые значения. |
| 9 | TUIC v5 | Добавлен с нуля (в v1 отсутствовал). |
| 10 | preset_groups.dart как отдельный файл | Удалён, слит в `build_config.dart` как приватный `_buildPresetGroups` — вызывается из одного места. |
| 11 | User-Agent default | `SubscriptionParserClient` (v1-совместимость). `ClashForAndroid/*` триггерит YAML, который мы не парсим. |

---

## See also

- [`004 subscription parser`](../004%20subscription%20parser/spec.md) — v1 legacy, заменено этим.
- [`005 config generator`](../005%20config%20generator/spec.md) — v1 сборщик заменён §3.4.
- [`018 detour server management`](../018%20detour%20server%20management/spec.md) — `DetourPolicy` на `ServerList`, применение в `ServerList.build(ctx)`.
- [`020 security and dpi bypass`](../020%20security%20and%20dpi%20bypass/spec.md) — TLS fragment first-hop invariant (§3.4.1 этой спеки).
- [`docs/PROTOCOLS.md`](../../../PROTOCOLS.md) — URI-формат каждого протокола + TUIC v5 + XHTTP fallback note.
