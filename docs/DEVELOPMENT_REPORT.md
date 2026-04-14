# Отчёт о разработке BoxVPN

**Дата:** 14 апреля 2026  
**Период:** Эволюция от MVP до полноценного приложения

---

## Резюме

BoxVPN прошёл путь от MVP (один экран: Read config → Start/Stop VPN → список нод) до полнофункционального Android VPN-клиента с:
- Полным парсером подписок (порт из singbox-launcher).
- Генератором конфигов на основе wizard template.
- Управлением подписками и настройками через UI.
- Mass ping, сортировкой, quick start, авто-обновлением.
- Dark theme и улучшенным UX.

Ниже — детальное описание каждого этапа.

---

## Этап 1: Реструктуризация спецификаций

### Проблема
Документация была разделена на `docs/spec/features/` и `docs/spec/tasks/` — неудобно, задачи оторваны от фич.

### Решение
- Перенесены все задачи из `docs/spec/tasks/` в `tasks.md` внутри соответствующих feature-папок.
- Удалена отдельная папка `tasks/`.
- Обновлены README и внутренние ссылки.

### Результат
Каждая фича — самодостаточная папка: `spec.md` + `plan.md` (опционально) + `tasks.md`.

---

## Этап 2: Subscription Parser (Feature 004)

### Задача
Перенести логику парсера подписок из Go-кодовой базы singbox-launcher в Dart.

### Реализация

**Файлы:**
- `services/subscription_fetcher.dart` — HTTP fetch с User-Agent, timeout 30s, лимит 10MB.
- `services/subscription_decoder.dart` — детектирование и декодирование: Base64 (standard, URL-safe, padded/unpadded), Xray JSON array, plain text.
- `services/node_parser.dart` (973 строки) — парсинг URI для 8 протоколов:
  - **VLESS** — `vless://uuid@host:port?...#fragment`
  - **VMess** — `vmess://base64json` (формат v2rayN)
  - **Trojan** — `trojan://password@host:port?...#fragment`
  - **Shadowsocks** — `ss://base64(method:password)@host:port#fragment` + SIP002
  - **Hysteria2** — `hy2://auth@host:port?...#fragment`
  - **SSH** — `ssh://user:pass@host:port#fragment`
  - **SOCKS** — `socks://user:pass@host:port#fragment`
  - **WireGuard** — `wireguard://...`
- `services/source_loader.dart` — оркестратор: Source → fetch → decode → parse → tag transform → uniqueness.

**Модели:**
- `models/parsed_node.dart` — `ParsedNode`: tag, scheme, server, port, uuid, flow, query, outbound (sing-box JSON).
- `models/proxy_source.dart` — `ProxySource`: source URL, connections, tagPrefix/Postfix/Mask, filters, excludeFromGlobal.

### Ключевые решения
- Каждый `ParsedNode` сразу содержит готовый `outbound` JSON — не нужен второй проход для генерации.
- Tag uniqueness: `tagCounts` map, дубликаты получают суффикс `#2`, `#3`, ...
- `isSubscriptionURL` / `isDirectLink` — эвристика для автоматического определения типа ввода.

---

## Этап 3: Config Generator (Feature 005)

### Задача
Из wizard template + пользовательских переменных + распарсенных нод сгенерировать полный sing-box JSON.

### Реализация

**Wizard Template** (`assets/wizard_template.json`, 206 строк):
- `parser_config`: outbound-группы (auto-proxy-out/urltest, proxy-out/selector, ru VPN), regex-фильтры по тегам.
- `vars`: 10 переменных (log_level, clash_api, clash_secret, resolve_strategy, auto_detect_interface, dns_strategy, dns_independent_cache, dns_default_domain_resolver, dns_final). Типы: enum, text, secret, bool.
- `config`: базовый sing-box JSON с плейсхолдерами `@var_name`.
- `selectable_rules`: 5 предустановленных правил (Block Ads, Russian domains direct, BitTorrent direct, Games direct, Private IPs direct) со ссылками на remote SRS rule sets.

**ConfigBuilder** (`services/config_builder.dart`):
1. `loadTemplate()` — загрузка и кэширование из asset bundle.
2. `_substituteVars()` — рекурсивная подстановка `@var_name` с type coercion (`"true"` → `true`, `"9090"` → `9090`).
3. `_generateOutbounds()` — 2-pass:
   - Pass 1: все node outbounds.
   - Pass 2: selector/urltest groups из template, фильтрация нод по `_matchesFilter` (literal, regex с `/.../i`, negation `!`), merge с `addOutbounds`, валидация тегов.
4. `_applySelectableRules()` — добавление rule_set и rules по enabled-списку.

**SettingsStorage** (`services/settings_storage.dart`):
- JSON-файл `boxvpn_settings.json` через `path_provider`.
- Секции: `vars`, `proxy_sources`, `enabled_rules`, `last_global_update`.
- In-memory cache для быстрого доступа.

### Модели
- `models/parser_config.dart`:
  - `WizardTemplate` — корневая структура.
  - `ParserConfigBlock` — parser_config с outbounds и reload interval.
  - `WizardVar` — переменная с типом, default, options, wizard_ui.
  - `SelectableRule` — правило роутинга с rule_set и rule.

---

## Этап 4: Subscription & Settings UI (Feature 006)

### Subscriptions Screen
- **Input bar**: TextField + Paste + Add.
- **Subscription list**: Dismissible (swipe-to-delete), ListTile с displayName, node count chip.
- **Actions**: "Update All & Generate" (appbar), "Generate Config" (bottom bar).
- **Progress**: CircularProgressIndicator + текст статуса.

### Settings Screen
- **Vars section**: SwitchListTile (bool), DropdownButton (enum), TextField (text), obscured TextField + Random (secret).
- **Rules section**: SwitchListTile для каждого SelectableRule.
- **Apply**: сохранение vars и rules → перегенерация конфига → SnackBar. Подсказка "Restart VPN" если туннель активен.

### Drawer Integration
- Пункты Subscriptions и Settings в navigation drawer HomeScreen.
- Оба экрана получают `SubscriptionController` и `HomeController` для cross-controller взаимодействия.

---

## Этап 5: Config Editor Improvements (Feature 007)

### Решение
- `prettyJsonForDisplay(String raw)` в `config_parse.dart` — JSON5 parse → JsonEncoder.withIndent('  ').
- Graceful fallback: если парсинг не удался, возвращает raw строку.
- ConfigScreen использует prettyJsonForDisplay в `initState` для TextEditingController.
- При сохранении — compact JSON (`canonicalJsonForSingbox`).

---

## Этап 6: Ping & Node Management (Feature 008)

### Mass Ping
- `HomeController.pingAllNodes()` — последовательный обход всех нод.
- `_massPingEpoch` — counter, инвалидирующий старые циклы при cancel/restart.
- Проверка `_state.tunnelUp` в каждой итерации — остановка при разрыве VPN.
- `cancelMassPing()` — устанавливает `_massPingRunning = false`, инкрементирует epoch, вызывает `notifyListeners()`.

### Расширенное контекстное меню
- `showMenu` с 4 пунктами: Ping, Use this node, разделитель, Copy name.
- `Clipboard.setData` + SnackBar для Copy.
- `canPing` и `canActivate` — условия доступности пунктов.

### Цветовая индикация
- `_delayColor(context)` — `< 200ms` green, `< 500ms` orange, else error color.

---

## Этап 7: Dark Theme & UX (Feature 009)

### Dark Theme
- `darkTheme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: _seed, brightness: Brightness.dark))`.
- `themeMode: ThemeMode.system`.

### Сортировка нод
- `NodeSortMode` enum: `defaultOrder`, `latencyAsc`, `latencyDesc`, `nameAsc`.
- `sortedNodes` getter в `HomeState`:
  - Latency sort: null → внизу, negative (error) → после позитивных.
  - Name sort: case-insensitive.
- `cycleSortMode()` в HomeController — циклическое переключение.

### Pull-to-refresh
- `RefreshIndicator(onRefresh: _controller.reloadProxies)` вокруг ListView.

### Улучшения HomeScreen
- `Listenable.merge([_controller, _subController])` — UI реагирует на оба контроллера.
- Node count `(N)` в заголовке.
- Reload groups button в строке заголовка Nodes.
- Long-press на заголовке → SettingsScreen. `HitTestBehavior.opaque` для reliable gesture detection.
- Progress banner при busy `_subController`.

---

## Этап 8: Quick Start & Auto-refresh (Feature 010)

### Quick Start
- `assets/get_free.json`: 2 бесплатные подписки (@igareck VLESS Reality Mobile), 4 enabled rules.
- `GetFreeLoader` — load + cache из asset bundle.
- `SubscriptionController.applyGetFreePreset()`: replace sources → save rules → fetch → generate.
- Quick Start card: `Card` с `rocket_launch_outlined` icon, описание, `FilledButton.icon` "Set Up Free VPN".
- Показывается когда: `configRaw.isEmpty && entries.isEmpty && !busy`.

### Auto-refresh
- `parseReloadInterval(String)`: regex `^(\d+)\s*(h|m|s)$` → Duration.
- `shouldRefreshSubscriptions(interval)`: сравнение `last_global_update` + interval vs now.
- `_startWithAutoRefresh()` в HomeScreen: если есть подписки и прошёл interval → updateAllAndGenerate → saveParsedConfig → start. Non-blocking: ошибки refresh не мешают запуску.

### Subscription Metadata
- `ProxySource.name`, `lastUpdated` (DateTime?), `lastNodeCount` (int) — persistent.
- `displayName`: name → hostname from URI → truncated URL.
- `SubscriptionEntry.subtitle`: status + `_formatAgo()` ("2h ago", "just now", "3d ago").

---

## Статистика

### Файлы

| Категория | Файлов | Примерно строк |
|-----------|--------|----------------|
| Controllers | 2 | ~650 |
| Models | 6 | ~430 |
| Screens | 5 | ~1200 |
| Services | 8 | ~1800 |
| Config | 2 | ~100 |
| Widgets | 1 | ~200 |
| Assets | 2 | ~310 |
| **Итого (lib/)** | **25** | **~4400** |

### Документация

| Документ | Строк |
|----------|-------|
| `docs/ARCHITECTURE.md` | ~200 |
| `CHANGELOG.md` | ~100 |
| `README.md` | ~80 |
| Feature specs (008-010) | ~300 |
| Этот отчёт | ~300 |

### Поддержанные протоколы (парсер)

| Протокол | URI scheme |
|----------|-----------|
| VLESS | `vless://` |
| VMess | `vmess://` (v2rayN base64) |
| Trojan | `trojan://` |
| Shadowsocks | `ss://` (SIP002 + legacy) |
| Hysteria2 | `hy2://` / `hysteria2://` |
| SSH | `ssh://` |
| SOCKS | `socks://` / `socks5://` |
| WireGuard | `wireguard://` |

### Wizard Template — routing rules

| Правило | По умолчанию | Источник |
|---------|-------------|---------|
| Block Ads | ✓ | geosite-category-ads-all.srs (remote) |
| Russian domains direct | ✓ | ru-domains (inline: .ru, .xn--p1ai, .su) |
| BitTorrent direct | ✓ | protocol: bittorrent |
| Games direct | ✓ | geosite-category-games.srs (remote) |
| Private IPs direct | ○ | ip_is_private: true |

---

## Этап 7: Нативный VPN и Routing (Features 013–016)

### Native VPN Service (013)
- Удалён сторонний плагин `flutter_singbox_vpn` (0 звёзд, непопулярный).
- Весь нативный код перенесён в `android/app/.../vpn/`: VpnPlugin, BoxVpnService, ConfigManager и др.
- Конфиг хранится в файле (`singbox_config.json`), а не SharedPreferences.
- Dart-обёртка BoxVpnClient с MethodChannel/EventChannel.

### Subscription Detail View (014)
- Тап по подписке → полноэкранный detail screen (URL, ноды, дата обновления).
- Inline rename, delete с подтверждением, refresh.
- Убраны swipe-to-delete и bottom sheet из основного списка.

### Rule Outbound Selection (015)
- Дропдаун outbound (direct/proxy/auto/vpn-X) рядом с каждым правилом.
- Настройка route.final для fallback трафика.

### Routing Screen (016)
- Отдельный экран Routing: Proxy Groups + Rules + outbound dropdowns.
- Settings упрощён — только технические vars.

---

## Что дальше (рекомендации)

| Приоритет | Фича | Описание |
|-----------|-------|----------|
| Высокий | **Profile Management** | Сохранение/загрузка нескольких конфигов (wizard states) |
| Средний | **Background Auto-update** | WorkManager / AlarmManager для обновления подписок в фоне |
| Средний | **Per-App Tunneling** | Выбор приложений для туннелирования (include/exclude) |
| Низкий | **Custom Routing Rules** | UI для добавления пользовательских routing rules |
| Низкий | **Onboarding Tour** | Пошаговый гайд для первого запуска |
| Низкий | **Widget / Quick Tile** | Android Quick Settings tile для Start/Stop |
