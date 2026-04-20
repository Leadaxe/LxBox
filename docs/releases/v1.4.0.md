# L×Box v1.4.0 (draft)

Android VPN client powered by [sing-box](https://sing-box.sagernet.org/).

<!--
  Draft release notes for v1.4.0. Changes are still accumulating — do not tag yet.
  When ready to release:
    1. Finalise the sections below (remove "draft" suffix).
    2. Copy the final body to `docs/releases/v1.4.0.md` (bilingual EN + RU details).
    3. Bump `app/pubspec.yaml` version + `about_screen._version`; add section to CHANGELOG.
    4. `git commit` → `git tag -a v1.4.0 -m "…"` → push main + tag.
    5. CI builds APK, publishes GitHub Release.
-->

Major release: unified routing rules model, local-only SRS, Stats tabs + Top apps, Debug API, background/power settings, auto-ping on connect.

## ✨ Highlights

- **Unified routing rules** — `AppRule` + `SelectableRule` toggles + `CustomRule` слиты в один `CustomRule` ([spec 030](docs/spec/features/030%20custom%20routing%20rules/spec.md)). Один редактор, все поля (domain/IP/port/package/protocol/private-IP/srs) в одной форме.
- **SRS — только локально** — sing-box больше ничего не качает сам. Ручной download через ☁ в UI, никаких скрытых auto-update ([spec 011](docs/spec/features/011%20local%20ruleset%20cache/spec.md)).
- **Presets = каталог** — вкладка Presets превратилась в read-only каталог пресетов, кнопка "Copy to Rules" клонирует пресет в твой реестр.
- **Reorder / context menus** — правила перетаскиваются за drag-handle, long-press → Delete с подтверждением, long-press на ☁ в редакторе → Refresh SRS / Clear cached file.
- **JSON preview** — в редакторе правила вкладка View показывает готовый sing-box фрагмент конфига (rule_set + routing rule) + warnings.
- **Stats redesign** — Statistics-экран получил табы `Overview` / `Connections` (больше не нужен отдельный navigate), карточка Top apps с иконкой + display name + packageName + byte counters, карточка By routing rule, чип sing-box memory.
- **Template vars UX** — формы в Settings / Routing перерисованы: label сверху, описание во всю ширину, поле — тоже. `Test URL` / `Test interval` / `Tolerance (ms)` получили preset-дропдауны. URLTest interval default поднят с `1m` до `5m` под invariant spam-avoidance.
- **Debug API** — локальный HTTP-сервер для dev-introspection/control ([spec 031](docs/spec/features/031%20debug%20api/spec.md)): `/state`, `/clash/*` (proxy с auto-auth), `/action/*` (триггеры пинга/urltest/rebuild'а), `/logs`, `/config`, `/files/*`, `/device`. Включается runtime-toggle'ом в App Settings → Developer.
- **Status sync on reattach** — при возврате в приложение со свёрнутого/кильнутого процесса (keep-on-exit + VPN активен) UI больше не застревает в Disconnected. `BoxVpnClient.getVpnStatus` pull'ит текущее состояние у native-сервиса в `HomeController.init`.
- **Auto-update subscriptions toggle** — глобальный выключатель в App Settings → Subscriptions + дубль в `SubscriptionsScreen` PopupMenu (три точки). Default ON. Off → автоматические триггеры (appStart / vpnConnected / periodic / vpnStopped) скипаются; ручное ⟳ работает всегда ([spec 027](docs/spec/features/027%20subscription%20auto%20update/spec.md#global-toggle-ui-контракт)).
- **Clash API reference** — [docs/api/clash-api-reference.md](docs/api/clash-api-reference.md) — полный разбор эндпоинтов, полей connections[].metadata, выключенных/недокументированных возможностей sing-box 1.12.12.
- **Background / Battery** — App Settings → Battery optimization whitelist status + App info (OEM toggles) с hint-диалогом ([spec 022](docs/spec/features/022%20app%20settings/spec.md)).
- **Auto-ping after connect** — через 5s после подключения VPN пингуем ноды активной группы автоматом (по умолчанию ON).
- **✨auto rename** — `auto-proxy-out` тег переименован в `✨auto` с Icons.speed в UI (единая константа `kAutoOutboundTag`).

---

## 🔧 Unified CustomRule model

Три параллельных механизма слиты в один. До v1.4.0:
- `AppRule` — только per-package.
- `SelectableRule` — template пресеты, toggle'ятся в Routing → Presets.
- `CustomRule` (v1.3.x) — enum type per rule, один matcher.

Теперь один `CustomRule` имеет все match-поля сразу:

```dart
class CustomRule {
  CustomRuleKind kind; // inline | srs
  List<String> domains, domainSuffixes, domainKeywords, ipCidrs;
  List<String> ports, portRanges;
  List<String> packages;     // package_name (AND с headless match)
  List<String> protocols;    // routing-rule level (tls/quic/bittorrent/…)
  bool ipIsPrivate;          // routing-rule level (ORed with rule_set)
  String srsUrl;             // kind=srs only
  String target;             // outbound tag OR "reject"
}
```

Semantics per sing-box default rule formula — OR within category (domain-family, port-family), AND between categories. `protocol` и `ip_is_private` эмитятся на routing-rule level (headless rule их не поддерживает).

Один редактор с табами **Params** / **View**. Params сгруппирован: APPS (над Source) → Source (inline/srs) → MATCH / RULE-SET URL → PORT → PROTOCOL → Delete. Dirty-aware save (подсветка), unsaved back → "Discard changes?" диалог.

## 🔧 SRS local-only

Убран `type:"remote"` + `update_interval:"24h"` из генерации конфига. Все `.srs` rule_set'ы хранятся локально в `$documents/rule_sets/<rule.id>.srs`, эмитятся как `type:"local", path:…`. Скачивание — только ручное:

- **Tile cloud icon** — ☁ (not cached) / ✅ (cached, green) / ❌ (failed) / spinner. Tap = download/retry.
- **Enable gate** — switch правила disabled пока нет cached файла.
- **Cleanup** — Delete rule удаляет cached файл, URL change на save стирает старый кэш.
- **Long-press на ☁ в editor** → menu: Refresh SRS / Clear cached file.

Причина: провайдеры банят за бездумные авто-запросы, юзер должен контролировать когда что обновляется (см. invariant `feedback_no_unplanned_autoupdates`).

## 🔧 Migration (one-shot)

- **AppRule → CustomRule.packages** — `SettingsStorage._absorbLegacyAppRules` подхватывает `app_rules` ключ при первом `getCustomRules`, конвертит, удаляет legacy key.
- **enabled_rules + rule_outbounds → CustomRule** — `RoutingScreen._migrateLegacyPresets` при первой load'е (флаг `presets_migrated`) конвертит enabled SelectableRule'ы через `selectableRuleToCustom`. Fresh installs получают seed из `template.selectableRules.where(r => r.defaultEnabled)`.

Конвертер поддерживает все формы preset'ов:
1. `rule_set:[remote SRS]` → `kind=srs`
2. `rule.rule_set:"<tag>"` — разворачивает template inline rule_set в match-поля
3. inline поля прямо в `rule` (включая `ip_is_private`, `protocol`) — копируются as-is

## ✨ Routing UI overhaul

### 3 табы вместо 4

```
Routing → Channels | Presets | Rules
```

- **Channels** — proxy groups + `route.final` selector (без изменений).
- **Presets** — read-only каталог пресетов с кнопкой "Copy to Rules". Для srs-пресетов копия создаётся в disabled-состоянии (юзер должен скачать файл сначала).
- **Rules** — реестр `CustomRule`. ReorderableListView с drag-handle слева, tile edge-to-edge, long-press → Delete, OutboundPicker inline.

### Tile дизайн

```
┌────────────────────────────────────────────────┐
│ ║ ⬤─ Firefox RU domains      ☁ ⌄ direct      │
│ ║    2 suffix · 1 app                          │
└────────────────────────────────────────────────┘
```

- `║` — drag handle (reorder).
- Switch — включатель (disabled для srs без кэша).
- Имя + summary (2 строки) — tap = edit.
- ☁ — для srs only (download status + tap = refresh).
- OutboundPicker справа — inline смена target'а без открытия editor'а.

### Editor — Params / View tabs

**Params** — все match-поля сразу, грамматически OR/AND per sing-box формуле.
**View** — готовый JSON preview (rule_set + routing rule) через тот же `applyCustomRules`, что реально применяется при build'е конфига. Copy button + warnings (например "SRS rule X skipped: no cached file").

## 🔧 Background / Battery

Новая секция в App Settings:

- **Battery optimization** — status tile (зелёный/красный), tap открывает системную страницу battery-optimization. Fallback на direct-prompt `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` если OEM не поддерживает primary.
- **App info (OEM power settings)** — hint-dialog перечисляет что искать (Autostart, Background activity, Battery, Saver exceptions), потом открывает `ACTION_APPLICATION_DETAILS_SETTINGS` с package URI.
- Permission `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` добавлен в AndroidManifest.

## 🔧 Auto-ping after connect

Через 5s после перехода в connected, `HomeController` пингует ноды активной группы однократно. Дефолт ON. Отменяется pending timer при disconnect/revoked чтобы не стрельнуть в уже отключённом состоянии. Toggle в App Settings → Feedback.

## ✨ Stats redesign

- `StatsScreen` теперь `DefaultTabController(length: 2)` с вкладками `Overview` / `Connections`. Вкладка Connections — `ConnectionsView`, тот же самый компонент что раньше был отдельным экраном, теперь embeddable (без Scaffold/AppBar).
- **Top apps card** — топ-10 приложений по суммарному трафику с иконкой + display name + packageName (монospace subtitle) + `N conns ↑↑ ↓↓`. Lazy-cache `AppInfoCache` дёргает native `getAppInfo` per-package, `AnimatedBuilder` перерисовывает строку когда ответ пришёл.
- **By routing rule card** — распределение активных соединений по rule+rulePayload с процентной полоской.
- **Memory chip** — `sing-box` расход RAM в 4-чиповом топ-карде (из `/connections.memory` поля Clash API).
- Удалена dead навигация: Connections-чип больше не кликабельный (вместо этого — вкладка).

## ✨ Template vars UX

Формы шаблонных переменных (routing screen Auto Proxy, settings_screen core vars) перерисованы:

- **Label сверху** — больше нет `ListTile` с label/subtitle слева и узким input'ом справа. На узких экранах `Test URL` раньше ломался на `Test` / `URL` (две строки), описание сжималось до 13 символов в строку.
- **Поле на всю ширину** — `Column(crossAxisAlignment: stretch)`, field растягивается, suffix ▾ прижат справа. Enum `DropdownButton` получил `isExpanded: true`.
- **Presets для URLTest** — `urltest_interval` дропдаун: `30s / 1m / 3m / 5m / 10m / 30m`. `urltest_tolerance`: `10 / 30 / 50 / 100 / 200`.
- **Interval default `1m` → `5m`** — согласуется с invariant `feedback_subscription_no_spam` / `feedback_no_unplanned_autoupdates`. Юзеры без ручного override получают 5m (меньше фонового трафика).

## ✨ Debug API (spec 031)

Локальный HTTP-сервер, bind'ится на `127.0.0.1:9269`, авторизация `Bearer`-токеном из App Settings → Developer. Позволяет с хоста по `adb forward tcp:9269 tcp:9269` читать state и триггерить действия без повторных сборок APK.

- **`/state`**, `/state/clash`, `/state/subs`, `/state/rules`, `/state/storage`, `/state/vpn`
- **`/device`** — Android version / model / ABI / app version / VPN permission / network type / uptime
- **`/config`** — raw sing-box JSON; `/config/pretty` — indent'ed
- **`/logs`** — AppLog entries; `POST /logs/clear`
- **`/clash/*`** — прозрачный проxy с подмешанным Clash secret'ом: `/clash/proxies`, `/clash/group/<tag>/delay`, `/clash/connections`, `PUT /clash/proxies/<tag>` selector-switch
- **`/action/*`** — триггеры контроллеров: `ping-all`, `ping-node`, `run-urltest`, `switch-node`, `rebuild-config`, `refresh-subs`, `download-srs`, `toast`
- **`/files/*`** — read-only доступ к cached SRS + whitelisted external-файлам
- **Безопасность** — host-check middleware (защита от DNS rebinding), токен нигде не пишется кроме internal shared_prefs, bind строго на loopback.

Toggle default OFF, в релизных APK ничего не слушает пока юзер не включит в настройках.

## 🔧 Keep-on-exit status sync

Фикс: при `Keep VPN on exit = true` + swipe из recents + возврат в приложение UI показывал `Disconnected` хотя туннель был активен. И кнопка Start оставалась неактивной.

**Причина**: native-сервис broadcast'ит `BROADCAST_STATUS` **только на transition** (`setStatus(new)`). Если Flutter-процесс умер, а сервис остался в steady-state `Started` — новый `VpnPlugin.statusReceiver` после reattach ничего не получит.

**Решение**:
1. `BoxVpnService.companion.currentStatus: VpnStatus` — `@Volatile` mirror, обновляется в каждом `setStatus`
2. MethodChannel `getVpnStatus` → возвращает `currentStatus.name`
3. `HomeController.init()` сразу после подписки на `onStatusChanged` pull'ит текущий статус и пропускает через тот же `_handleStatusEvent` — он эмитит connected/connecting без изменений

## 📚 Clash API reference

Новый документ [docs/api/clash-api-reference.md](docs/api/clash-api-reference.md) — полный разбор sing-box 1.12.12 Clash API endpoints: структура `/proxies`, поля `connections[].metadata` (включая `processPath` с uid-суффиксом, `dnsMode`, `rule`+`rulePayload`, chains ordering), `/group/<tag>/delay` с pitfall'ом "force-urltest не обновляет `.now` персистентно", `/traffic` streaming vs snapshot. Используется как reference при доработке `clash_api_client` и `TrafficSnapshot`.

## ✨ AppPicker — lazy icons

Native `getInstalledApps` больше не возвращает иконки в одном вызове (раньше 500 apps × PNG-compress + base64 = ~10s блокировки UI). Теперь:

- `getInstalledApps` возвращает только metadata (pkg/name/isSystem) за сотни ms
- `getAppIcon(pkg)` — lazy per-tile запрос, session-level cache `_iconCache`
- Placeholder — CircleAvatar с первой буквой имени, иконка подменяется при arrival'e
- Scroll плавный, иконки появляются по мере viewport'а

Плюс crash-fixes: `if (!mounted) return` перед setState после awaits; PopupMenu items (Select all / Invert / Import) disabled пока loading; `_popped` flag — защита от двойного `Navigator.pop`.

## ✨ Build speed

Local release build с 38 мин до ~1.5 мин через `--target-platform android-arm64` в `scripts/build-local-apk.sh`. Собираем только одну архитектуру для локального тестирования. CI продолжает собирать все три (arm + arm64 + x64).

## 🐛 Critical fixes

- **`ip_is_private` unknown field** — sing-box отклонял конфиг с `ip_is_private` в headless rule. Поле **не поддерживается** в rule_set inline, работает только на routing-rule level. Перенесено, где per sing-box formula становится OR с `rule_set`.
- **Protocol-only rules skip'ались** — когда в rule только `protocol: [bittorrent]` (без domain/ip_cidr), `match` был пустой → skip. Теперь эмитится routing rule без rule_set, всё работает.
- **AppPicker крэшился при parallel tap** — setState без `mounted` guard'а + double `Navigator.pop`.

## ♻️ Rename / refactor

- `AppRule` класс полностью удалён; функциональность — `CustomRule.packages`.
- `applyAppRules` удалён из `post_steps`; `applyCustomRules` теперь возвращает `List<String>` с warnings.
- `applySelectableRules` удалён — пресеты копируются явно через `selectableRuleToCustom`.
- `RuleSetDownloader` переписан: id-based API (вместо tag), удалены `maxAge` / `cacheAll` (auto-refresh убран).
- `AppPickerScreen` — убран editable title (не нужен внутри `CustomRuleEditScreen`).
- `IP Filters` → `Rules` (tab rename).

## 📝 Docs

Обновлены спеки 011 (local ruleset cache — manual-download rewrite), 022 (app settings — battery / background / auto-ping), 030 (полный rewrite — unified model, JSON preview, context menus, migrations). RELEASE_NOTES.md + docs/releases/v1.4.0.md.

Memory invariant `feedback_no_unplanned_autoupdates` — явная не-функциональность: никаких скрытых background-refresh / TTL-refetch для SRS и прочих ресурсов.

## 📦 Install

Grab the APK below and install on Android (8.0+). **213/213 tests pass.** Release APK ≈ 56 MB (arm64) / 72 MB (universal from CI).

---

<details>
<summary><strong>🇷🇺 На русском</strong></summary>

Крупный релиз: единая модель routing-правил, локальные SRS без автообновлений, настройки батареи/фона, авто-пинг на connect.

### ✨ Главное

- **Единая модель правил** — `AppRule` + `SelectableRule` toggle'ы + `CustomRule` слиты в один `CustomRule`. Один редактор — все поля (domain/IP/port/package/protocol/private-IP/srs).
- **SRS только локально** — sing-box ничего сам не качает. Скачивание — ручное по кнопке ☁, никаких скрытых auto-update.
- **Presets = каталог** — вкладка Presets превратилась в каталог с "Copy to Rules". Копия идёт в твой реестр, там редактируешь/удаляешь как хочешь.
- **Reorder / context menus** — правила перетаскиваются за drag-handle, long-press → Delete с подтверждением.
- **JSON preview** — в редакторе вкладка View показывает готовый sing-box фрагмент конфига + warnings.
- **Background / Battery** — App Settings → Battery optimization status + App info (OEM toggles) с hint-диалогом.
- **Auto-ping after connect** — через 5s после подключения пингуем ноды активной группы (по умолчанию ON).
- **Stats: 2 таба + Top apps** — `Overview` (трафик, memory, by-rule, top apps) / `Connections`. Top apps показывает иконку + display name + packageName + счётчик соединений + байты.
- **Template vars UX** — label сверху, поля на всю ширину, preset-дропдауны для URLTest interval/tolerance. Default interval `5m` (раньше `1m`) под invariant spam-avoidance.
- **Debug API (§031)** — локальный HTTP-сервер для dev/staging: `/state`, `/clash/*`, `/action/*`, `/logs`. Включается в App Settings → Developer, токен — через Copy в UI. По умолчанию выключен.
- **Keep-on-exit status sync** — при swipe-из-recents + возврате UI больше не застревает в Disconnected. `getVpnStatus` pull'ит native-состояние в init'е.
- **Auto-update подписок toggle** — глобальный в App Settings → Subscriptions + дубль в PopupMenu на экране серверов. OFF → автоматические триггеры скипаются, ручное ⟳ всегда работает.
- **Clash API reference** — docs/api/clash-api-reference.md, полный разбор эндпоинтов и полей.
- **`auto-proxy-out` → `✨auto`** — URLTest-тег переименован, Icons.speed в UI.

### 🔧 CustomRule — один редактор

Три параллельных механизма слиты. Теперь один `CustomRule` содержит все match-поля сразу, эмит по sing-box default rule formula (OR внутри категории, AND между). `protocol` и `ip_is_private` — на routing-rule level (headless их не поддерживает).

Редактор: табы **Params** / **View**. Params: APPS (над Source) → Source (inline/srs) → MATCH / URL → PORT → PROTOCOL → Delete. Dirty-aware save, unsaved back → "Discard changes?".

### 🔧 SRS local-only

Убран `type:remote` и `update_interval` из генерации конфига. Файлы в `$documents/rule_sets/<id>.srs`, в конфиг идёт `type:local, path:…`. Скачивание только ручное. Switch правила заблокирован пока нет кэша. Delete rule стирает файл, смена URL — тоже.

### 🔧 Миграции (one-shot)

- AppRule → CustomRule.packages
- enabled_rules + rule_outbounds → CustomRule (с флагом `presets_migrated`)
- Конвертер preset'ов (`selectableRuleToCustom`) поддерживает все формы включая `ip_is_private` и template inline rule_set references.

### ✨ UI routing

- 3 табы: Channels / Presets / Rules
- Tile с drag-handle слева, edge-to-edge, long-press → Delete
- Editor: Params + View, все секции в одном экране
- Cloud-иконка в URL-поле: tap=download, long-press=меню (Refresh / Clear cached file)

### 🔧 Background / Battery

- Battery optimization tile (зелёный/красный) → открывает системные настройки
- App info с hint-диалогом перед запуском (что искать в OEM-настройках)
- Permission `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`

### 🔧 Auto-ping

Через 5 сек после connected пингуем ноды активной группы одноразово. Отменяется при disconnect. Toggle в App Settings.

### ✨ AppPicker — lazy icons

Раньше native возвращал иконки всех apps в одном вызове (~10s). Теперь только metadata за сотни ms, иконки lazy per-tile с session-cache'ом.

### ✨ Build speed

`--target-platform android-arm64` в локальном скрипте → release build ~1.5 мин вместо ~38 мин.

### 🐛 Critical fixes

- `ip_is_private` перенесён на routing-rule level (в headless его нет, sing-box крашился при старте).
- Protocol-only правила теперь эмитятся (раньше skip'ались).
- AppPicker крэш при parallel tap — mounted-guards + pop-guard.

### ♻️ Rename / refactor

- `AppRule` удалён (→ `CustomRule.packages`)
- `applyAppRules` / `applySelectableRules` удалены
- `RuleSetDownloader` id-based API
- IP Filters → Rules (tab rename)

### 📝 Docs

Спеки 011, 022, 030 переписаны. Memory invariant `feedback_no_unplanned_autoupdates`.

### 📦 Установка

Скачай APK ниже, установи на Android (8.0+). **213/213 тестов.** Release APK ≈ 56 MB (arm64) / 72 MB (universal).

</details>
