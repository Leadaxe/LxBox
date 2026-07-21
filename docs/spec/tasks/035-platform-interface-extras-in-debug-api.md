# 035 — `PlatformInterface` extras (`readWIFIState` / `clearDNSCache`) + Debug API exposure

| Поле | Значение |
|------|----------|
| Статус | ✅ Реализовано (позже, в изменённой форме) — `readWIFIState()` (WifiInfoReader.kt); clearDNSCache переосмыслен в `ACTION_CLEAR_DNS_CACHE` (§263); WiFi ушёл в MethodChannel `getCurrentWifiInfo`, а не в Debug `/state/wifi`. Шапка «Draft» устарела. |
| Дата | 2026-05-06 |
| Связанные | [`031 debug api`](../features/031%20debug%20api/spec.md), [`030 vpn reload button`](030-vpn-reload-button.md), [`031 reset-network API`](031-reset-network-api.md), [`tasks/060-libbox-1-13-migration`](060-libbox-1-13-migration/spec.md) |

## Цель

В `PlatformInterfaceWrapper.kt` два callback'а из sing-box `PlatformInterface` сейчас no-op:

```kotlin
override fun clearDNSCache() {}
override fun readWIFIState(): WIFIState? = null
```

Sing-box зовёт их когда ему что-то нужно от платформы. `readWIFIState` — для wifi-aware routing rules (`wifi_ssid` / `wifi_bssid` matchers); `clearDNSCache` — flush platform-side DNS cache (на Linux/iOS реальный API есть, на Android — нет).

Делаем две вещи:
1. **Реализовать `readWIFIState()`** правильно через `WifiManager` — sing-box получит корректные SSID/BSSID для wifi-aware rules (если юзер их когда-нибудь добавит).
2. **Документировать `clearDNSCache()` как сознательный no-op** на Android, без выдумывания псевдо-implementation. У нашего `LocalResolver` (см. `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/LocalResolver.kt`) state'а нет — кэшировать там нечего.
3. **Экспонировать оба** через **Debug API** (§031): `GET /state/wifi` и `POST /action/clear-dns-cache`. Первое — для отладки wifi-rule матчинга, второе — для completeness (чтобы юзер мог дёрнуть и увидеть честный `noop` ответ, не думая что endpoint забыли).

## Что делает каждый метод

### `readWIFIState()` — реализовать

Возврат — `WIFIState(ssid, bssid)` (libbox struct, два string-поля). Источник — `WifiManager.connectionInfo` (depricated, но всё ещё единственный способ; новые `NetworkCallback`-based API возвращают `WifiInfo` через capabilities, поведение эквивалентно с т.з. SSID/BSSID).

**Permission caveat:** API 27+ возвращает SSID `"<unknown ssid>"` и BSSID `"02:00:00:00:00:00"` если у app нет одного из:
- `ACCESS_FINE_LOCATION` (API 29+)
- `ACCESS_COARSE_LOCATION` (API 27-28)
- активная NETWORK_SETTINGS-роль (system-only)

VPN-app не имеет легитимного use-case требовать location-permission ради wifi-aware rules — это privacy-нагрузка, юзер скорее откажет. Делаем **best-effort**: читаем то что доступно, sanitize'им placeholder'ы (`<unknown ssid>` / `02:00:00:00:00:00`) → `null`. Если оба null — возвращаем `null` как WIFIState (sing-box тогда матчит как «no wifi info»).

Permission в манифест **не добавляем** — это политика privacy. Если юзер хочет wifi-aware rules — добавит permission через future feature (нужен runtime-prompt на API 23+, отдельная UX-задача за рамками 035).

### `clearDNSCache()` — остаётся no-op (документированно)

Анализ что возможно:

| Вариант | Вердикт |
|---|---|
| `InetAddress.clearCachedHost` | Hidden API, заблокирован non-SDK list'ом с API 28+; reflection не работает |
| `Network.flushDns()` | Не существует в публичном Android API |
| Trigger `DnsResolver.query` с force-refresh | Нет такого флага в API |
| Очистить наш `LocalResolver` cache | `LocalResolver` stateless (см. `LocalResolver.kt`: `lookup` зовёт `InetAddress.getAllByName` каждый раз) — кэшировать нечего |
| Дёрнуть `commandServer.resetNetwork()` (sing-box-side flush) | Это **другой** уровень — таски §031. `clearDNSCache()` — callback от sing-box нам, дёргать его в обратку = loop. Не делаем |

**Решение:** оставить `override fun clearDNSCache() {}`, добавить комментарий-обоснование в Kotlin. Debug API endpoint всё равно делаем — возвращает `platform_op: "noop"` с reason'ом. Это честно отражает реальность для тех кто будет debug'ить wifi/DNS поведение через curl.

## Реализация

### 1. `PlatformInterfaceWrapper.kt`

Заменить:
```kotlin
override fun clearDNSCache() {}
override fun readWIFIState(): WIFIState? = null
```

На:

```kotlin
/// Sing-box просит платформу flush'нуть свой DNS cache.
/// На Android **публичного API нет** — `InetAddress.clearCachedHost` hidden,
/// `DnsResolver` без force-refresh флага. Наш `LocalResolver` stateless
/// (см. LocalResolver.kt). Оставляем сознательным no-op; экспонируем через
/// Debug API `POST /action/clear-dns-cache` для completeness, ответ —
/// `platform_op: "noop"`. См. §035.
override fun clearDNSCache() {}

/// Возвращает текущее wifi state для wifi-aware routing rules (`wifi_ssid` /
/// `wifi_bssid` matchers в sing-box). Best-effort: без `ACCESS_FINE_LOCATION`
/// API 27+ возвращает placeholder'ы ("<unknown ssid>" / "02:00:00:00:00:00")
/// — мы их sanitize'им в null. Permission не добавляем в манифест намеренно
/// (privacy), это feature за рамками §035.
override fun readWIFIState(): WIFIState? {
    val wm = BoxApplication.context.getSystemService(Context.WIFI_SERVICE)
        as? android.net.wifi.WifiManager ?: return null
    val info = runCatching { wm.connectionInfo }.getOrNull() ?: return null
    val ssid = sanitizeSsid(info.ssid)
    val bssid = sanitizeBssid(info.bssid)
    if (ssid == null && bssid == null) return null
    return WIFIState().apply {
        this.ssid = ssid ?: ""
        this.bssid = bssid ?: ""
    }
}

private fun sanitizeSsid(raw: String?): String? {
    if (raw.isNullOrEmpty()) return null
    // WifiInfo.getSsid() оборачивает в кавычки если SSID — UTF-8.
    val unquoted = if (raw.startsWith("\"") && raw.endsWith("\"") && raw.length >= 2)
        raw.substring(1, raw.length - 1) else raw
    if (unquoted == "<unknown ssid>" || unquoted.isEmpty()) return null
    return unquoted
}

private fun sanitizeBssid(raw: String?): String? {
    if (raw.isNullOrEmpty()) return null
    if (raw == "02:00:00:00:00:00") return null  // permission-denied placeholder
    return raw
}
```

`Context` импорт уже есть транзитивно через `BoxApplication`; явно добавить `import android.content.Context` если линтер просит.

### 2. Helper-метод для Debug API: `readWifiStateMap()`

В этом же файле или в `VpnPlugin.kt` — функция возвращающая `Map<String, Any?>` для MethodChannel'а (расширенная по сравнению с тем что нужно sing-box'у — добавляем RSSI/frequency/link_speed для удобства отладки):

```kotlin
fun readWifiStateMap(context: Context): Map<String, Any?> {
    val wm = context.getSystemService(Context.WIFI_SERVICE)
        as? android.net.wifi.WifiManager
    val granted = androidx.core.content.ContextCompat.checkSelfPermission(
        context, android.Manifest.permission.ACCESS_FINE_LOCATION
    ) == android.content.pm.PackageManager.PERMISSION_GRANTED
    val info = runCatching { wm?.connectionInfo }.getOrNull()
    return mapOf(
        "ssid" to sanitizeSsid(info?.ssid),
        "bssid" to sanitizeBssid(info?.bssid),
        "rssi" to info?.rssi,
        "frequency_mhz" to (
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) info?.frequency else null
        ),
        "link_speed_mbps" to info?.linkSpeed,
        "permission_granted" to granted,
    )
}
```

`sanitizeSsid` / `sanitizeBssid` переиспользуются (вынести из interface'а в companion object или top-level private fun).

### 3. `VpnPlugin.kt` — MethodChannel handler

В `onMethodCall` switch (по аналогии с `getCoreVersion`):

```kotlin
"getWifiState" -> {
    // §035 Debug API. Снимок текущего wifi state — SSID/BSSID/RSSI/freq.
    // Best-effort: без ACCESS_FINE_LOCATION на API 27+ SSID/BSSID будут
    // null (sanitize placeholder'ов). permission_granted в ответе говорит
    // юзеру почему пусто.
    try {
        result.success(PlatformInterfaceWrapperKt.readWifiStateMap(context))
    } catch (t: Throwable) {
        Log.e(TAG, "getWifiState failed", t)
        result.success(null)
    }
}
```

(Имя `PlatformInterfaceWrapperKt` — если функция top-level в файле; если в companion — `PlatformInterfaceWrapper.Companion.readWifiStateMap`. Финальный shape выберется при имплементации.)

`clearDNSCache` через MethodChannel **не пробрасываем** — Dart-сторона возвращает `noop`-ответ сама, native-вызов не нужен (нативный no-op = не делать ничего; гонять MethodChannel ради no-op'а это лишний round-trip и lying-about-effort).

### 4. `BoxVpnClient.dart`

Один новый метод:

```dart
/// Snapshot текущего wifi state. Пустой Map если native не смог достать
/// (нет permission / нет WifiManager / not connected to wifi). Поля:
///   ssid, bssid, rssi, frequency_mhz, link_speed_mbps, permission_granted
/// Все опциональны, тип Object? (int / String / bool). См. §035.
Future<Map<String, Object?>?> getWifiState() async {
  final r = await _invoke<Map<dynamic, dynamic>>(
    _Methods.getWifiState,
    timeout: _Timeouts.settings,
    onTimeoutValue: null,
  );
  if (r == null) return null;
  return r.map((k, v) => MapEntry(k.toString(), v));
}
```

Регистрация в `_Methods`:
```dart
static const getWifiState = 'getWifiState';
```

### 5. Debug API — `GET /state/wifi`

В `lib/services/debug/handlers/state.dart` добавить ветку и handler:

```dart
return switch (req.path) {
  // ... existing
  '/state/vpn' => _vpn(req, ctx),
  '/state/wifi' => _wifi(req, ctx),
  _ => throw NotFound('state path: ${req.path}'),
};

Future<DebugResponse> _wifi(DebugRequest req, DebugContext ctx) async {
  final m = await BoxVpnClient().getWifiState();
  if (m == null) {
    return JsonResponse({
      'ssid': null,
      'bssid': null,
      'rssi': null,
      'frequency_mhz': null,
      'link_speed_mbps': null,
      'permission_granted': false,
      'error': 'native unavailable',
    });
  }
  return JsonResponse(m);
}
```

Ответ-shape (success):
```jsonc
{
  "ssid": "Home WiFi",
  "bssid": "aa:bb:cc:dd:ee:ff",
  "rssi": -47,
  "frequency_mhz": 5180,
  "link_speed_mbps": 866,
  "permission_granted": true
}
```

Ответ когда permission'а нет (типичный default state у LxBox):
```jsonc
{
  "ssid": null,
  "bssid": null,
  "rssi": -47,
  "frequency_mhz": 5180,
  "link_speed_mbps": 866,
  "permission_granted": false
}
```

(RSSI/frequency/link_speed — некоторые из них не требуют location-permission и доступны всегда.)

### 6. Debug API — `POST /action/clear-dns-cache`

В `lib/services/debug/handlers/action.dart`, в switch — рядом с `_resetNetwork`:

```dart
'/action/clear-dns-cache' => _clearDnsCache(ctx),
```

Handler:

```dart
/// `POST /action/clear-dns-cache` — semantically symmetric to sing-box
/// `clearDNSCache()` callback, который в `PlatformInterfaceWrapper.kt`
/// реализован как сознательный no-op (на Android публичного API для
/// flush'а platform-DNS-cache не существует). Endpoint возвращает честный
/// `platform_op: "noop"` чтобы отладчик через curl видел реальное
/// поведение, а не думал что мы забыли. Для **реального** flush'а DNS
/// state в sing-box используйте `POST /action/reset-network` (§031).
Future<DebugResponse> _clearDnsCache(DebugContext ctx) async {
  return JsonResponse({
    'ok': true,
    'action': 'clear-dns-cache',
    'platform_op': 'noop',
    'reason': 'Android has no public API for system DNS cache flush; '
        'LocalResolver is stateless. Use /action/reset-network for '
        'sing-box-side DNS transport reset.',
  });
}
```

Никакого `requireHome()` — endpoint работает даже когда tunnel down, не требует ресурсов.

## Permissions

В `AndroidManifest.xml` **ничего не добавляется**. `ACCESS_FINE_LOCATION` намеренно не запрашивается — privacy нагрузка несоразмерна use-case'у (wifi-rules — фича за рамками 035). Когда/если такая фича появится — позже, отдельной таской с runtime-prompt'ом.

`ACCESS_WIFI_STATE` **не нужен** для `WifiManager.connectionInfo` (нужен только для сканирования; у нас просто active connection info — pre-installed permission).

## Test plan

Это task — unit-тесты не пишем (pure native + JSON-pass-through). Smoke через curl и adb:

```bash
TOKEN="..."  # из Debug API settings
BASE="http://127.0.0.1:9270"

# 1) wifi state — connected to wifi, no permission
curl -s -H "Authorization: Bearer $TOKEN" $BASE/state/wifi | jq
# expected: ssid: null, bssid: null, rssi: <int>, permission_granted: false

# 2) wifi state — connected to wifi, после ручного grant permission'а через adb
adb shell pm grant com.leadaxe.lxbox android.permission.ACCESS_FINE_LOCATION
curl -s -H "Authorization: Bearer $TOKEN" $BASE/state/wifi | jq
# expected: ssid: "<реальный SSID>", bssid: "<MAC>", permission_granted: true

# 3) wifi state — отключиться от wifi (только cellular)
curl -s -H "Authorization: Bearer $TOKEN" $BASE/state/wifi | jq
# expected: всё null (или error: "native unavailable")

# 4) clear-dns-cache — должен ВСЕГДА возвращать noop
curl -s -X POST -H "Authorization: Bearer $TOKEN" $BASE/action/clear-dns-cache | jq
# expected: {"ok": true, "action": "clear-dns-cache", "platform_op": "noop", "reason": "..."}
```

Sing-box-side smoke (что `readWIFIState()` действительно зовётся когда конфиг матчит wifi):
- Добавить временное правило `{"wifi_ssid": ["Anything"], "outbound": "direct"}` в config
- Tail logcat'а sing-box-tag — должны быть строки `dns: lookup ssid match` или эквивалентные

Если sing-box не зовёт `readWIFIState` без wifi-rule в конфиге — это нормально (lazy), отдельной верификации в рамках 035 не требует.

## Что НЕ в скопе

- **Runtime-prompt для `ACCESS_FINE_LOCATION`** + UX flow в Settings («Enable wifi-aware rules?») — будущая feature, не task. Когда (и если) добавится — добавить ссылку отсюда.
- **UI для wifi-rules** в Custom Rules editor — отдельная задача. Поля `wifi_ssid` / `wifi_bssid` в `CustomRule.dart` уже могут существовать (sealed-rule supports), но editor их не показывает — это UX-фича.
- **Реальный platform-DNS flush** на Android — не делаем псевдо-implementation. Когда Google добавит публичный API (сомнительно) — обновим. До тех пор `clear-dns-cache` остаётся честным no-op'ом, а `reset-network` (§031) — реальным инструментом для DNS-recovery.
- **Расширение `WIFIState` libbox-struct'а** дополнительными полями (RSSI и т.п.) — это upstream sing-box, не наша задача. RSSI/freq/link_speed мы экспонируем **только в Debug API ответе**, не в sing-box callback.
- **Periodic emission** wifi-state'а через EventChannel (для UI badge типа "connected via WiFi 5") — отдельная task'ка если понадобится.

## Risks

| Риск | Митигация |
|---|---|
| `WifiManager.connectionInfo` deprecated с API 31, может вернуть null на новых OEM | runCatching + null-check; fallback к `null` WIFIState — sing-box обработает как «нет wifi info» |
| BSSID/SSID — sensitive PII, leak через Debug API | Debug API уже за Bearer-токен auth + локальный bind на 127.0.0.1 (см. §031); токен ротируется. На уровне SSID/BSSID это не более чувствительно чем уже-экспонируемые `/state/clash` (proxy creds) или `/state/storage` (full settings dump) |
| Юзер врубит wifi-rule в конфиге, но без `ACCESS_FINE_LOCATION` — правило не сматчится, юзер не поймёт почему | `permission_granted: false` в `/state/wifi` ответе делает причину видимой; future UX-feature даст runtime-prompt. На уровне 035 — документация в response'е |
| `WifiInfo.getSsid()` quirks: на API 33+ может возвращать `WifiManager.UNKNOWN_SSID` константу вместо `"<unknown ssid>"` строки | sanitize handles обе формы; на новых SDK добавить branch `if (Build.VERSION.SDK_INT >= 33 && raw == WifiManager.UNKNOWN_SSID)` если репродьюсится |
| `clearDNSCache()` callback зовётся sing-box'ом часто, наш no-op даёт false-impression что cache reset происходит | Sing-box сам имеет internal DNS cache (`dns/router.go`), который flush'ится через свой собственный `dns.Router.ClearCache()` независимо от platform callback'а. Наш no-op платформенный — не ломает sing-box-side кэш |

## Docs to update

См. постоянную карту в [`docs/spec/README.md → Карта обновления документации`](../README.md#карта-обновления-документации).

| Файл | Что добавить |
|---|---|
| [`docs/api/debug-api-reference.md`](../../api/debug-api-reference.md) | `GET /state/wifi` (читает Android WifiManager — SSID/BSSID/RSSI/freq/link_speed sanitize'нутые; `permission_granted` поле). `POST /action/clear-dns-cache` (no-op stub с честным `platform_op:"noop"` response'ом, ссылка на `/action/reset-network` §031 как реальный инструмент). Bash use-cases. |
| [`CHANGELOG.md`](../../../CHANGELOG.md) | Entry в `Unreleased`: «Debug API: `/state/wifi` для Android wifi state, `/action/clear-dns-cache` no-op stub». |
| [`docs/ARCHITECTURE.md`](../../ARCHITECTURE.md) | Опционально — заметка в native-side / PlatformInterface section про `readWIFIState` implementation. |
| [`RELEASE_NOTES.md`](../../../RELEASE_NOTES.md) + [`docs/releases/vX.Y.Z.md`](../../releases/) | На bump'е версии — entry про wifi state endpoint. |
| [`pubspec.yaml`](../../../app/pubspec.yaml) | Patch bump в release-batch'е с §035-§037. |
