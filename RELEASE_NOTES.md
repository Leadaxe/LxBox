# L×Box v2.4.0

**Public Intent API (§047)** — управление L×Box из Tasker / MacroDroid / Llama / Automate (как Plugin или raw broadcast). Плюс новый детальный разбор соединений (Stats→Conns), вычистка интерфейса до English-only, строгий allowlist на импорте настроек и hardening границы JNI. Ядро → `v1.13.13-lx.14`.

**Quick links:**
[✨ Added](#-added) ·
[🔧 Changed](#-changed) ·
[🛠 Fixed](#-fixed) ·
[🔬 Verified](#-verified) ·
[📲 Install](#-install) ·
[🇷🇺 На русском](#-кратко-на-русском)

---

## ✨ Added

| # | Что |
|---|---|
| §047 | **Public Intent API — automation** ([AUTOMATION.md](docs/AUTOMATION.md)). Управление L×Box из автоматизаторов **двумя** способами: **(1) Plugin** — L×Box виден в Tasker/Locale как плагин (Action + State), команда выбирается мышкой через нативный экран; **(2) raw broadcast** — `am broadcast` с action-строкой (shell/ADB/не-plugin). 9 actions (`START_VPN`/`STOP_VPN`/`TOGGLE_VPN`, `SWITCH_NODE`, `SET_GROUP`, `URLTEST_GROUP`, `REFRESH_SUBS`, `REBUILD_CONFIG`, `RESET_NETWORK`), исходящие события (`VPN_CONNECTED`/`DISCONNECTED`/`ERROR`/`REVOKED`, `ACTIVE_NODE/GROUP_CHANGED`, `SUB_REFRESHED/FAILED`, `UPDATE_AVAILABLE`, `PERMISSION_NEEDED`). **Opt-in**: по умолчанию приём команд выключен, события наружу не шлются. Включается в **App Settings → Automation** |
| §152 | **Conns: детальный bottom sheet по тапу** — тайл соединения теперь tappable → полная инфа (host, chain, process, rule, byte-счётчики, длительность) без обрезки `ellipsis` |
| §153 | **Conns: подсветка зависших однобоких TCP** — соединения с сигнатурой залипания (напр. `↑517 ↓0` — ClientHello ушёл, ответа нет) подсвечиваются розовым в списке Stats→Conns |
| §154 | **Conns: иконка приложения в строке** — маленькая launcher-иконка приложения-владельца соединения рядом с `processPath` |

## 🔧 Changed

| # | Было | Стало |
|---|---|---|
| §010 | Ядро `v1.13.13-lx.12` | **`v1.13.13-lx.14`** — фикс GRO split-brain на WG-endpoint (медленный download на LTE без detour; `UDP_GRO` гейтился за `runtime.GOOS==linux` → склеенный recv ломал AEAD) |
| §156 | В UI и Debug API просочились русские строки | **English-only** — вычистка кириллицы из интерфейса и API; интерфейс единообразно английский |
| §158 | Вкладки App Settings прижаты влево, overflow незаметен | **Центрированы** (`TabAlignment.center`) + двусторонний edge-fade `ShaderMask` |
| §157 | В automation была нерабочая галка «Require permission» | Удалена (Dart+native+manifest+docs) — оставляла мёртвый код и сбивала с толку |
| §155 | — | **Аудит проекта (июнь 2026) + быстрые победы** — native crash-safety, catch-логи, актуализация docs-статусов, disambiguation |

## 🛠 Fixed

| # | Что |
|---|---|
| §151 | **JNI-iterator no-throw + ALPN double-decode + LocalResolver SERVFAIL**. Разобран механизм abort через границу JNI: throw из Kotlin-callback роняет процесс (`Runtime::Abort`) **только** если Go-метод возвращает `void`/value без `error`. **F1** — итераторы `StringIterator`/`NetworkInterfaceIterator` больше не бросают `NoSuchElementException` за концом, а возвращают пустой элемент (единственный подтверждённый abort-класс). **F2** — `alpn=http%252F1.1` больше не уходит мусором в ядро (повторный decode + валидация в парсере). **F3** — LocalResolver возвращает `ctx.errorCode(SERVFAIL)` вместо шумного `error()` при потере сети в момент DNS-запроса |
| §159 | **Строгий allowlist (default-deny) на импорте настроек** — импорт фильтруется по белому списку ключей (а не чёрному); экспорт расфильтрован симметрично; отброшенные ключи → applog + снэкбар; `ping_options` strip; распутан seed |
| §154 | Чистка package name из `processPath` перед резолвом иконки (формат ядра `pkg (pkg)` / `pkg (user)` → чистый pkg) |

## 🔬 Verified

- `flutter analyze` — **No issues found**.
- `flutter test` — **1186 passed** (вкл. §047 automation gates/throttle, §151 ALPN double-decode round-trip, §153 one-way-stuck logic, §159 allowlist).
- Release-APK arm64 собран чисто (`app-arm64-v8a-release.apk`, 29.3 MB) — Kotlin compile без ошибок (закрывает signature-инвариант §151/§157).
- Ядро — **`v1.13.13-lx.14`** (форк sing-box-lx, fetch с SHA256-verify).
- §158 — on-device подтверждено на Android 13 (UX принят).

## 📲 Install

```bash
adb install -r LxBox-v2.4.0-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

## 🇷🇺 Кратко на русском

- **Automation (§047)** — теперь L×Box можно дёргать из Tasker/MacroDroid/Llama/Automate: подключать/отключать VPN, переключать ноду/группу, обновлять подписки и т.д. Видно как плагин (выбор команды мышкой) или через broadcast-интенты. **По умолчанию выключено** — включается в App Settings → Automation.
- **Соединения (§152/§153/§154)** — по тапу на строке открывается полная инфа; зависшие однобокие TCP подсвечиваются розовым; у строки видна иконка приложения.
- **Интерфейс English-only (§156)** — убраны затёкшие русские строки.
- **Импорт настроек безопаснее (§159)** — строгий белый список ключей вместо чёрного: чужие/мусорные ключи не применяются, отброшенное видно в снэкбаре.
- **Стабильность (§151):** разобран реальный механизм abort через JNI, закрыты итераторы-throw, починен ALPN с двойным кодированием, убран шум DNS-резолвера при смене сети.
- **Новое ядро** `v1.13.13-lx.14` — фикс медленного download на WG-endpoint по LTE.

Предыдущий релиз: [v2.3.5](docs/releases/v2.3.5.md).
