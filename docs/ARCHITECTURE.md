# L×Box architecture

This document describes the structure of the L×Box Flutter application, the boundaries of responsibility, the data flows and the native side.

The current parser and builder version is **v2** (spec 026, phase 5 completed in v1.3.0). Details are in [spec/features/026 parser v2](./spec/features/026%20parser%20v2/spec.md).

---

## Supported platforms

| Параметр | Значение |
|----------|----------|
| Android minSdk | **24** (Android 7.0) |
| Android targetSdk | `flutter.targetSdkVersion` (актуальная target, обычно API 34/35) |
| Android compileSdk | `flutter.compileSdkVersion` |
| JVM | Java 17 |
| NDK | 28.2.13676358 |

### Поддержка по тирам

| Tier | Android | Статус |
|------|---------|--------|
| **Primary** | 11+ (API 30+) | Тестируется, все фичи работают, production-ready |
| **Best-effort** | 7.0–10 (API 24–29) | Compile OK, install OK, базовый VPN-функционал должен работать. Фичи требующие новых API (например, silent-kill detection через `getHistoricalProcessExitReasons`, API 30+) деградируют к no-op за `SDK_INT`-гейтами. Не тестируется регулярно; жалобы принимаются, но fix'ы на best-effort основе. На 7.x дополнительно: старый системный trust store — на 7.0 нет корня ISRG Root X1, HTTPS-подписки с Let's Encrypt-сертификатами не валидируются (на 7.1.1+ корень есть). |
| **Unsupported** | <7 (API <24) | Установка заблокирована `minSdk=24`; ниже 24 не пускает сам Flutter (пол движка) |

> **Android TV (§372).** Приложение объявлено совместимым с TV
> (`uses-feature leanback` / `touchscreen` — обе `required="false"`,
> `LEANBACK_LAUNCHER` в intent-filter), но остаётся **best-effort**:
> UI рассчитан на касание, отдельного leanback-интерфейса нет. Две
> особенности платформы, которые надо помнить при правках:
> в прошивках TV **нет DocumentsUI**, но intent не остаётся без обработчика —
> его перехватывает системная заглушка `frameworkpackagestubs`, которая молча
> отменяет выбор (`resolveActivity` её находит, ошибки нет, результат пуст).
> Поэтому все пики идут через
> [`services/file_import.dart`](../app/lib/services/file_import.dart): он
> спрашивает платформу (`hasRealFilePicker`, отбрасывает заглушки по имени
> пакета) **до** запуска пика и подсказывает буфер обмена / URL. Не полагаться
> на код ошибки `file_picker` — на TV его не будет. И управление идёт с **D-pad** — виджеты
> без фокусного узла (`GestureDetector`) с пульта недостижимы, для кликабельных
> элементов на пути подключения нужен `InkWell`/кнопка. Подробности —
> [§372](spec/tasks/372-android-tv-support.md).

> **Рендерер (§131).** На `Build.VERSION.SDK_INT < 31` (Android ≤11) Flutter
> принудительно переключается с Impeller на **Skia** (`getFlutterShellArgs` →
> `--enable-impeller=false` в [`MainActivity`](../app/android/app/src/main/kotlin/com/leadaxe/lxbox/MainActivity.kt)).
> Impeller-шейдеры валят старые GPU-драйверы (Adreno 3xx → SIGSEGV в `libsc-a3xx.so`).
> На Android 12+ Impeller сохранён. Гейт по версии ОС, не по GPU — у Flutter нет
> чистого рантайм-детекта GPU. Подробности — [§131](spec/tasks/131-impeller-adreno-gpu-crash.md).

### Почему именно 24 как minSdk

- **24 — абсолютный пол**: Flutter 3.41.x поддерживает минимум API 24 (`FlutterExtension.minSdkVersion = 24`), libbox.aar собран с `minSdkVersion=23`. Ниже 24 приложение не собрать в принципе.
- Исторически с v1.4.0 стоял `minSdk=26` («Android 8.0+» из release notes 1.3.x); понижен до 24 в §233 по запросу пользователей со старыми устройствами — технических зависимостей от API 26 в коде не было (см. аудит в [spec/tasks/233](spec/tasks/233-minsdk-24.md)).
- **VpnService API** (`setMetered`, `setUnderlyingNetworks`) доступны с API 29+, для старых есть fallback-пути (без setMetered — vpn работает нормально, просто не маркируется как non-metered).
- **`ActivityManager.getHistoricalProcessExitReasons`** (API 30+) — нужен для silent-kill detection в task 007. В коде обёрнут в `if (Build.VERSION.SDK_INT >= 30)` — на старых просто не триггерит snackbar.
- **`NotificationChannel`** (API 26+) — за `SDK_INT >= O`-гейтами; оба notification-билдера ставят `setPriority(...)`, так что на pre-O приоритет корректен без каналов. FGS стартует через `ContextCompat.startForegroundService` (на <26 — обычный `startService`, background-ограничений до Oreo нет).
- **`BoxApplication.fixAndroidStack`** включается ровно на API 24–25 — воркараунд libbox под Android 7.x.

### `Build.VERSION.SDK_INT` проверки

В Kotlin (DefaultNetworkMonitor, ServiceNotification, BoxApplication, etc.) version guards — рабочий механизм тиров: с `minSdk=24` ветки `>= N (24)` и выше снова достижимы. Гейты `>= M (23)` всегда true — можно упростить отдельным cleanup-pass'ом, но выигрыш минимален.

---

## Overview

L×Box is an Android VPN client built on **sing-box** (through **libbox**). The full cycle:
subscriptions → parsing → config → the VPN tunnel → control through the **libbox CommandClient**.

### The core: the `sing-box-lx` fork

The VPN core is our fork [`Leadaxe/sing-box-lx`](https://github.com/Leadaxe/sing-box-lx)
(upstream sing-box plus AmneziaWG, XHTTP and the LxBox features), controlled through the
libbox CommandClient. The AAR is downloaded by `scripts/fetch-libbox.sh` from the fork's
GitHub Releases, and the version is pinned in `app/android/libbox.version`.

**The full picture — the build tags, the gotchas of a version bump and the rc history — is in
[`KERNEL.md`](KERNEL.md).**

### The layers and their responsibilities

Four layers with one-directional dependencies: **UI → State → Services → Platform**
(never the other way round). Logic never lives in `build()`, and the UI never touches
Platform directly — only through the controllers.

```
┌──────────────────────────────────────────────────────────────────────┐
│  UI   lib/screens · lib/widgets                                        │
│  Тонкие экраны: композиция + lifecycle + setState; логика — в          │
│  presenter/view-model. Паттерн: <screen>.dart (StatefulWidget, владеет │
│  state + все Navigator.push) + <screen>/widgets|sections|tabs/ +       │
│  presenter/VM. Подписка через AnimatedBuilder / ListenableBuilder.     │
├──────────────────────────────────────────────────────────────────────┤
│  STATE   lib/controllers — ChangeNotifier-брокеры                      │
│  HomeController  — VPN/CommandClient/nodes/ping/heartbeat (split на     │
│                    part'ы: config_io · heartbeat · ping_orchestration)  │
│  SubscriptionController — entries, fetch, generateConfig (+ part)       │
│  view-model'и: NodeFilterViewModel · CustomRuleEditController           │
│  Иммутабельный HomeState + copyWith (_unset sentinel) + ParsedConfig.   │
├──────────────────────────────────────────────────────────────────────┤
│  SERVICES   lib/services · lib/models · lib/config                     │
│  Parser v2 (parser/) · Builder (builder/) · subscription/ ·            │
│  settings_storage/ · traffic_profiler/ · debug/ (HTTP Debug API) ·     │
│  vpn/cc_channel (libbox CommandClient) · app_log ·                     │
│  кэши (AppInfoCache·HttpCache) ·                                        │
│  ConfigNode/ParsedConfig (§091).                                        │
│  Sealed-модели: NodeSpec · SingboxEntry · CustomRule · ValidationIssue. │
├──────────────────────────────────────────────────────────────────────┤
│  PLATFORM / NATIVE                                                      │
│  Dart: vpn/box_vpn_client — MethodChannel + status/coreLog Stream.      │
│  Kotlin: VpnPlugin (мост) → BoxVpnService (Android VpnService) +        │
│  BoxService (libbox runtime, §049-split) + DefaultNetworkMonitor        │
│  (§087 network-reset) + LocalResolver + WifiInfoReader.                │
└──────────────────────────────────────────────────────────────────────┘
```

**Инвариант фасадов (§291):** домен даёт наружу **фасад** и не знает
потребителей (в сигнатурах нет `DebugContext`/виджетов/intent'ов); внешние
адаптеры (Debug HTTP · Automation broadcast · UI) знают транспорт+безопасность,
но не то, к чему дают доступ; общая операция объявлена один раз, все адаптеры
сводятся к вызову фасада. Эталоны формы: `ChannelMutations` (атомарный
heal+resync, сырые статики `@visibleForTesting`), `SubscriptionController`
(владеет мутациями server-lists; Debug+Automation делегируют), `ProbeController`
(`services/probe/` — общий probe над всей подсистемой ServerList: пороги/ping/
чистые решения + `probeNodesOf`-адаптер; `ProbeGateMixin` — общий VPN-гейт),
`DnsController` (`services/dns/` — `load()`→snapshot + `stage()` над DNS-секцией;
экран тонкий), `VpnSettingsFacade` (`services/vpn_settings/` — `applyVpnMode`
несёт инварианты password-gen/auth-force/`has_tun`-зеркало для UI **и** Debug).
Типизированные storage-модели: sealed `DnsServerRef`/`DnsRuleRef` (§294).
Полный инвариант + план strangler — `docs/spec/features/291 layered-architecture-facades/`.

**Брокеры событий (push, снизу вверх):** §122 — управляющий канал UI переведён
на libbox **CommandClient** (server-stream push вместо Timer-polling). Push-каналы:
native статус-`Stream<TunnelStatusEvent>` (lifecycle туннеля), `lxbox/coreLog`-stream
(→ `AppLog` → `TrafficProfiler`) и CommandClient-стримы поверх EventChannel
`lxbox/cc/*` (status · outbounds · groups · connections · dns — `vpn/cc_channel.dart`).
Unary-pull остался точечно — `getGroups()` (lifeline там, где groups-push дырявый),
плюс императивы сверху вниз (`urlTestOutbound` · `selectOutbound` · `closeConnection`).
Heartbeat — watchdog по **тишине** status-стрима, без HTTP-poll'а. Подробные
потоки — в разделе [Потоки данных](#потоки-данных).

### Инвариант: ДВА канала разной надёжности (статус vs данные) — НЕ путать

Принципиальное разделение, нарушение которого = баги вида «Connected, но Channel/
Nodes пустые после swipe» (см. §185):

| Канал | Что несёт | Надёжность / жизненный цикл |
|---|---|---|
| **VpnService status broadcast** (native `Stream<TunnelStatusEvent>` / `BROADCAST_STATUS`) | ТОЛЬКО **глобальный статус** туннеля (Connected/Stopped/Connecting/error) | **НАДЁЖНЫЙ, всегда есть.** Чисто native (Android Service), переживает смерть Flutter-движка (swipe-kill при keep-VPN). Единственный источник правды для статуса. UI обязан показывать статус из него. |
| **CommandClient-стримы** (`lxbox/cc/*`: groups · connections · outbounds · status-tick) | **Данные для отображения на экране**: группы/ноды, соединения, трафик, per-app | **ЭФЕМЕРНЫЙ.** Привязан к Flutter-движку: подписки в Dart, refcount в native. Сервис/ядро живут независимо, но стримы существуют только пока жив движок-потребитель. Поэтому CommandClient **обязан пересинхронизироваться** при появлении нового потребителя (см. «три точки синхронизации» ниже): пере-подписка + `getGroups`-pull (детерминированный lifeline, §122). НЕ источник статуса — только данные для UI.

**keep-VPN-on-exit НЕ останавливает ядро** — это ВЕРНОЕ поведение (`BoxService.onTaskRemoved` при keep = no-op, ядро/CommandServer живут). Свайп убивает только UI-движок; статус продолжает идти broadcast'ом, а CommandClient-данные должны переподняться при следующем открытии UI. Не «чинить» keep-VPN, не дёргать `doStop` на swipe.

**Lifecycle CommandClient-клиентов — ТРИ точки синхронизации native↔Dart:**
1. **Уход в фон** (движок жив) — усыпить screen+status (`pauseScreen`/`pauseStatus`); профайлер НЕ трогаем (пишет в фоне, §164).
2. **Возврат из фона** (движок жив) — поднять обратно, парно (`resumeScreen`/`resumeStatus`).
3. **Cold-start Flutter** (новый движок) — native-состояние CommandClient привести в чистое (refcount=0, снять висячие подписки/sink'и), новый UI подключается с нуля. Надёжная точка — `onAttachedToEngine` (Dart мог умереть внезапно при swipe и не отписаться).

**Профайлер держит буфер в Dart** (`TrafficProfiler`), а его native `profilerClient` живёт в фоне (§164 не паузит). Следствие: запись существует только пока жив Flutter-движок — by design профайлер пишет, пока приложение открыто. На cold-start native-сторона профайлера приводится в чистое (осиротевший `profilerClient` от прошлого движка останавливается принудительно), буфер начинается пустым.

### Принцип «cohesion over line-count» (§089)

Цель структурного рефактора §089 — **единая ответственность + связность**, не
число строк. ~600 строк легитимны, когда файл = одна cohesive ответственность.
Декомпозиция крупных файлов — через `part`/`mixin` (та же библиотека →
library-private доступ сохранён) либо вынос виджет-поддеревьев. Задокументированные
крупные исключения (split дал бы риск без пользы):

| Файл | Строк | Почему остаётся целым |
|---|---|---|
| `services/traffic_profiler.dart` | 1243 | Монолитный stateful singleton: приём CC connections+DNS-стримов + diff-снапшоты + confidence + dual SSE fan-out — всё через общий private state и один `ChangeNotifier`-контракт. Core-лог **не** парсит (лог-питатель выпилен в §044/§180). Pure-типы (`models.dart`) и correlation-структуры (`internal.dart`) уже вынесены `part`'ом. |
| `models/custom_rule.dart` | 618 | Уже sealed `Inline`/`Srs`/`Preset`; объём присущ трём структурно разным вариантам. Дальнейший split + SRS-cache у Preset (spec 011) — **behavior-changing** → отложен в §090. |
| `android/.../VpnPlugin.kt` | 1084 | Единый `MethodCallHandler`-контракт; split разнёс бы channel-контракт по файлам. |

### ConfigNode / ParsedConfig (§091 — реализовано)

`ConfigCache` + `ConfigIntrospection` + reverse-map `subscriptionsOfTag`
схлопнуты в `ParsedConfig` — `Map<tag, ConfigNode{tag, type, section, detour,
isMarkedDetour, detourRefCount, raw, transportLabel, securityLabel}>`,
парсится один раз на смену `configRaw` (поле `HomeState.configModel`);
пинги — отдельный динамик-слой, джойн на рендере (`NodeViewItem`).
Принадлежность подписке — **prefix-фильтр** по эмитированному тегу
(`home/subscription_lookup.dart`), без членства в node-списках. Убран целый
класс багов «UI reverse-парсит display-тег» (§077/§079/§080).

`transportLabel`/`securityLabel` (§102/§103) — eager-лейблы subtitle ноды
(протокол · транспорт · security: `tcp`/`ws`/`grpc`/`h2`/`httpupgrade`/`quic`/`xhttp`;
`TLS`/`Reality` + `+Vision` при `flow=xtls-rprx-vision`; для WireGuard —
уровень обфускации `awg`/`awg2`) — вычисляются один раз в `ParsedConfig.parse`,
не в getter'ах. См. [`spec/tasks/091`](./spec/tasks/091-config-node-model.md),
[`102`](./spec/tasks/102-subtitle-transport-variant.md),
[`103`](./spec/tasks/103-variant-filter-chips.md).

---

## 3-слойный Parser v2 pipeline

```
UI / Controller
  │  paste / URL / QR / file  →  SubscriptionSource
  ▼
parseFromSource(source)  ─┐
  │ HTTP fetch (UrlSource)│  → ParseResult{ nodes, meta, rawBody, headers }
  │ body_decoder + parsers│
  └───────────────────────┘
  ▼
ServerList (sealed)  —  SubscriptionServers | UserServer
  │ .build(ctx: EmitContext)
  │   ├─ applies tagPrefix + allocateTag
  │   ├─ per-node emit(vars) → SingboxEntry (Outbound | Endpoint)
  │   ├─ applies detour policy (register/use/override)
  │   └─ registers in selector / auto-proxy-out groups
  ▼
buildConfig(lists, settings)
  │ template (assets/wizard_template.json)
  │ post-steps (в порядке выполнения):
  │   1. server_list_build   → outbounds/endpoints из ServerList
  │   2. applyAllCustomRules → единый проход по customRules в storage order
  │                            (dispatch по kind → preset/inline/srs handler);
  │                            registry получает rule_sets и routing rules
  │                            в порядке storage; DNS-аспекты — в UnifiedApplyResult
  │                            (spec 030 + 033 + 062)
  │   3. flush registry      → config.route.{rule_set, rules}
  │   4. applyTlsFragment, applyMixedCaseSni  → TLS-обфускация (spec 028)
  │   5. applyCustomDns      → dns.servers/rules из template + bundle-extras
  │   6. validator → ValidationResult{ fatal[], warnings[] }
  ▼
BuildResult{ config, configJson, validation, emitWarnings, generatedVars }
  │
  ▼
HomeController.saveParsedConfig(configJson)  →  native VpnService
```

**Invariants:**
- Each `NodeSpec` has round-trip `parseUri(spec.toUri()) ≈ spec`.
- Polymorphic `emit(vars)` — WireGuard → Endpoint, others → Outbound.
- `EmitContext.allocateTag(baseTag)` guarantees global uniqueness across all lists.
- Warnings bubble up: parse-time → `NodeSpec.warnings`, emit-time → appended by emit. (XHTTP-фолбэк в `httpupgrade` убран в §097 — emit нативный, ядро `with_xhttp`.)

---

## Wizard template (`assets/wizard_template.json`)

Asset-шаблон, который читается один раз через `TemplateLoader.load()` (синглтон, deep-copy на каждый билд). Определяет скелет sing-box конфига, глобальные переменные, preset-группы (VPN tiers) и selectable-правила (каталог routing-пресетов).

### Секции шаблона

| Секция | Роль | Пример / где используется |
|---|---|---|
| `parser_config` | sing-box `version` + reload interval | прямой emit в корень |
| `dns_options.servers` | Canonical DNS-серверы (system/google/cloudflare/quad9/adguard). Storage хранит kind-refs `{enabled, kind: inline\|preset\|template, tag, description?, body?}` (§043 + §044). Body для kind:inline — partial sing-box shape **без** tag/description/enabled (они на ref-level; tag синтезируется на build-time). Резолвится в bodies через `resolveDnsServersBodies`. | `applyCustomDns` через `resolveDnsServersList` |
| `dns_options.rules` | Дефолтные DNS-rules. Storage — kind-refs (§061 dns-rules-refactor, бывший feature §041) (`inline\|srs\|preset\|template`). Catch-all удалён в task §039 (empty-template-dns-rules) — fall-through идёт через `dns.final`. | `applyCustomDns`: bundle-rules через `resolveDnsRulesList` |
| `ping_options`, `speed_test_options` | UI-фичи (HomeScreen, SpeedTest) | не попадают в sing-box конфиг |
| `group_templates` + `default_channels` | §125/§267 — **SEED** для `channels[]` (на первом запуске). Билдер каналы читает из storage `channels[]`, НЕ из template. §267 заменил плоский `preset_groups`. | `_buildChannelGroups(channels)` в `build_config.dart` (бывш. `_buildPresetGroups`) |
| `config` | База sing-box конфига: log, inbounds, route-skeleton | deep-copy'ится в начале `buildConfig` |
| `sections[].vars[]` | Глобальные переменные UI — chapter: `core` / `routing` / `dns` | `TemplateVarListView` рендерит в SettingsScreen/RoutingScreen; `@name` подставляется в config через `_substituteVars` |
| `selectable_rules` | Каталог пресет-правил (legacy inline + bundle — spec 033) | вкладка Presets в `RoutingScreen` |

### Selectable rules — два режима

Пресет в `selectable_rules[]` работает в одном из двух режимов:

**Legacy (до v1.4.x, без `preset_id`):**
```json
{
  "label": "BitTorrent direct",
  "default": true,
  "rule": { "protocol": ["bittorrent"], "outbound": "direct-out" }
}
```
Копируется юзером в `CustomRule(kind: inline | srs)` через `selectableRuleToCustom` — содержимое копируется **по значению**, дальнейшие правки шаблона не влияют на уже скопированное правило.

**Bundle (v1.5+, `preset_id` задан) — spec 033:**
```json
{
  "preset_id": "ru-direct",
  "label": "Russian domains direct",
  "default": true,

  "vars": [
    {"name": "out", "type": "outbound", "default_value": "direct-out", "title": "Outbound"},
    {"name": "dns_server", "type": "dns_servers", "required": false, "default_value": "yandex_doh", "title": "Transport"},
    {"name": "dns_ip", "type": "enum", "default_value": "77.88.8.88", "options": [
      {"title": "77.88.8.88 · Safe", "value": "77.88.8.88"}, ...
    ]}
  ],
  "rule_set":    [ { "tag": "ru-domains", "type": "inline", "format": "domain_suffix", "rules": [...] } ],
  "dns_rule":    { "rule_set": "ru-domains", "server": "@dns_server" },
  "rule":        { "rule_set": "ru-domains", "outbound": "@out" },
  "dns_servers": [
    {"type": "https", "tag": "yandex_doh", "server": "77.88.8.88", "port": 443, "path": "/dns-query", "tls": {"enabled": true, "server_name": "safe.dot.dns.yandex.net"}, "detour": "@out"},
    ...
    {"type": "udp",   "tag": "yandex_udp", "server": "@dns_ip", "server_port": 53, "detour": "@out"}
  ]
}
```
`CustomRule(kind: preset)` хранит **тонкую ссылку** — только `{presetId, varsValues}`. Expansion (`preset_expand.dart`) на каждый билд:
1. Резолвит переменные из `varsValues` (или `default_value` если ключ отсутствует; для `required: false` + отсутствие ключа + пустой default → `null` → фрагменты с `@var` выкидываются).
2. Рекурсивно подставляет `@var` в `rule_set`/`dns_rule`/`rule`/`dns_servers`.
3. Фильтрует `dns_servers` до одного с `tag == vars['dns_server']`.
4. Если `@out` резолвится в `"direct-out"` — удаляет `detour` из DNS-серверов (direct не требует forwarding).

Merge фрагментов от разных `CustomRule(kind: preset)` — identical-skip по tag + first-wins с warning для реальных конфликтов, детерминированный порядок по индексу в UI.

### Vars

`WizardVar` едина для глобальных `sections[].vars[]` и preset-local `selectable_rules[i].vars[]`. Поддерживаемые типы (`type`):

| `type` | UI | Substitution |
|---|---|---|
| `bool` | SwitchListTile | `"true"` / `"false"` → Dart bool |
| `text` | TextField (+ combo-popup если есть `options`) | строка |
| `enum` | Dropdown с `title → value` | строка (`value`) |
| `secret` | TextField с eye-toggle + Generate | строка |
| `outbound` (preset only) | OutboundPicker | строка (tag) |
| `dns_servers` (preset only) | Dropdown по `preset.dns_servers[].tag` | строка (tag) |

**`options`** принимает два формата (legacy-совместимо): строка-литерал (`"foo"` ≡ `{title: "foo", value: "foo"}`) или объект `{"title": "...", "value": "..."}`. UI показывает `title`, expansion/storage — `value`.

**`required: bool`** (default `true`) — для optional var в UI появляется пункт "— (none)"; при выборе → `varsValues[name] = ""`. Expansion отличает `containsKey=false` (юзер не трогал → применяется `default_value`) от `value=""` (юзер явно выбрал none → `null`).

### Как связаны слои

```
wizard_template.json
  │  load (TemplateLoader)  →  WizardTemplate (в памяти, shared)
  │
  ├── config       ──► _substituteVars(@global vars)                          ──► base config
  ├── customRules (один список, mixed kind — preset/inline/srs)
  │    │  applyAllCustomRules — единый проход в storage order
  │    │  с dispatch по kind. Cross-preset rule_set dedup через
  │    │  RuleSetRegistry.tryRegisterRuleSet (identical-skip / first-wins).
  │    │  (spec 062 — раньше preset/inline шли двумя проходами и cross-kind
  │    │  ordering между ними был потерян)
  │    ├── kind: preset
  │    │    └─ expandPreset (pure) ──► PresetFragments
  │    │       └─ register rule_sets in registry; routing rule (if route enabled);
  │    │           DNS aspect (if dns enabled) → UnifiedApplyResult.{dnsRules, dnsServers}
  │    ├── kind: inline
  │    │    └─ headless rule_set с непустыми match-полями + routing rule
  │    │       (auto-suffix tag через registry.addRuleSet) (spec 030)
  │    └── kind: srs
  │         └─ local rule_set по cached path + routing rule (spec 030)
  ├── dns_options  ──► applyCustomDns(template + extras)                      ──► config.dns
  └── channels[] (storage) ──► _buildChannelGroups(per-channel node_filter)  ──► config.outbounds
      (§125/§267: каналы из channels[], seed из group_templates+default_channels; +block/direct опции, auto-двойник)
```

**Почему DoH/DoT в bundle хардкодят `server: "77.88.8.88"` + `tls.server_name`:**
В sing-box 1.12 DNS-сервер типа `https`/`tls` с hostname-сервером требует `domain_resolver` (тег другого DNS-сервера для bootstrap resolve), иначе chicken-and-egg. Указывая IP напрямую + `tls.server_name` для SNI/cert verify — избавляемся от bootstrap dependency (не нужно ходить в 8.8.8.8 для резолва `safe.dot.dns.yandex.net`) и получаем Safe-профиль Yandex с корректной TLS проверкой.

`@dns_ip` применяется **только** к UDP-серверу — для DoH/DoT замена IP сломала бы TLS (cert mismatch с захардкоженным SNI). Для реально разных режимов Yandex (Safe/Base/Family) → отдельные пресеты, если понадобятся, чтобы не городить nested-lookup в substitution-движке.

---

## Дерево исходников

Структура после §089: тонкие экраны с под-папками `<screen>/`, контроллеры и
крупные сервисы разнесены `part`'ами по ответственности. Per-file роли ниже.

### `app/lib/`

```
main.dart                    # Entry point: ThemeNotifier, MaterialApp,
                             #   home: HomeScreen, navigatorObservers:[homeReturnObserver]
                             #   (named routes нет — навигация императивная)
```

#### `vpn/` — Dart-сторона native-моста

```
box_vpn_client.dart          # BoxVpnClient.I — типизированная обёртка над
                             #   MethodChannel/EventChannel; каждый вызов
                             #   timeout-wrapped + safe-default; onStatusChanged stream
box_vpn_client/method_names.dart  # part: _Methods — зеркало when(call.method) из VpnPlugin.kt
box_vpn_client/timeouts.dart      # part: _Timeouts — per-method Duration (status 3s, start 30s…)
cc_channel.dart              # §122 CcChannel.instance — Dart-клиент libbox CommandClient (заменил
                             #   ClashApiClient): push-стримы status/outbounds/groups/connections/dns (§180)
                             #   поверх EventChannel lxbox/cc/* + императивы (urlTestOutbound, getRules,
                             #   getGroups unary-pull, selectOutbound, closeConnection); фан-аут через
                             #   broadcast (ОДИН native sink на канал, §122 sink-leak-guard)
```

#### `config/`

```
config_parse.dart            # JSON5/JSONC → canonical JSON (для libbox) + pretty-print (для editor)
consts.dart                  # kAutoOutboundTag (✨auto), kDetourTagPrefix (⚙) — зеркало wizard_template
```

#### `models/` — типизированные данные (sealed-иерархии, без I/O)

```
node_spec.dart               # sealed NodeSpec (11 вариантов: Vless/Vmess/Trojan/Shadowsocks/
                             #   Hysteria2/Naive/Tuic/Ssh/Socks + Wireguard + Masque §130); getEntries detour-chain;
                             #   Awg value-object (§097): AWG/AWG2-поля WireguardSpec (jc/jmin/jmax/
                             #   s1–s4/h1–h4/i1–i5), round-trip parse/emit; null = обычный WG
node_spec_emit.dart          # emit()/toUri() impl на вариант (NodeSpec → SingboxEntry); parity-tested
singbox_entry.dart           # sealed SingboxEntry = Outbound | Endpoint (WireGuard → Endpoint)
node_entries.dart            # NodeEntries{main, detours} — результат getEntries
emit_context.dart            # abstract EmitContext: allocateTag/addEntry/selector+auto регистрация
template_vars.dart           # TemplateVars — глобальные emit-флаги (tls_fragment/mux/sniOverride)
tls_spec.dart                # TlsSpec + RealitySpec (utls/reality/alpn) → toSingbox()
transport_spec.dart          # sealed TransportSpec (Ws/Grpc/Http/HttpUpgrade/Xhttp); XHTTP — нативный
                             #   emit (§097, ядро with_xhttp: mode/x_padding_bytes/no_grpc_header)
node_warning.dart            # sealed NodeWarning + WarningSeverity (parse/emit warnings)
validation.dart              # sealed ValidationIssue + ValidationResult (dangling refs/empty urltest → fatal)
parser_config.dart           # модели wizard_template.json: WizardTemplate/PresetGroup/SelectableRule/WizardVar
custom_rule.dart             # sealed CustomRule = Inline|Srs|Preset (routing rules; →§090, см. Обзор)
server_list.dart             # sealed ServerList = SubscriptionServers | UserServer
subscription_meta.dart       # SubscriptionMeta — userinfo-заголовки (traffic/expire/title/update-interval)
app_info.dart                # AppInfo — метаданные установленных приложений (native getInstalledApps)
background_mode.dart         # enum BackgroundMode (never|lazy|always) — Doze-поведение туннеля
tunnel_status.dart           # TunnelStatus enum + TunnelStatusEvent (native status mapping + errorReason)
debug_entry.dart             # DebugEntry + DebugSource/Level/Filter (унифицированная лог-строка)
home_state.dart              # immutable HomeState + copyWith; configModel: ParsedConfig (§091,
                             #   re-parse на смену configRaw); NodeSortMode (default/latency/name/
                             #   manual — §100: manual в карусели и меню, mode + manual order
                             #   персистятся в settings_storage); memoized sortedNodes
config_node.dart             # §091 ConfigNode + ParsedConfig — структурная мета нод собранного
                             #   конфига (type/section/detour/isMarkedDetour/detourRefCount/raw);
                             #   §102/§103 eager transportLabel/securityLabel (transport-слот +
                             #   TLS/Reality/+Vision, awg/awg2); parsed раз на смену configRaw
channel.dart                 # §125 Channel — конфигурируемые каналы (vpn-1 неудаляем, N∈1..10)
auto_select.dart             # §322 членство узла автовыбора (папки) + его параметры
import_rule.dart             # §302 ImportRule — правила обработки узлов подписки на импорте
dns_ref.dart                 # §294 typed model dns_options.servers[]/rules[] (kind-discriminated refs)
memory_limit_setting.dart    # §271 memory limit ядра (SetupOptions.oomMemoryLimit)
stop_reason.dart             # §279 типизированная причина аварийного стопа/revoke
traffic_snapshot.dart        # снимок агрегатов трафика для главного экрана
ui_msg.dart                  # UiMsg — пользовательское сообщение с ленивым рендером (l10n §279)
```

#### `controllers/` — ChangeNotifier-брокеры состояния

```
home_controller.dart         # главный VPN-брокер: _state/_vpn/_cc; статус-handler; start/stop/
                             #   reconnect/reload; CommandClient groups (push + getGroups-pull);
                             #   selection-сеттеры; lifecycle
home_controller/config_io.dart          # part _ConfigIoMixin: load/saveParsedConfig, import, configChangedNeedRestart
home_controller/heartbeat.dart          # part _HeartbeatMixin: watchdog по тишине CommandClient status-стрима
                             #   (§122, без HTTP-poll'а) + dead-tunnel detection
home_controller/ping_orchestration.dart # part _PingMixin: single/group/mass URLTest, 10 worker'ов, epoch-cancel
subscription_controller.dart            # подписки: List<ServerList>, add/remove/rename/toggle/move
                                        #   (§098 drag-reorder), fetch, buildConfig; §101 — rehydrationDone
                                        #   (фикс стартовой гонки rehydrate↔bootstrap) + empty-fetch guard
                                        #   (HTTP 200 с 0 нод не затирает кэшированные ноды)
subscription_controller/subscription_entry.dart # part SubscriptionEntry: ChangeNotifier-обёртка над immutable ServerList
```

#### `screens/` — UI (тонкий экран + под-папка)

```
home_screen.dart             # композиционный корень (518): владеет брокерами, side-effects, rebuild/reconnect
home/node_list_presenter.dart   # §089 presenter: §048 фильтр/split + §070 frozen-sort cache +
                                #   chip-options; §103 variantsOfTag + канонич. порядок variant-чипов
home/node_filter_view_model.dart# ChangeNotifier VM: regex/protocol/variants(§103)/sub/ping фильтры,
                                #   единый !-negate на категорию (§096) + detour tri-state (чекбокс+!,
                                #   §096), §083 per-channel память
home/node_filter.dart           # pure NodeFilter helper (match-предикаты + inverts) + extractEmojis
home/node_actions.dart          # long-press действия ноды; §099 — copy-JSON варианты (node / server /
                                #   server+detours(N)) перенесены в dropdown внутри View JSON
home/home_menus.dart            # showSortOptionsMenu (+ Custom/manual §100) + showPingSettings
home/home_dialogs.dart          # top-level dialog/snackbar функции (update/permission/battery/revoked)
home/restore_backup.dart        # empty-state quick-restore flow (SAF)
home/subscription_lookup.dart   # §091 prefix-фильтр: нода принадлежит подписке ⇔ tag.startsWith
                                #   ('$prefix '); заменил §077 reverse-map по node-спискам
home/channel_filters.dart       # §083 immutable снимок match-фильтров канала (+ variants §103)
home/filter_widgets.dart        # filter chip/row виджеты (viz-toggle чипы §095, NegateToggle §096)
home/widgets/                   # node_list · home_controls · home_drawer (nav-хаб) · nodes_header ·
                             #   traffic_bar · status_chip · progress_banner · filter_panel (§095
                             #   Filter mode: табы Regex/Protocol/Subscribes/Settings + чипы-сводка)
                             #   · add_server_cta
routing_screen.dart          # routing-конфиг (598) + LazyPersistMixin + _RoutingSrsCacheMixin (part)
routing_screen/                 # widgets/ (custom_rule/preset_catalog/route_final/routing_group/srs_status) + menus
dns_settings_screen.dart     # DNS-настройки (592) + editor-sheets + dns_server_resolver + widgets/
custom_rule_edit_screen.dart # CustomRule editor (456) + custom_rule_edit/ (edit_controller, tabs/, sections/, widgets/)
subscription_detail_screen.dart # детали подписки (431, TabController) + widgets/ (settings/source/meta/node_list)
subscriptions_screen.dart    # список подписок (445) + widgets/ + helpers (clipboard/paste/share/context-menu)
stats_screen.dart            # хост TabBarView: Overview + Connections + LiveEvents (§288 — PerAppTrace убран)
stats_screen/overview_tab.dart  # Overview-таб + overview_models
stats_screen/                   # §264-266 Traffic Processing: trace_explorer + profiler_filter(+_sheet,
                             #   profiler_filters) + traffic_event_detail_sheet · aggregate_detail_sheet ·
                             #   memory_detail_sheet · routing_section (детали — features/044)
live_events_tab.dart         # Stats-субтаб «Profiler» (371): event_tile/recording_header/unattributed_banner
tun_apps_tab.dart            # per-app VPN routing субтаб (384) — шарится Stats/Routing
app_settings_screen.dart     # настройки приложения (516): General/Diagnostics табы + update_status_row
backup_screen.dart           # export/import снапшота (229) + export_card/import_card/preview
lazy_persist_mixin.dart      # LazyPersistMixin — отложенный persist на settings-экранах (flush на возврат)
# монолитные одиночные экраны (без под-папки, 60–505): about · add_server_wizard ·
#   app_picker · auto_group_edit (§322 узел автовыбора) · channel_edit (§125) ·
#   config · connections · crash_reports (§316 Go-паники ядра) · debug ·
#   dns_server_edit · folder_detail (§234 папка серверов, зеркалит
#   subscription_detail) · node_settings · oom_reports (§318 OOM-снимки ядра) ·
#   outbound_view · settings · speed_test · vpn_mode_tab (§119) ·
#   warp_experiment (§284 endpoint generator) · warp_wizard (§130 WARP/MASQUE мастер)
# owner_navigation.dart            # §258 общий переход «config-тег → экран владельца»
# probe_gate_mixin.dart            # §296 VPN-гейт probe: два CommandServer на процесс невозможны
```

#### `services/` — сервисный слой

```
parser/                      # Parser v2 (text → NodeSpec)
  body_decoder.dart          #   Layer-1: raw body → sealed DecodedBody (base64 sniff + JSON-flavor)
  amnezia_link.dart          #   Amnezia vpn:// → WG/AWG INI-тексты (base64url+qCompress, §110)
  parse_all.dart             #   Layer-2: exhaustive switch DecodedBody → List<NodeSpec> (per-line null-skip)
  uri_parsers.dart           #   barrel + parseUri scheme-dispatcher
  uri_parsers/<proto>.dart   #   per-protocol URI→NodeSpec (vless/vmess/trojan/ss/hy2/naive/tuic/ssh/socks/wg/masque)
  json_parsers.dart          #   parseXrayElement + parseSingboxEntry (round-trip)
  singbox_config.dart        #   §368: sing-box config/массив конфигов → узлы+группы+detour
                             #   (паритет с Xray-веткой: 2 прохода, дедуп, синонимы тегов)
  ini_parser.dart            #   WireGuard INI → wg:// URI → WireguardSpec
  transport.dart             #   parseTransport (query→TransportSpec) + transportToQuery
  uri_utils.dart             #   shared: base64-safe decode, newUuidV4, tagFromLabel, packet-encoding
                             #   allow-list; awgClampMtu (§097 — клиентский MTU AWG-нод ≤1280)
builder/                     # NodeSpec + template → sing-box config
  build_config.dart          #   buildConfig() orchestrator → BuildResult; _BuildCtx (EmitContext + tag allocator)
  server_list_build.dart     #   per-subscription emit: detour policy, tag allocation, selector/auto регистрация
  if_engine.dart             #   §120 typed template engine: подстановка vars + #if-конструкт (общее ядро)
  preset_expand.dart         #   expandPreset (CustomRulePreset → fragments, @var) + mergeFragments (§033);
                             #   §265: param globalVars — ref-vars {"ref":…} берут значение из глобального userVars, не varsValues
  normalize_pinned_presets.dart   #   §264 pinned-пресеты нормализуются в начало storage-order
  rule_set_registry.dart     #   реестр route.rule_set + route.rules; tag-уникальность
  validator.dart             #   validateConfig: dangling refs, empty urltest → ValidationResult
  post_steps.dart            #   barrel (part): post-обработки ниже
  post_steps/tls_transforms.dart  #   applyMixedCaseSni + applyTlsFragment (§028)
  post_steps/custom_rules.dart    #   applyAllCustomRules (preset/inline/srs в storage order, §062)
  post_steps/dns_rules.dart       #   applyCustomDns / resolveDnsRulesList (§061+§033)
  post_steps/dns_servers.dart     #   resolveDnsServersList/Bodies (§043+§044)
  post_steps/heal_dangling_detours.dart # §172 healDanglingDetours: detour∉allTags снимается (warning),
                             #   зовётся перед validateConfig — битый detour из подписки деградирует, не роняет конфиг
  post_steps/heal_dangling_resolve_servers.dart # §247 деградация битых server-ссылок resolve-правил
  post_steps/heal_legacy_dns_strategy.dart      # §246 hotfix: несовместимая пара в dns.rules
  post_steps/heal_unknown_utls_fingerprints.dart# §281 страховка от неизвестного uTLS fingerprint
  post_steps/heal_invalid_reality.dart          # §343 страховка от битого REALITY-блока (short_id)
  post_steps/tun_packages.dart    #   applyTunPackages — OS split-tunnel (§046, последний шаг)
subscription/                # fetch/auto-update подписок
  sources.dart               #   sealed SubscriptionSource (Url/File/Clipboard/Inline/Qr) + fetch (3-try backoff);
                             #   §129 file-подписка: url=file:<uuid> (input_helpers.isFileSubscription) читается из HttpCache-снапшота
                             #   (не сеть); смена источника online↔file транзакционна (updateSourceAt, старый снапшот держится до успеха)
  auto_updater.dart          #   5-триггерный refresh + per-sub interval + retry/fail-caps + dedup (§027)
  http_cache.dart            #   on-disk кэш последнего raw body + headers (offline rehydrate);
                             #   §101 — атомарная запись tmp→rename (kill-safe при unawaited save)
  input_helpers.dart         #   isSubscriptionUrl/isDirectLink (вкл. awg://, §097)/isWireGuardConfig/isFileSubscription (§129) (paste UX)
settings_storage.dart        # фасад над lxbox_settings.json — тонкие делегаты в part-файлы:
settings_storage/io.dart            #   атомарный load/save/recovery (main→.bak→{}, §072)
settings_storage/vars.dart          #   vars-домен + Wi-Fi history (§051)
settings_storage/sources_rules.dart #   server_lists (+v1 migration), rules/groups, custom_rules
settings_storage/network.dart       #   route_final/excluded/dns/ping_options (§040/§061)
settings_storage/backup_tun.dart    #   снапшот (§031) + tun-apps split-tunnel (§046)
settings_storage/channels.dart      #   §125 каналы (Channel CRUD + seed vpn-1)
settings_storage/native_prefs.dart  #   NativePrefsKeys — мост в SharedPreferences Kotlin-стороны
settings_storage/vpn_mode.dart      #   §119 VPN mode (allow/deny списки per-app)
settings_storage/warp.dart          #   §025/§130 WARP/MASQUE аккаунты + пул генератора
traffic_profiler.dart        # TrafficProfiler singleton (1243, см. Обзор): сессии, rolling buffer, SSE
traffic_profiler/models.dart        #   part: TrafficEvent/Session + enums + JSON
traffic_profiler/internal.dart      #   part: _ConnSnapshot correlation-структура (§180 _DnsAccumulator/§044 _ConnMeta выпилены)
debug/                       # localhost HTTP Debug API (§031)
  bootstrap.dart             #   applyDebugApiSettings — строит DebugContext, рестартит сервер
  debug_registry.dart        #   нуллабельные refs на контроллеры (bind в HomeScreen.initState)
  context.dart               #   DebugContext — per-handler инъекция (requireHome/Sub, clock, log, config)
  contract/errors.dart       #   sealed DebugError (NotFound/Unauthorized/Conflict/…) — transport-agnostic
  transport/server.dart      #   DebugServer — HttpServer на 127.0.0.1, Router+pipeline, lifecycle
  transport/request.dart     #   DebugRequest — immutable snapshot, body read once (maxBodyBytes)
  transport/response.dart    #   sealed DebugResponse (Json/RawJson/Bytes/Stream/Error)
  transport/router.dart      #   longest-prefix mount/resolve
  transport/pipeline.dart    #   onion-chain middleware runner
  transport/config.dart      #   DebugServerConfig (port/token/timeout/maxBody/unauth-paths)
  transport/middleware/      #   error_mapper · access_log · host_check · auth · timeout
  handlers/                  #   /state /settings /action /profiler /rules /subs /config /logs /device
                             #     /files /diag /backup /wifi_history /help /ping /warp /channels (§275)
                             #     /folders (§238) /pool (§208) (+ _shared CRUD-хелперы)
  serializers/               #   home_state · storage (denylist scrubber) · rules · subs (URL-маскинг)
warp/                        # §025/§130 WARP + MASQUE-транспорт (питает warp_wizard_screen)
  warp_client.dart           #   регистрация в Cloudflare (POST /reg): X25519-приватник не покидает телефон
  warp_account.dart          #   WARP-аккаунт (client_id→reserved, ключи)
  warp_endpoint_picker.dart  #   пул WARP-эндпоинтов + рандом endpoint/SNI (§148 курированные блоки; БЕЗ пробы)
  scan/                      #   §284/§305 генератор нод: рандом-посев (IP × port × proto × SNI) → папка «WARP GENERATOR»; пул scan_pool.dart ← assets/warp_endpoints.json
  masque_account.dart · masque_keys.dart · masquerade_params.dart  #   §130 MASQUE (Cloudflare QUIC/CONNECT-IP) — эмит MasqueSpec
migration/proxy_source_migration.dart  # one-shot v1 proxy_sources → v2 server_lists
nav/home_return_observer.dart          # глобальный NavigatorObserver (§076): rebuild на возврат к home
app_log.dart                 # AppLog ChangeNotifier-singleton: per-source ring buffers + persistent warn/error (§043)
app_info_cache.dart          # AppInfoCache — session-кэш AppInfo по package + revision ValueNotifier
json_clone.dart              # deepCopyJson/deepCloneJson/deepEqualsJson (§089 P6 — общий для builder/backup)
format_utils.dart            # formatBytes/formatDuration/formatTime (канонические форматтеры)
relative_time.dart           # relativeTime(now, past) — "2h ago" (pure, тестируемый)
url_mask.dart                # maskSubscriptionUrl — scheme://host/*** для логов/шеринга
tag_resolver.dart            # §085 TagResolver — единый владелец display-тега (displayTag/isDetourMarker/strip)
rule_name_resolver.dart      # §165 — маппинг ядровой rule.String() (лоссовая, обрезает списки >3) →
                             #   custom_rules[].name для Stats→Traffic by Rule / Conns; нормализация + indexOf + кэш промахов
template_loader.dart         # wizard_template.json loader (singleton, deep-copy на билд)
rule_set_downloader.dart     # download+cache remote .srs (parallel, atomic tmp+rename, retry)
backup_service.dart          # export/import полного снапшота настроек (§031)
update_checker.dart          # GitHub-релиз check + dismissed-version guard (см. §090 по half-wired stub)
node_emoji.dart              # §094 emoji-теги: палитра + protocol-default emoji + вставка в rawBody/tag
haptic_service.dart · community_servers_loader.dart · dump_builder.dart · url_launcher.dart ·
config_dirty_check.dart · error_humanize.dart · error_format.dart · parse_hints.dart ·
clash_log_pump.dart · logcat_reader.dart · stderr_reader.dart · exit_info_reader.dart ·
selectable_to_custom.dart · version_info.dart · wifi_history_listener.dart  # вспомогательные
automation/                  # §047 Dart-сторона automation (дополняет Kotlin Locale/Tasker plugin):
  automation_dispatcher.dart #   диспетчер входящих команд (start/stop/toggle/select-node/…)
  event_emitter.dart         #   исходящие события (VPN up/down, sub-refresh) с throttle (default OFF)
  handlers.dart              #   обработчики команд поверх контроллеров
l10n/                        # §279/§285 подсистема локализации (см. раздел «Локализация (l10n)»)
  get_local_text.dart        #   GetLocalText (natural-key движок: .s/.plural, printf, fallback=ключ); GetLocalText.en
  plural_resolver.dart       #   PluralResolver + En/RuPluralResolver (CLDR формы плюрала)
  locale_controller.dart     #   LocaleController — владелец пайплайна смены локали + глобальный getLocalText
  template_overlay.dart      #   TemplateOverlay.apply/extract — pre-parse оверлей шаблона
  app_language_reconcile.dart#   трёхсторонний reconciliation LocaleManager↔storage (Android 13+)
  template_aware_state.dart  #   mixin: перечитывание шаблона в didChangeDependencies по локали
project_links.dart           # §362 — единственный источник ссылок проекта + @плейсхолдеры
install_source.dart          # §390 — канал установки (github/play/fdroid): dart-define, иначе
                             #   по installingPackageName. Определяет updateUrl (куда за апдейтом)
support/                     # §105/§356/§357 support-лента + активное время
  support_message.dart       #   модели ленты (i18n/since_version/mark_read) + выбор/markRead/snooze
  support_nav.dart           #   §357 псевдопротокол lxbox://action:payload (route:/add:)
  support_state.dart         #   персист support-стейта (SupportState.I): read/baseline/снуз
  active_time_tracker.dart   #   счётчик наработки: нативный аптайм §187 + legacy wall-clock
platform_channels.dart       # §141 — имена MethodChannel/EventChannel (single source: Dart↔Kotlin)
process_name.dart            # §154 — резолв package→имя процесса (профайлер-атрибуция)
profile_dump_writer.dart     # §207 — сериализация pprof-дампа (goroutine/CPU) на диск
```

#### `widgets/` — кросс-экранные

```
node_row.dart                # строка ноды: ACTIVE pill + proto label + ping (принимает NodeViewItem, §068)
node_view_item.dart          # NodeViewItem — immutable view-row (статик-мета + динамика, §068)
emoji_picker_button.dart     # §094 — popup-палитра emoji (node_settings, add-server wizard)
reorder_grab_strip.dart      # §098 — единый grab-strip для drag-reorder (routing/DNS rules ·
                             #   subscriptions · node list в manual-sort mode §098/§100)
outbound_picker.dart · template_var_list.dart · core_logs_hint_banner.dart ·
wifi_entry.dart · wifi_manual_add_dialog.dart · wifi_permission_dialog.dart · wifi_saved_picker_sheet.dart
```

### `app/android/app/src/main/kotlin/com/leadaxe/lxbox/`

```
MainActivity.kt              # FlutterActivity: регистрирует VpnPlugin; /utils + /wifi_history каналы;
                             #   VPN-consent flow; QS-tile/shortcut quick actions
vpn/VpnPlugin.kt             # Flutter-плагин (1084, см. Обзор): MethodCallHandler всех /methods;
                             #   status+coreLog EventChannel sinks; §122 cc-методы (ccConnectScreen/
                             #   ccUrlTestOutbound/ccGetGroups/…) + lxbox/cc/* EventChannel sinks;
                             #   statusReceiver мост; app-icon encode
vpn/BoxCommandClient.kt      # §122 — управляющий канал UI↔ядро через libbox CommandClient (три клиента:
                             #   statusClient/screenClient/profilerClient; addCommand-подписка + write*-колбэки;
                             #   §163/§164 setStatusInterval-энергомодель). Заменил Clash HTTP API.
vpn/BoxVpnService.kt         # Android VpnService + PlatformInterface side (§049-split, тонкий):
                             #   §122 — владеет cc*Sink (status/outbounds/groups/connections/dns §180 push в Dart);
                             #   openTun (Builder.establish, allowBypass §069, per-app routes); forwards в BoxService
                             #   §119: openTun зовётся libbox'ом ТОЛЬКО при наличии tun-inbound. Режим Proxy
                             #   (vpn_mode=proxy, config без tun) → нет openTun → нет establish → нет VPN-туннеля.
                             #   Foreground/protect/override tun-agnostic → proxy-режим = config-only, Kotlin не трогаем.
vpn/BoxService.kt            # CommandServerHandler — владеет libbox runtime (fileDescriptor/commandServer
                             #   AtomicReference, serviceScope); startSingbox/doStop/serviceReload; setStatus broadcast
vpn/BoxApplication.kt        # Application: async Libbox.setup (libboxReady barrier); singleton wifiObserver
vpn/CrashRecovery.kt         # §334 — «прошлый запуск упал» (непустой CrashReport-lxbox.log) → сброс cache.db +
                             #   tempPath. Детект СТРОГО до Libbox.setup: тот архивирует репорт и затирает файл
vpn/PlatformInterfaceWrapper.kt # libbox PlatformInterface: localDNS→LocalResolver, findConnectionOwner, readWIFIState
vpn/PProfClient.kt           # §207 — libbox PProfServer (goroutine/CPU dump, порт 6060..6065; loopback-only)
vpn/DefaultNetworkMonitor.kt # §087: detect genuine iface switch (prev!=new), debounce 1500ms → resetNetwork
vpn/DefaultNetworkListener.kt# ConnectivityManager.NetworkCallback в coroutine-actor (порт SagerNet)
vpn/LocalResolver.kt         # LocalDNSTransport — DNS-запросы bound к underlying network (не tun)
vpn/ConfigManager.kt         # file-based config store (filesDir) + notificationTitle
vpn/ServiceNotification.kt   # foreground-service notification (typed SPECIAL_USE на API34+); §182 action-кнопки Stop/Reconnect (broadcast ACTION_STOP / ACTION_RECONNECT)
vpn/VpnStatus.kt             # enum Stopped/Starting/Started/Stopping (native-сторона статуса)
vpn/BootReceiver.kt          # BOOT_COMPLETED auto-start + SharedPreferences native-тогглов
vpn/LxBoxTileService.kt      # QS-tile toggle (§032) с оптимистичным рендером
vpn/QuickShortcuts.kt        # dynamic launcher shortcuts (Connect/Disconnect)
vpn/LxBoxIntentReceiver.kt   # §047 raw broadcast API: 9 incoming actions, опц. permission-gate, setEnabled
vpn/WifiInfoReader.kt        # §051 единый источник Wi-Fi SSID/BSSID (permission preflight, sealed Result)
vpn/WifiNetworkObserver.kt   # §051 auto-record: NetworkCallback → WifiHistoryBridge → Dart onWifiSeen
vpn/PermissionUtils.kt · Extensions.kt  # SDK-gated permission check; мелкие Kotlin-расширения

automation/                  # §047 Locale/Tasker plugin (FIRE_SETTING/QUERY_CONDITION) — см. ../docs/AUTOMATION.md
automation/LocaleApi.kt              #   константы стандарта twofortyfouram + JSON bundle (de)serialize + cachedNodes/Groups
automation/LocaleSettingReceiver.kt  #   FIRE_SETTING → shared action-handlers (start/stop/toggle напрямую, остальное → VpnPlugin.handleAutomationAction)
automation/LocaleConditionReceiver.kt#   QUERY_CONDITION → currentStatus/active-кеш → result code (SATISFIED/UNSATISFIED/UNKNOWN)
automation/LocaleQuickActionActivity.kt # one-tap Start/Stop/Toggle (Theme.NoDisplay, headless setResult+finish; команда по alias)
automation/LocaleSettingEditActivity.kt # «Custom…» edit-экран: RadioGroup команд + селектор нод/групп из native-кеша
automation/LocaleConditionEditActivity.kt # edit-экран условия (VPN up / active node= / active group=)
```

---

## Потоки данных

### 1. Запуск VPN

```
User tap Start (toggle button)
  │  HapticService.onConnectTap()
  ↓
HomeScreen._startWithAutoRefresh()
  │  (no HTTP fetch — auto-update is a separate concern, spec 027)
  ↓
HomeController.start()
  ↓
BoxVpnClient.startVPN() → MethodChannel → VpnPlugin
  ↓
BoxVpnService.onStartCommand()
  ├─ resetScope() → fresh serviceScope
  ├─ startForeground notification
  └─ serviceScope.launch {
       startCommandServer()
       DefaultNetworkMonitor.start(serviceScope)
       Libbox.newService(config) → libbox creates tunnel
     }
  ↓
Broadcast STATUS_CHANGED → "Started"
  ↓
EventChannel → Dart: HomeController._handleStatusEvent()
  ├─ state.configChangedNeedRestart = false
  ├─ HapticService.onVpnConnected() — medium impact
  └─ AutoUpdater.onVpnConnected() — triggers refresh after 2 min
  ↓
CommandClient: connectScreen() → groups push-стрим (selector only) +
  getGroups() unary-pull (детерминированное наполнение, push дырявый)
  ↓
UI updates: group dropdown, node list, traffic bar
```

### 2. Subscription добавление + авто-конфиг

```
Paste/QR/file → SubscriptionsScreen._add() | _pasteFromClipboard()
  ↓
SubscriptionController.addFromInput(text)
  ├─ isSubscriptionUrl → add SubscriptionServers entry + _fetchEntry
  ├─ isWireGuardConfig → parseWireguardIni → UserServer entry
  ├─ isDirectLink → parseUri → UserServer entry
  └─ isJsonOutbound → parseAll(decode(json)) → UserServer entries
  ↓
_persist() — writes to lxbox_settings.json
  ↓
_regenerateAndSave() — auto (v1.3.1+)
  ├─ generateConfig() — no HTTP, local assembly only
  └─ homeController.saveParsedConfig(config)
        ├─ changed = canonical(new) != canonical(state.configRaw)   (§116 text diff)
        ├─ needRestart = changed && (tunnelUp || prev)              (§323 — no longer sticky
        │                                                            when changed == false)
        └─ if (needRestart && tunnelUp): ask the core                (§324)
              formatConfig(saved + OverrideOptions) vs runningConfigRaw
                fresh   → needRestart = false   (cosmetic-only difference)
                stale   → keep
                unknown → keep (conservative: core could not answer)
  ↓
UI refreshes row (subtitle: "<PROTOCOL> server") + snackbar
  ↓
If tunnelUp: pink "Config changed — restart VPN" banner (spec 003 §8a)
```

### 3. Subscription auto-update (spec 027)

```
Trigger: appStart | vpnConnected+2min | periodic(1h) | vpnStopped | manual(force)
  ↓
AutoUpdater.maybeUpdateAll(trigger, force)
  ├─ if _running → skip (dedup)
  ├─ candidates = entries.filter(_shouldUpdate)
  │   └─ _shouldUpdate: enabled ∧ !frozen(fails>=5) ∧ !minRetry(15min) ∧ (force ∨ interval elapsed)
  │       (§129: подписки с url=file:<uuid> auto-updater пропускает — они читаются из HttpCache-снапшота, не из сети)
  └─ for entry in candidates:
       ├─ _inFlight.contains(url) → skip
       ├─ refreshEntry(entry, trigger)  → _fetchEntryByRef
       │    ├─ lastUpdateStatus==inProgress → skip (crash-safe guard)
       │    ├─ mark inProgress + persist
       │    ├─ parseFromSource(UrlSource)
       │    ├─ HttpCache.save(url, body, headers)
       │    └─ copyWith(lastUpdated, lastUpdateStatus, nodes, consecutiveFails)
       └─ sleep 10s ± 2s (between subs)
```

### 4. Subscription metadata

```
HTTP Response Headers:
  profile-title: base64:...           → subscription display name
  subscription-userinfo: upload=N; ...→ traffic quota + expire
  profile-update-interval: 24         → updateIntervalHours
  support-url: https://t.me/...
  profile-web-page-url: https://...
  content-disposition: filename="..." → fallback for title (v1.3.0+)
  ↓
Stored in SubscriptionMeta → SubscriptionServers.{name, meta, updateIntervalHours}
  ↓
Displayed in:
  - Subscription list row: "124 nodes · 🔄 24h · 🕐 3h ago · (2 fails)"
  - Subscription detail → Subscription block (URL, interval picker, status, refresh)
  - Source tab: live GET with headers view
```

### 5. Persistent storage

Состояние L×Box живёт в двух местах с разной семантикой:

- **`wizard_template.json`** — **catalog**: что вообще существует (preset'ы, vars, sections, default DNS-серверы). Bundled в APK, меняется в коммите. Полная схема — [TEMPLATE.md](./TEMPLATE.md).
- **`lxbox_settings.json`** — **user-state**: что юзер выбрал/настроил (vars override, custom_rules, enabled_groups). Меняется в runtime через UI / Debug API. Полная схема — [STORAGE.md](./STORAGE.md).

#### Catalog (template, bundled in APK)

```
app/assets/wizard_template.json     # rootBundle.loadString(), template_loader.dart
├── parser_config           # §026 — version + reload interval
├── dns_options             # §043+§044 — default DNS servers + rules
├── ping_options            # §040 — default URL + presets
├── speed_test_options      # §015 — speed-test endpoints
├── group_templates         # §267 — magic_nodes реестр + channel/auto шаблоны (SEED для channels[])
├── default_channels[]      # §267 — сид каналов (vpn-1..2); билдер читает channels[] из storage
├── sections[]              # §022 — Wizard UI chapters (vars сгруппированы по темам)
├── config                  # нативная sing-box-секция с @var-плейсхолдерами
│   ├── log / dns / inbounds / endpoints / outbounds / experimental
│   └── route               #   rules[] / rule_set[] / final / default_domain_resolver
└── selectable_rules[]      # §033 — catalog preset'ов: block-ads, ru-direct,
                            #   ru-inside, bittorrent-direct, private-ip-direct
```

#### User-state (на устройстве)

```
<getApplicationDocumentsDirectory>/
├── lxbox_settings.json     # SettingsStorage (Dart) — главный файл состояния:
│                           #   vars / server_lists / custom_rules /
│                           #   dns_options / ping_options /
│                           #   route_final / channels[] (§125, replaces enabled_groups) /
│                           #   excluded_nodes (§048 sandbox) / last_global_update /
│                           #   presets_migrated / channels_migrated
├── singbox_config.json     # ConfigManager (Kotlin) — финальный sing-box JSON
├── http_cache/             # HttpCache — сырое тело + headers подписок
│   └── <sha1(url)>.{body,headers}
├── rule_sets/              # §011 — кэш бинарных .srs
│   └── <tag>.srs
├── applog.txt              # §038/§043 — JSON-lines, 200 строк / 64KB ring
└── corelog.txt             # §043 — JSON-lines, 200 строк / 64KB ring

SharedPreferences (Android):
├── app_theme_mode                       # Flutter UI prefs (haptic_enabled → vars, §159)
└── boxvpn_boot.{auto_start_vpn, keep_vpn_on_exit, background_mode,
                 core_logs_enabled, allow_bypass, auto_redirect,
                 has_tun}                # §189 — ЗЕРКАЛО JSON-секции native_prefs
                                         # (рабочая копия в оперативке). Истина —
                                         # lxbox_settings.json. has_tun (§192) —
                                         # вычисляемое из vpn_mode, только тут.
```

##### Три уровня хранения native-prefs (§189 / §192)

Шесть Android-настроек (`auto_start`/`keep_on_exit`/`background_mode`/
`core_logs_enabled`/`allow_bypass`/`auto_redirect`) живут на трёх уровнях:

| Уровень | Где | Роль |
|---|---|---|
| **диск / истина** | `lxbox_settings.json` → секция `native_prefs` | источник правды; backup; переживает всё |
| **оперативка** | native `SharedPreferences` `boxvpn_boot.*` | рабочая копия для **Dart-less моментов** — когда Flutter-движка нет |
| **in-memory** | `SettingsStorage._cache` | lazy-loaded кэш JSON в Dart-процессе |

**Зачем нужна native-копия:** часть кода исполняется когда Flutter-движок
недоступен и JSON прочитать нечем — `BOOT_COMPLETED` (`BootReceiver` авто-старт),
swipe `onTaskRemoved` (keep-on-exit решение), `openTun`/`establish` (allow_bypass,
per-app). Эти точки читают native-копию **синхронно**.

**Поток write-through + sync на старте:** любой `SettingsStorage.setNativeBool` /
`setNativeBackgroundMode` пишет JSON (первично) → зеркалит в native (method-channel);
native **никогда** не пишет JSON. На старте (`bootstrapAndSyncNativePrefs()` из
`main.dart`): нет секции → bootstrap (native⇒JSON seed, единственный native⇒JSON);
есть секция → sync (JSON⇒native, диск перезаливает оперативку — расхождение само
чинится). Все писатели (UI, импорт `backup_service`, Debug API) обязаны идти через
этот слой — прямые native-записи эфемерны (sync откатит). Реализация —
[`lib/services/settings_storage/native_prefs.dart`](../app/lib/services/settings_storage/native_prefs.dart).

**`has_tun` (§192)** — седьмой native-ключ, **производное** от `vpn_mode` (§119):
`vpn`/`vpn_proxy` → `true`, `proxy` → `false`. Зеркалится при смене режима и на
старте; гейтит `VpnService.prepare()` (в proxy-режиме `prepare` не зовётся — он зря
забрал бы VPN-слот и отозвал чужой активный VPN). Вычисляемое, потому **не** в
backup-блоке и **не** в JSON-секции `native_prefs` — живёт только в `boxvpn_boot.has_tun`.

#### Builder (template + user-state → final config)

`build_config.dart` мерджит template `config`-секцию + `selectable_rules[*]` (через `expandPreset`) + `dns_options.{servers,rules}` (через resolvers §061/§044) + `channels[]` из storage (§125 — `_buildChannelGroups`: per-channel `node_filter`-regex по node-tag'ам из `server_lists`, опции direct/block, auto-двойник) + `vars`-substitution → пишет финальный `singbox_config.json` для libbox.

**Idle-suspend (§128/§215, ядро SPEC 020).** Настройка threshold'а (storage-ключ `route_idle_suspend`, default `30s`, `''` = off) прокидывается билдером в `route.lx_idle_suspend` финального конфига. Требует ядро с build-тегом `with_lx_idle_suspend` (в AAR он есть; при его отсутствии непустое `route.lx_idle_suspend` роняет старт — детали см. `KERNEL.md`). Управляется через сетевые настройки (`settings_storage/network.dart`).

One-shot миграции (`SettingsStorage`):
- `proxy_sources` → `server_lists` (v1 → v2, §033) — `migrateProxySources` на первом чтении.
- `app_rules` → `custom_rules` с `packages` (до v1.3.2 → §030) — `_absorbLegacyAppRules`.
- `enabled_rules + rule_outbounds` → `custom_rules` (до §030) — в `RoutingScreen._load`, гард `presets_migrated`.
- `dns_options.servers[]` shape: pre-§043 → §043 → §044 — `_migrateLegacyDnsServers` в builder post-steps.

Sensitive-поля при `GET /state/storage` фильтруются allow-list'ом в `services/debug/serializers/storage.dart` (`debug_token`, subscription URLs, support/web URLs из `meta`). Подробности — STORAGE.md §"Debug API exposure".

---

### 6.5. Traffic profiler (§044 / §048)

`TrafficProfiler` — singleton ChangeNotifier, который держит system-wide
rolling buffer событий. Всё in-memory; persist принципиально не делается. Spec: [`docs/spec/features/044 per-app traffic profiler/spec.md`](./spec/features/044%20per-app%20traffic%20profiler/spec.md). Историческая справка по per-app-режиму: [`docs/features/per-app-trace.md`](./features/per-app-trace.md).

```
              ┌────────────────────────────────────────┐
              │  TrafficProfiler (singleton)            │
              │   _active: Session? + _completed: Q[5]  │
              └────────────────────────────────────────┘
                     ▲                    ▲
                     │ events             │ events
                     │                    │
        ┌────────────┴────────┐  ┌────────┴──────────────────────┐
        │ DNS-стрим (§180)    │  │ Connections push (§168)       │
        │  CcChannel.dnsQueries│  │  CcChannel.connections        │
        │  (profilerClient,   │  │  (profilerClient,             │
        │   SPEC 018)         │  │   diff vs prev snapshot)      │
        └─────────────────────┘  └────────────────────────────────┘
                     │                    │
                     ▼                    ▼
        dnsResolve/dnsFail         TCP/UDP open/close events
        attribution ИЗ ЯДРА        attribution из ядра
        (processInfo) + cnameChain (CcConnection.packageName,
        + dnsServer/outbound(rc.10) chains §174, detours §178)

              ┌────────────────────────────────────────┐
              │ _globalRollingBuffer  (append-only)     │
              │  +  byDomain / byIp aggregates          │
              │     (computed on-demand)                │
              └────────────────────────────────────────┘
                     │
        ┌────────────┴───────────────────────────────────────────┐
        ▼                              ▼                         ▼
  Profiler tab              Debug API /profiler/live*    SSE /profiler/live/stream
  (TraceExplorer:           (start, stop, state,          (live-push для
   поток/Aggregated +        live, unattributed)           external clients)
   фильтр по приложениям)
```

> Per-app session-слой снят в **§288**: вкладка `App`, класс `Session` и
> роуты `/profiler/{start,stop,active,sessions,session/<id>,stream}` удалены.
> Остался только system-wide режим; трафик одного приложения смотрят фильтром
> по приложениям на вкладке Profiler.

**Источники событий (§180/§044 — БЕЗ парсинга core-лога):**
- **DNS-стрим (§180, ядро SPEC 018)** — `CcChannel.dnsQueries` (канал `lxbox/cc/dns`, `subscribeDNSQueries` на `profilerClient`). Каждый `CcDnsQuery` несёт `domain`/`queryType`/`rcode`/`source`/`failed`/`error`, атрибуцию к app **из ядра** (`processInfo.packageName`), `answers[]` (весь response.Answer → cnameChain из type==CNAME), и (rc.10) `dnsServer`/`dnsServerType`/`outbound`. `_ingestDnsQuery` эмитит `dnsResolve`/`dnsFail`. **Текстовый core-лог парсинг выпилен начисто** (§044): не было `_dnsRe`/`_DnsAccumulator`/`router: found package` regex'ов — всё структурно из ядра.
- **Connections-стрим (§168)** — CommandClient `connections` push (`CcChannel.connections` через фоновый `profilerClient`, `connectProfiler()`) пока идёт global recording (§048). Снапшот diff'ается против `_connSnapshots`. TCP/UDP-атрибуция из ядра: `CcConnection.packageName` (UID-strip), `chains` (§174), `detours` (§178).
- Connection-issue classifier: `dnsTimeout` (структурный `q.failed` из DNS-стрима) + `tcpReset` (heuristic: TCP закрылся <1с с 0 bytes).

**Global / system-wide recording (§048).** Вкладка **Profiler** (бывш. Live) в Statistics — единственный режим профайлера: `startGlobalRecording()` подключает оба стрима. События в `_globalRollingBuffer` (окно **настраиваемое** 1m/10m/1h, §044 retention; hard cap 20000) и `globalLiveStream()` SSE. `_maybeDetachCcConnections()` гасит `profilerClient` когда recording off.

**Memory bounds:**
- `_globalRollingBuffer`: retention-окно (§044, default 10мин) + hard cap 20000.

**UI plumbing (§160/§044):**
- `StatsScreen` 3 вкладки: Stats / Conns / **Profiler** (system-wide, бывш. Live). Вкладка `App` снята в §288.
- Движок `TraceExplorer`: control-строка (пауза · retention · группировка · фильтр-окно) + тогл поток/Aggregated(by Domain/IP) + drill-down detail-sheet. Фильтр вынесен в `ProfilerFilterSheet` (Protocol + App оси). §181 `routingLine` строит читаемую трассировку события.

**Coupling (важно для extraction):**
- **`CcChannel` (CommandClient) — единственный источник.** Профайлер слушает `CcChannel.connections` + `CcChannel.dnsQueries` через фоновый `profilerClient`. Привязан к жизни канала: события идут пока туннель жив и `profilerClient` поднят (`connectProfiler()`). **core-логи больше не нужны** — `CoreLogsHintBanner` оставлен как опциональная подсказка, но DNS/TCP атрибуция от него не зависит (всё из ядра, §180/§168).
- **Контракт ядра (SPEC 017/018).** Поля `chain()`/`detour()`/`DnsQuery.*` — нативные методы libbox AAR. При бампе ядра новые методы проверять `javap` ДО вызова в Kotlin (forward-compat: отсутствие метода = compile error, не runtime). Имена gomobile-стиля (напр. `getDNSServer`, не `getDnsServer`); итераторы (`chain()`/`outbound()` → `StringIterator`).

---

### 6.6. WARP / MASQUE (§025 · §130)

Cloudflare WARP-интеграция (`services/warp/`, мастер `screens/warp_wizard_screen.dart`, storage `settings_storage/warp.dart`). Два транспорта:

- **WARP-WireGuard (§025).** `WarpClient` регистрирует устройство сам (POST в Cloudflare) — приватный ключ **X25519 генерируется на телефоне и не покидает его**. `client_id` (3 байта из base64) → WireGuard `reserved`; default-пир `engage.cloudflareclient.com:2408`. `warp_endpoint_picker.dart` даёт пул диапазонов/портов и рандомит endpoint (без пробы). Эмитится как обычная WireGuard-нода.
- **MASQUE (§130, флагман v2.9.0).** Отдельная крипта (`masque_keys.dart` — ECDSA P-256, не X25519), `masque_account.dart`, `masquerade_params.dart`. `MasqueSpec` ([`node_spec.dart`](../app/lib/models/node_spec.dart), `protocol='masque'`) эмитит sing-box outbound `type: masque` (Cloudflare QUIC / CONNECT-IP), `network` = `h3`/`h2`. Требует ядро с поддержкой masque-транспорта — см. `KERNEL.md`.
- **Endpoint generator (§284/§305).** Кнопка **«Make experiment»** в мастере (`services/warp/scan/` + `SubscriptionController.generateWarp`) открывает экран `screens/warp_experiment_screen.dart`: число узлов (дефолт 20, клампится 1..200) + **редактируемый JSON пула** (дефолт — bundled `assets/warp_endpoints.json`, кнопка Reset возвращает исходный). Дальше: одна регистрация WARP/MASQUE (кешированные аккаунты переиспользуются) → N случайных узлов (IP × port × protocol{AWG, h3, h2} × SNI) поверх кредов (`ScanNodeBuilder`) → (пере)создаётся папка **«WARP GENERATOR»** (`kScanFolderName`), которая сразу открывается через `pushReplacement` (назад → Servers). Пробы генератор **не гоняет** и мёртвые не удаляет — пользователь тестирует штатной кнопкой Test в папке. **DNS-независимо**: url пробы папки — IP-литерал `https://1.1.1.1/cdn-cgi/trace`. Без изменений ядра.
- **Пул эндпоинтов (§305, device-verified).** `assets/warp_endpoints.json` сгруппирован **по транспорту**; парсер — `ScanPool.fromFullJson` (один и тот же для bundled asset и для JSON-override окна эксперимента):
  - `wireguard`: `v4_cidr` · `v6_cidr` · `ports` (2408/500/1701/4500 — достоверные) · `ports_extra` (empirical, §132 — ниже приоритетом) · `sni_pool` · `utls_fp_pool`;
  - `masque`: `v4_cidr` · **`h3_v4_cidr`** · `ports_h3` · `ports_h2` · `sni_pool`.

  MASQUE-физика (боевой тест через рабочий туннель): **h2** живёт по всему блоку `162.159.198.0/24`+`162.159.199.0/24`, **h3 (QUIC) — только на 4 адресах** (`.198.1`, `.198.2`, `.199.1`, `.199.2`), поэтому для него отдельная секция `h3_v4_cidr` (рандом по /24 давал ~1% попаданий). Порты рабочие для обоих — все 7 (`443/500/1701/4500/4443/8443/8095`); SNI на h3 не влияет. Выбор источника — `ScanPool.masqueV4CidrFor(net)` / `masquePortsFor(net)`. v6-эндпоинты подставляются только при `ipv6_enabled`. Как **корректно мерить живость** узлов — см. [DIAGNOSTICS.md](DIAGNOSTICS.md) и [spec/tasks/305](spec/tasks/305-masque-endpoint-h2-pool-and-override.md).

### 6. AppLog (per-source ring buffers, §043)

`AppLog` хранит in-memory кольцевые буферы **per source** — `app=300`, `core=500`. Sing-box (verbose, сотни строк/мин на busy traffic) не вытесняет наши собственные app-сообщения.

```
HomeController/UI                    Sing-box (Go goroutines)
       │                                       │
       │ AppLog.I.info(...)                    │ writeDebugMessage(line)
       │   source: app                         │   ↓
       │                              [PlatformInterface override]
       │                              BoxVpnService.writeDebugMessage:
       │                                ├─ strip ANSI escapes
       │                                ├─ skip TRACE/DEBUG (volume reduction)
       │                                └─ coreLogSink.success(msg)  ← main thread post
       │                                       │
       │                              EventChannel "lxbox/coreLog"
       │                                       │
       │                              ClashLogPump.attach() listener
       │                                       │ parseLevel (regex \bWARN\b etc.)
       │                                       │ AppLog.I.log(level, msg, source: core)
       ▼                                       ▼
┌─────────────────────────────────────────────────────┐
│           AppLog (singleton)                          │
│                                                       │
│  Map<DebugSource, List<DebugEntry>> _entriesBySource  │
│   ├─ app:  [...] cap 300                              │
│   └─ core: [...] cap 500                              │
│                                                       │
│  log(level, msg, source) — O(1) amortized insert      │
│    + per-source trim                                  │
│  entries — O(n×k) k-way merge на чтении (k=2)         │
│  entriesForSource(s) — O(1) direct lookup             │
│                                                       │
│  Persistent (warn/error only):                        │
│    app  → applog.txt                                  │
│    core → corelog.txt                                 │
└─────────────────────────────────────────────────────┘
       │                                       │
       │ /logs?source=...&level=...&q=...      │ DebugScreen
       │ /logs/app   /logs/core                │ (segmented "All/Core/App",
       │ /logs/clear?source=...                │  level filter chips,
       ▼                                       ▼ search field)
   Debug API                            Flutter UI
```

**Key design rules:**
- `coreLogSink` (Volatile companion field в `BoxVpnService`) принимает sing-box callbacks из любого Go thread'а.
- `EventChannel.EventSink.success()` требует **main thread** — диспатчим через `coreLogMainHandler.post {...}`. Без этого openTun ловит `@UiThread` exception от Flutter, sing-box интерпретирует как "configure tun interface failed", VPN падает на старте.
- Forwarding gate'нут флагом `Libbox.setup(SetupOptions{debug: ...})` (читается из `BootReceiver.isCoreLogsEnabled(context)` в `BoxApplication.initialize`). Default false, юзер opt-in'ит через UI или Debug API. Изменение применяется только после restart Service'а — `Libbox.setup` зовётся один раз.

### 7. Граф detour-зависимостей (§355)

```
activeConfigRaw (смена) ──► DependencyGraph.fromConfig (models/dependency_graph.dart)
                              статика: node/dns --detour--> node|канал; состав групп
delayByChannel (замер)  ──┐
groups-стрим (выбор)    ──┴─► HomeController._recomputeDependencyHealth()
                              computeSick: dead-нода (все замеры ERR) → BFS вверх
                              по обратным рёбрам (selector-выбор заражает канал;
                              urltest болен только при мёртвом составе — §308
                              самолечится)
  ↓ (только при изменении результата)
HomeState.sickRoots (корень → пострадавшие DNS/ноды с via-путём)
  ├─ NodeRow: ⚠-метка у имени корня → тап → dependency_sheet
  └─ DNS-жертва появилась → lastError = DnsViaDeadNodeMsg (баннер; уход всех
     dns-жертв снимает его)
```

Никакой новой сетевой активности: только уже существующие события. Правила
health и не-цели — в [спеке §355](spec/tasks/355-detour-dependency-health-warnings.md).

---

## Dart `BoxVpnClient` API surface

Тонкий клиент над тремя channel'ами (`com.leadaxe.lxbox/methods` + два EventChannel'а). Файл — [`app/lib/vpn/box_vpn_client.dart`](../app/lib/vpn/box_vpn_client.dart). Это **единственная** точка где Dart-side touches MethodChannel — все остальные вызовы идут через типизированный API клиента.

**Singleton + DI:**
- Production — `BoxVpnClient.I` (или `BoxVpnClient()` — alias на singleton, оставлен для обратной совместимости).
- Tests — `BoxVpnClient.forTest(methods: mock, events: mock)`. `@visibleForTesting`.

**Группы методов** (порядок повторяет `_Methods` constants):

| Группа | Методы | Notes |
|---|---|---|
| Config | `saveConfig` / `getConfig` | `getConfig` fallback `'{}'` чтобы builder мог parse без null-checks |
| VPN lifecycle | `startVPN` / `stopVPN` / `reloadVPN` / `resetNetwork` / `getVpnStatus` / `getCoreVersion` / `quitApp` | `stopVPN` блокирующий native до `setStatus(Stopped)` — позволяет `await stop; await start` без race |
| Settings (boot prefs / native toggles) | auto_start, keep_on_exit, core_logs_enabled, allow_bypass, auto_redirect, background_mode (+ has_tun §192) | §189 — native `SharedPreferences boxvpn_boot.*` теперь **зеркало** JSON-секции `native_prefs`; источник истины = `lxbox_settings.json` (write-through + sync на старте). Все писатели идут через `SettingsStorage.setNativeBool`/`setNativeBackgroundMode`. |
| Per-app routing | `getInstalledApps` / `getAppIcon` / `getAppInfo` | Icons lazy — `getInstalledApps` без icons (тяжело), `getAppIcon` per-package по запросу |
| System helpers | `isIgnoringBatteryOptimizations` / `open*Settings` / `*NotificationPermission` / `*NearbyWifiPermission` / `showToast` | Permission `request*` — async, UI делает re-check через паренный `check*` |
| Quick Settings | `requestAddTile` | API 33+ |

**Status stream design:**

```dart
late final Stream<TunnelStatusEvent> onStatusChanged = _events
    .receiveBroadcastStream()
    .map(...)
    .asBroadcastStream();
```

`late final` критично: до v1.4.0 каждый getter создавал новый stream, native `EventChannel.onListen` дёргался повторно, native перезаписывал `statusSink` — основной listener после первого reconnect ломался ([tasks/001](spec/tasks/001-reconnect-sink-leak.md)). Сейчас singleton broadcast stream — один native listener, любое количество Dart-подписчиков.

**Timeout policy:**

Каждый MethodChannel-вызов обёрнут в `.timeout()` с per-метода настроенным значением (см. `_Timeouts` constants):

| Категория | Timeout | Почему |
|---|---|---|
| status / settings | 3s | Lightweight read/write of preferences |
| config | 5s | File I/O |
| app metadata (per-package) | 5s | One PackageManager query |
| installed apps list | 15s | `PackageManager.getInstalledApplications` дорогой |
| startVPN | 30s | System dialog timing + libbox setup |
| stopVPN | 10s | Blocking до `setStatus(Stopped)` |
| reloadVPN / resetNetwork | 5-10s | Wait for `serviceReload` / `closeAll + DNS flush + dialer rebind` |
| requestAddTile | 10s | System dialog confirmation |

**На таймауте** — лог в `AppLog` + safe-default fallback (например `tunnel: disconnected` для `getVpnStatus`). Без таймаутов мы видели реальные deadlock'и где native не отвечал на запрос — Flutter UI блокировался без recovery path.

---

## Native Architecture (Kotlin)

### Class layout (§049 F1 split)

В §049 audit'е мы port'нули pattern из reference SagerNet (`bg/BoxService.kt` commit 3b3883e, libbox 1.13.11) — разделили **Android Service лейер** от **libbox runtime лейера**:

```
┌─────────────────────────────────────────┐  ┌────────────────────────────────────┐
│ BoxApplication : Application            │  │ VpnPlugin : MethodCallHandler      │
│  • onCreate (registered in Manifest)    │  │  • setMethodCallHandler            │
│  • §334 CrashRecovery ← СТРОГО ДО setup │  │  • EventChannel sinks (status/log) │
│    событие + 2 подписчика: чистка здесь,│  │  • static currentStatus mirror     │
│    баннер §316 — в Dart, от архива      │  │     (sync read by HomeController)  │
│  • Libbox.setup(SetupOptions) async     │  │                                    │
│  • libboxReady : CompletableDeferred    │  │                                    │
│  • Singleton WifiNetworkObserver        │  │                                    │
└─────────────────────────────────────────┘  └────────────────────────────────────┘
                                                           │ start/stop intent
                                                           ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│ BoxVpnService : VpnService, PlatformInterfaceWrapper                            │
│  • Android lifecycle (onCreate/onStartCommand/onRevoke/onDestroy)               │
│  • PlatformInterface impl: defaultNetwork / processInfo / readWIFIState         │
│  • openTun()  ← libbox calls back через PlatformInterface                       │
│  • field: private val service = BoxService(this, this)  ← THIS line is the F1   │
│  • forwards lifecycle: onStartCommand → service.startSingbox(intent), etc.      │
└─────────────────────────────────────────────────────────────────────────────────┘
                                          │ owns
                                          ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│ BoxService : CommandServerHandler   (plain class, NOT a Service)                │
│  • libbox state: AtomicReference<ParcelFileDescriptor> fileDescriptor           │
│                  AtomicReference<CommandServer>          commandServer          │
│  • serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)              │
│  • startSingbox(intent) / doStop() / serviceReload() / receiver{stop,reload,..} │
│  • CommandServer(this, platformInterface)  ← 2 different Java instances:        │
│       CSH=BoxService  PI=BoxVpnService  (mirrors reference; reduces refnum-42   │
│       JNI race surface compared with prior `CommandServer(this, this)`)         │
│  • status broadcasts via BROADCAST_STATUS → VpnPlugin.statusReceiver → sink     │
└─────────────────────────────────────────────────────────────────────────────────┘
```

**Зачем split:** до §049 `BoxVpnService` имплементировал и `PlatformInterface`, и `CommandServerHandler` (один `this` передавался обоим libbox-сторонам). На стороне libbox это означало refcnt=2 на один `Seq.Ref` → расширенное окно gomobile refcount race (часть симптомов «refnum 42» в §050). После split два разных Java instance → libbox tracker'ы видят разные refnum'ы.

### Structured Concurrency

```
BoxService (per-instance, recreated с каждым new BoxVpnService)
  └─ serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
       ├─ resetScope() in startSingbox (cancel is terminal)
       ├─ All coroutines tied to service lifecycle
       ├─ DefaultNetworkMonitor receives serviceScope
       │    └─ checkUpdate() uses scope.launch — dies with service
       └─ doStop() calls serviceScope.cancel() as safety net
```

**`AtomicReference` для fileDescriptor / commandServer** (§049 F2/F3): `getAndSet(null)?.close()` гарантирует что только один поток выполнит close. Главный fix для §047 race condition на mutations `fileDescriptor` (5 call-site'ов могли double-close → kernel переиспользует fd-int → sing-box пишет в чужой fd → silent ENXIO → TCP перестаёт работать через 15-30 минут).

### Channel Contract

Three Flutter-Android channels live в `VpnPlugin.kt`:

| Channel | Type | Direction |
|---|---|---|
| `com.leadaxe.lxbox/methods` | MethodChannel | bidirectional (Dart → Native; Dart ← Native для `wifi_history`-promotion от `WifiNetworkObserver`) |
| `com.leadaxe.lxbox/status_events` | EventChannel | Native → Dart (TunnelStatus broadcasts) |
| `lxbox/coreLog` | EventChannel | Native → Dart (sing-box log lines) |

**MethodChannel methods** (groups follow `_Methods` constants в `box_vpn_client.dart`):

| Group | Method | Input | Output |
|---|---|---|---|
| **Config** | saveConfig | `config: String` | bool |
| | getConfig | — | String |
| **VPN lifecycle** | startVPN | — | bool (may trigger system VpnService dialog) |
| | stopVPN | — | bool — **блокирующий** native до `setStatus(Stopped)`, чтобы caller мог делать `await stopVPN(); await startVPN()` без race |
| | reloadVPN | — | bool — `box.serviceReload()` без status flap |
| | resetNetwork | — | bool — light recovery: `closeAllConnections + DNS flush + dialer rebind`. Tunnel must be up. |
| | getVpnStatus | — | "Started" \| "Starting" \| "Stopped" \| "Stopping" \| "Unknown" |
| | getCoreVersion | — | String — sing-box version + tags |
| | quitApp | — | bool (returns immediately, process dies ~250ms) — `finishAffinity + Process.killProcess` для применения `Libbox.setup(debug=…)` |
| **Settings (boot prefs / native toggles)** | getAutoStart / setAutoStart | bool | bool — auto-start VPN on boot (`BootReceiver`) |
| | getKeepOnExit / setKeepOnExit | bool | bool — keep VPN running когда Flutter-процесс убит |
| | getCoreLogsEnabled / setCoreLogsEnabled | bool | bool — §043 forward sing-box logs to Dart `AppLog`; требует full process restart |
| | getAllowBypass / setAllowBypass | bool | bool — §049 F15 `VpnService.Builder.allowBypass()`; apply на следующем `establish()` |
| | getBackgroundMode / setBackgroundMode | "never" \| "lazy" \| "always" | bool — §052 foreground-service tunnel sleep mode |
| **Notifications** | setNotificationTitle | `title: String` | bool — кастомный foreground notification title |
| | setNotificationText | `text: String` | bool — §123 кастомный foreground notification text (`'<selector>: <node>'`; title = `'L×Box [final = <route.final>]'`), оба owned Dart'ом |
| **Per-app routing helpers** | getInstalledApps | — | List<Map> (`package` / `appName` / `isSystemApp`) — без icons (тяжело) |
| | getAppIcon | `packageName: String` | String (base64 PNG) |
| | getAppInfo | `packageName: String` | Map (name+isSystem, **без icon** — §109) \| `{notFound: true}` (подтверждённо не установлен) \| error (retryable) |
| **System helpers** | isIgnoringBatteryOptimizations | — | bool |
| | openBatteryOptimizationSettings | — | bool — primary `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` prompt; fallback на список apps для OEM где direct prompt молча отбрасывается (ColorOS / MIUI / HyperOS) |
| | openAppDetailsSettings | — | bool |
| | openAppSettings | — | bool — App Permissions screen (3-уровневый OEM fallback: `MANAGE_APP_PERMISSIONS` → `MANAGE_PERMISSION_APPS` → `ACTION_APPLICATION_DETAILS_SETTINGS`). Для permissions без runtime prompt (`ACCESS_BACKGROUND_LOCATION` API 30+) |
| | areNotificationsEnabled | — | bool |
| | openNotificationSettings | — | bool |
| | checkNotificationPermission | — | bool — `POST_NOTIFICATIONS` на API 33+, true на pre-33 |
| | requestNotificationPermission | — | null — async; UI должен re-check через `checkNotificationPermission` |
| | checkNearbyWifiPermission | — | bool — `NEARBY_WIFI_DEVICES` на API 33+, true на pre-33 |
| | requestNearbyWifiPermission | — | null — async; re-check |
| | showToast | `msg: String, duration: "short"\|"long"` | bool |
| **Quick Settings tile** | requestAddTile | — | bool — `StatusBarManager.requestAddTileService` (API 33+) |
| **Diagnostics** | getApplicationExitInfo | — | List<Map> (API 30+) |
| | getLogcatTail | `count?, level?` | String |

**EventChannel `status_events`** — `TunnelStatusEvent`:
```json
{ "status": "Started" | "Starting" | "Stopped" | "Stopping", "error": "..." }
```

**EventChannel `coreLog`** — sing-box log lines, по одной строке на event. Filter (skip TRACE/DEBUG) + ANSI-strip применяются в `BoxVpnService.writeDebugMessage` до отправки. Включается через `core_logs_enabled` toggle (`Libbox.setup(SetupOptions{debug: ...})`, читается в `BoxApplication.onCreate` один раз — изменение применяется только после restart процесса).

---

### Permissions (Manifest + runtime)

**Manifest declarations** ([AndroidManifest.xml](../app/android/app/src/main/AndroidManifest.xml)):

| Permission | Зачем | Runtime grant? |
|---|---|---|
| `INTERNET` | sing-box egress | install-time |
| `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_SYSTEM_EXEMPTED` | VPN service визибл foreground (FGS политика API 34+) | install-time |
| `RECEIVE_BOOT_COMPLETED` | auto-start on boot | install-time |
| `POST_NOTIFICATIONS` | foreground service notification (API 33+) | runtime, default off |
| `QUERY_ALL_PACKAGES` | per-app split-tunneling list, app-picker | install-time |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | one-tap battery whitelist prompt (API 23+) | install-time + system one-tap dialog |
| `ACCESS_WIFI_STATE` | sing-box wifi rules / WifiInfo helpers | install-time |
| `ACCESS_COARSE_LOCATION` / `ACCESS_FINE_LOCATION` | pre-API-29 fallback для WifiInfo SSID | runtime, default off |
| `ACCESS_BACKGROUND_LOCATION` | API 29+ требование для `WifiManager.connectionInfo` из background (foreground service это и есть «background») | runtime, granted **только через Settings** на API 30+ |
| `NEARBY_WIFI_DEVICES` (`neverForLocation`) | API 33+ обязательный для real SSID/BSSID; без него `WifiInfo.ssid` = `"<unknown ssid>"` | runtime, default off |

**`neverForLocation` flag** на `NEARBY_WIFI_DEVICES` декларирует Google Play, что permission используется **не для location tracking** — это снимает дополнительный compliance review. У нас он действительно нужен только для SSID/BSSID (sing-box wifi rules).

**Permission gating в `BoxService.startSingbox`** ([BoxService.kt:267](../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxService.kt:267)):

После `startOrReloadService` (это парсит config) sing-box exposes `commandServer.needWIFIState()` — `true` если в активном config'е есть `wifi_ssid:`/`wifi_bssid:` правила. Если нужен и хоть один permission missing — `stopAndAlert("alert:permission_location:<comma-list>")`. Иначе sing-box падает с misleading `Unknown reference: 42` (real cause — unhandled `SecurityException` через JNI; см. §050).

Permission matrix:

| API | Что нужно для `WifiInfo.ssid` |
|---|---|
| API 28- | `ACCESS_FINE_LOCATION` |
| API 29-32 | `ACCESS_BACKGROUND_LOCATION` |
| API 33+ | `ACCESS_BACKGROUND_LOCATION` + `NEARBY_WIFI_DEVICES` (без NEARBY → `<unknown ssid>`) |

**Defensive try/catch в `PlatformInterfaceWrapper.readWIFIState`** ([PlatformInterfaceWrapper.kt:139](../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/PlatformInterfaceWrapper.kt:139)) — backup для случая когда permission grants drift'ует (например, Android revoke after long idle). `SecurityException` / `RuntimeException` → `return null`. Sing-box graceful'но получает null, не валит процесс через JNI.

#### JNI no-throw инвариант (§050 · §151)

Кросс-каттинговое правило для **всех** Kotlin-колбэков, которые libbox зовёт через gomobile-биндинг (`PlatformInterfaceWrapper`, `BoxService`/`BoxCommandClient` итераторы и `write*`-колбэки): **unchecked exception, вылетевшее через JNI = `Runtime::Abort` всего процесса** (не ловится Dart'ом, крашит особенно старые API — Android 10). Уточнение §151: методы с Go-сигнатурой `... error` защищены самим биндингом (исключение конвертится в error-возврат) — реальная abort-поверхность это методы **без** error-возврата. Следствие для итераторов (`StringIterator.Next()`/`HasNext()`, `chain()`/`outbound()`): возвращать пустое значение вместо броска. Симптом такого abort исторически — misleading `Unknown reference: 42` (root cause = unhandled `SecurityException` через JNI, см. §050).

**Runtime grant flow** (Flutter side):

```
[Connect tap]
   ↓
BoxService.startSingbox detects needWIFIState() && missing permissions
   ↓
stopAndAlert("alert:permission_location:<perms>")
   ↓
HomeController.lastError = "Stopped: alert:permission_location:..."
   ↓
home_screen._handleStatusEvent ловит prefix → AlertDialog
   ↓
[Allow Wi-Fi info]               [Open Settings]
runtime prompt (NEARBY)          MANAGE_APP_PERMISSIONS intent
                                 → 3 fallback стратегии:
                                   1. MANAGE_APP_PERMISSIONS
                                   2. MANAGE_PERMISSION_APPS
                                   3. ACTION_APPLICATION_DETAILS_SETTINGS
   ↓                                    ↓
re-check via checkNearbyWifiPermission → user re-Connect
```

`POST_NOTIFICATIONS` идёт через **explainer flow** в `home_screen._maybeShowNotificationPermissionDialog` (вызывается из `init`): один раз на cold start показывается AlertDialog (пояснение "VPN runs as foreground service, system requires notification"), потом system runtime prompt. Persisted флаг `notif_perm_prompted_v1` — explainer не повторяется.

---

### VPN Lifecycle & Status Sync

Модель туннеля: **`BoxVpnService` — это Android foreground-service, живущий **отдельно от Flutter-процесса**. Это даёт три состояния проекта которые надо координировать:

1. **Flutter-процесс живой, сервис живой** — нормальная работа. `setStatus(new)` в сервисе отправляет broadcast `BROADCAST_STATUS`, `VpnPlugin.statusReceiver` ловит и толкает в EventChannel sink → `HomeController._handleStatusEvent`. Всё в реальном времени.

2. **Flutter-процесс умер, сервис жив** — случается при `keep-on-exit = true` + swipe из recents / OOM-kill / system trimming. Android завершает Flutter activity + engine, но foreground-service (START_STICKY для touch-like policy) продолжает крутить sing-box и гнать трафик. Юзер возвращается → новый процесс, новый `HomeController.init`, новый listener. Broadcast'ы идут только на **transition**, а сервис уже в steady-state — никто не шлёт "I'm Started" повторно.

3. **Сервис умер системой** — OOM, краш libbox, revoked другим VPN. `setStatus(Stopped, error=...)` уходит в broadcast (если плагин ещё жив) или просто в `companion.currentStatus = Stopped` (если плагин мёртв вместе с процессом).

#### Pull-sync механика

Источник правды — `BoxVpnService.companion.currentStatus: VpnStatus` (`@Volatile`, обновляется в каждом `setStatus`). `VpnPlugin` выставляет его через MethodChannel `getVpnStatus`.

```
HomeController.init()
  ├─ _loadSavedConfig()
  ├─ _statusSub = _vpn.onStatusChanged.listen(_handleStatusEvent)  ← подписка на delta
  └─ raw = await _vpn.getVpnStatus()                               ← pull текущего
     └─ _handleStatusEvent({status: raw})  ← тот же handler, он сам решит что emit'ить
```

Без `getVpnStatus`-pull'а кейс №2 ломался: UI вечно "Disconnected" пока не случится следующий transition (а его может и не случиться, пока юзер не нажмёт Stop).

#### Broadcast vs pull — когда что

| Событие | Механика |
|---------|----------|
| Транзит (`Starting` → `Started`) | broadcast → EventChannel |
| App reattach (новый Flutter-процесс, сервис жив) | pull `getVpnStatus` в `init` |
| Heartbeat failed (тишина CommandClient status-стрима > timeout) | `HomeController._onTunnelDead` → `TunnelStatus.revoked` |
| Safety-timeout (застряли в Starting/Stopping 10s) | `Future.delayed` в `_handleStatusEvent` форс'ит disconnected |

#### Reconnect flow (v1.4.0+)

`HomeController.reconnect()` — композиция `_stopInternal + _startInternal` с blocking семантикой на native:

```
1. Если tunnel уже down — просто start() и выход.
2. busy=true.
3. _stopInternal: await _vpn.stopVPN() — native блокирует до
   setStatus(Stopped) или 5с timeout. Intent-based reset sticky флага.
4. Если stop timed out — abort, lastError="Stop timed out".
5. _startInternal: setNotificationTitle + startVPN + intent-based reset.
6. busy=false в finally.
```

Никакого `firstWhere`/timeout на Dart стороне. Blocking `stopVPN` на native через `BoxVpnService.stopAwait` (Completer, сompletes в `setStatus(Stopped)`) гарантирует `status=Stopped` до `startVPN` — race в `onStartCommand` guard исключён.

До v1.4.0 reconnect строился на Dart-side координации через `firstWhere(disconnected|revoked)` и был уязвим к sink-leak в `BoxVpnClient.onStatusChanged` (исправлен через `asBroadcastStream`). Детали — `docs/spec/tasks/001-reconnect-sink-leak.md`, `002-blocking-stopvpn-intent-reset.md`.

#### Keep-on-exit настройка

Toggle в **Mode-вкладке** (§188; до §188 — VPN Settings → System (§052); до §052 — App Settings → Background). Персистится через §189-слой: пишется в JSON-секцию `native_prefs.keep_on_exit` (источник истины), зеркалится в native `SharedPreferences` (`boxvpn_boot.keep_vpn_on_exit`) через `setKeepOnExit(bool)` — имя исторически от BootReceiver, но флаг используется и для keep-on-exit. Default ON (§188). Также экспонирован в Debug API: `GET|PUT /settings/vpn/keep_on_exit`.

При значении `true` и killе Flutter-процесса система не обязана останавливать foreground-service, а на `onTaskRemoved` service сам стоп не делает. Значение `false` → service слушает task-removed и вызывает `doStop()`.

Pull-sync работает независимо от значения keep-on-exit: если сервис как-то пережил процесс, UI всё равно синхронизируется.

#### Deep-links между tab'ами и settings (§052)

Tab'ы которые depend на глобальном toggle в settings (core_logs_enabled / VPN settings vars) умеют open соответствующий screen с правильно открытым tab'ом. Реализация: `initialTab` parameter на `AppSettingsScreen` / `SettingsScreen`, `DefaultTabController.initialIndex: widget.initialTab.clamp(0, length-1)`.

Два паттерна — **contextual banner** (state-зависимый hint) и **overflow item** (state-independent jump):

- **Statistics → Live + Per-app → contextual `CoreLogsHintBanner`** ([core_logs_hint_banner.dart](../app/lib/widgets/core_logs_hint_banner.dart)). Inline banner widget показывается **только когда `core_logs_enabled=false`**; self-hides при включении (auto-refresh на `AppLifecycleState.resumed`). Split hit-zone: левая зона (i + «DNS / router events off») → tooltip: баннер — опциональная подсказка для просмотра сырого core-лога; DNS/TCP-атрибуция от него **не** зависит (всё из ядра, §180/§168), см. секцию 6.5; правая («turn on Forward sing-box logs» + chevron) → deep-link в `AppSettingsScreen(initialTab: 1)` с auto-scroll и highlight нужного toggle'а. Это лучше чем PopupMenu overflow: явно виден когда нужен, исчезает когда не нужен.
- **Routing → Tunnel apps → ⋮ → "VPN settings (Core)"** → `SettingsScreen(initialTab: 1)`. State-independent jump (всегда полезно ходить из Tunnel apps к Core vars), overflow PopupMenu уместен. Открывает Core а не System — юзер настраивает Tunnel apps mode и хочет рядом mtu / log_level / dns_final.
- **Drawer → Debug → ⋮ → "Diagnostics settings"** → `AppSettingsScreen(initialTab: 1)` — fast-path на Quit&reopen после toggle Forward sing-box logs.

---

## CommandClient (libbox)

§122 — управляющий канал UI ↔ ядро. Clash HTTP API полностью выпилен (ядро собрано без `with_clash_api`, блок `experimental.clash_api` больше не инжектится в конфиг — на 1.14 без server'а он fatal). Вместо HTTP-петель — libbox **CommandClient**: ядро поднимает локальный command-server, клиент подписывается на server-stream push и шлёт unary-RPC. Файлы: нативный [`BoxCommandClient.kt`](../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxCommandClient.kt), Dart-клиент [`app/lib/vpn/cc_channel.dart`](../app/lib/vpn/cc_channel.dart) (`CcChannel.instance`).

### Модель: push-стримы, не pull-снапшоты

Ядро эмитит изменения; UI подписывается. Старый поток из трёх Timer-polling'ов (Clash HTTP-петли `/proxies`, ~20s heartbeat `/traffic`, `/connections` 5s) заменён server-stream push'ем. Снапшоты приходят сами; точечный unary-pull остался только там, где стартовый push дырявый (`getGroups`).

### Нативные клиенты (`BoxCommandClient.kt`)

Четыре независимых `CommandClient` — развязка частоты обновления от состава данных и lifecycle:

| Клиент | Команды | Lifecycle |
|---|---|---|
| `statusClient` | `CommandStatus` (+ `setStatusInterval`) | always-on пока туннель жив; в фоне (`onAppPaused`) гасится (0 тиков/0 drain); §164 адаптивная частота NORMAL 0.5с (главный экран) / FAST 0.1с (Stats) — пересоздаётся с новым интервалом |
| `screenClient` | `CommandOutbounds` + `CommandGroup` + `CommandConnections` | поднимается по `connectScreen()` (refs>0), гасится в фоне |
| `profilerClient` | `CommandConnections` + `subscribeDNSQueries` (SPEC 018, §180) | поднимается по `connectProfiler()` для recording; §164 **не паузится** в фоне → recording живёт при свёрнутом app |
| `pingClient` | голый `PingHandler`, без подписок — только unary RPC | §175/§209 — поднимается лениво, **lifecycle-независим** (`pauseClients` его НЕ трогает). Носитель ВСЕХ unary-снапшотов/действий (`urlTestOutbound` + `getPool`/`getGroups`/`getRules` + `selectOutbound`/`close*`). Дисконнект только в `cancelPing`/`resyncForReopen`/`shutdownAll`. Подписок нет → 0 нагрузки в покое. Следствие: снапшоты работают и при свёрнутом приложении |

Подписка в gomobile-фасаде = `CommandClientOptions.addCommand(int)` + колбэки `CommandClientHandler.write*` (прямых `subscribe*`-методов в AAR нет).

### Dart-слой (`CcChannel`)

Push-стримы поверх EventChannel `lxbox/cc/*` (`status` · `outbounds` · `groups` · `connections` · `dns`). **§122 sink-leak-guard:** каждый EventChannel держит РОВНО ОДИН native sink; `CcChannel` делает один внутренний `listen` и фан-аутит через `StreamController.broadcast` (native sink ставится при первом Dart-подписчике, снимается при уходе последнего) — иначе cancel одного потребителя (dispose Stats) обнулял бы sink главного экрана → watchdog видел бы тишину → ложный dead-tunnel.

| Стрим / метод | Тип | Назначение |
|---|---|---|
| `status` | push `Stream<CcStatus>` | up/down + traffic snapshot; питает heartbeat-watchdog |
| `outbounds` | push `Stream<List<CcOutbound>>` | список outbound'ов |
| `groups` | push `Stream<List<CcGroup>>` | selector/urltest группы + selected/active |
| `connections` | push `Stream<List<CcConnection>>` | active TCP/UDP + bytes + packageName/processPath. **Pull нет** (см. §193 ниже) — ядро шлёт полный список ОДИН раз (reset-снапшот на подписку), дальше только дельты |
| `dnsQueries` | push `Stream<List<CcDnsQuery>>` | §180 (SPEC 018) — DNS-запросы из ядра (domain/queryType/rcode/answers/cnameChain + dnsServer/outbound); `subscribeDNSQueries` на `profilerClient`; питает профайлер (`dnsResolve`/`dnsFail`) |
| `getGroups()` | unary-pull `List<CcGroup>?` | детерминированный снапшот групп (lifeline на дыру стартового push'а; `null` = клиент недоступен, не трогать state) |
| `getRules()` | unary-pull `List<CcRule>` | снапшот route+DNS правил (диагностика) |
| `getPool(tag)` | unary-pull `List<CcPoolSlot>?` | §208/§209 — снапшот пула round_robin-группы (`slot/tag/delay`). `null` = клиент недоступен, `[]` = пул пуст (не round_robin). Питает UI «View pool» + Debug `/pool` |
| `urlTestOutbound(tag)` | unary-RPC `CcDelayResult` | per-node delay. **Инвариант:** `error` — единственный признак провала; `delay==0 && error==''` = успех 0мс |
| `selectOutbound(group, tag)` | unary-RPC | selector switch |
| `closeConnection(id)` / `closeConnections()` | unary-RPC | закрыть одно/все соединения |

**§209 — все unary-методы выше идут через `pingClient`** (lifecycle-независим), не через `anyClient()` (status/screen/profiler паркуются в фоне §164). Поэтому снапшоты (`getPool`/`getGroups`/`getRules`) и действия работают и при свёрнутом приложении. Контракт ошибки: при недоступном клиенте List-снапшот возвращает `null` (не пустой список) — «нет клиента» отличимо от «нет данных»; действия возвращают честный `false`.

Lifecycle-сигналы (`connectScreen`/`disconnectScreen`, `connectProfiler`/`disconnectProfiler`, `pauseClients`/`resumeClients`, `setStatusFast`) дёргают соответствующие native-клиенты.

### Wiring

`HomeController` на `connected` event подписывается на `status` + `groups`-стримы и поднимает `screenClient` (`connectScreen()`), затем делает unary `getGroups()`-pull (с короткими ретраями пока сервис не STARTED) для детерминированного наполнения дерева групп — на случай если стартовый groups-push потерялся в гонке `waitForStarted`. На disconnect — отписка + `disconnectScreen()` + сброс кэшей. Per-node delay и selector switch идут через `urlTestOutbound` / `selectOutbound`.

### Gotchas

- **Empty groups-push поверх живого** — ядро может прислать пустой groups-push поверх непустого state; guard в `_onCcGroups` игнорит пустой push если `ccGroups` непуст. Детерминированный источник истины — `getGroups`-pull.
- **No external subscribers** — командный server слушает localhost; сторонние Clash-дашборды (yacd / clash-meta) больше не поддерживаются в принципе (Clash API нет).
- **§193 — connections single-shot, нет pull (асимметрия с groups).** `connections`-под-поток `screenClient`'а принципиально хрупче `groups`. Ядро (sing-box-lx) отдаёт полный список соединений **только один раз** — reset-снапшот при подписке (`SubscribeConnections`); дальше идут только дельты. У `groups` есть unary-pull `getGroups()` плюс повторные снапшоты на urlTest, у `connections` pull'а **нет** (`getConnections` в libbox отсутствует — javap rc.10 подтвердил). Поэтому при **повторном** открытии Stats (`screenClient` не пересоздаётся, refcount>0) нового reset-снапшота не приходит — UI остался бы пустым. Фикс §193: native-сторона при появлении нового connections-sink'а пере-эмитит накопленный `screenAccumulator` — [`BoxCommandClient.reEmitScreenConnections()`](../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxCommandClient.kt) зовётся из `VpnPlugin.onListen` connections-канала (идемпотентно: пустой/null acc → пустой list). Плюс `resyncForReopen` (§185, рвущий `screenClient`/`pingClient`) гейтнут до cold-start: флаг `_didColdStartResync` в [`home_controller.dart`](../app/lib/controllers/home_controller.dart) выполняет полный resync ровно один раз за жизнь движка, чтобы не рвать connections на каждом реконнекте. **Долг ядра:** добавить unary `GetConnections` симметрично `GetGroups`.
- **§194 — три счётчика соединений считают РАЗНОЕ.** Не путать:
  - **Главный экран** ([`traffic_bar.dart`](../app/lib/screens/home/widgets/traffic_bar.dart)) — два раздельных чипа: `connectionsIn` (🔗 = `trafficManager.ConnectionsLen()` ядра = соединения **приложений**, ТЕ ЖЕ что в `CommandConnections`-списке = на Stats) и `connectionsOut` (🗄 = `connectionManager.Count()` = **физические** соединения наружу к серверам). Раньше шапка складывала In+Out в одно число — путало, т.к. не сходилось со списком на Stats.
  - **Stats** — активные из списка (`closedAt==0`) ≈ `connectionsIn`.
  - **Conns** — живые + closed-история, показывает «N active / M total».

---

## Локализация (l10n, §279 / §285)

en (базовый) + ru; новый язык = один natural-key словарь + один
template-overlay + один `values-<lang>/` без структурных изменений.
Runtime-переключение без рестарта приложения, включая нативные поверхности при
живом VPN-сервисе. С §285 UI-строки локализуются через **natural keys**
(английский текст call-site'а И ЕСТЬ ключ; ARB/gen_l10n снесены). Полная
архитектура — [спека §279](spec/features/279%20localization/spec.md) +
[ревизия getLocalText](spec/features/279%20localization/getlocaltext.md);
translator-guide — [`l10n.md`](l10n.md).

| Компонент | Роль |
|---|---|
| `lib/services/l10n/get_local_text.dart` | `GetLocalText` — natural-key движок: `.s("en text", args)` / `.plural("%d en", n)`, printf `%s/%d/%1$s/%%`, форма-индекс, fallback = сам ключ; `GetLocalText.en` — пиненный английский рендерер |
| `lib/services/l10n/plural_resolver.dart` | `PluralResolver` + `En`/`RuPluralResolver` (CLDR формы: ru one/few/many/other) — набор форм диктует shape plural-объекта в словаре |
| `assets/l10n/ru/ui.json` | Natural-key словарь: `englishKey → { value: String\|pluralObj, special: {"N": {value}} }`. `en`-файла нет by design — английский базовый, в коде (fallback на сам ключ) |
| `lib/services/l10n/locale_controller.dart` | `LocaleController` — **единственный владелец** смены локали + глобальный `getLocalText` getter (dict-reload в пайплайне); `didChangeLocales` ловит смену системного языка при `setting=='system'` |
| `lib/services/l10n/template_overlay.dart` | Pre-parse оверлей display-текста `wizard_template.json` (адреса по machine-id, см. [TEMPLATE.md](TEMPLATE.md#localizing-the-display-text--the-l10n-overlay-279)) |
| `lib/services/l10n/template_aware_state.dart` | Mixin: refetch template-derived состояния в `didChangeDependencies` по `Localizations.localeOf` (initState переживает rebuild — снапшот локали там запрещён checker'ом) |
| `lib/services/l10n/app_language_reconcile.dart` | Трёхсторонний reconciliation `LocaleManager`↔storage на старте (Android 13+, зеркало `last_pushed_locale`) |
| `lib/models/ui_msg.dart` | sealed `UiMsg` — хранимые ошибки/статусы как типизированные объекты; `render()` через ambient `getLocalText` в момент показа, `renderEn()` → `GetLocalText.en` — путь UiMsg→String на machine-поверхностях (automation/AppLog/notification) |
| `app/tool/l10n/` | 4 CI-checker'а (`--strict` на каждом PR): ui_check (natural-key словарь↔код) / template_check / hardcoded_check (+ rendering-locality) / kotlin_check |
| `android … L10n.kt` | Нативный резолвер: читает `boxvpn_boot.app_language`, `createConfigurationContext` **в момент рендера, без кэша** — работает в сервис-процессе при мёртвом Flutter |

`MaterialApp.localizationsDelegates` несёт только Flutter-встроенные делегаты
(Global Material/Widgets/Cupertino chrome); строки приложения идут через
`getLocalText`, не через `Localizations`-делегат.

**Пайплайн смены языка** (любой путь записи `app_language` — picker, Debug API
side-effect hook, restore, смена системного языка — сходится в
`LocaleController.set()` / `_applyLocale()`):

```
LocaleController.set(v)
  ├─ SettingsStorage.setAppLanguage(v)      # JSON-var (истина) + MethodChannel-зеркало
  │     └─ native: BootReceiver pref → resubmit notification-канала →
  │        ServiceNotification.relabel → updateShortcuts (+onResume retry) →
  │        tile.requestListeningState → Libbox.setLocale → LocaleManager (33+)
  └─ _applyLocale(effective)
        ├─ _text = GetLocalText(dict<tag>, resolver<tag>)  # natural-key словарь новой локали
        ├─ await TemplateLoader.reload(tag)  # ПРОГРЕВ ДО notify (кэш ключуется тегом локали)
        ├─ RuleNameResolver.relocalize(...)  # display-зеркала билдера без ребилда конфига
        ├─ LazyPersistFlush.flushAll()
        └─ notifyListeners()                 # merged Listenable с themeNotifier → rebuild MaterialApp
```

**Границы** (английские навсегда): логи, Debug API-ответы, automation/Tasker-payload'ы,
`emitWarnings`, wire-значения и теги, имена файлов, user data, payload
OS/ядра (passthrough `RawMsg.detail`). Единицы (`B/KB/MB`, `Mbps`, `ms`) и
суффиксы длительности — латиница в обеих локалях.

---

## State Management

| Controller | Responsibility |
|-----------|---------------|
| `HomeController` | VPN lifecycle, CommandClient (groups/status/connections), nodes, ping (10 concurrent — `_pingConcurrency`), heartbeat, traffic, configChangedNeedRestart, autoUpdater wiring, haptic on transitions |
| `SubscriptionController` | CRUD entries (server_lists), `refreshEntry`/persist, `generateConfig` (no HTTP), `bindAutoUpdater`, init sweep (inProgress→failed) |
| `ThemeNotifier` | Theme mode, SharedPreferences persistence |
| `HapticService` (singleton) | Event-based haptic with 100 ms throttle, respects system setting (spec 029) |
| `AutoUpdater` | Owned by HomeScreen; wraps SubscriptionController for 4-trigger auto-update with spam gates (spec 027) |

Pattern: `ChangeNotifier` + `AnimatedBuilder`. `HomeState` is immutable with `copyWith` (sentinel `_unset` for nullable fields).

`_needsRestart` in HomeScreen is a derived getter — returns `true` when `_subController.configDirty || (state.tunnelUp && state.configChangedNeedRestart)`. **§076 update**: `configDirty` branch is no longer gated on `tunnelUp` — settings-changed banner shows whenever there are pending changes, independent of tunnel state. Two banners mutually exclusive: blue «Settings changed» for `configDirty`, pink «Restart VPN» for `tunnelUp && configChangedNeedRestart && !configDirty`. Sticky until tunnel up↔down transition (see spec 003 §8a).

**§323/§324 update — the pink banner is no longer purely sticky.** Two things clear it early:

- **§323** — an identical rebuild (`changed == false`) *clears* the flag instead of preserving it. Rationale: if the saved config matches the previous one byte-for-byte, the running instance cannot be stale, regardless of flag history. A successful `reloadVpn()` also clears it (the core re-read the file, so running == saved).
- **§324** — a text diff answers "did the file change", not "is the running instance stale". When the diff says *changed* and the tunnel is up, the core is asked instead: `formatConfig(saved + OverrideOptions)` vs `runningConfigRaw` (§311 snapshot). Both sides pass through the same core parser+encoder (kernel SPEC 037 §3), so field order / `omitempty` / `[] → null` collapse **inside the core** — no client-side list of "differences to ignore". The verdict can only *clear* a false banner, never raise one; `unknown` (core unreachable, snapshot absent, old kernel) keeps the banner. See `services/config_staleness.dart` — it mirrors `OverrideOptions` because `formatConfig` does not apply them while the snapshot is post-override.

---

## Navigation

```
HomeScreen
  ├─ Drawer:
  │   ├─ Servers → SubscriptionsScreen
  │   │              ├─ onTap UserServer → NodeSettingsScreen (editable Tag, Mark as detour)
  │   │              └─ onTap SubscriptionServers → SubscriptionDetailScreen
  │   │                     (Nodes / Settings / Source tabs)
  │   ├─ Routing → RoutingScreen
  │   ├─ DNS Settings → DnsSettingsScreen
  │   ├─ VPN Settings → SettingsScreen — 2 tabs (§052):
  │   │       • System — Tunnel sleep mode (`BackgroundMode`)
  │   │                 (§188 — «Allow VPN bypass» и «Keep VPN on exit» переехали в Mode-вкладку)
  │   │       • Core   — sing-box engine vars (`chapter: core`, mtu / log_level / dns_final / …)
  │   ├─ App Settings → AppSettingsScreen — 2 tabs (§052 Phase 2):
  │   │       • General      — theme, autostart, haptic
  │   │       • Diagnostics  — system permissions block + verbose / share / wipe + Quit&reopen
  │   │       (Background tab удалён; `keep_on_exit` + `background_mode` переехали в VPN Settings → System,
  │   │        permissions block — в Diagnostics)
  │   ├─ Speed Test → SpeedTestScreen
  │   ├─ Statistics → StatsScreen (via traffic bar tap)
  │   ├─ Config: Editor / File / Clipboard
  │   ├─ Debug → DebugScreen (share all dump button)
  │   └─ About → AboutScreen (local build badge + git describe)
  ├─ Start/Stop toggle + sticky restart warning
  ├─ Traffic bar → tap → StatsScreen
  ├─ Group dropdown (selector groups only)
  └─ Node list:
       ├─ NodeRow layout: [ACTIVE pill] [PROTOCOL · transport · security (§102)] ... [ping →]
       └─ long-press: Ping · Use · View JSON · Copy URI
          (§099 — copy-JSON варианты в dropdown внутри View JSON:
           Copy node JSON / Copy server JSON / Copy server + detours(N))
```

---

## Key Decisions

| Decision | Reason |
|----------|--------|
| Native VPN service (no plugin) | flutter_singbox_vpn was unmaintained (0 stars), config in SharedPreferences |
| File-based config storage | Large JSON configs don't belong in SharedPreferences |
| serviceScope vs GlobalScope | Structured concurrency — coroutines die with service |
| libbox CommandClient for management (§122) | Server-stream push вместо Timer-polling; Clash HTTP API выпилен (на 1.14 без `with_clash_api` он fatal). Нет localhost HTTP-порта → нет surface для port-scan |
| 10 concurrent mass ping (`_pingConcurrency`) | Sequential was too slow for 50+ nodes; cap балансирует latency vs sing-box load |
| SRS rules off by default | Require download, may fail offline |
| App list caching | getInstalledApps (~5s) called once, reused |
| profile-title from headers + content-disposition fallback | Auto-name subscriptions even without profile-title |
| URLTest hidden from dropdown | Users can't manually select in urltest — confusing UX |
| **Sealed `NodeSpec`** (Parser v2, v1.3.0) | Exhaustive switch at compile time; no runtime `type == 'vmess'` checks |
| **3-layer parser/builder** | Separation of concerns: parse ≠ build ≠ emit |
| **UserServer.toJson stores only rawBody** | `nodes` is derivable via `parseAll(decode(rawBody))` on fromJson; saves disk space, avoids NodeSpec serialization drift |
| **AutoUpdater gates** (spec 027) | `minRetryInterval=15min`, `maxFailsPerSession=5`, `_running`/`_inFlight` dedup — subscriptions never spam providers |
| **configChangedNeedRestart sticky flag** | Restart warning doesn't disappear on Stop-dialog cancel |
| **TLS-insecure → info severity** | Providers set it intentionally (REALITY, self-signed); shouldn't crowd out genuine warnings |
| **Shared `asBroadcastStream` for status events** (v1.4.0) | `BoxVpnClient.onStatusChanged` cached as `late final` — один native `onListen`, `statusSink` стабилен. Раньше каждый вызов getter'а перезаписывал sink и ломал основной listener после первого reconnect'а. См. tasks/001. |
| **Blocking `stopVPN` через Completer** (v1.4.0) | Method channel ждёт `setStatus(Stopped)` на native (5с timeout) — caller получает control только после реального завершения. Убирает race в `onStartCommand` guard в reconnect'е. См. tasks/002. |
| **Intent-based sticky reset** (v1.4.0) | `configChangedNeedRestart=false` в `_stopInternal`/`_startInternal` по факту применённого намерения, не только по transition event'у. Robust к Doze/OOM потерям broadcast'ов. |
| **`TunnelStatus.unknown`** (v1.4.0) | Default для неизвестного raw вместо `disconnected` — убирает ложные срабатывания `firstWhere` predicate'ов на мусорных events. UI маппит в Disconnected label. |
| **`ConfigCache` в HomeState** (v1.4.0; superseded §091 → `ParsedConfig`) | Outbound JSON парсился один раз при `saveParsedConfig`, не в itemBuilder'е. §091 заменил пару `protoByTag`/`detourTags` полноценной моделью `ConfigNode` (см. строку §091 ниже). |
| **`kDetourTagPrefix` single source of truth** (v1.4.0) | Константа `⚙ ` в `lib/config/consts.dart` — used by node_settings UI, builder, home filter, node_filter screen. Раньше литералы дублировались. |
| **Two persist patterns: Lazy vs Eager** (v1.9.0, §076) | Editing screens с toggle-flood UX (`tun_apps_tab`, `routing_screen`, `dns_settings_screen`, `settings_screen` Core) используют **lazy** — mutations in-memory + `_markDirty` (sync `configDirty=true`), flush on `dispose()` + `paused`, rebuild lazy на возврат к home. Discrete-event screens (`subscriptions`, `app_settings`, `custom_rule_edit`, `node_filter`) — **eager** immediate-write + snackbar. 1 settings + 1 config write per editing session вместо до 10 (per-toggle eager). |
| **Global `HomeReturnObserver`** (v1.9.0, §076) | Universal `NavigatorObserver` в `MaterialApp.navigatorObservers`. Срабатывает при `previousRoute.isFirst == true` (home стал top). Покрывает все navigation пути — drawer, long-press, system back, swipe, programmatic pop, cross-nav. Раньше rebuild trigger был в `_pushRoute.then()` callback'е — терялся при опен screen через non-drawer пути. |
| **mtime-based bootstrap** (v1.9.0, §076; §113) | `ConfigDirtyCheck.isDirty()` сравнивает `lxbox_settings.json.mtime > singbox_config.json.mtime` (**секундная резолюция**, §113) на launch. Восстанавливает `configDirty` после kill mid-edit без persist'а флага. `subController.init` set'ит флаг, `home._initSubsAndAutoUpdate` триггерит тихий bootstrap rebuild. **§113**: после §107 порядок дисковых записей инвертирован (конфиг пишется на возврате к home, настройки — позже на `dispose`), из-за чего `settings>config` стало нормой → ложный «config changed» после kill. Фикс: (а) `configDirty` владеется `SettingsStorage` — config-значимые сейверы (typed + config-var allowlist, **не** `saveServerLists`) сами поднимают флаг (`SubscriptionController.configDirty` — делегат); (б) `_save()` при снятом флаге выравнивает mtime конфига к mtime настроек (`ConfigDirtyCheck.touchConfig`). |
| **`markConfigChangedNeedRestart` external mark** (v1.9.0, §076) | `HomeController` method для настроек применяемых вне config pipeline. Native VPN-тогглы (allow_bypass / keep_on_exit / background_mode) — с §189 пишутся write-through через `SettingsStorage.setNativeBool`/`setNativeBackgroundMode` (JSON-истина + зеркало в native) — вызывают этот метод → home banner вместо локального snackbar'а. Gated на `tunnelUp`. |
| **Cohesion over line-count + `part`/`mixin` декомпозиция** (§089) | Монстры (home_screen 2370, home_controller 1089, …) раздроблены не по числу строк, а по ответственности: тонкий экран + `<screen>/widgets/` + presenter/VM; контроллер + `part`-mixin'ы (та же библиотека → library-private доступ сохранён, поведение bit-identical). ~600 строк легитимны для cohesive-файла; крупные исключения задокументированы (см. [Обзор](#принцип-cohesion-over-line-count-089)). |
| **`ConfigNode` структурная мета вместо reverse-parse тега** (§091, реализовано) | `config-tag == нода в Clash`; протокол/detour достаются из конфига по тегу без reverse-map. Один `ParsedConfig` (parsed раз на `configRaw`, поле `HomeState.configModel`) заменил `ConfigCache.protoByTag/detourTags` + `ConfigIntrospection` + reverse-map `subscriptionsOfTag` (теперь prefix-фильтр, `home/subscription_lookup.dart`). Класс багов §077/§079/§080 устранён структурно. §102/§103 — eager `transportLabel`/`securityLabel` для subtitle и variant-фильтра. +14 тестов. |
| **`VarValuesModel` — per-key реактивная модель настроек** (§232) | Однонаправленный поток а-ля Vue («props down, events up»): значения template-vars экрана живут в `VarValuesModel` (`Map<String, ValueNotifier>` + dirty-set), каждое поле `TemplateVarListView` подписано `ValueListenableBuilder`'ом на СВОЙ ключ — программные изменения (`on_change`: галка ipv6 → стратегии) видны в UI мгновенно и точечно. Заменила ДВЕ рассинхронизирующиеся копии (`_varValues` в State + приватная `_values` виджета), из-за которых on_change-записи терялись. `model.set` — только память; storage пишет ЕДИНСТВЕННОЕ место — `_persist` на dispose/paused по `dirtyKeys` (уточнение lazy-паттерна §076: до выхода изменения нигде, кроме модели). Кросс-экранная доставка (dns_strategy на DNS Settings) — через cache при следующем `_load()` того экрана; app-global модель отвергнута (экраны не co-mounted). §161-edge: пустое required — `set(markDirty:false)`+`unstage`, до storage не доезжает. |
| **`preset_on_change.dart` — on_change ПРЕСЕТА** (§266) | Отдельный от §232 движок: источник — не значение var, а **состояние пресета** (псевдо-vars `@rule_enable`=`cr.enabled`, `@dns_enable`=`presetDnsEnableVar`); приёмник — **глобальный `userVars`** (`SettingsStorage.setVar`, сразу на диск), не in-memory модель. `applyPresetOnChange(preset, cr)` собирает on_change со всех vars пресета, резолвит `#if`-цель в namespace `{...userVars, rule_enable, dns_enable}` через `evalIfScalar`, пишет каждую цель. Применение: FakeIP гасит `resolve_enabled` пока активен (`@rule_enable AND @dns_enable → false`). Зовётся из **5 точек** смены состояния (routing-свич/создание, редактор `onBoolVarToggle`, DNS Settings `_togglePresetDnsEnable`) — пропуск любой = цель не пересчитается на этом пути. Псевдо-var **обязана** нести `default_value`+`required:false`, иначе `expandPreset` выходит рано и DNS-блок пресета молча не эмитится (`29fe61c`). См. TEMPLATE.md § «on_change пресета». |

---

## Dependencies

| Package | Purpose |
|---------|---------|
| `http` | subscription fetch + rule-set/update/WARP HTTP requests |
| `json5` | JSON5/JSONC config parsing |
| `file_picker` | Config import from filesystem |
| `path_provider` | Documents directory for persistent storage |
| `shared_preferences` | Theme mode, haptic toggle |
| `share_plus` | Config/log export via system share sheet |
| **libbox** (native) | sing-box core — fork [`Leadaxe/sing-box-lx`](https://github.com/Leadaxe/sing-box-lx) (`with_awg` + `with_xhttp`, §097/§104; §122 — без `with_clash_api`). Пин — `app/android/libbox.version` (single source of truth; при бампе версии сверяться с файлом и `KERNEL.md`, не с этой строкой); AAR скачивает `scripts/fetch-libbox.sh` из GH Releases форка (SHA256-verify) в gitignored `libs/` — и локально (`build-local-apk.sh`), и в CI (`ci.yml` → «Fetch sing-box-lx core»). Maven-строка стокового libbox удалена из `build.gradle.kts` (исторически: JitPack `com.github.singbox-android:libbox:1.13.11`, миграция из `io.github.sagernet:libbox` — spec 039) |

---

## Known limitations

### Config Editor — one-way pipeline (issue [#3](https://github.com/Leadaxe/LxBox/issues/3))

Source of truth для всех экранов настроек (Subscriptions, Routing, DNS, VPN settings, App settings) — **structured app state** (`SubscriptionEntry[]`, `NodeSpec`, `CustomRule[]`, `SettingsStorage`). [`buildConfig`](../app/lib/services/builder/build_config.dart) собирает sing-box JSON из этого состояния, поток односторонний:

```
state ──buildConfig──▶ configRaw ──save──▶ libbox
```

Config Editor (`ConfigScreen.saveConfigRaw` → [`HomeController.saveConfigRaw`](../app/lib/controllers/home_controller.dart)) сохраняет введённый JSON в sing-box и в `state.configRaw`, но **не парсит его обратно в models**. Поэтому:

- Ручные правки в JSON не видны в menu screens — state о них не знает.
- Любое изменение в UI вызывает `buildConfig` поверх state и затирает manual edits.
- Connection statistics видят правки, потому что sing-box рантаймится с тем JSON'ом, что в editor'е сохранён.

Полноценный round-trip требует sing-box JSON → state parser'а покрывающего все формы outbound'ов / routing rules / DNS servers / inbound configs. Это эффективно вторая product surface, в near-term roadmap не входит. Mitigations для пользователей: выражать кастомизацию через **Routing → Custom rules** (state-bound, выживают пересборку); хранить «чистый» JSON-конфиг отдельно и переподавать его через editor после auto-update подписок.

---

## Feature Specs

Живут в [`docs/spec/features/`](./spec/features/). Каждая фича — папка `NNN name/spec.md`. Только **живые** продуктовые / архитектурные концепции; исторические / superseded / one-shot миграции — в [`docs/spec/tasks/`](./spec/tasks/) (см. [§054 spec reorg](./spec/tasks/054-spec-reorg-features-vs-tasks.md)).

| # | Feature |
|---|---------|
| 003 | Home screen |
| 006 | Servers UI |
| 007 | Config editor |
| 008 | Ping and node management |
| 009 | UX and theme |
| 010 | Quick start and offline |
| 011 | Local ruleset cache |
| 012 | Native VPN service |
| 014 | DNS settings |
| 015 | Speed test |
| 016 | Statistics and connections |
| 017 | Custom nodes and node settings |
| 018 | Detour server management |
| 019 | WireGuard endpoint |
| 020 | Security and DPI bypass (TLS fragment) |
| 021 | CI/CD pipeline |
| 022 | App settings |
| 023 | Debug and logging |
| 024 | Load balance — *Released* (§208 round-robin balancer, v2.7.0) |
| 025 | WARP integration — *Released* (v2.3.0; §130 MASQUE-транспорт) |
| **026** | **Parser v2** (sealed NodeSpec, 3-layer pipeline) |
| **027** | **Subscription auto-update** (4 triggers, spam gates) |
| **028** | **AntiDPI: mixed-case SNI** |
| **029** | **Haptic feedback** |
| 030 | Custom routing rules (unified `CustomRule` model: inline + local-only SRS) |
| 031 | Debug API (localhost HTTP server для dev introspection) |
| 032 | Quick Connect (QS tile + home shortcut) |
| 033 | Preset bundles (selectable rules с `preset_id`, expansion + merge) |
| 034 | App icon |
| 035 | MCP server — *Draft* |
| 036 | Update check (GitHub Releases polling, sideload-flow) |
| 037 | Naive proxy support |
| 038 | Crash diagnostics (`getHistoricalProcessExitReasons`) |
| 040 | Backup & restore UI (4 toggleable categories) |
| 042 | Health watchdog (heartbeat metrics + auto-recovery) |
| 043 | AppLog per-source quotas + diagnostics platform (Debug API + AppLog + Crash diagnostics) |
| **044** | **Per-app traffic profiler** (recording per-app DNS/connections/routing chain — Live/Domains/IPs/Connections sub-tabs, connection-issue detection, Debug API + SSE) |
| 045 | TLS ECH (Encrypted Client Hello) — anti-DPI extension прячущий SNI целиком — *Draft* |
| 046 | Tunnel apps split-tunneling (per-app include/exclude через VpnService.Builder) |
| 047 | Public Intent API (Tasker / Macrodroid automation через Android broadcast intents) — *Draft* |
| 048 | Home node filters (двухфазная pool/match модель — фундамент Filter mode §095/§096/§103) |
| 070 | Sort options (меню сортировки нод) |
| 071 | Manual node reorder (drag; §100 — manual в карусели + персист) |
| 074 | Add server wizard |
| 076 | Settings & config lifecycle (lazy/eager persist, HomeReturnObserver, mtime-bootstrap) |
| **097** | **AWG2 (AmneziaWG 2.0) + смена ядра на `sing-box-lx`** (`with_awg`/`with_xhttp`: AWG/AWG2 end-to-end, нативный XHTTP, MTU-кламп 1280; §104 — fork-ядро во всех сборках через `fetch-libbox.sh`) |
| 105 | Support message (support/web URLs в meta подписки) |
| 117 | DNS rework |
| 118 | Subscription fetch identity (User-Agent / identity headers) |
| 120 | Template engine — typed vars + `if` (общее ядро подстановки, §120) |
| 119 | VPN mode (vpn / vpn_proxy / proxy — §119, has_tun) |
| **121** | **libbox 1.14 adoption** (миграция обвязки на ядро 1.14) |
| **122** | **CommandClient migration** (полный отказ от Clash HTTP API → libbox CommandClient) |
| 123 | Subscription model (три CC-клиента: status/screen/profiler; §123/§164 энергомодель; notification text) |
| 124 | Background mode — tunnel sleep (Doze-поведение туннеля) |
| **125** | **Configurable channels** (CRUD-каналы поверх channels[]; enabled_groups DEPRECATED) |
| 126 | First-run wizard |
| **127** | **XHTTP full URL params** (нативный XHTTP: mode/x_padding_bytes/no_grpc_header) |
| **128** | **Idle-suspend** (`route.lx_idle_suspend`, ядро SPEC 020; default `30s`) |
| **129** | **File subscription** (url=file:<uuid>, HttpCache-снапшот, транзакционная смена online↔file) |
| **130** | **MASQUE WARP transport** (флагман v2.9.0 — MasqueSpec, Cloudflare QUIC/CONNECT-IP; services/warp/) |
| **234** | **Server folders** (папки ручных серверов: FolderMember + per-member toggle + tag_prefix/detour-политика) |
| 236 | Folder server testing (headless probe членов папки) |
| **248** | **Detour channels** (каналы как detour-цели; §254 циклы → fatal с виновниками) |
| **279** | **Localization** (en+ru: ARB + template-overlay + values-<lang>; §280 фазы 0-7) |
| **283** | **Subscription node disable** (per-node toggle в подписке: identity-хеш сути узла + TTL-GC отметок) |

**Демотированные (через §054) — теперь в `tasks/`:**

| Был | Теперь |
|-----|--------|
| ~~001~~ Mobile stack | [`tasks/055-mobile-stack-decision/`](./spec/tasks/055-mobile-stack-decision/spec.md) — historical architectural decision |
| ~~002~~ MVP scope | [`tasks/056-mvp-scope-historical/`](./spec/tasks/056-mvp-scope-historical/spec.md) — historical milestone |
| ~~004x~~ Subscription parser | [`tasks/057-subscription-parser-v1-superseded/`](./spec/tasks/057-subscription-parser-v1-superseded/spec.md) — superseded by §026 |
| ~~005x~~ Config generator | [`tasks/058-config-generator-wizard-v1-superseded/`](./spec/tasks/058-config-generator-wizard-v1-superseded/spec.md) — superseded by §026 |
| ~~013~~ Routing | [`tasks/059-routing-v1-superseded/`](./spec/tasks/059-routing-v1-superseded/spec.md) — superseded by §030 |
| ~~039~~ libbox 1.13 migration | [`tasks/060-libbox-1-13-migration/`](./spec/tasks/060-libbox-1-13-migration/spec.md) — one-shot migration (Done) |
| ~~041~~ DNS rules refactor | [`tasks/061-dns-rules-refactor/`](./spec/tasks/061-dns-rules-refactor/spec.md) — refactor, live spec — §014 |

Освобождённые номера (001, 002, 004, 005, 013, 039, 041) **не переиспользуются** — archive-ссылки сохраняются.

Дополнительно — летопись отдельных рабочих циклов (баги, рефакторинги): [`docs/spec/tasks/`](./spec/tasks/). Процессы (например, ночная работа): [`docs/spec/processes/`](./spec/processes/).

---

## Reusable layers (extraction targets)

LxBox monolith — но архитектурно есть несколько self-contained слоёв, которые **в принципе** можно вынести в отдельные packages (Flutter pub.dev) или хотя бы в `packages/` подпапку monorepo. Этот раздел — чек-лист для будущей extraction'а: что reusable, что coupled с LxBox, что надо параметризовать перед публикацией.

### Layer 1 — Sing-box VPN engine (Kotlin + Dart channel)

**Что:** Native обёртка над libbox + Dart MethodChannel client. Без UI, без opinion'ов о config-формате.

| Файлы | Lines |
|---|---|
| `app/android/.../vpn/{BoxApplication, BoxVpnService, BoxService, PlatformInterfaceWrapper, VpnPlugin, ConfigManager, ServiceNotification, VpnStatus, DefaultNetworkMonitor, DefaultNetworkListener, LocalResolver, BootReceiver, Extensions}.kt` | ~3000 |
| `app/lib/vpn/box_vpn_client.dart` | ~600 |
| `app/lib/models/{tunnel_status, background_mode, app_info}.dart` | ~150 |

**Public API surface:** `BoxVpnClient.I` (см. раздел [Dart `BoxVpnClient` API surface](#dart-boxvpnclient-api-surface)) + EventChannel'ы status/coreLog.

**Coupling с LxBox (надо разорвать перед extraction):**
- **Channel names hardcoded** — `com.leadaxe.lxbox/methods`, `com.leadaxe.lxbox/status_events`, `lxbox/coreLog`. Параметризовать через plugin config.
- **SharedPreferences keys hardcoded** — `boxvpn_boot.{auto_start_vpn, keep_vpn_on_exit, background_mode, core_logs_enabled}`. Префикс должен быть configurable или общий fallback.
- **Notification icon / channel name** — `ServiceNotification.kt` ссылается на `R.drawable.ic_notification` + строки. Должно браться из host app.
- **Manifest declarations** — package должен **документировать** требуемые permissions (location, NEARBY_WIFI_DEVICES, FGS, etc.) и intent-filters (BootReceiver, TileService) для host app.
- **`WifiNetworkObserver` зависит от Dart-side `wifi_history` MethodChannel** — это §051 фича LxBox, не general-purpose. Извлекать **отдельно** или сделать optional.

**Quality gates пройдены:** §049 audit (atomic CAS, F1 split, F2-F26 fixes), §050 closeout (refnum 42 root cause = `SecurityException` через JNI). Wrapper зрелый.

**iOS:** отсутствует. Для cross-platform package — отдельная задача (Network Extension + Packet Tunnel Provider + Swift bridges).

### Layer 2 — CommandClient channel

**Что:** libbox `CommandClient`-канал управления (§122) — нативный `BoxCommandClient.kt` + Dart-клиент `CcChannel`.

| Файлы | Lines |
|---|---|
| `app/android/.../BoxCommandClient.kt` | ~native |
| `app/lib/vpn/cc_channel.dart` | ~700 |

**Coupling с LxBox:** **средний**. Dart-сторона generic (push-стримы + unary-RPC поверх MethodChannel/EventChannel), но привязана к нативному `BoxCommandClient` (три клиента, §164-энергомодель) и именам каналов `lxbox/cc/*` — extraction идёт в паре с VPN-engine (Layer 1), не отдельно.

**API surface:** см. раздел [CommandClient (libbox)](#commandclient-libbox) — status/outbounds/groups/connections push + `getGroups`/`getRules`/`urlTestOutbound`/`selectOutbound`/`closeConnection`.

**Готовность к extraction:** **средняя**. Идёт вместе с Layer 1 (общий native command-server + channel names).

### Layer 3 — Sing-box subscription parser / builder

**Что:** Sealed `NodeSpec` (11 protocol variants, вкл. Masque §130) + URI/JSON/INI parsers + builder NodeSpec → sing-box config JSON.

| Файлы | Lines |
|---|---|
| `app/lib/models/{node_spec, node_spec_emit, tls_spec, transport_spec, ...}.dart` | ~2000 |
| `app/lib/services/parser/*.dart` | ~1500 |
| `app/lib/services/builder/*.dart` | ~2000 |

**Coupling с LxBox:** **высокий**. Builder зависит от `wizard_template.json` shape (наш формат preset'ов / vars / sections), `SettingsStorage` (server_lists, vars, custom_rules), и от наших sealed моделей (`ServerList`, `CustomRule`).

**Готовность к extraction:** **низкая**. Нужен серьёзный refactor — отделить `NodeSpec` parser/emit (reusable) от builder pipeline (LxBox-specific). Имеет смысл только если есть конкретный re-use case.

### Layer 4 — TrafficProfiler

**Что:** Per-app + system-wide observer DNS/TCP/UDP events.

**Coupling:** **высокий** — см. coupling notes в [секции 6.5](#65-per-app-traffic-profiler-044). Зависит от `CcChannel` connections- и dnsQueries-стримов (core-лог **не** парсится, §044/§180). Расцеплять для extraction нужно через интерфейс connection/DNS source.

**Готовность:** низкая. Имеет смысл только если LxBox VPN engine уже extracted и кто-то строит на нём свой profiler.

### Дорожная карта extraction (если решим идти)

1. **Phase 1** — Sing-box VPN engine + CommandClient-канал (Layer 1 + Layer 2) в `packages/flutter_singbox/` (path dependency monorepo). Refactor channel names (`lxbox/*`, `lxbox/cc/*`) + SharedPreferences keys + notification config. Не публикуем на pub.dev пока — верифицируем что LxBox работает.
2. **Phase 2** — выделить из Layer 3 reusable `NodeSpec` parser/emit (без builder pipeline).
3. **Phase 3** — Решение про публикацию: GPLv3 viral от libbox = main blocker. Если ОК с GPLv3-only userbase — публикуем.
4. **Phase 4** — iOS support (если нужен).

**Текущий статус:** ничего не extracted. VPN-engine (Layer 1) + CommandClient-канал (Layer 2) — связка для первого extraction'а.
