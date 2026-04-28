# L×Box v1.6.0

Two user-facing wins: NaïveProxy joins the supported protocol list, and **Quick Connect** — a Quick Settings tile and a home-screen shortcut — lets you toggle the VPN without opening the app. Plus a critical fix for VLESS subscriptions that were crashing the libbox.so on connect.

**Quick links:**
[✨ Highlights](#-highlights) ·
[🧪 Tests](#-tests) ·
[📦 Install](#-install) ·
[🇷🇺 На русском](#-l×box-v160-на-русском)

---

## ✨ Highlights

- **NaïveProxy parser, emit, and share-URI round-trip** ([§037](docs/spec/features/037%20naive%20proxy/spec.md), [#2](https://github.com/Leadaxe/LxBox/issues/2)) — subscriptions containing `naive+https://user:pass@host:443/?...#Label` are now parsed into a typed `NaiveSpec`, generated as a sing-box `type: "naive"` outbound, and reversed back to the same URI on **Copy link**. The DuckSoft de-facto URI format is supported in full: anonymous and password-only userinfo, `extra-headers=…` (CRLF-encoded HTTP headers, deterministic lexicographic order), UTF-8 fragment labels, `padding=…` ignored with a log warning. The libbox AAR we ship (`com.github.singbox-android:libbox`, main `androidApi=23+` variant) already bundles the `with_naive_outbound` build tag, so no APK size impact and no native rebuild required.

### Why NaïveProxy

- Real Chrome TLS fingerprint via cronet/Chromium net-stack — JA3/JA4 indistinguishable from a real browser, harder for fingerprint-based DPI than uTLS approximations.
- Common in subscription providers oriented at strict-DPI markets — those entries used to be silently dropped by Parser v2, now they land in the node list.
- Caddy + `forwardproxy` server side is trivial to deploy; users with self-hosted naive can now paste the URI and connect.

### Behavioural notes

- TLS is always enabled (`tls.enabled: true`, `tls.server_name = host`) — naive without TLS is meaningless.
- The naive outbound in sing-box rejects `alpn`, `insecure`, `utls`, `reality`, `min_version`, `cipher_suites`, `fragment` — the parser deliberately leaves them unset; users who need custom TLS edit the JSON in the config editor.
- `naive+quic://` URIs and the `quic`/`quic_congestion_control` outbound fields are deferred to a future release — there is no stable URI standard for them yet (spec 037 §10).
- Defensive `NaiveBuildTagWarning` is wired up: if a future libbox upgrade ever lands without the `with_naive_outbound` tag, sing-box will return `naive outbound is not included in this build, rebuild with -tags with_naive_outbound`, which we surface as a per-node UI warning rather than a silent failure.

- **Quick Connect: Quick Settings tile + home-screen shortcut** ([§032](docs/spec/features/032%20quick%20connect/spec.md), [#1](https://github.com/Leadaxe/LxBox/issues/1), [task 014](docs/spec/tasks/014-quick-connect-tile-shortcut.md)) — two ways to toggle the VPN without opening the app:

  - **Quick Settings tile**. Pull down the status bar → edit tiles → drag **L×Box** into the active set. Tap = toggle on/off; the tile shows live state (`Connected` / `Disconnected` / `Connecting…` / `Stopping…`) synced from `BoxVpnService.setStatus` via `TileService.requestListeningState`. App Settings → General → **Quick connect** has an `Add` button that on Android 13+ shows a system prompt (`StatusBarManager.requestAddTileService`); on older versions it falls back to a snackbar with manual instructions. OEM quirks (ColorOS / MIUI silently dropping the prompt) are surfaced as a snackbar with the same fallback.
  - **Home-screen shortcut**. Long-press the L×Box icon on your launcher → tap **Toggle VPN**. Static `res/xml/shortcuts.xml` with `extra action=toggle`.

  The first time a tile or shortcut tap is made, `MainActivity` flashes briefly to host the system VPN consent dialog (`VpnService.prepare(...)` is an Activity-only API). The user sees a one-shot toast «Opening L×Box for VPN permission (one-time)». After consent, activity calls `finish()` and you land back on the home screen. Every subsequent tap goes straight to `BoxVpnService.start/stop` with no UI flash. If the user cancels the consent dialog, a follow-up toast «VPN permission denied. Open L×Box to retry.» appears once and the activity exits — no re-prompting from the tile.

  Edge cases: taps during transient `Starting`/`Stopping` are ignored (no race); on OOM-kill of the service `currentStatus` is reset to `Stopped` in `onDestroy` so the tile won't lie «Connected» on the next bind.

## 🧪 Tests

- `test/parser/uri_naive_test.dart` — 19 cases: canonical / default-port / password-only / anonymous / extra-headers parsing / invalid header drop / padding ignored / unknown query keys / UTF-8 fragment / IPv6 host / dispatcher routing / bare `naive://` rejection.
- `test/models/naive_emit_test.dart` — 17 cases: emit shape (`type`, `extra_headers` field name, no `network` field), TLS block (`enabled` + `server_name`, no `alpn`/`utls`/`insecure`), userinfo encoding, port elision, header sort order, header charset validation, three round-trip stability tests.
- Sealed exhaustiveness updated in `node_spec_test.dart` and `node_warning_test.dart` (10 protocols, 6 warning types).
- Suite total: **409** tests (was 373), all green.

## 📦 Install

[Latest release on GitHub →](https://github.com/Leadaxe/LxBox/releases/latest)

`apk` is signed with the upload keystore; install over previous L×Box versions in place.

---

## 🇷🇺 L×Box v1.6.0 на русском

Релиз про две вещи: добавлен 10-й протокол **NaïveProxy** ([§037](docs/spec/features/037%20naive%20proxy/spec.md), [#2](https://github.com/Leadaxe/LxBox/issues/2)) и **Quick Connect** — плитка в шторке + ярлык на иконке для toggle VPN без открытия app'а ([§032](docs/spec/features/032%20quick%20connect/spec.md), [#1](https://github.com/Leadaxe/LxBox/issues/1)). Плюс критический фикс падения libbox.so на VLESS-подписках.

### Что работает

- В подписках строки `naive+https://user:pass@host:443/?...#Label` (формат DuckSoft, как у NekoBox / NaiveGUI / v2rayN / Hiddify) теперь парсятся в типизированный `NaiveSpec` и попадают в список узлов вместо silent-skip.
- Генератор конфига выдаёт sing-box outbound `type: "naive"` с правильным TLS-блоком (`enabled: true`, `server_name = host`, без `alpn`/`utls`/`insecure` — naive их отвергает).
- `Copy link` в context-menu возвращает эквивалентный URI (round-trip с детерминированным порядком extra-headers).
- Поддерживается аутентификация: `user:pass`, password-only (`onlypass@host`), anonymous.
- `extra-headers=Header%3AValue%0D%0A...` — парсинг + перепаковка с лекс-сортировкой ключей и валидацией charset'а имени заголовка по DuckSoft-спеке.

### Зачем

- Cronet даёт **настоящий** Chrome TLS-fingerprint — не uTLS-имитация. Для каналов с DPI по JA3/JA4 это качественно стойче, чем vless+vision на проблемных сетях.
- Подписки от провайдеров (особенно Иран/Китай-направленных) часто содержат naive-узлы вперемешку с vless — раньше LxBox их выкидывал, теперь подхватывает.
- Сервер на Caddy + `forwardproxy` поднимается тривиально — кто себе уже поставил, может вставить URI и подключаться.

### Что важно знать

- TLS обязателен — naive без TLS не работает в принципе.
- Кастомизация TLS через URI не поддерживается (cronet всё равно использует Chrome-стек) — кому нужно, правит JSON в редакторе.
- `naive+quic://` отложен — стандарта URI для QUIC-варианта пока нет, sing-box outbound в текущих сборках работает HTTPS+TCP через cronet.
- libbox AAR который мы тянем (`singbox-android/libbox`, main `androidApi=23+` вариант) уже включает `with_naive_outbound` — APK не вырос. Будущие апгрейды защищены runtime-warning'ом, если когда-нибудь регрессирует.

### Quick Connect (§032, [#1](https://github.com/Leadaxe/LxBox/issues/1))

Долгожданный запрос: toggle VPN без открытия приложения. Теперь два способа:

- **Плитка в шторке (Quick Settings).** Потяни статус-бар → редактирование плиток → перетащи **L×Box** в активные. Тап = toggle on/off, плитка показывает `Connected` / `Disconnected` / `Connecting…` / `Stopping…` синхронно с реальным сервисом. На Android 13+ App Settings → General → **Quick connect** → `Add` показывает системный prompt от `StatusBarManager.requestAddTileService` (на старых Android и проблемных OEM — текстовая инструкция в snackbar).
- **Ярлык на хоум-скрине.** Long-press на иконку L×Box → выбери **Toggle VPN**.

Первый раз tile или shortcut коротко открывает приложение — это API-ограничение Android: системный VPN consent-диалог можно показать только из Activity. Ты увидишь toast «Opening L×Box for VPN permission (one-time)», диалог, после OK — VPN запустится и activity сама закроется (вернёшься на хоум). Все следующие тапы идут напрямую в сервис без UI-вспышки. Если отказался от consent'а — toast «VPN permission denied. Open L×Box to retry.» и activity тоже закрывается (не пытаемся перепрашивать из шторки).

Edge cases: тап во время `Starting`/`Stopping` молча игнорится; если сервис умер от OOM — `currentStatus` сбрасывается, плитка не врёт «Connected» при следующем bind'е.

См. [task 014](docs/spec/tasks/014-quick-connect-tile-shortcut.md) с разбором реализации и smoke-теста.

### Тесты

- 36 новых юнит-тестов: 19 парсер + 17 emit / round-trip.
- Полный suite: **409** тестов (было 373), всё зелёное.

### Установка

[Последний релиз на GitHub →](https://github.com/Leadaxe/LxBox/releases/latest)

APK подписан release-keystore'ом, ставится поверх предыдущей версии.
