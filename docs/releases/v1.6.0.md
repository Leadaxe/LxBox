# L×Box v1.6.0

«Diagnostics + recovery + DNS-cleanup» release. libbox 1.13.x migration with native VPN service rewrite under the hood; user-visible — light-recovery (Reload button + reset-network), per-group ping/test settings, human-readable error banners, fixed RU DNS routing via ru-direct preset, backup/restore UI, and more.

**Quick links:**
[✨ Highlights](#-highlights) ·
[🐞 Fixes](#-fixes) ·
[🏗 Under the hood](#-under-the-hood) ·
[⚠ Breaking](#-breaking) ·
[🇷🇺 На русском](#-l×box-v160-на-русском)

---

## ✨ Highlights

### Light-recovery without losing the tunnel

- **Reload button in the AppBar.** Default tap = light reload of the sing-box core (`commandServer.startOrReloadService`) — no TUN teardown, no full reconnect. In-place restart with the same config in <1s. Long-press menu also lists Reload as the first item.
- **`POST /action/reset-network`** Debug API. Calls sing-box `commandServer.resetNetwork()`: closes all active connections + flushes DNS cache + resets DoH/DoT transports + refreshes inbound/outbound dialers. No box runtime / Service / TUN recreate. Use it when DoH connection pool went stale after long idle (≈ what Reload does, but addressable from adb).

### Per-group ping/test settings

Each VPN group can now have its **own** test endpoint (URL + timeout) for ping / mass-URLTest / group URLTest. Useful when groups have different routing semantics:

| Group | Routing | Recommended endpoint |
|---|---|---|
| VPN-1 (foreign-routed) | through bypass-VPN | `https://www.gstatic.com/generate_204` |
| VPN-2 (РФ-direct) | direct path / WG router in Russia | `https://ya.ru/` |
| VPN-3 (China-direct, hypothetical) | direct path in CN | `https://baidu.com/` |

Earlier the single global URL would false-negative for half the groups. Now: storage shape `ping_options: {url?, timeout_ms?, groups: {<groupTag>: {url?, timeout_ms?}}}` mirrors the template; resolve chain is per-group → global → template default.

UI: in **Ping Settings** dialog there's now a SegmentedButton «All groups | <currentGroup>», plus a Reset-to-global button when an override exists.

Debug API: `GET/PUT /settings/ping_options` (full structure), `GET/PUT/DELETE /settings/ping_options/groups/{tag}` (scoped).

**Bonus fix:** the previous global `pingUrl`/`pingTimeout` lived only in HomeController memory — not persisted. On every app restart the UI showed a misleading template default. Now persists to `SettingsStorage`.

### Backup & restore UI

New screen — export/import user data (server lists / routing rules / app settings / debug config) as a single JSON. 4 toggleable categories, dry-run preview before apply, merge vs replace mode. Export through `share_plus`, import through `file_picker`. Same surface available via Debug API: `GET /backup/export?include=...`, `POST /backup/import?merge=...`.

### Human-readable error banners

Replaced raw Dart exception toString'ы in user-visible places with a unified `formatUserError(e)` helper. No more leaked technical jargon (`Future not completed`, `errno = N`, long `address = ...` tuples, `PlatformException(code, msg, null, null)`):

| Error | Before | After |
|---|---|---|
| Ping timed out | `Ping: TimeoutException after 0:00:10.000000: Future not completed` | `direct-out → ya.ru — timeout 5.8s` |
| Native VPN start failed | `PlatformException(start_failed, vpn_service.prepare returned false, null, null)` | `vpn_service.prepare returned false` |
| Clash API unreachable | `Clash API: SocketException: Connection refused (OS Error: Connection refused, errno = 61), address = ...` | `Clash API: Connection refused` |
| File pick — missing file | `Failed to read file: FileSystemException: Cannot open file, path = '/p' (OS Error: No such file or directory, errno = 2)` | `Failed to read file: No such file or directory` |
| Invalid JSON paste | `Invalid JSON: FormatException: Unexpected character (at character 5)\n{...}\n^` | `Invalid JSON: Unexpected character` |

Applied in `home_controller.dart` (file pick, start/stop/reconnect VPN, Clash API refresh, switch node) and snackbar'ах 6 экранов (config / backup / dns_settings / node_settings / debug / speed_test).

### `ru-direct` preset works in Russia again

Default DNS for the `ru-direct` preset switched from **DoH/Safe-tier** (`yandex_doh @ 77.88.8.88`, HTTPS/443) to **UDP/Base-tier** (`yandex_udp @ 77.88.8.8`, UDP/53). Reason — for users where `outbound = direct-out` or a WG router in RU, the Yandex DoH endpoint on `:443` was DPI-blocked: TLS handshake to `safe.dot.dns.yandex.net` hangs, while ICMP/UDP to the same IP works fine. All `.ru` lookups via `ru-direct` failed → `ERR_CONNECTION_REFUSED` in the browser and Tinkoff/etc mobile apps. UDP/53 on 77.88.8.8 is universally permitted.

Tooltip on `dns_server` shortened: «Recommended: Base/UDP — most stable. DoH/DoT may be filtered by ISPs.». Options reordered — Base/UDP first.

**Existing installs unaffected**: explicit `vars_values` in `SettingsStorage` take precedence over the template default; new default fires only for users who never picked a value (or reset).

### Empty template DNS catch-all

Removed the template-level catch-all `{name: "Default → Google DoH", server: google_doh}` from `wizard_template.json`. Anything not matched by preset/inline DNS rules now flows through `dns.final` (= variable `@dns_final`, default `local_dns_resolver` = system resolver via PlatformInterface; user can override in the wizard).

Why: `google_doh` (HTTPS/443) was degrading on long idle — DoH connection pool went stale → re-dial failed → entire fall-through DNS died (observed twice this week, recovery via `resetNetwork()`/Reload). System resolver is state-less and not subject to this.

Existing users with a `Default → Google DoH` storage entry — orphan cleanup in `resolveDnsRulesList` removes it on the next config rebuild. Tooltip on `dns_final` updated. Also, the `direct_dns_resolver` server tag was renamed to `google_udp` for symmetry with `cloudflare_udp` naming.

### Sing-box internal logs in Debug API + AppLog

`GET /logs/core` exposes router/dns/inbound/outbound events from sing-box itself. Source delivery: `PlatformInterface.writeDebugMessage` → `EventChannel("lxbox/coreLog")` → new `ClashLogPump` Dart subscriber → `AppLog` as `DebugSource.core`. Level parsed via regex (`\bWARN\b`/`\bERROR\b` etc.); TRACE/DEBUG dropped on the native side for volume reduction; ANSI escape codes stripped.

Toggle: `PUT /settings/core_logs_enabled {"enabled":true}` (default false; storage in `SharedPreferences boxvpn_boot.core_logs_enabled` because `Libbox.setup` reads it before Flutter engine; **takes effect after force-stop & restart of the app**).

UI toggle: **App Settings → Diagnostics → "Forward sing-box logs"**. Shortcut from DebugScreen ⋮ menu → "Diagnostics settings".

### AppLog per-source quotas + persistent split

The single 500-entry ring-buffer was outgrown by sing-box's verbosity (hundreds of lines/min on busy traffic) — app-level messages would get evicted within minutes. Now: `Map<DebugSource, List>` with independent caps `app=300`, `core=500`. K-way merge on read (insert is O(1) amortized), `entriesForSource(s)` direct lookup without merge for filtered queries. Persistent split: `applog.txt` (app warn/error) + `corelog.txt` (core warn/error), 200 lines / 64KB each — `initPersistent()` loads both.

Debug API: `GET /logs/app`, `GET /logs/core` (aliases for `/logs?source=...`); `POST /logs/clear?source=app|core` for per-source clear.

### Debug API: `PUT /config` + lockable rebuild

Two new endpoints for testing sing-box features that our parser/builder doesn't yet understand (e.g., Tailscale outbound):

- `PUT /config` with raw sing-box JSON — sing-box reloads with that config.
- `PUT /settings/config_locked {"locked": true}` — pins the config from UI rebuilds (`SubscriptionController.generateConfig()` returns null silently while locked).
- `GET /state/config_locked` — current state.

Storage: `config_locked_for_debug`, default false.

### Misc UI

- **Core version visible in About dialog** (`commandServer.coreVersion()` next to the app version) — quick glance to see which libbox is shipped.

---

## 🐞 Fixes

- **Clash delay endpoint hang after ~27 min uptime** (root-cause [§039 libbox migration](../spec/features/039%20libbox%201.13%20migration/spec.md)). Symptom: every node in the server list showed "err" in the UI after 28-30 minutes of active VPN session, even though traffic through the selected node kept flowing. Hours-long sessions silently broken for anyone trying to compare nodes or do a manual switch. Root cause — DNS cache dedup-lock goroutine leak in sing-box `dns/client.go:144-164`: the per-question wait channel blocked **without** `ctx.Done()`-awareness; the first time an upstream DNS-transport froze, all subsequent waiters parked forever, including the probe-mechanism goroutines. Fix — upstream commit `aba8346b` ("Fix DNS cache lock goroutine leak"), shipped in sing-box `v1.12.21+` and `v1.13.0+`.
- **Mass ping cancel actually cancels** ([§034](../spec/tasks/034-mass-ping-cancel-actually-cancels.md)). Tapping Stop during a mass-ping previously left three side-effects:
  1. Spinner indicators kept hanging until timeout for nodes that hadn't responded yet (worker `break` without cleaning up pingBusy state).
  2. `_runAllUrltestGroups` kept iterating the auto-group regardless of cancel.
  3. In-flight HTTP delay/groupDelay requests kept executing (Dart `http.Client` has no per-request cancel).
  Fix: `cancelMassPing` now (1) clears `pingBusy` entirely; (2) `_runAllUrltestGroups(epoch)` checks epoch on every iteration; (3) `ClashApiClient` has a separate `_delayHttp` client for delay/groupDelay — `cancelDelays()` closes it, in-flight HTTP sockets drop, workers get an exception and break.
- **Clash delay/groupDelay timeout sync** ([§040](../spec/tasks/040-per-group-ping-test-settings.md)). The Dart-side wrapper used a hardcoded `_timeout = 10s` regardless of the `timeoutMs` query-param sent to clash API. If the user set `timeout_ms=5000`, the Dart side still waited 10s and threw `TimeoutException` instead of getting a clean clash response. Now `Duration(milliseconds: timeoutMs) + _delayResponseBuffer` where `_delayResponseBuffer = 750ms` (cleanup buffer on the sing-box side: cancel TCP/TLS, JSON-encode, deliver via loopback). Applied in `delay()` and `groupDelay()`.

---

## 🏗 Under the hood

- **libbox: 1.12.12 → 1.13.11** ([§039](../spec/features/039%20libbox%201.13%20migration/spec.md)). Major architectural changes:
  - `BoxService` class deleted in 1.13 — its API absorbed into `CommandServer`. Single `CommandServer` owns runtime via `startOrReloadService(config, opts)`. Two-phase shutdown: `closeService()` → `close()`.
  - `PlatformInterface` simplified: removed `writeLog`, `packageNameByUid`, `uidByPackageName` — sing-box now maintains UID→package mapping itself and exposes package names via richer `ConnectionOwner` struct.
  - `Seq.destroyRef` no longer called — Go runtime in 1.13 self-cleans refnums; manual destroyRef = double-free.
  - Two-phase shutdown on `Dispatchers.IO` — order matters; swapping = Go callbacks may hang → ANR.
- **Dart wrapper cleanup** (`box_vpn_client.dart`):
  - `getVpnStatus()` / `onStatusChanged` return typed `TunnelStatus` / `TunnelStatusEvent` instead of `String` / `Map<String, dynamic>`.
  - `BackgroundMode` enum (was `String 'never|lazy|always'`).
  - `AppInfo` model — typed class in `lib/models/app_info.dart`.
  - **MethodChannel timeouts** on critical calls — `getVpnStatus` (3s), `startVPN` (30s), `stopVPN` (10s), `getInstalledApps` (15s); on timeout → `AppLog.error` + safe-default fallback.
  - `BoxVpnClient.I` singleton + `BoxVpnClient.forTest({methods, events})` factory for unit tests.
  - Method-name constants (`_Methods.saveConfig` etc.) — centralized contract with `VpnPlugin.kt`.
- **DNS rules schema cleanup** ([§041 dns rules](../spec/features/041%20dns%20rules%20refactor/spec.md) + [§032](../spec/tasks/032-dns-rules-schema-symmetry.md) + [§033](../spec/tasks/033-unified-kind-vocabulary.md)). Discriminator `dns_options.rules[i].type` → `kind`; vocabulary `inline | srs | preset | template` shared with `custom_rules`. For `kind: preset` we store `presetId` (immutable) instead of mutable `title=preset.label`. Field rename `title` → `name`. Auto-link on creation / mandatory link on deletion: adding a `custom_rules.kind:preset` automatically creates the matching `dns_options.rules.kind:preset` entry (when the preset has a `dns_rule` in the template). **Independent enable** for route-aspect ↔ DNS-aspect: a preset's DNS rule can be turned off without losing routing. **No migration** — legacy keys silently dropped, auto-discovery rebuilds fresh state from current template + active presets.
- **Action endpoints unified into `/action/urltest`** ([§040](../spec/tasks/040-per-group-ping-test-settings.md)). One endpoint with scope-dispatch by query — simpler than three parallel paths:
  - `POST /action/urltest?tag=<node>` — single-node URLTest
  - `POST /action/urltest?group=<group>` — group URLTest
  - `POST /action/urltest?all=true` — mass URLTest of active group
  - HomeController methods renamed: `pingNode` → `runNodeUrltest`, `pingAllNodes` → `runMassUrltest`. `runGroupUrltest` unchanged.
- **Persistent docs-update map** ([`docs/spec/README.md`](../spec/README.md)). Every spec (feature/task) must list a `## Docs to update` section. Backfill done in §035-§041 + §043. Implementation phase isn't considered done until the docs are synced.

---

## ⚠ Breaking

- **APK is now arm64-only** (~73 MB → ~56 MB). Previously CI shipped a fat-APK with three ABIs (`armeabi-v7a + arm64-v8a + x86_64`); `libbox.so` (~17 MB) and `libapp.so` were duplicated per ABI. Now CI builds `flutter build apk --release --target-platform android-arm64` — same as the local script. Coverage: arm64-v8a covers 95%+ of modern Android; Android 14+ Google has banned 32-bit-only platforms. Excluded: armeabi-v7a-only Android Go budget devices (Itel A48, Tecno Pop 5, Samsung A03 Core) — outside the VPN-client target audience. Those users will see «device not compatible» on install. v1.5.0 was the last fat-APK build.
- **Debug API: `/action/ping-*` endpoints removed**. Renamed and consolidated into `/action/urltest?{tag,group,all}=...`. No backward-compat aliases — adb-scripts and saved curl commands using the old paths will get 404. Update them to the unified endpoint.
- **`wizard_template.json`** no longer ships a default DNS catch-all rule. Anything not matched by preset/inline rules flows through `dns.final` (default `local_dns_resolver`). Existing users keep working through orphan cleanup; new users see `dns.rules` populated only by their active presets/inline overrides.

---

## 📦 Install

[Latest release on GitHub →](https://github.com/Leadaxe/LxBox/releases/latest) · скачайте `LxBox-v1.6.0.apk`, откройте на устройстве (разрешите «установка из неизвестных источников» если потребуется).

APK подписан upload-keystore'ом; устанавливается поверх предыдущих L×Box-версий **только** на arm64-v8a-устройства (95%+ современных Android'ов; armeabi-v7a-only Android Go-будгет-устройства не поддерживаются — увидят «device not compatible»).

---

## 🧪 Tests

`flutter test` — 474 tests passing. New coverage:
- `test/services/error_format_test.dart` — 12 cases for `formatUserError` (TimeoutException / SocketException / FileSystemException / FormatException / ClashHttpException / PlatformException / generic + edge cases).
- `test/services/app_log_per_source_test.dart` — per-source quotas, k-way merge, persistent split.
- `test/services/clash_log_pump_test.dart` — sing-box log level parser.
- `test/services/builder/dns_rules_resolver_test.dart` — auto-discovery + orphan cleanup for §033/§041.

---

## 🇷🇺 L×Box v1.6.0 на русском

**«Диагностика + восстановление + DNS-cleanup».** Под капотом — миграция на sing-box 1.13.x с переработкой нативного VPN-сервиса. Снаружи — light-recovery (Reload и reset-network), per-group ping/test settings, понятные ошибки в UI, починка DNS в РФ через ru-direct preset, backup/restore UI.

### Что увидит юзер

- **Reload-кнопка в AppBar.** Default тап = light reload core'а без обрыва TUN'а — in-place restart sing-box runtime'а с тем же config'ом за <1s. Long-press menu тоже содержит Reload первым пунктом.
- **Backup & restore** — экспорт/импорт настроек через UI (server lists / routing / app settings / debug config). 4 категории, dry-run preview, merge vs replace.
- **Per-group ping/test settings.** VPN-1 тестируется по gstatic, VPN-2 по ya.ru, VPN-3 (если есть) по baidu.com. Раньше один global URL фейлил половину групп. Persist'ятся теперь и global, и per-group настройки (раньше global'ы жили только в памяти).
- **Понятные ошибки.** Вместо `TimeoutException after 0:00:10.000000: Future not completed` теперь `direct-out → ya.ru — timeout 5.8s`. Применено в banner'ах и snackbar'ах.
- **`ru-direct` preset работает в РФ.** Default DNS — UDP/Base (`yandex_udp @ 77.88.8.8`) вместо DoH/Safe (`yandex_doh @ 77.88.8.88`). Раньше Yandex DoH endpoint на :443 у части юзеров (особенно direct-out / WG router в РФ) DPI-режется → весь .ru break'ился. UDP/53 универсально пропускается.
- **Default DNS catch-all убран.** Всё что не матчится preset/inline-правилами идёт в system resolver (раньше — Google DoH, который stale'ился на long-idle и ломал DNS целиком).
- **Mass-ping Stop реально останавливает.** Раньше спиннеры висели до timeout'а + auto-группа продолжала тестироваться.
- **Версия sing-box core видна в About** — рядом с версией приложения.

### Под капотом

- **libbox 1.12.12 → 1.13.11.** Single `CommandServer` (вместо BoxService + CommandServer); упрощённый `PlatformInterface`; two-phase shutdown.
- **Sing-box логи теперь видны в нашем AppLog** через `GET /logs/core` (Debug API) или DebugScreen с фильтром по source. Toggle `Forward sing-box logs` в App Settings → Diagnostics (default OFF; применяется после force-stop). Per-source quotas: app=300, core=500 — sing-box flood не вытесняет app-сообщения.
- **DNS rules schema cleanup**: общая лексика `kind: inline | srs | preset | template` между route и DNS, immutable `presetId` вместо mutable `label`-а, auto-link при создании / orphan cleanup при удалении.
- **Debug API расширен:** `/action/reset-network`, `/action/urltest` (single endpoint, scope через query), `PUT /config` + lockable rebuild, `/settings/ping_options`, `/settings/core_logs_enabled`.
- **APK ~56 MB** (было ~73 MB) — single-arch arm64-v8a.

### ⚠ Breaking

- **APK arm64-only** — armeabi-v7a-only устройства больше не поддерживаются (Android Go бюджет); arm64 покрывает 95%+ современных Android'ов.
- **Debug API: старые `/action/ping-*` удалены без alias'ов.** Adb-скрипты с `/action/ping-node?tag=` / `/action/ping-all` нужно обновить на `/action/urltest?tag=` / `/action/urltest?all=true`.
- **Template больше не содержит default DNS catch-all.** Existing-юзеры — orphan cleanup сам уберёт; new-юзеры увидят `dns.rules` только с preset/inline-правилами.

### 📦 Установка

[Последний релиз на GitHub →](https://github.com/Leadaxe/LxBox/releases/latest) — скачайте `LxBox-v1.6.0.apk`, откройте файл на устройстве, разрешите установку. Поверх предыдущих L×Box-версий встаёт через одну подпись keystore.

---

Предыдущий релиз: [v1.5.0](v1.5.0.md).
