# L×Box — аудит проекта (июнь 2026)

> Read-only обзор всех частей проекта: Dart-слой, native (Kotlin), документация/спеки,
> тесты/CI. Находки верифицированы по коду. Severity: 🔴 high · 🟡 medium · 🟢 low.
>
> Дата: 2026-06-22. Метод: статический анализ + точечная проверка. Деструктивных
> операций не выполнялось (см. [DIAGNOSTICS.md](DIAGNOSTICS.md)).

---

## TL;DR — топ-приоритеты

| # | Область | Severity | Суть | Усилие |
|---|---|---|---|---|
| 1 | Native threading | 🟡→🔴 | `statusSink?.success()` + `registerReceiver()` без try/catch — `DeadObjectException`/OEM-crash валит Flutter-engine | 30 мин |
| 2 | Тесты контроллеров | 🔴 | `home_controller` (799) + `subscription_controller` (932) — **0 unit-тестов** | дни |
| 3 | Docs-статусы | 🟡 | §036 фактически реализован, но помечен Draft; §042 Draft без кода (верно) | 1 ч |
| 4 | Дубли номеров спек | 🟡 | tasks/ §128, §143, §146 — по 2 файла на номер | 1 ч |
| 5 | Пустые `catch(_)` | 🟡 | 6 мест глотают ошибки без лога | 15 мин |
| 6 | DEVELOPMENT_REPORT | 🟡 | не обновлялся ~2 мес (апрель), отстал от текущего состояния | — |

Общая оценка кода: **хорошая база, точечный долг**. JNI-safety на native — образцовая. Слабое место — покрытие тестами бизнес-логики и рассинхрон части docs со статусом.

---

## 1. Dart-слой (`app/lib/`)

299 файлов, ~54K строк. TODO/FIXME/HACK — **не найдено** (чисто).

### 🟡 Пустые `catch(_)` без логирования
Ошибки молча проглатываются — не видны в Debug→Logs:
- `screens/speed_test_screen.dart` — строки 166, 191, 201, 254
- `screens/connections_screen.dart` — 176, 183 *(чужой §152, отдельная сессия)*
- `screens/home/restore_backup.dart` — 37

**Рекомендация:** добавить `AppLog.I.debug/warning('[tag] $e')` в каждый. Малое усилие, заметный выигрыш в диагностике.

### 🟡 Крупные файлы — кандидаты на split
| Файл | Строк | Приоритет |
|---|---|---|
| `services/traffic_profiler.dart` | 1243 | high — выделить session/gc |
| `controllers/subscription_controller.dart` | 932 | high — fetcher/parser отдельно |
| `screens/dns_settings_screen.dart` | 815 | medium |
| `controllers/home_controller.dart` | 799 | medium (миксины уже есть) |

### 🟢 Дубли-паттерны (упрощение, не баги)
- `if (!mounted) return` после await — 130+ повторов → опциональный `MountedGuard` mixin.
- `_timer?.cancel()` в dispose — порядок (до `super.dispose()`) корректен везде, но не документирован.
- read-after-await в `traffic_profiler.start` (251–264) и `subscription_controller._rehydrateFromCache` (127–180) — guard'ы есть, риск низкий; причесать при рефакторе.

### ✅ Хорошо
Логирование (`AppLog.I` везде, без `print`), StreamSubscription/Timer отменяются в dispose, error-handling согласован.

---

## 2. Native (Kotlin, `app/android/.../`)

26 файлов, ~3.7K строк. Топ: VpnPlugin (766), BoxService (741).

### ✅ JNI-safety — образцово (🟢)
Все 10 callback'ов из Go-ядра (`PlatformInterfaceWrapper`, `BoxService.writeDebugMessage/sendNotification/serviceReload/getSystemProxyStatus`, `LocalResolver`, `DefaultNetworkMonitor.notifySync`) **корректно** обёрнуты try/catch или возвращают fail-safe. Ноль потенциальных `Runtime::Abort` через JNI. Это прямое следствие правила [«JNI callbacks НЕ должны бросать»](#) — соблюдается.

### 🔴 Threading — 2 реальных места без защиты
Не JNI-граница, но broadcast/engine-crash валит процесс:
- **`VpnPlugin.kt:120`** — `statusSink?.success(event)` без try/catch → `DeadObjectException` если Dart-engine умер. **Фикс:** `runCatching { statusSink?.success(event) }.onFailure { Log.e(...) }`.
- **`VpnPlugin.kt:168`** — `context.registerReceiver(...)` без обёртки (а `unregisterReceiver` на 185 — обёрнут). На отдельных OEM может бросить → краш в `onAttachedToEngine`. **Фикс:** `runCatching { registerReceiver(...) }`.

### 🟡 Прочее native
- `LxBoxTileService.kt:104` — `Toast` без `mainHandler.post` (TileService.onClick не гарантирует main thread).
- `BoxService.kt:86` — `receiverRegistered` без `@Volatile` (читается/пишется из разных потоков) → `@Volatile` или `AtomicBoolean`.

### 🟢 Low / техдолг
- `BoxApplication.kt:54` и `DefaultNetworkListener.kt:29` — `GlobalScope` (one-time init / process-singleton, допустимо, но deprecated practice).
- `MainActivity.kt:235,301` — `Toast(applicationContext)` → лучше `this`.
- Manifest: `ACCESS_COARSE_LOCATION` в Kotlin-коде не используется (FINE/BACKGROUND нужны для WiFi-SSID API-гейтов) — кандидат на удаление либо комментарий «зачем».
- `automation/` (§047) exported receiver'ы без `android:permission` — **намеренно** (Locale-стандарт запрещает; raw-receiver гейтит в `onReceive`). См. [AUTOMATION.md](AUTOMATION.md) и [§047 spec](spec/features/047%20public%20intent%20api/spec.md).

---

## 3. Документация и спеки

### 🟡 Рассинхрон статуса со кодом
- **§036 Update Check** — статус `Draft`, но `services/update_checker.dart` **реализован** (используется в §047-эмиттере `UPDATE_AVAILABLE`). → Обновить статус на Implemented + commits.
- **§042 Health Watchdog** — статус `Draft`, кода **нет** (проверено: `HealthWatchdog`/`HeartbeatHealth` отсутствуют). Статус верен; стоит добавить timeline или «backlog». Влияет на §047 health-события (`HEARTBEAT_FAILED`/`LATENCY_DEGRADED` зарезервированы под §042 — см. [AUTOMATION.md](AUTOMATION.md)).
- Прочие Draft: §035 MCP, §037 NaïveProxy (research готов, реализации нет), §045 TLS ECH (spec-only), §024 Load Balance (planned).

### 🟡 Дубли номеров в `docs/spec/tasks/`
Реальны — по 2 файла на номер:
- `128-force-direct-out-detour.md` + `128-jni-callback-crash-android10.md`
- `143-interrupt-connections-on-node-switch.md` + `143-warp-masquerade-id-ip-ib.md`
- `146-warp-quic-initial-fragmented-i1.md` + `146-test-vectors/`

**Рекомендация:** перенумеровать вторые в свободные номера, обновить cross-ref. (Следствие параллельных сессий — см. правило про коллизии.)

### 🟡 DEVELOPMENT_REPORT.md устарел
Последняя дата ~апрель, строки 506–507 числят §024/Profile Mgmt как «не реализовано» — за 2 месяца статусы могли измениться. → Пометить как «исторический срез по vX» или обновить.

### 🟢 Ссылки и cross-ref
Битых markdown-ссылок не найдено. §047 теперь корректно прошит в [ARCHITECTURE.md](ARCHITECTURE.md) (дерево + `automation/`) и [§032](spec/features/032%20quick%20connect/spec.md). Хороший стиль статуса с commits — у §117/§091, стоит распространить на остальные Done-спеки.

### 🟢 Возможные «сироты» (фичи без явной спеки)
about / outbound-viewer / dns-server-edit / single-app-picker экраны — вероятно часть родительских спек (§022/§014/§046), но без явной ссылки. Низкий приоритет — проверить и при желании прилинковать.

---

## 4. Тесты и CI

96 тест-файлов, 1138 `test()`. CI (`.github/workflows/ci.yml`) гоняет `flutter analyze` + `flutter test` на каждый PR/push — ✅ работает.

### 🔴 Дыры в покрытии критичных путей
| Область | lib | test | Покрытие |
|---|---|---|---|
| `controllers/` | 6 | **0** | 0% — home (799) + subscription (932) без тестов |
| `config/` (parse) | 3 | **0** | 0% — парсер конфигов не покрыт |
| `vpn/` | 3 | 1 | только контракт канала, нет lifecycle |
| `services/` | 125 | 40 | 32% |
| `models/` | 20 | 6 | 30% |
| `parser/` / `builder/` | — | — | ~67% ✅ |

**Приоритет тестов:** (1) `home_controller` / `subscription_controller` state-flows, (2) VPN lifecycle с мок-каналом (start→connected→stop, timeout→force-stop), (3) `config_parse` (fixtures уже есть).

### 🟡 Kotlin — нет тест-инфраструктуры
0 тестов, нет `src/test/`. Critical: `VpnPlugin` (MethodChannel-контракт), `LocaleApi` bundle round-trip (§047), `BoxVpnService` lifecycle. **Рекомендация:** добавить JUnit-setup + базовые unit-тесты (особенно `LocaleApi` — чистая логика, легко покрыть).

### 🟢 Качество
- `analysis_options.yaml` — голый `flutter_lints`, не усилен. Можно добавить strict-правила (unused_*, prefer_const, avoid_print) для ловли регрессий в CI.
- Флаки: `Future.delayed(350ms)` в `node_filter_view_model_test`, `.timeout(5s)` в `rehydrate_race_test` — на медленном CI хрупко → `fake_async`.
- Нет code-coverage tracking (codecov) — нет видимости %.
- `pubspec`: «43 packages have newer versions» — обычная подсказка, не критично.

---

## Сводный план (по приоритету)

**Быстрые победы (часы):**
1. 🔴 Обернуть `VpnPlugin.kt:120` и `:168` в `runCatching` (native crash-safety).
2. 🟡 Логи в 6 пустых `catch(_)`.
3. 🟡 Обновить статус §036 (Draft→Implemented); добавить timeline §042.
4. 🟡 Перенумеровать дубли §128/§143/§146.
5. 🟡 `@Volatile` на `BoxService.receiverRegistered`; `Toast` на main в `LxBoxTileService`.

**Средний горизонт (дни):**
6. 🔴 Unit-тесты `home_controller` / `subscription_controller` / VPN-lifecycle / `config_parse`.
7. 🟡 Kotlin тест-инфраструктура + `LocaleApi`/`VpnPlugin` тесты.
8. 🟡 Split `traffic_profiler.dart` (1243) и `subscription_controller.dart` (932).
9. 🟡 Освежить DEVELOPMENT_REPORT.

**Долгий хвост (по желанию):**
10. 🟢 Усилить `analysis_options.yaml`, code-coverage в CI, `MountedGuard` mixin, fake_async в флаки-тестах, прилинковать «сироты»-экраны.

---

## Что НЕ трогалось

- Чужой `connections_screen` (§152) — параллельная сессия, не аудировался по существу.
- Деструктивных/диагностических операций на устройстве не выполнялось.
- §047 Public Intent API — полностью реализован и проверен на железе, отдельно: [AUTOMATION.md](AUTOMATION.md) + [§047 spec](spec/features/047%20public%20intent%20api/spec.md).
