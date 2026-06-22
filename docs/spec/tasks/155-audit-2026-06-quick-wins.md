# 155 — Аудит проекта (июнь 2026) + быстрые победы

| Поле | Значение |
|------|----------|
| Статус | **In progress** — быстрые победы (native crash-safety, catch-логи, docs-статусы, disambiguation) сделаны; unit-тесты вынесены в follow-up |
| Дата старта | 2026-06-22 |
| Тип | audit + hardening (native / Dart / docs) |
| Метод | статический анализ + точечная проверка по коду; деструктивных операций не выполнялось (см. [DIAGNOSTICS.md](../../DIAGNOSTICS.md)) |
| Связанные | [§141](141-deep-code-audit-hardening.md) (предыдущий deep-audit), [§151](151-jni-iterator-throw-and-alpn-double-decode.md) (JNI-граница), [§042](../features/042%20health%20watchdog/spec.md), [§036](../features/036%20update%20check/spec.md) |

> Read-only обзор всех частей проекта (Dart-слой, native Kotlin, docs/спеки,
> тесты/CI). Находки верифицированы по коду. Severity: 🔴 high · 🟡 medium · 🟢 low.
> Этот файл заменил `docs/PROJECT_AUDIT_2026-06.md` (вынесен в spec-таску).

---

## TL;DR — топ-приоритеты

| # | Область | Severity | Суть | Статус |
|---|---|---|---|---|
| 1 | Native threading | 🔴 | `statusSink?.success()` + `registerReceiver()` без try/catch — `DeadObjectException`/OEM-crash валит Flutter-engine | ✅ сделано |
| 2 | Тесты контроллеров | 🔴 | `home_controller` (799) + `subscription_controller` (932) — **0 unit-тестов** | ⏸ follow-up |
| 3 | Docs-статусы | 🟡 | §036 фактически реализован, но помечен Draft; §042 Draft без кода (верно) | ✅ сделано |
| 4 | Дубли номеров спек | 🟡 | tasks/ §128, §143 — по 2 файла на номер | ✅ disambiguation |
| 5 | Пустые `catch(_)` | 🟡 | 6 мест глотают ошибки без лога | ✅ сделано |
| 6 | DEVELOPMENT_REPORT | 🟡 | не обновлялся ~2 мес (апрель), отстал от текущего состояния | ⏸ follow-up |

Общая оценка кода: **хорошая база, точечный долг**. JNI-safety на native — образцовая.
Слабое место — покрытие тестами бизнес-логики и рассинхрон части docs со статусом.

---

## 1. Dart-слой (`app/lib/`)

299 файлов, ~54K строк. TODO/FIXME/HACK — **не найдено** (чисто).

### 🟡 → ✅ Пустые `catch(_)` без логирования
Ошибки молча проглатывались — не видны в Debug→Logs. **Исправлено** (debug/warning-лог в каждом, поток управления не тронут):
- `screens/speed_test_screen.dart` — строки 166, 191, 201, 254 (`AppLog.I.debug('[speedtest] …')`)
- `screens/home/restore_backup.dart` — 37 (`AppLog.I.warning('[restore] …')`)
- `screens/connections_screen.dart` — 176, 183 — **НЕ тронуто** (чужой §152, отдельная сессия)

### 🟡 Крупные файлы — кандидаты на split (follow-up)
| Файл | Строк | Приоритет |
|---|---|---|
| `services/traffic_profiler.dart` | 1243 | high — выделить session/gc |
| `controllers/subscription_controller.dart` | 932 | high — fetcher/parser отдельно |
| `screens/dns_settings_screen.dart` | 815 | medium |
| `controllers/home_controller.dart` | 799 | medium (миксины уже есть) |

### 🟢 Дубли-паттерны (упрощение, не баги)
- `if (!mounted) return` после await — 130+ повторов → опциональный `MountedGuard` mixin.
- read-after-await в `traffic_profiler.start` и `subscription_controller._rehydrateFromCache` — guard'ы есть, риск низкий; причесать при рефакторе.

### ✅ Хорошо
Логирование (`AppLog.I` везде, без `print`), StreamSubscription/Timer отменяются в dispose, error-handling согласован.

---

## 2. Native (Kotlin, `app/android/.../`)

26 файлов, ~3.7K строк. Топ: VpnPlugin (766), BoxService (741).

### ✅ JNI-safety — образцово (🟢)
Все 10 callback'ов из Go-ядра (`PlatformInterfaceWrapper`, `BoxService.writeDebugMessage/sendNotification/serviceReload/getSystemProxyStatus`, `LocalResolver`, `DefaultNetworkMonitor.notifySync`) **корректно** обёрнуты try/catch или возвращают fail-safe. Ноль потенциальных `Runtime::Abort` через JNI. Прямое следствие правила «JNI callbacks НЕ должны бросать».

### 🔴 → ✅ Threading — 2 места без защиты (исправлено)
Не JNI-граница, но broadcast/engine-crash валит процесс:
- **`VpnPlugin.kt` (statusReceiver)** — `statusSink?.success(event)` → обёрнут в `runCatching{…}.onFailure{ Log.w }`. `DeadObjectException` при мёртвом Dart-engine больше не валит процесс.
- **`VpnPlugin.kt` (onAttachedToEngine)** — `context.registerReceiver(…)` → обёрнут в `runCatching{…}.onFailure{ Log.e }`. Симметрично к уже-обёрнутому `unregisterReceiver` в `onDetachedFromEngine`.

### 🟡 → ✅ Прочее native (исправлено)
- `LxBoxTileService` — `Toast` в `connectOrPromptConsent` теперь через `mainHandler.post{…}` (TileService.onClick не гарантирует main thread).
- `BoxService.receiverRegistered` — добавлен `@Volatile` (читается/пишется из binder-потока `receiver.onReceive` и из service main thread).

### 🟢 Low / техдолг (follow-up)
- `BoxApplication`/`DefaultNetworkListener` — `GlobalScope` (one-time init / process-singleton, допустимо, но deprecated practice).
- `MainActivity` — `Toast(applicationContext)` → лучше `this`.
- Manifest: `ACCESS_COARSE_LOCATION` в Kotlin-коде не используется — кандидат на удаление либо комментарий «зачем».
- `automation/` (§047) exported receiver'ы без `android:permission` — **намеренно** (Locale-стандарт; raw-receiver гейтит в `onReceive`). См. [AUTOMATION.md](../../AUTOMATION.md).

---

## 3. Документация и спеки

### 🟡 → ✅ Рассинхрон статуса со кодом (исправлено)
- **§036 Update Check** — был `Draft`, код **реализован** (`services/update_checker.dart`, используется в §047-эмиттере `UPDATE_AVAILABLE`). → Статус обновлён на `Released (v1.5.0)` + коммиты `135037f`/`3df01f0`/`ddaf050`.
- **§042 Health Watchdog** — статус `Draft` **верен** (классов `HealthWatchdog`/`HeartbeatHealth` нет). → В шапку добавлена пометка **backlog** + ссылка на §047 (события `HEARTBEAT_FAILED`/`LATENCY_DEGRADED` зарезервированы под §042, сейчас не эмитятся).
- Прочие Draft (без изменений): §035 MCP, §037 NaïveProxy (research готов), §045 TLS ECH (spec-only), §024 Load Balance (planned).

### 🟡 → ✅ Дубли номеров в `docs/spec/tasks/` (disambiguation)
Реальны — по 2 файла на номер. **Решение:** не перенумеровывать (ссылки в истории/коде/памяти зафиксированы), а развести алиасами:
- §128: `force-direct-out-detour` (§128-detour, won't-fix) + `jni-callback-crash-android10` (§128-jni)
- §143: `interrupt-connections-on-node-switch` (§143-interrupt) + `warp-masquerade-id-ip-ib` (§143-warp)
- §146 — **не** коллизия: `146-warp-quic-initial-fragmented-i1.md` + `146-test-vectors/` — одна таска (директория = hex-векторы).

В шапку каждого файла-дубля добавлена пометка-сноска, в [tasks/README.md](README.md#известные-коллизии-номеров) — таблица «Известные коллизии номеров» + правило профилактики.

### 🟡 DEVELOPMENT_REPORT.md устарел (follow-up)
Последняя дата ~апрель, числит §024/Profile Mgmt как «не реализовано» — за 2 месяца статусы могли измениться. → Пометить как «исторический срез по vX» или обновить.

### 🟢 Ссылки и cross-ref
Битых markdown-ссылок не найдено. §047 корректно прошит в ARCHITECTURE.md и §032. Стиль статуса с commits (§117/§091) стоит распространить на остальные Done-спеки.

---

## 4. Тесты и CI

96 тест-файлов, 1138 `test()`. CI (`.github/workflows/ci.yml`) гоняет `flutter analyze` + `flutter test` на каждый PR/push — ✅ работает.

### 🔴 Дыры в покрытии критичных путей (follow-up — НЕ в этом проходе)
| Область | lib | test | Покрытие |
|---|---|---|---|
| `controllers/` | 6 | **0** | 0% — home (799) + subscription (932) без тестов |
| `config/` (parse) | 3 | **0** | 0% — парсер конфигов не покрыт |
| `vpn/` | 3 | 1 | только контракт канала, нет lifecycle |
| `services/` | 125 | 40 | 32% |
| `models/` | 20 | 6 | 30% |

**Приоритет тестов:** (1) `home_controller` / `subscription_controller` state-flows, (2) VPN lifecycle с мок-каналом (start→connected→stop, timeout→force-stop), (3) `config_parse` (fixtures уже есть).

### 🟡 Kotlin — нет тест-инфраструктуры (follow-up)
0 тестов, нет `src/test/`. Critical: `VpnPlugin` (MethodChannel-контракт), `LocaleApi` bundle round-trip (§047), `BoxVpnService` lifecycle.

### 🟢 Качество (follow-up)
- `analysis_options.yaml` — голый `flutter_lints`, можно усилить (unused_*, prefer_const, avoid_print).
- Флаки: `Future.delayed(350ms)`/`.timeout(5s)` → `fake_async`.
- Нет code-coverage tracking (codecov).

---

## Сделано в этом проходе (commit)

1. 🔴 `VpnPlugin.kt` — `runCatching` на `statusSink.success` и `registerReceiver`.
2. 🟡 `BoxService.kt` — `@Volatile receiverRegistered`.
3. 🟡 `LxBoxTileService.kt` — `Toast` через `mainHandler.post`.
4. 🟡 Логи в 6 пустых `catch(_)` (speed_test ×4, restore_backup ×1; §152 не тронут).
5. 🟡 §036 Draft→Released + commits; §042 backlog-пометка.
6. 🟡 Disambiguation дублей §128/§143 + README-секция.

## Follow-up (вынесено, НЕ в этом проходе)

- 🔴 Unit-тесты `home_controller` / `subscription_controller` / VPN-lifecycle / `config_parse`.
- 🟡 Kotlin тест-инфраструктура + `LocaleApi`/`VpnPlugin` тесты.
- 🟡 Split `traffic_profiler.dart` (1243) и `subscription_controller.dart` (932).
- 🟡 Освежить DEVELOPMENT_REPORT.
- 🟢 Усилить `analysis_options.yaml`, code-coverage, `MountedGuard` mixin, fake_async, прилинковать «сироты»-экраны.

## Что НЕ трогалось

- Чужой `connections_screen` (§152) — параллельная сессия.
- Деструктивных/диагностических операций на устройстве не выполнялось.
- §047 Public Intent API — полностью реализован и проверен на железе: [AUTOMATION.md](../../AUTOMATION.md).
