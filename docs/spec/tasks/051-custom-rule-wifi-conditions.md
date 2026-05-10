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

# Phase 3 — Auto-record `wifi_history` with stickiness debounce

## Цель

История wifi-сетей сейчас наполняется только при явных user actions (Add current / Manual). Если юзер не использует editor через Add current, «Pick saved» остаётся пустым. Phase 3 — listener который пишет в history ровно те сети **на которых юзер реально сидел дольше N секунд**, чтобы:

1. История росла без ручных действий.
2. Не засорять её случайными drive-by сетями (магазин, в который зашёл на 30 сек, кафе с 5-минутной чашкой кофе и забытым выходом).

## Stickiness debounce — ключевая часть

**Без debounce auto-record становится trap'ом**: один день в Москве по делам = 10-15 random SSID в истории, через неделю «Pick saved» забит мусором, нужного домашнего SSID не найти.

**С debounce**: записывается только если юзер пробыл на сети ≥ `STICKINESS_THRESHOLD_MS` (default 60 секунд). Прошёл мимо кафе → не записалось. Сел работать на час — записалось.

```kotlin
// 60 секунд — middle ground. Дом / офис / постоянное кафе = легко больше
// минуты. Случайные drive-by hotspot'ы = меньше. Тюнинг через в Diagnostics
// если понадобится (probably overengineering, не предусматриваем).
private const val STICKINESS_THRESHOLD_MS = 60_000L
```

LRU-eviction по `last_seen` (cap 50, уже есть) — second line of defense: если debounce пропустит что-то, старая запись вытеснится свежими «настоящими» сетями.

## Архитектура

```
┌─ BoxApplication.onCreate ───────────────────────────────────┐
│                                                             │
│  WifiNetworkObserver.start()                                │
│  ├─ NetworkRequest(TRANSPORT_WIFI)                          │
│  ├─ ConnectivityManager.NetworkCallback                     │
│  │  ├─ onCapabilitiesChanged(net, caps)                     │
│  │  │  └─ if WIFI: read connectionInfo → handlePending()    │
│  │  └─ onLost(net)                                          │
│  │     └─ pending = null                                    │
│  └─ Pending tracker:                                        │
│     ┌──────────────────────────────────────┐                │
│     │ var pendingSsid: String?             │                │
│     │ var pendingBssid: String             │                │
│     │ var pendingSince: Long               │                │
│     │ scheduledRunnable                    │                │
│     │                                      │                │
│     │ handlePending(ssid, bssid):          │                │
│     │   if (ssid, bssid) == pending:       │                │
│     │     keep timer running               │                │
│     │   else:                              │                │
│     │     cancel timer                     │                │
│     │     pending = (ssid, bssid)          │                │
│     │     pendingSince = now               │                │
│     │     schedule(60s) → emit             │                │
│     └──────────────────────────────────────┘                │
│                                                             │
└─────────────────────────────────────────────────────────────┘
                                ▼ MethodChannel "onWifiSeen"
                  ┌──────────────────────────────────┐
                  │ Dart: SettingsStorage            │
                  │ .addToWifiHistory(ssid, bssid)   │
                  │ (idempotent, cap 50, LRU evict)  │
                  └──────────────────────────────────┘
```

**Никакого cache** — `PlatformInterfaceWrapper.readWIFIState` остаётся как сейчас (defensive try/catch + binder IPC). Cache deferred в Phase 4 если измерение покажет необходимость (см. Out of scope).

**Никакого TTL fallback** — NetworkCallback на Android надёжен; если он не fire'ит, у нас другие проблемы.

## Реализация (high-level)

```kotlin
class WifiNetworkObserver(private val ctx: Context) {
    private val cm = ctx.getSystemService(ConnectivityManager::class.java)
    private val handler = Handler(Looper.getMainLooper())
    private var pending: Triple<String, String, Long>? = null  // ssid, bssid, since
    private var pendingTimer: Runnable? = null

    private val callback = object : NetworkCallback() {
        override fun onCapabilitiesChanged(net: Network, caps: NetworkCapabilities) {
            if (!caps.hasTransport(TRANSPORT_WIFI)) return
            val info = readWifi() ?: return
            handlePending(info.ssid, info.bssid)
        }
        override fun onLost(net: Network) {
            cancelPending()
        }
    }

    fun start() {
        val req = NetworkRequest.Builder()
            .addTransportType(TRANSPORT_WIFI).build()
        cm.registerNetworkCallback(req, callback)
    }

    private fun handlePending(ssid: String, bssid: String) {
        if (ssid.isEmpty()) return
        val cur = pending
        if (cur != null && cur.first == ssid && cur.second == bssid) return
        cancelPending()
        pending = Triple(ssid, bssid, System.currentTimeMillis())
        pendingTimer = Runnable {
            // Threshold met — promote to history.
            WifiHistoryBridge.notify(ssid, bssid)
            pending = null
        }
        handler.postDelayed(pendingTimer!!, STICKINESS_THRESHOLD_MS)
    }

    private fun cancelPending() {
        pendingTimer?.let(handler::removeCallbacks)
        pendingTimer = null
        pending = null
    }

    /// Reuse same logic as PlatformInterfaceWrapper.readWIFIState — defensive
    /// SecurityException catch + <unknown ssid> normalization. На permission
    /// missing просто skip (history не пишем).
    private fun readWifi(): WIFIState? = ...  // copy-paste pattern из §050
}
```

```kotlin
object WifiHistoryBridge {
    private var channel: MethodChannel? = null
    fun attach(ch: MethodChannel) { channel = ch }
    fun notify(ssid: String, bssid: String) {
        Handler(Looper.getMainLooper()).post {
            channel?.invokeMethod("onWifiSeen", mapOf(
                "ssid" to ssid, "bssid" to bssid))
        }
    }
}
```

```dart
// В app/lib/main.dart или новом WifiHistoryListener:
_channel.setMethodCallHandler((call) async {
  if (call.method == 'onWifiSeen') {
    final m = (call.arguments as Map).cast<String, String>();
    final ssid = m['ssid'] ?? '';
    final bssid = m['bssid'] ?? '';
    if (ssid.isNotEmpty) {
      await SettingsStorage.addToWifiHistory(ssid, bssid);
    }
  }
});
```

## Resource budget

| Что | Стоимость |
|---|---|
| **NetworkCallback subscription** | Event-driven; стоимость = wakelock в момент fire (микросекунды) |
| **Pending timer** | `Handler.postDelayed` — стандартный Android primitive, бесплатно |
| **MethodChannel `onWifiSeen`** | Один call на actual stable network change (~5 раз в день у обычного юзера) |
| **Storage write** | JSON serialize 50 × ~100 bytes = 5KB на каждое stable change |

Бюджет: близок к нулю. Никакого polling, hot-path никак не затрагивается.

## Edge cases

| Кейс | Поведение |
|---|---|
| Подключился к Wi-Fi на 30 сек → выключил | Pending timer cancelled на onLost. История чистая. |
| Подключился, посидел 65 сек, отключился | Через 60 сек → history append. Через 65 сек → onLost (pending уже null). |
| Roaming между AP одного SSID (BSSID меняется) | Каждое CapabilitiesChanged → новый pending (другой BSSID). Если пробыл 60+ сек на каждом → две entries в истории (это OK). |
| Hidden SSID (`<unknown ssid>`) | `readWifi` вернёт `WIFIState("", "")` → empty ssid → handlePending skip. |
| Permission revoked после старта observer | `readWifi` ловит SecurityException → null → skip. История не пишется до restore permission. |
| App restart посреди pending окна | Pending state не персистится — теряется. Юзер пробыл 50 сек, restart, снова 60 сек → запись через ~110 сек. Acceptable (mostly invisible). |
| Юзер на VPN'е через cellular, wifi off | NetworkCallback `onLost` fires → cancelPending. Никакой записи. |

## Tests

- Unit-test для `WifiNetworkObserver.handlePending`:
  - Same (ssid, bssid) повторно → таймер не пересоздаётся
  - Different (ssid, bssid) → старый таймер cancel, новый schedule
  - `onLost` → pending cleared
  - После 60 сек same network → MethodChannel notify fires ровно один раз
- Integration на устройстве:
  - Connect VPN, остаться на одной сети 65 сек → проверить что entry появилась в `wifi_history` (через `/state/storage` Debug API endpoint)
  - Toggle wifi off через 30 сек → entry НЕ должна появиться
  - Roaming на другую SSID — посмотреть что pending перезаписывается

## Acceptance

- [ ] `WifiNetworkObserver` registered в `BoxApplication.onCreate`
- [ ] `STICKINESS_THRESHOLD_MS = 60_000` константа
- [ ] Pending state per process (не персистится — by design)
- [ ] `WifiHistoryBridge` MethodChannel + Dart handler
- [ ] `wifi_history` растёт ровно когда юзер реально пробыл на сети ≥ 60 сек
- [ ] Permission revoke → skip без crash
- [ ] Без regression: 548 tests pass, smoke на устройстве

## Out of scope (Phase 4 — only if measured needed)

**`WifiStateCache` для readWIFIState hot path** — premature optimization без бенчмарка. Перед добавлением:

1. Включить Forward sing-box logs + busy traffic + wifi rule в config.
2. Снять `dumpsys binder_calls_stats com.leadaxe.lxbox` до/после.
3. Если IPC к `WifiManager` не пропорционален connection rate (sing-box внутри уже дедупит) → cache не нужен, close Phase 4.
4. Если IPC растёт линейно с traffic → добавить cache backed by NetworkCallback (тот же `WifiNetworkObserver` экспозит cached `current: WIFIState?` для hot path).

Не имплементить «на всякий случай».
