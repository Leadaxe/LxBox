# 051 — CustomRule: wifi_ssid / wifi_bssid conditions

| Поле | Значение |
|------|----------|
| Статус | Phase 1 + 2 done; Phase 3 draft |
| Дата | 2026-05-10 |
| Связанные | [`030 custom routing`](../features/030%20custom%20routing/spec.md) — расширяет sealed model; [`050 libbox-debug-build`](./050-libbox-debug-build/findings.md) — F12.3 readWIFIState fix (prerequisite); [`052 vpn settings system/service tabs`](./052-vpn-settings-system-service-tabs.md) — permission rows перенесены в Diagnostics |
| Затронутые файлы | `app/lib/models/custom_rule.dart`, `app/lib/services/builder/post_steps.dart`, `app/lib/services/debug/handlers/rules.dart`, `app/lib/services/debug/serializers/rules.dart`, `app/lib/screens/custom_rule_edit_screen.dart`, `app/lib/services/url_launcher.dart`, `app/lib/services/settings_storage.dart`, `app/lib/widgets/wifi_permission_dialog.dart`, `app/android/app/src/main/kotlin/com/leadaxe/lxbox/MainActivity.kt`, `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/PlatformInterfaceWrapper.kt`, `test/builder/`, `test/parser/` |

## Phases

| # | Scope | Status |
|---|---|---|
| **1** | Модель + builder + Debug API + tests + spec | ✅ Done (commit before §052) |
| **2** | Editor UI — chips + Add current / Pick saved / Manual + permission rows + shared dialog + history | ✅ Done (commit `5dd3c37` + earlier) |
| **3** | Native cache + NetworkCallback events — оптимизация горячего пути `readWIFIState` + auto-record history | 🔵 Draft |

## Цель

Дать `CustomRuleInline` и `CustomRuleSrs` поддержку условий `wifi_ssid` / `wifi_bssid`, чтобы юзер мог объявлять правила вида «на этом Wi-Fi → direct» **persistent** (через `POST /rules`), не прибегая к временному `PUT /config` + `config_locked`.

UI editor — Phase 2. Эта таска — **только модель + builder + Debug API**.

## Контекст

Sing-box нативно поддерживает `wifi_ssid: [string,...]` и `wifi_bssid: [string,...]` в каждом `route.rules[i]` и `dns.rules[i]`. Условия AND-ятся со всеми остальными полями того же правила, поэтому юзер может комбинировать:

- Чисто wifi: `wifi_ssid:[lexRouter] → direct`
- Wifi + domain: `wifi_ssid:[OfficeWiFi] AND domain:[*.bank.com] → direct`
- Wifi + SRS rule_set: `rule_set:[geosite-ru] AND wifi_ssid:[HomeWiFi] → ru-direct`

Поэтому **отдельный `CustomRuleWifi` kind не вводим** — потеряли бы возможность комбинировать. Расширяем существующие kind'ы.

## Что меняется в модели

### `CustomRuleInline`

```dart
class CustomRuleInline extends CustomRule {
  // existing
  final List<String> domains, domainSuffixes, domainKeywords;
  final List<String> ipCidrs, ports, portRanges, packages, protocols;
  final bool ipIsPrivate;
  final String outbound;

  // NEW
  final List<String> wifiSsids;       // canonical (без quotes)
  final List<String> wifiBssids;      // xx:xx:xx:xx:xx:xx, lower-case
}
```

### `CustomRuleSrs`

```dart
class CustomRuleSrs extends CustomRule {
  // existing
  final String srsUrl;
  final List<String> ports, portRanges, packages, protocols;
  final bool ipIsPrivate;
  final String outbound;

  // NEW
  final List<String> wifiSsids;
  final List<String> wifiBssids;
}
```

### `CustomRulePreset` — **не меняется**

Preset подставляется из template'а; vars-substitution для wifi-условий — отдельная фича (если понадобится). Phase 1 за её скобки.

## Serialization

### `CustomRule.toJson` / `fromJson`

```json
{
  "id": "...",
  "kind": "inline",
  "name": "Home wifi → direct",
  "enabled": true,
  "outbound": "direct-out",
  "domains": [],
  "ip_cidrs": [],
  "ports": [],
  "wifi_ssids": ["lexRouter"],
  "wifi_bssids": ["38:2c:4a:cf:6d:5c"]
}
```

Pравила:
- `fromJson` defaults `wifi_ssids: const []`, `wifi_bssids: const []` — старые backup'ы / settings без этих полей загружаются без ошибок.
- `toJson` пишет ключи **только если non-empty** (skip empty) — backup compactness.
- BSSID нормализация: lower-case при чтении (юзер мог ввести uppercase).

### Migration

**Zero**. Старые rules не имеют этих полей → defaults to empty → behavior unchanged.

## Builder pipeline

При генерации `route.rules[i]` / `dns.rules[i]` из `CustomRule`:

```dart
if (rule.wifiSsids.isNotEmpty) jsonRule['wifi_ssid'] = rule.wifiSsids;
if (rule.wifiBssids.isNotEmpty) jsonRule['wifi_bssid'] = rule.wifiBssids;
```

Для DNS-маршрутизации (если правило затрагивает DNS) — аналогично эмитим `wifi_ssid`/`wifi_bssid` в DNS-rule.

**Order invariant** — wifi-условия не меняют относительный порядок правил в `route.rules[]`. CustomRule rules вставляются на свою позицию (после infrastructure: resolve/sniff/hijack-dns), внутри — в порядке `custom_rules` array. Wifi-conditions — это **дополнительный фильтр** в том же rule, не отдельная sequence.

## Debug API

### `POST /rules`

Body новых полей:

```json
{
  "name": "Home wifi → direct",
  "kind": "inline",
  "enabled": true,
  "outbound": "direct-out",
  "wifi_ssids": ["lexRouter"],
  "wifi_bssids": ["38:2c:4a:cf:6d:5c"]
}
```

Validation в `_ruleFromJsonStrict`:
- `wifi_ssids`: list of strings, non-empty strings, max 32 chars каждое (sing-box hard limit?). Empty list = no wifi condition.
- `wifi_bssids`: list of strings матчащих `^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$`, normalize to lower-case.

### `PATCH /rules/{id}`

`setIfPresent('wifiSsids', fieldStringList(body, 'wifi_ssids'));`
`setIfPresent('wifiBssids', fieldStringList(body, 'wifi_bssids'));`

### `GET /rules` / `GET /state/rules`

Сериализатор включает `wifi_ssids` / `wifi_bssids` в response (даже если empty — для consistency с другими list-полями).

## Permission flow

Уже работает без новых правок:

1. `BoxService.startSingbox` после `startOrReloadService` вызывает `cs.needWIFIState()`.
2. Если sing-box видит `wifi_ssid`/`wifi_bssid` в любом правиле → `needWIFIState()` returns `true`.
3. Permission check матрица (см. §050):
   - API 28-: `ACCESS_FINE_LOCATION`
   - API 29-32: `ACCESS_BACKGROUND_LOCATION`
   - API 33+: `ACCESS_BACKGROUND_LOCATION + NEARBY_WIFI_DEVICES`
4. Missing → `stopAndAlert("alert:permission_location:...")` → Flutter dialog с runtime prompt + Settings fallback.

Pre-flight permission check **на уровне POST /rules** — out of scope Phase 1 (юзер увидит alert при следующем connect). Phase 2 UI editor добавит preflight на save.

## Тесты

- `test/models/custom_rule_test.dart`: 
  - JSON round-trip с / без wifi-полей
  - default empty при отсутствии в JSON (migration)
  - BSSID normalization (uppercase → lowercase)
- `test/builder/custom_rules_to_route_test.dart`:
  - `wifi_ssid` / `wifi_bssid` правильно эмитятся в sing-box JSON только при non-empty
  - инфраструктура остаётся первой (resolve/sniff/hijack-dns), wifi-rule после
  - комбинации: wifi + domain в одном rule → оба поля в JSON
- `test/parser/...`: если есть reverse parsing existing config'ов — поддержать чтение wifi-условий

## Out of scope (Phase 2 — UI)

- Editor-секция в `RuleEditScreen` с двумя chip-input'ами
- Кнопка «Use current Wi-Fi» — читает `WifiManager.connectionInfo` через MethodChannel; disabled с tooltip если permissions нет
- Pre-flight permission check при save rule с непустыми wifi-полями (показать существующий dialog)
- `CustomRulePreset` поддержка через vars-substitution `{{wifi_ssid_home}}` (если понадобится)

## Workflow для юзера после Phase 1

```
POST /rules?rebuild=true
{
  "name": "Home wifi → direct",
  "kind": "inline",
  "enabled": true,
  "outbound": "direct-out",
  "wifi_ssids": ["lexRouter"]
}
```

→ rule в `settings.custom_rules`, builder автоматически подставит `wifi_ssid` в sing-box config при rebuild. Persistent через рестарты, **без** `config_locked`.

## Acceptance

- [x] Round-trip JSON tests passing для inline + srs (Phase 1)
- [x] Builder тесты подтверждают эмиссию `wifi_ssid` / `wifi_bssid` только при non-empty (Phase 1)
- [x] `POST /rules` с wifi-полями → правило в storage → rebuild → правило в active config (Phase 1)
- [x] Smoke на устройстве: создать rule через API, reconnect VPN, трафик direct'ом — `outbound/direct[direct-out]` для api.ipify.org (Phase 1, v13905)
- [x] UI editor — chip-based section с Add current / Pick saved / Manual (Phase 2, v13912)
- [x] Без regressions для существующих non-wifi rules (548 tests pass, ни одна fixture не сломалась)

---

# Phase 3 — Native cache + NetworkCallback (perf optimization)

## Цель

`PlatformInterfaceWrapper.readWIFIState()` сейчас на каждый sing-box rule-evaluation делает binder IPC к `system_server` через `WifiManager.connectionInfo`. Sing-box при busy traffic дёргает callback десятки раз в секунду (один call на каждый TCP setup, DNS query). Каждый call — JNI crossing + IPC + parcel marshal/unmarshal.

Cache + event-driven invalidation убирает binder из горячего пути: чтение становится O(1) read of volatile field. Bonus — auto-record `wifi_history` при изменении сети (не нужен manual «Add current» в editor, история наполняется естественно).

## Архитектура

```
┌─ BoxApplication ─────────────────────────────────┐
│                                                  │
│  WifiStateCache (singleton)                      │
│  ├─ @Volatile var current: WIFIState?            │
│  ├─ @Volatile var lastFetchedAt: Long            │
│  ├─ fun read(): WIFIState?      ← hot path       │
│  ├─ fun refresh()               ← event-triggered│
│  └─ fun clear()                                  │
│                                                  │
│         ▲ subscribes                             │
│         │                                        │
│  ConnectivityManager.NetworkCallback             │
│  ├─ NetworkRequest TRANSPORT_WIFI                │
│  ├─ onAvailable     → cache.refresh()            │
│  ├─ onCapabilitiesChanged → cache.refresh()      │
│  └─ onLost          → cache.clear()              │
│                                                  │
└──────────────────────────────────────────────────┘
            ▲
            │ readWIFIState()
            │
┌─ PlatformInterfaceWrapper ───────────────────────┐
│  override fun readWIFIState(): WIFIState? =      │
│      WifiStateCache.read()                       │
└──────────────────────────────────────────────────┘
```

## Cache

```kotlin
object WifiStateCache {
    @Volatile private var _current: WIFIState? = null
    @Volatile private var _lastFetchedAt: Long = 0L

    /// TTL fallback на случай missed callbacks (paranoid).
    private const val MAX_STALE_MS = 30_000L

    fun read(): WIFIState? {
        val now = System.currentTimeMillis()
        val cur = _current
        if (cur != null && now - _lastFetchedAt < MAX_STALE_MS) {
            return cur
        }
        // Stale or empty → blocking refresh on caller thread (rare path).
        // Sing-box callback может приехать ДО первого NetworkCallback fire
        // — тогда первый readWIFIState() пройдёт IPC, последующие cached.
        return refresh()
    }

    @Synchronized
    fun refresh(): WIFIState? {
        val info = try {
            BoxApplication.wifiManager.connectionInfo
        } catch (_: SecurityException) {
            _current = null
            _lastFetchedAt = System.currentTimeMillis()
            return null
        } catch (_: RuntimeException) {
            _current = null
            _lastFetchedAt = System.currentTimeMillis()
            return null
        } ?: run {
            _current = null
            _lastFetchedAt = System.currentTimeMillis()
            return null
        }

        var ssid = info.ssid
        if (ssid == "<unknown ssid>") {
            _current = WIFIState("", "")
            _lastFetchedAt = System.currentTimeMillis()
            return _current
        }
        if (ssid.startsWith("\"") && ssid.endsWith("\""))
            ssid = ssid.substring(1, ssid.length - 1)
        val bssid = info.bssid?.lowercase() ?: ""
        val newState = WIFIState(ssid, bssid)
        val changed = (_current?.ssid != ssid) || (_current?.bssid != bssid)
        _current = newState
        _lastFetchedAt = System.currentTimeMillis()
        if (changed) onChanged(ssid, bssid)
        return newState
    }

    @Synchronized
    fun clear() {
        _current = null
        _lastFetchedAt = System.currentTimeMillis()
    }

    /// Triggered ровно когда network actually changed. Auto-history hook.
    private fun onChanged(ssid: String, bssid: String) {
        if (ssid.isEmpty()) return
        // Post to main looper, dispatch via MethodChannel в Dart →
        // SettingsStorage.addToWifiHistory(ssid, bssid).
        WifiHistoryBridge.notify(ssid, bssid)
    }
}
```

## NetworkCallback registration

```kotlin
class WifiNetworkObserver(private val ctx: Context) {
    private val cm = ctx.getSystemService(ConnectivityManager::class.java)
    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            WifiStateCache.refresh()
        }
        override fun onCapabilitiesChanged(
            network: Network,
            caps: NetworkCapabilities,
        ) {
            // Capabilities update fires при roaming, SSID change, etc.
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
                WifiStateCache.refresh()
            }
        }
        override fun onLost(network: Network) {
            WifiStateCache.clear()
        }
    }

    fun start() {
        val req = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .build()
        cm.registerNetworkCallback(req, callback)
    }

    fun stop() = cm.unregisterNetworkCallback(callback)
}
```

Регистрируется в `BoxApplication.onCreate` (process scope). Lifecycle = process lifecycle, не VPN service. Это правильно — wifi state нужно знать ДО старта sing-box (config может содержать wifi rules).

## Auto-history hook

```kotlin
object WifiHistoryBridge {
    private var channel: MethodChannel? = null

    fun attach(ch: MethodChannel) { channel = ch }

    fun notify(ssid: String, bssid: String) {
        // Run on main thread (MethodChannel requirement).
        Handler(Looper.getMainLooper()).post {
            channel?.invokeMethod("onWifiSeen", mapOf(
                "ssid" to ssid,
                "bssid" to bssid,
            ))
        }
    }
}
```

Dart-side в `BoxVpnClient` или новый сервис (`WifiHistoryListener`):

```dart
_channel.setMethodCallHandler((call) async {
  if (call.method == 'onWifiSeen') {
    final m = (call.arguments as Map).cast<String, String>();
    await SettingsStorage.addToWifiHistory(
      m['ssid'] ?? '',
      m['bssid'] ?? '',
    );
  }
});
```

`addToWifiHistory` уже идемпотентен — upsert по `(ssid, bssid)` обновляет `last_seen` без дубликата. Cap 50, evict oldest.

## Resource budget

| Что | Стоимость |
|---|---|
| **Cache read** (hot path) | volatile read + nullness check + age check. Микросекунды. |
| **Cache miss / stale** | один binder IPC, ~ms. Только при первом читателе после ChangeEvent или после 30s idle. |
| **NetworkCallback** | event-driven, no polling. Стоимость = wakelock на момент event'а (микросекунды). |
| **MethodChannel notify** | при actual network change (роуминг, переподключение). Реально 1-5 раз в день у обычного юзера. Бесплатно. |
| **Storage write** | `addToWifiHistory` — JSON serialize 50 entries × ~100 bytes = 5KB write. На каждое actual change. |

Бюджет: одна операция write на смену сети. Read из cache бесплатен.

## Edge cases

| Кейс | Поведение |
|---|---|
| Permissions revoked mid-session | `refresh()` ловит `SecurityException` → cache cleared → sing-box получает null. Existing F12.3 fix. |
| App startup ДО первого NetworkCallback fire | Первый `readWIFIState()` идёт через `refresh()` (cache empty + stale TTL=0) → один IPC, потом cached. |
| Wi-Fi off / cellular only | NetworkCallback `onLost` → cache cleared → readWIFIState returns null. |
| Roaming между BSSID одного SSID | `onCapabilitiesChanged` triggers refresh → новый bssid в кеше. История получает новую entry с тем же ssid но другим bssid. |
| Hidden SSID (`<unknown ssid>`) | refresh пишет `WIFIState("", "")` → onChanged не вызывается (ssid пустой). Не засирает историю. |
| Permission revoked: sing-box busy при revoke | Race: пока sing-box hot-path читает cache, NetworkCallback может ещё не fire'нуть. Read возвращает stale value. После TTL 30s → stale-refresh → SecurityException → null. Acceptable (короткое окно мисматча). |

## Tests

- Unit-test для `WifiStateCache.refresh()` с mock'ed `WifiManager`:
  - Returns valid info → cache set + `onChanged` fires
  - Same info повторно → `onChanged` НЕ fires
  - SecurityException → cache cleared, no `onChanged`
  - `<unknown ssid>` → cache set to empty, no `onChanged`
- Integration на устройстве:
  - Включить wifi rule в config + connect VPN
  - Ходить sing-box logs (Forward sing-box logs ON) — наблюдать что binder IPC count к WifiManager не растёт пропорционально connection rate (нужен `dumpsys binder_calls_stats`)
  - Toggle wifi off/on — наблюдать что cache clear → set цикл работает + history grows naturally

## Acceptance

- [ ] `WifiStateCache` singleton + unit tests
- [ ] `WifiNetworkObserver` registered в `BoxApplication.onCreate`, unregister при `onTerminate`
- [ ] `PlatformInterfaceWrapper.readWIFIState()` теперь cache.read() — не binder IPC на каждый call
- [ ] `WifiHistoryBridge` MethodChannel + Dart handler в `BoxVpnClient` (или свой сервис)
- [ ] `wifi_history` растёт автоматически при смене сети (без вызова Add current)
- [ ] Permission revoke → cache cleared → null gracefully (не crash)
- [ ] Manual «Add current» в editor продолжает работать (тот же `getCurrentWifiInfo` channel — может стать `cache.read()` под капотом, или остаться форс-IPC для freshness)
- [ ] Без regression: 548 tests + smoke на устройстве

## Out of scope (Phase 4+)

- **Per-app wifi history** — отдельная entry на каждое приложение которое матчилось на эту сеть. Нет use-case.
- **Geo correlation** — «эта SSID = домашняя сеть» через bssid → фиксированный outbound preset. Слишком complex для wifi rules.
- **Multi-network simultaneous** (Wi-Fi + Cellular одновременно) — sing-box один SSID отдаёт через `connectionInfo`, не multi. Если понадобится — отдельный API.
