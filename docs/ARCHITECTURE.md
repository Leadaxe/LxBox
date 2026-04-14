# Архитектура BoxVPN

Документ описывает структуру Flutter-приложения BoxVPN, зоны ответственности пакетов, потоки данных и ключевые решения.

---

## Обзор

BoxVPN — Android-клиент на базе **sing-box** (через **libbox** / `flutter_singbox_vpn`). Приложение реализует полный цикл: от подписки до работающего VPN-туннеля с управлением узлами через **Clash API**.

```
┌────────────────────────────────────────────────────────────┐
│                        Flutter UI                          │
│  HomeScreen · SubscriptionsScreen · SettingsScreen · ...   │
├────────────────────────────────────────────────────────────┤
│                      Controllers                           │
│     HomeController          SubscriptionController         │
│     (VPN, Clash API,        (подписки, fetch,              │
│      nodes, ping)            config generation)            │
├────────────────────────────────────────────────────────────┤
│                       Services                             │
│  ConfigBuilder · SourceLoader · NodeParser · ClashApiClient│
│  SubscriptionFetcher · SubscriptionDecoder                 │
│  SettingsStorage · GetFreeLoader                           │
├────────────────────────────────────────────────────────────┤
│                       Models                               │
│  HomeState · ProxySource · ParsedNode · ParserConfig       │
│  WizardTemplate · WizardVar · SelectableRule               │
├────────────────────────────────────────────────────────────┤
│                    Platform / Native                       │
│  flutter_singbox_vpn (libbox, Android VpnService)          │
│  path_provider · shared_preferences                        │
└────────────────────────────────────────────────────────────┘
```

---

## Дерево исходников

```
app/lib/
├── main.dart                     # Точка входа, MaterialApp, темы
├── config/
│   ├── clash_endpoint.dart       # Извлечение Clash API endpoint из конфига
│   └── config_parse.dart         # JSON5 → canonical JSON, prettyJsonForDisplay
├── controllers/
│   ├── home_controller.dart      # VPN lifecycle, Clash API, ping, сортировка
│   └── subscription_controller.dart  # CRUD подписок, config generation, get_free
├── models/
│   ├── home_state.dart           # Immutable state: tunnel, nodes, delays, sortMode
│   ├── proxy_source.dart         # ProxySource, OutboundConfig, константы
│   ├── parsed_node.dart          # ParsedNode: результат парсинга URI
│   ├── parser_config.dart        # WizardTemplate, ParserConfigBlock, WizardVar, SelectableRule
│   ├── tunnel_status.dart        # Enum TunnelStatus (from native events)
│   └── debug_entry.dart          # DebugEntry для лога событий
├── screens/
│   ├── home_screen.dart          # Главный экран: VPN controls, groups, nodes, traffic bar, quick start
│   ├── subscriptions_screen.dart # Управление подписками (add, edit, delete)
│   ├── settings_screen.dart      # Wizard vars + selectable rules
│   ├── config_screen.dart        # JSON-редактор конфига с share
│   ├── debug_screen.dart         # Лог debug-событий с export
│   └── about_screen.dart         # Версия, кредиты, tech stack
├── services/
│   ├── config_builder.dart       # Template + vars + nodes → sing-box JSON
│   ├── source_loader.dart        # ProxySource → List<ParsedNode>
│   ├── node_parser.dart          # URI parsing: vless, vmess, trojan, ss, hy2, ssh, socks, wg
│   ├── subscription_fetcher.dart # HTTP fetch с User-Agent и лимитами
│   ├── subscription_decoder.dart # Base64, JSON array, plain text decode
│   ├── clash_api_client.dart     # HTTP-клиент для Clash API (proxies, delay, select, traffic)
│   ├── settings_storage.dart     # Persistent JSON-файл: vars, sources, rules, timestamps
│   └── get_free_loader.dart      # Загрузка встроенного пресета get_free.json
└── widgets/
    └── node_row.dart             # Строка узла: статус, задержка, context menu
```

---

## Потоки данных

### 1. Запуск VPN (полный цикл)

```
User tap "Start"
  ↓
HomeScreen._startWithAutoRefresh()
  ├─ shouldRefreshSubscriptions(reload interval)?
  │   └─ YES → SubscriptionController.updateAllAndGenerate()
  │              ├─ SubscriptionFetcher.fetch(url) → bytes
  │              ├─ SubscriptionDecoder.decode(bytes) → lines
  │              ├─ SourceLoader.loadNodesFromSource() → List<ParsedNode>
  │              └─ ConfigBuilder.generateConfig()
  │                   ├─ loadTemplate() → WizardTemplate (asset)
  │                   ├─ SettingsStorage.getAllVars() → user overrides
  │                   ├─ _substituteVars(config, vars)
  │                   ├─ _generateOutbounds(selectors, nodes)
  │                   │    ├─ node outbounds (from ParsedNode.outbound)
  │                   │    └─ selector/urltest groups (with filters)
  │                   ├─ _applySelectableRules(config, rules, enabled)
  │                   └─ return jsonEncode(config)
  │              ↓
  │   HomeController.saveParsedConfig(json)
  │              ↓
  │   FlutterSingbox.saveConfig(json)
  ↓
HomeController.start()
  ↓
FlutterSingbox.startVPN()
  ↓
Native: libbox creates tunnel
  ↓
StatusChanged event → "Started"
  ↓
HomeController._refreshClashAfterTunnel()
  ↓
ClashApiClient.fetchProxies() → groups, nodes
  ↓
UI: группы в dropdown, узлы в ListView
```

### 2. Парсинг подписки (subscription pipeline)

```
URL / direct link
  ↓
SubscriptionFetcher.fetch(url)
  ├─ HTTP GET (User-Agent, timeout 30s, max 10MB)
  └─ SubscriptionDecoder.decode(bytes)
       ├─ try base64 (standard, URL-safe, padded/unpadded)
       ├─ try JSON array (Xray format)
       └─ fallback: plain text lines
  ↓
SourceLoader.loadNodesFromSource(source, tagCounts)
  ├─ split lines, filter empty
  ├─ for each URI: NodeParser.parse(uri)
  │    ├─ detect scheme (vless, vmess, trojan, ss, hy2, ssh, socks, wg)
  │    ├─ parse components → ParsedNode
  │    └─ generate outbound JSON (sing-box format)
  ├─ apply tagPrefix, tagPostfix, tagMask
  └─ ensure tag uniqueness (append #2, #3...)
  ↓
List<ParsedNode>
```

### 3. Config generation (3-pass outbound algorithm)

```
Pass 1: Collect all node outbounds
  └─ ParsedNode.outbound for each node

Pass 2: Build selector/urltest groups
  └─ For each OutboundConfig in template:
       ├─ Filter nodes by filters (tag regex, host, scheme)
       ├─ Combine filtered tags + addOutbounds
       ├─ Validate tags exist
       └─ Create selector/urltest entry

Pass 3: Apply selectable rules
  └─ For each enabled rule:
       ├─ Add rule_set entries (inline/remote)
       └─ Add route rule
```

### 4. Persistent storage

```
boxvpn_settings.json (path_provider documents dir)
  ├─ vars: { "log_level": "warn", "clash_api": "127.0.0.1:9090", ... }
  ├─ proxy_sources: [ { source, tag_prefix, last_updated, last_node_count, ... } ]
  ├─ enabled_rules: [ "Block Ads", "Russian domains direct", ... ]
  └─ last_global_update: "2026-04-14T12:00:00.000"
```

---

## State Management

Приложение использует `ChangeNotifier` + `AnimatedBuilder`:

| Controller | Ответственность |
|-----------|-----------------|
| `HomeController` | VPN lifecycle, Clash API, nodes, ping/mass ping, sort mode, heartbeat, traffic |
| `SubscriptionController` | CRUD подписок, fetch, config generation, get_free preset |

`HomeState` — immutable data class с `copyWith`. Nullable поля используют sentinel `_unset` для корректного обнуления.

`HomeScreen` слушает оба контроллера через `Listenable.merge([_controller, _subController])`.

`HomeScreen` implements `WidgetsBindingObserver` — при возврате из фона вызывает `HomeController.onAppResumed()` для немедленной проверки tunnel health.

---

## Ключевые решения

| Решение | Причина |
|---------|---------|
| `json5` для парсинга конфига | sing-box конфиги часто содержат комментарии |
| Wizard template как Flutter asset | Компилируется в APK, не требует загрузки |
| `ChangeNotifier` вместо Riverpod/Bloc | Минимализм для MVP, без лишних зависимостей |
| Clash API вместо прямых вызовов libbox | sing-box уже предоставляет HTTP API для управления |
| Epoch counter в mass ping | Предотвращает race condition при cancel + restart |
| `RefreshIndicator` на списке нод | Стандартный мобильный паттерн pull-to-refresh |
| `ThemeMode.system` | Тема следует за системными настройками без ручного переключения |
| Heartbeat через `/connections` | Двойное назначение: traffic stats + VPN revoke detection |
| `WidgetsBindingObserver` | Быстрое обнаружение revoke при возврате из background |
| `share_plus` для экспорта | Стандартный system share sheet, без platform-specific кода |

---

## Зависимости

| Пакет | Назначение |
|-------|-----------|
| `flutter_singbox_vpn` | Native bridge к libbox (VPN tunnel) |
| `http` | HTTP-клиент для Clash API и fetch подписок |
| `json5` | Парсинг JSON5/JSONC конфигов |
| `file_picker` | Импорт конфига из файловой системы |
| `path_provider` | Директория для persistent storage |
| `shared_preferences` | (зарезервировано для будущих настроек) |
| `share_plus` | Экспорт конфига и логов через system share sheet |

---

## Навигация

```
HomeScreen (main)
  ├─ Drawer:
  │   ├─ Subscriptions → SubscriptionsScreen
  │   ├─ Settings → SettingsScreen
  │   ├─ Config:
  │   │   ├─ Editor → ConfigScreen
  │   │   ├─ Read from file
  │   │   └─ Paste from clipboard
  │   ├─ Debug → DebugScreen (copy/share logs)
  │   └─ About → AboutScreen
  ├─ Quick Start card (when no config, no subscriptions)
  ├─ VPN Controls (Start/Stop with confirmation)
  ├─ Traffic bar (upload, download, connections, uptime)
  ├─ Group selector + Mass Ping button
  └─ Nodes list (sort, pull-to-refresh, long-press menu)
       └─ Long-press on "Nodes" header → SettingsScreen
```
