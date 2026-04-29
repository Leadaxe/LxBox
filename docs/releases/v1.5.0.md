# L×Box v1.5.0

Reliability + UX + introspection iteration. Critical fix for Android 9-11 startup. Two new user-facing protocols / shortcuts. Full crash diagnostics.

**Quick links:**
[✨ Highlights](#-highlights) ·
[🐞 Fixes](#-fixes) ·
[⚠ Breaking](#-breaking) ·
[🇷🇺 На русском](#-l×box-v150-на-русском)

---

## ✨ Highlights

### Protocols & connectivity

- **NaïveProxy** ([§037](https://github.com/Leadaxe/LxBox/blob/develop/docs/spec/features/037%20naive%20proxy/spec.md), [#2](https://github.com/Leadaxe/LxBox/issues/2)) — parser for `naive+https://` URIs (DuckSoft format), generator for sing-box `type: "naive"` outbound, share-URI round-trip. 10th typed protocol in Parser v2. Cronet (`with_naive_outbound`) is already bundled in our `libbox.aar`, no APK-size impact.
- **Quick Connect: QS tile + home-screen shortcut** ([§032](https://github.com/Leadaxe/LxBox/blob/develop/docs/spec/features/032%20quick%20connect/spec.md), [#1](https://github.com/Leadaxe/LxBox/issues/1)) — toggle VPN without opening the app. Tile in the notification shade syncs with `BoxVpnService.currentStatus`; long-press on the launcher icon → **Toggle VPN**. First tap briefly opens the app for the system VPN consent dialog (Android API requirement); subsequent taps go straight to the service.

### Diagnostics

- **Crash diagnostics** ([§038](https://github.com/Leadaxe/LxBox/blob/develop/docs/spec/features/038%20crash%20diagnostics/spec.md)) — four independent post-mortem channels available through one `Share dump` button (⤴ in Debug AppBar) or `GET /diag/dump`:
  - **A. stderr-redirect** — Go panic stacktrace from libbox/sing-box; written to `filesDir/stderr.log` before SIGABRT, survives the process. New conditional `stderr` tab in Debug screen.
  - **B. ApplicationExitInfo** (Android 11+) — `getHistoricalProcessExitReasons` lazy-read in DumpBuilder. Reason + tombstone for NATIVE_CRASH or Java stacktrace for CRASH.
  - **C. Persistent AppLog** — `warning` + `error` levels written to `filesDir/applog.txt` (ring-buffer, 200 entries / 64 KB cap). Loaded on `main()` with `fromPreviousSession=true`, visually marked in UI; survives process restart.
  - **D. Logcat tail** — `Runtime.exec("logcat", "-d", "-t", 1000, "*:E")` via `ProcessBuilder` (no `READ_LOGS` permission needed; logd UID-filters automatically). Catches `AndroidRuntime FATAL EXCEPTION`, `libc`/`DEBUG`/`tombstoned`, `art`/`linker`. Especially useful when AEI didn't attach trace (Samsung One UI quirk on REASON_CRASH).
- **Debug API `/diag/*` group** ([§031](https://github.com/Leadaxe/LxBox/blob/develop/docs/spec/features/031%20debug%20api/spec.md)): `/diag/dump`, `/diag/exit-info`, `/diag/logcat`, `/diag/stderr`, `/diag/applog`. Everything available via UI is also accessible over HTTP for adb-driven flows.
- **Debug API `/backup/*` group** — `GET /backup/export` + `POST /backup/import` для бэкапа/восстановления `{config, vars, server_lists}`. Без диагностического шума и без кешей; совместим с форматом `/diag/dump`. Опции `?merge=` и `?rebuild=` для гибкости restore.
- **`POST /action/preview-empty-state?on=true|false`** — UI-only override empty-state без потери данных, для скриншотов/regression-теста UX.

### Home screen polish

- **First-run empty-state guide** ([task 024](https://github.com/Leadaxe/LxBox/blob/develop/docs/spec/tasks/024-home-empty-state-cta.md)) — на первом запуске (нет конфига) главный экран показывает «Add a server» с крупной круглой `+`-кнопкой → `SubscriptionsScreen`. Никаких disabled-кнопок и догадок куда нажимать.
- **Tap-to-connect zone** — когда серверы есть но VPN не запущен, центр экрана показывает крупную кликабельную зону «Tap to connect» (play-icon 64dp). Тап стартует VPN — равноценно нажатию Start в верхней панели.

### UX & reliability (carryover from earlier dev cycles)

- **Tunnel sleep mode (3-way)** — Settings → Background → «Tunnel sleep mode»: `never` (default; pushes/SIP stay alive at the cost of ~1–3% battery overnight), `lazy` (pause on deep Doze only — old default), `always` (pause on every screen-off, max battery).
- **Tabbed App Settings** — three tabs: **General** (appearance/behaviour/subscriptions/updates), **Background** (battery/notifications/OEM/sleep mode), **Diagnostics** (permissions summary, Debug API).
- **Update check on launch** ([§036](https://github.com/Leadaxe/LxBox/blob/develop/docs/spec/features/036%20update%20check/spec.md)) — daily ping to GitHub Releases; SnackBar on a newer tag with **View** / **Not now**. Manual `Check now` from About / Settings bypasses the cap.
- **Battery-optimization prompt** at startup if not whitelisted (rate-limited to once per 24h).
- **Notifications status indicator** in Settings → Background (matters for `POST_NOTIFICATIONS` on Android 13+).

---

## 🐞 Fixes

- **`CHANGE_NETWORK_STATE` permission for Android 9-11** ([task 023](https://github.com/Leadaxe/LxBox/blob/develop/docs/spec/tasks/023-change-network-state-permission.md)) — `DefaultNetworkListener` on API 28-30 calls `ConnectivityManager.requestNetwork(...)`, which requires `CHANGE_NETWORK_STATE`. Without it: `SecurityException` → `REASON_CRASH` immediately after VPN consent OK on A50/A10/Y9. On API 31+ a different code path is used (`registerBestMatchingNetworkCallback`) which is why the regression only appeared on Android 9-11 while Android 12+ kept working. Permission is `normal`-level, no runtime prompt, silent migration.
- **VLESS `packetEncoding` allow-list** ([task 012](https://github.com/Leadaxe/LxBox/blob/develop/docs/spec/tasks/012-vless-packet-encoding-libbox-panic.md)) — xray-style subscriptions encode `packetEncoding=none` in their URIs, which produced `"packet_encoding": "none"` in outbound JSON; sing-box `vless.NewOutbound` only accepts `xudp`/`packetaddr`/omitted and called `E.New("unknown packet encoding: …")`, which crashed libbox via an upstream `format.ToString` bug. Parser now normalises on input: `xudp`/`XUDP` → `xudp`, `PacketAddr` → `packetaddr`, `none` silently dropped, anything else → warning + drop.
- **Race: `Libbox.newService` before `Libbox.setup` finishes** ([task 027](https://github.com/Leadaxe/LxBox/blob/develop/docs/spec/tasks/027-libbox-init-race-fix.md)) — `BoxApplication.libboxReady: CompletableDeferred<Unit>` barrier; `BoxVpnService` `serviceScope.launch` waits for it before any libbox call. Bonus: libbox `workingDir` moved from external (`getExternalFilesDir(null)`) to internal (`context.filesDir`) — same place where `SettingsStorage` and subscriptions already live; eliminates Knox/SELinux edge cases on Samsung One UI 3.x and EMUI.
- **Quick Connect class-verification on Android 9-11** ([task 015](https://github.com/Leadaxe/LxBox/blob/develop/docs/spec/tasks/015-android-9-11-quickconnect-regression.md)) — `Tile.subtitle` (API 29+) extracted into a `@RequiresApi(Q)` helper; `LxBoxTileService.refreshTile` and `QuickShortcuts.refresh` gated on API 30+ with outer `try { Throwable }`; all callsites in `setStatus`/`onDestroy`/`initialize` wrapped in `runCatching`. `FOREGROUND_SERVICE_SPECIAL_USE` permission gated to `minSdkVersion="34"`; typed `startForeground` on API 34+.

### Reliability internals

- **`Libbox.newService` / `svc.start` / `serviceScope.launch` catch `Throwable`** ([task 016](https://github.com/Leadaxe/LxBox/blob/develop/docs/spec/tasks/016-libbox-newservice-throwable-catch.md)) — not just `Exception`; `Error` subclasses (OOM, NoClassDefFoundError, VerifyError) now surface through `stopAndAlert(...)` instead of vanishing the process.
- **`/files/local`** Debug API alias for `/files/external` (legacy). Internal app-scoped storage.

---

## ⚠ Breaking

- **Tunnel sleep mode default flipped: `lazy` → `never`.** Old default paused the tunnel on deep Doze, which broke long-lived TCP sockets and push notifications. New default keeps the tunnel always active (+1–3% battery overnight). Want the old behaviour — Settings → Background → **Tunnel sleep mode → Lazy sleep**.

---

## 📦 Install

[Latest release on GitHub →](https://github.com/Leadaxe/LxBox/releases/latest)

APK is signed with the upload keystore; install over previous L×Box versions in place.

---

## 🇷🇺 L×Box v1.5.0 на русском

Релиз с критическим фиксом запуска на Android 9-11, новым 10-м протоколом (NaïveProxy), Quick Connect (плитка в шторке + ярлык на иконке), и встроенной диагностикой крашей через 4 канала + HTTP API.

### Основные фиксы

- **Android 9-11 / VPN не запускался** (Samsung A50/A10, Huawei Y9 2018) — в манифесте не хватало `CHANGE_NETWORK_STATE`, который требует `ConnectivityManager.requestNetwork(...)` на API 28-30. На Android 12+ используется другой код-путь, поэтому регрессия проявлялась только на 9-11. Permission `normal`-уровня, без runtime-промпта, миграция silent.
- **Crash при VLESS-подписке с `packetEncoding=none`** — парсер теперь нормализует на входе по allow-list: `none` тихо дропается, неизвестные значения → warning + дроп.
- **Race в init libbox** — добавлен барьер `libboxReady: CompletableDeferred<Unit>`, VPN не стартует до готовности sing-box. Заодно libbox перенесён из external в internal storage — там же где подписки и настройки.
- **Quick Connect class-verification на Android 9-11** — `Tile.subtitle` в `@RequiresApi`-helper, всё gated на API 30+; FGS_SPECIAL_USE permission гейтнут `minSdkVersion="34"`.

### Новые фичи

- **NaïveProxy** ([§037](https://github.com/Leadaxe/LxBox/blob/develop/docs/spec/features/037%20naive%20proxy/spec.md)) — Cronet TLS fingerprint, `naive+https://`-URIs парсятся в подписках в типизированный outbound. Полезно когда DPI ловит uTLS-имитации.
- **Quick Connect** ([§032](https://github.com/Leadaxe/LxBox/blob/develop/docs/spec/features/032%20quick%20connect/spec.md)) — плитка в шторке + ярлык на лаунчер-иконке. Toggle VPN без открытия app'а.
- **Crash diagnostics** ([§038](https://github.com/Leadaxe/LxBox/blob/develop/docs/spec/features/038%20crash%20diagnostics/spec.md)) — четыре канала (stderr-redirect / ApplicationExitInfo / persistent AppLog / logcat tail) собираются одной кнопкой ⤴ Share в Debug-экране. Также через HTTP `/diag/*` endpoints.
- **Update check on launch** ([§036](https://github.com/Leadaxe/LxBox/blob/develop/docs/spec/features/036%20update%20check/spec.md)) — раз в сутки чек GitHub Releases, SnackBar при новой версии.

### Что меняется в поведении

- **Tunnel sleep mode default**: `lazy` → `never`. Push'ы и долгоживущие TCP больше не падают при Doze. Старый режим возвращается через Settings → Background.

### Установка

[Последний релиз на GitHub →](https://github.com/Leadaxe/LxBox/releases/latest)

APK подписан release-keystore'ом, ставится поверх предыдущей версии.
