# L×Box v1.5.0

Reliability + UX + introspection iteration.

**Quick links:**
[⚠ Breaking](#-breaking) ·
[✨ Highlights](#-highlights) ·
[🛠 Tools & process](#-tools--process) ·
[🧪 Tests](#-tests) ·
[📦 Install](#-install) ·
[🇷🇺 На русском](#-l×box-v150-на-русском)

---

## ⚠ Breaking

- **Tunnel sleep mode default flipped: `lazy` → `never`.** Previously the tunnel was hardcoded to `pause()` on deep Doze + `wake()` on exit (the upstream sing-box-for-android pattern). At Doze, long-lived TCP sockets and push notifications used to die — users complained «internet drops until I reopen the app». New default `never` keeps the tunnel always active, costing roughly +1–3% battery overnight in exchange for stable pushes and SIP/VoIP. Want the old behaviour back — Settings → Background → **Tunnel sleep mode → Lazy sleep**. Migration is silent: existing installs get the new default without a dialog; the toggle is in plain sight in Settings.

## ✨ Highlights

- **Tunnel sleep mode (3-way setting)** — Settings → Background → «Tunnel sleep mode»: `never` (default), `lazy` (pause on deep Doze only), `always` (pause on every screen-off, max battery savings). Stored in `BootReceiver` SharedPreferences.
- **Tabbed App Settings** — three tabs: **General** (appearance, behaviour, subscriptions, updates, feedback), **Background** (keep-on-exit, battery, notifications, OEM, sleep mode), **Diagnostics** (permissions summary, Debug API).
- **Update check on launch** ([§036](docs/spec/features/036%20update%20check/spec.md)) — pings `api.github.com/repos/Leadaxe/LxBox/releases/latest` once a day, surfaces newer versions as a SnackBar with **View** / **Not now**. View → opens the release page in the browser; install is manual (sideload). Default ON, single-line disclosure under the toggle. Manual `Check now` from About / Settings bypasses the cap.
- **Battery-optimization startup prompt** — if `isIgnoringBatteryOptimizations == false`, HomeScreen shows an AlertDialog asking the user to whitelist L×Box. Rate-limited to once per 24h.
- **Notifications status indicator** — Settings → Background shows a red icon if notifications are disabled (matters on Android 13+ for `POST_NOTIFICATIONS`); tap opens per-app notification settings.
- **Debug API `/help`** — self-documenting capability map. `?format=text` for LLM-agent prompts, `?format=json` for auto-tooling. No auth (matches `/ping`).
- **About screen — proper app icon** instead of the placeholder shield (W1 routing-cross from v1.4.2 wasn't shown on About before).
- **MCP server design** ([§035](docs/spec/features/035%20mcp%20server/spec.md), draft) — blueprint for wrapping Debug API as an MCP server (stdio + Node + TS, `tools/resources/prompts`, `lxbox.help`). Implementation deferred until there's a concrete need.

## 🛠 Tools & process

- **`scripts/install-apk.sh`** — auto-detects device (wifi > USB), installs the latest built APK, force-stops + relaunches, restores Debug API forward (`tcp:9269`).
- **`scripts/ensure-wifi-adb.sh`** — verifies wifi-adb is up; if not, bootstraps it from a USB-connected device (`adb tcpip 5555` + `adb connect <ip>`).
- **Night-work autonomous process** (`docs/spec/processes/night-work/`) — canonical spec, startup prompt, report template, morning-review checklist, session-start.sh.

## 🧪 Tests

- `test/services/update_checker_test.dart` — 10 unit tests covering `isNewer` (semver compare, malformed input, suffix stripping, two-vs-three-part versions).
- `test/vpn/box_vpn_client_test.dart` — MethodChannel contract tests for the new wrappers (`setBackgroundMode`, `getBackgroundMode`, `areNotificationsEnabled`, `isIgnoringBatteryOptimizations`).

## 📦 Install

Grab the APK from the Release page (sideload). After installing, on first launch:
1. If the battery-optimization dialog appears — open settings and select «No restrictions» / «Don't optimize».
2. Settings → Background → check **Tunnel sleep mode**: leave on `never` for max reliability or switch to `lazy`/`always` if you want battery savings.

---

## 🇷🇺 L×Box v1.5.0 на русском

Релиз про надёжность + UX + интроспекцию.

**Быстрые ссылки:**
[⚠ Несовместимое](#-breaking) ·
[✨ Главное](#-highlights-ru) ·
[🛠 Tooling](#-tools--process) ·
[🧪 Тесты](#-tests) ·
[📦 Установка](#-установка)

### ⚠ Несовместимое

- **Tunnel sleep mode default сменился: `lazy` → `never`.** Раньше поведение туннеля было захардкожено: `pause()` при глубоком Doze + `wake()` на выходе (паттерн из upstream sing-box-for-android). При Doze ломались длинные TCP-соединения и push-уведомления — юзеры жаловались «интернет отваливается пока не откроешь app». Новый дефолт `never` держит туннель всегда активным, ценой +1–3% батареи за ночь в обмен на стабильные push'и и SIP/VoIP. Если нужно старое поведение — Settings → Background → **Tunnel sleep mode → Lazy sleep**. Миграция silent: существующие установки получают новый дефолт без диалога, переключатель видно сразу в настройках.

### ✨ Главное {#-highlights-ru}

- **Tunnel sleep mode (3 режима)** — Settings → Background → «Tunnel sleep mode»: `never` (default), `lazy` (pause только при deep Doze), `always` (pause при каждом screen-off, максимум экономии батареи). Хранение в `BootReceiver` SharedPreferences.
- **App Settings разбит на табы** — три таба: **General** (appearance, поведение, подписки, обновления, feedback), **Background** (keep-on-exit, батарея, нотификации, OEM, sleep mode), **Diagnostics** (статус permissions, Debug API).
- **Проверка обновлений при старте** ([§036](docs/spec/features/036%20update%20check/spec.md)) — пингует `api.github.com/repos/Leadaxe/LxBox/releases/latest` раз в сутки, при наличии новой версии показывает SnackBar с **View** / **Not now**. View открывает страницу релиза в браузере, install — вручную (sideload). Default ON, single-line disclosure под toggle. Manual `Check now` обходит cap.
- **Battery-optimization попап при старте** — если приложение не whitelisted, HomeScreen показывает диалог с переходом в системные настройки. Не чаще раза в сутки.
- **Notifications status в настройках** — Settings → Background красная иконка если нотификации запрещены (важно на Android 13+ для `POST_NOTIFICATIONS`); тап открывает per-app notification settings.
- **`/help` в Debug API** — самодокументируемая карта endpoint'ов. `?format=text` для LLM-агентов, `?format=json` для авто-tooling'а. Без auth (как `/ping`).
- **About — настоящая иконка app'а** вместо плейсхолдер-щита (W1 routing-cross из v1.4.2 раньше там не показывалась).
- **MCP server design** ([§035](docs/spec/features/035%20mcp%20server/spec.md), draft) — план обёртки Debug API в MCP server. Реализация отложена до конкретной потребности.

### 🛠 Tools & process {#tools-process-ru}

- **`scripts/install-apk.sh`** — auto-detect устройство (wifi > USB), install + force-stop + launch + восстановление Debug API forward.
- **`scripts/ensure-wifi-adb.sh`** — проверка / bootstrap wifi-adb с USB-устройства.
- **Night-work autonomous process** (`docs/spec/processes/night-work/`) — canonical spec, startup-prompt, report-template, morning-review checklist, session-start.sh.

### 🧪 Тесты

- `test/services/update_checker_test.dart` — 10 unit-тестов на `isNewer` (semver compare, malformed input, suffix stripping).
- `test/vpn/box_vpn_client_test.dart` — MethodChannel contract tests для новых wrapper'ов.

### 📦 Установка

Скачать APK со страницы Release (sideload). При первом запуске:
1. Если появился battery-optimization диалог — выбрать «Без ограничений».
2. Settings → Background → проверить **Tunnel sleep mode**: оставить `never` для максимальной надёжности или переключить на `lazy`/`always` для экономии батареи.

---

> Предыдущий релиз: [v1.4.2 — новая иконка](docs/releases/v1.4.2.md).
