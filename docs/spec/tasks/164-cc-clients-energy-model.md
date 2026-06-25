# 164 — Энергомодель CC-клиентов (FAST/NORMAL + сон в фоне)

| Поле | Значение |
|------|----------|
| Тип | Task (реализация энергомодели из feature 123 §4) |
| Статус | In progress (реализовано, device-проверка pending) |
| Связано | [feature 123 subscription-model](../features/123%20subscription-model/spec.md) §3-4 |

Снижение CPU/батареи от status-стрима: адаптивная частота + сон CC-клиентов в фоне. Реализует §3-4 feature 123.

---

## 1. Проблема

`statusClient` (CommandStatus) тикал `1e8`=0.1с **always-on** пока туннель up — 10 снапшотов/сек через gRPC+IPC+EventChannel-marshal, даже когда:
- UI не виден (фон) — статистику никто не смотрит;
- открыт главный экран — 0.1с для цифры скорости избыточно (глаз не видит разницы с 0.5с).

UI-троттлы (главный 1с, память 3с) экономят только ребилд — поздно, ядро уже сгенерило и протолкнуло все 10 тиков.

## 2. Решение — три рычага у источника

### 2.1 Адаптивная частота status (NORMAL/FAST)
`setStatusInterval` меняется только пересозданием клиента (нет метода на живом). `@Volatile statusIntervalNs` + `connectStatus()`.
- **NORMAL** = 5e8 нс (0.5с, 2/сек) — базовый, главный экран.
- **FAST** = 1e8 нс (0.1с, 10/сек) — когда открыт Stats.
- `setStatusFast(Boolean)` — переключает (no-op если не изменилось/туннель не жив/на паузе).

### 2.2 Сон в фоне (onAppPaused)
- **statusClient** → `pauseStatus()` (disconnect, 0 тиков). `statusPaused` гейтит reconnect-петлю.
- **screenClient** → `pauseScreen()` (disconnect, **screenRefs СОХРАНЯЕТСЯ**). `screenPaused` — отдельный флаг, ≠ refcount=0 («потребитель есть, но UI в фоне»). `connectScreen` в паузе только инкрементит refcount.
- **profilerClient** → НЕ трогаем (recording живёт в фоне).
- **heartbeat** → `_stopHeartbeat` (уже было).

### 2.3 Возврат (onAppResumed)
- `resumeStatus()` (NORMAL) + `resumeScreen()` (поднять если `screenRefs>0`). Делается ПОСЛЕ `_resyncOnResume` — если туннель лёг в фоне, `_handleStatusEvent` уже погасил CC, resume гейтится `tunnelUp`.

## 3. Почему сон безопасен
Выключение/падение VPN в фоне прилетает через нативный `BROADCAST_STATUS` (feature 123 §1.1), не через CC-клиенты. Усыпив status/screen, теряем только невидимую статистику, но НЕ слепнем к состоянию туннеля. dead-tunnel-watchdog (питался status-тишиной) в фоне и так не нужен — heartbeat выключен, broadcast ловит.

## 4. Реализация (файлы)

**Native — `BoxCommandClient.kt`:**
- `STATUS_INTERVAL_FAST`=1e8 / `STATUS_INTERVAL_NORMAL`=5e8; `@Volatile statusIntervalNs` (старт NORMAL).
- `@Volatile statusPaused` / `screenPaused`.
- `setStatusFast(fast)`, `pauseStatus()`, `resumeStatus()`, `pauseScreen()`, `resumeScreen()`.
- `connectStatus()` — `if (statusPaused) return` + `setStatusInterval(statusIntervalNs)`.
- `connectScreen()` — `if (wasZero && !screenPaused) connectScreenClient()`.
- `shutdownAll()` — сброс `screenPaused`/`statusPaused`.

**Plugin — `VpnPlugin.kt`:** cases `ccSetStatusFast` (arg `fast`), `ccPauseClients` (status+screen), `ccResumeClients`.

**Dart — `cc_channel.dart`:** `setStatusFast(bool)`, `pauseClients()`, `resumeClients()`.

**Dart — `home_controller.dart`:** `onAppPaused` → `pauseClients()` (если tunnelUp); `_resyncOnResume` → `resumeClients()` (если tunnelUp).

**Dart — `stats_screen.dart`:** `initState` → `setStatusFast(true)`; `dispose` → `setStatusFast(false)`.

## 5. Эффект

| Состояние | Было | Стало |
|-----------|------|-------|
| Главный экран (foreground) | 10 тиков/сек | 2 тиков/сек (NORMAL) |
| Stats открыт | 10 тиков/сек | 10 тиков/сек (FAST — нужно) |
| Фон | 10 тиков/сек always-on | **0 тиков** (pause) |

В фоне (где телефон с VPN проводит большую часть времени) — полное обнуление status/screen-нагрузки, profiler живёт по recording.

## 6. Критерии приёмки

1. Главный экран: status тикает 0.5с (NORMAL), не 0.1с.
2. Открытие Stats → FAST 0.1с (плавные счётчики); закрытие → возврат NORMAL.
3. Фон (onAppPaused) → statusClient+screenClient погашены (0 тиков); profilerClient жив если recording.
4. Возврат из фона → клиенты подняты (status NORMAL, screen если потребители живы); UI актуален.
5. Выключение VPN в фоне ловится (broadcast) — при возврате статус корректен.
6. Recording в фоне не прерывается усыплением screenClient (profiler независим).
7. screenRefs не теряется при pause/resume (экран-потребитель восстанавливается).

## 7. Device-проверка (pending)
- `dumpsys batterystats` / CPU по процессу до/после (фон-drain).
- Recording в фоне продолжается при свёрнутом приложении.
- Stats показывает плавную статистику (0.1с), главный — 0.5с без лагов.
