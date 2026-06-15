# 129 — Принудительная остановка VpnService при зависшем ядре

| Поле | Значение |
|------|----------|
| Статус | **Draft — анализ готов, реализация не начата** |
| Дата старта | 2026-06-16 |
| Тип | Защита на стороне приложения (Dart + Kotlin), НЕ фикс ядра |
| Симптом | После `Connecting… → timeout → disconnect` нативный `BoxVpnService` **не убивается** и **продолжает работать вхолостую**: tun0 поднят, ядро роутит входящий трафик (логи льются), VPN-иконка в системе — НО наружу проходит 0 байт (`up/down=0`, `connections=0`). UI показывает `stopping`/`disconnected`. Повторный start не проходит, кнопка не реагирует. Лечится только `am force-stop`. |
| Триггер репро | Активный узел AmneziaWG с `detour` на другой WireGuard-туннель (issue [#2](https://github.com/Leadaxe/sing-box-lx/issues/2)) — заклинивает **dial наружу**, `setStatus(Stopped)` никогда не приходит. |
| Связанные | [§050](050-libbox-debug-build/spec.md) (JNI callbacks must not throw); issue [#2](https://github.com/Leadaxe/sing-box-lx/issues/2) (AWG-detour вешает ядро — корневая причина зависания); §111 (detour-цепочки) |

---

## TL;DR

> **Ядро НЕ мёртвое — оно работает вхолостую.** При зависшем dial-пути (detour
> AWG→WG, issue #2) ядро остаётся живым: держит tun0, принимает и логирует
> входящий трафик из системы (`router: found package name…`), VPN-иконка горит.
> НО наружу проходит **0 байт** (`up/down=0`, `connections=0`) — насос крутится,
> труба на выходе заткнута. **Три состояния разъезжаются:** система (VPN жив,
> tun0 поднят) ↔ ядро (живо, dial заклинен, 0 трафика) ↔ Dart (`stopping`/
> `None`).
>
> Почему сервис не убивается: таймаут `Connecting` в нашем коде — чисто
> UI-операция, он `_emit`-ит `disconnected`, но НЕ инициирует реальную
> остановку VpnService. А когда остановка зовётся — она **кооперативная**, ждёт
> `setStatus(Stopped)` от ядра. Ядро живо, но этого статуса не отдаёт (умер не
> процесс, а конкретный dial-путь) → 5с таймаут → `return false`, **сервис
> остаётся жить и роутить вхолостую**. Решение — БЕЗ watchdog/поллинга: у нас
> уже есть событие-триггер (таймаут `_armTransientTimeout`, синтезирующий
> `disconnected`). В этой самой точке, перед `_emit(disconnected)`, принудительно
> прибить VpnService (`forceStop` → `stopSelf()` в обход застрявшего Go-teardown).
> Сам факт срабатывания таймаута = «ядро не отдало Stopped» = достаточное условие.

---

## Наблюдаемое поведение (с устройства, ядро v1.13.13-lx.8)

App-логи воспроизведённого зависания:
```
21:26:02.256 [vpn] _handleStatusEvent raw="Starting" tunnel=connecting prev=disconnected
21:26:12.257 Timeout in Connecting…, forcing disconnect      ← +10с, только _emit(disconnected)
...
21:30:28.885 [vpn] stopVPN returned false                    ← native не отдал Stopped
21:30:34.900 Timeout in Stopping…, forcing disconnect        ← застряло уже в Stopping
```
- Процесс ядра **не падает** (нет Runtime::Abort/panic/SIGABRT), но `tun0` не создан, сервис висит.
- Debug API `POST /action/start-vpn` возвращает `200/true`, но реального туннеля не даёт.
- Восстановление: только `am force-stop com.leadaxe.lxbox` + перезапуск.

---

## Корневой анализ — где разрывы

### Разрыв 1 — Dart: таймаут `Connecting` не зовёт реальный stop

[`home_controller.dart`](../../../app/lib/controllers/home_controller.dart) — `_armTransientTimeout` (строки 207-224). На переходе в `connecting`/`stopping` (строка 189-193) ставится 10-секундный safety-timer `_transientTimeout` (`Duration(seconds: 10)`, строка 71). По истечении делается **только**:
```dart
_emit(_state.copyWith(
  tunnel: TunnelStatus.disconnected,
  lastError: 'Connection timed out',
  ...
));
```
Никакого вызова `_stopInternal()` / `_vpn.stopVPN()`. `forcing disconnect` в логе — название намерения, но VpnService не трогается. UI рисует «disconnected», ядро живёт.

### Разрыв 2 — Kotlin: остановка кооперативная, без force-kill

[`VpnPlugin.kt:596`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/VpnPlugin.kt) `stopVpn`:
```kotlin
withTimeout(5_000) { BoxVpnService.stopAwait(context).await() }   // ждём ЯДРО
... catch (TimeoutCancellationException) { return false }          // 5с → false, и ВСЁ
```
[`BoxVpnService.kt:97`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxVpnService.kt) `stopAwait` шлёт `ACTION_STOP` broadcast и ждёт `stopCompleter`, который комплитится **только** из `BoxService.setStatus(Stopped)` → `completeStopIfWaiting()` (строки 55-64).

[`BoxService.kt:326`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxService.kt) `doStop` — два места, где всё застревает:
```kotlin
if (status == Stopped || status == Stopping) { return }   // GUARD: повторный stop молча выходит (328-330)
...
serviceScope.launch {
    closeFileDescriptor()              // ← вызовы в зависшее Go-ядро
    DefaultNetworkMonitor.stop()       //   блокируются навсегда, если ядро заклинило
    closeCommandServerAtomic("doStop")
    withContext(Dispatchers.Main) {
        setStatus(Stopped)             // ← сюда корутина не доходит
        service.stopSelf()             // ← stopSelf() не зовётся
    }
}
```
**Итог:** cleanup завязан на ответ зависшего ядра. Нет watchdog'а, который форсит `stopSelf()` в обход. Сервис остаётся жить → `onStartCommand` guard (`status != Stopped`) молча игнорит новый start → кнопка не реагирует.

| Звено | Что должно быть | Что есть сейчас |
|---|---|---|
| Таймаут `Connecting` (Dart) | вызвать реальный stop | только `_emit(disconnected)` |
| `stopVpn` (Kotlin) | при таймауте ядра — force `stopSelf()` | `return false`, сервис жив |
| `doStop` (Kotlin) | force-teardown по deadline | cleanup блокируется на зависшем ядре, guard глотает повторный stop |

### Почему так было сделано (не недосмотр)
Дизайн — **кооперативный blocking-stop** ([VpnPlugin.kt:589-595](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/VpnPlugin.kt) комментарий): ждём `setStatus(Stopped)`, чтобы `await stopVPN()` → `await startVPN()` не ловили race в `onStartCommand`. Корректно — **пока ядро живо**. Сценарий «ядро повисло и не отдаст Stopped» (= issue #2) не покрыт.

---

## Решение — реактивный kill в точке таймаута (БЕЗ watchdog)

Лечим **симптом** (зависший сервис не убивается); корень (зависание ядра на
detour AWG→WG) — отдельная задача ядра, см. issue #2.

**Принцип (ключевое решение, §129): НЕ заводить периодический watchdog.**
Поллинг трафика = лишний таймер + расход батареи. У нас **уже есть
событие-триггер** — таймаут `_armTransientTimeout`, который синтезирует переход
в `disconnected`, когда ядро НЕ отдало `Stopped`. Сам факт срабатывания этого
таймаута = «ядро не остановилось само» = достаточное условие, чтобы прибить
VpnService. Детект «0 трафика N секунд» НЕ нужен — таймаут уже и есть детект.

### Слой A — Dart: в точке таймаута прибить VpnService перед `_emit(disconnected)`
[`home_controller.dart`](../../../app/lib/controllers/home_controller.dart) `_armTransientTimeout` callback (≈209-223). Сейчас делает **только** `_emit(disconnected)`. Добавить ПЕРЕД ним force-kill native-сервиса:
```dart
_transientTimeoutTimer = Timer(_transientTimeout, () async {
  if (_state.tunnel != expected) return;
  _addDebug(DebugSource.app, 'Timeout in ${expected.label}, forcing disconnect');
  await _vpn.forceStopVpn();          // ← НОВОЕ: ядро не отдало Stopped → прибить сервис
  _emit(_state.copyWith(tunnel: TunnelStatus.disconnected, ...));
});
```
**Не** звать обычный `stopVPN()` — это кооперативный путь, который ждёт
`setStatus(Stopped)` и сам же виснет (он и привёл сюда). Нужен жёсткий путь.

### Слой B — Kotlin: новый метод `forceStopVPN` → force-`stopSelf()` в обход ядра
1. Новый method-channel `"forceStopVPN"` в [`VpnPlugin.kt`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/VpnPlugin.kt) (рядом с `stopVPN`, ≈136) → `BoxVpnService.forceStop(context)`. БЕЗ `stopAwait`/5с-ожидания — синхронно best-effort.
2. Новый `forceStop` / `doForceStop` в [`BoxService.kt`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxService.kt): **в обход `serviceScope.launch`-cleanup** (он и висит на ядре, ≈341-351). На Main-thread сразу: `notification.stop()`, `unregisterReceiver`, `setStatus(Stopped)`, **`service.stopSelf()`**. Teardown ядра (`closeFileDescriptor`/`closeCommandServerAtomic`) — best-effort в `withTimeout(короткий)`, чтобы зависший вызов не блокировал убийство.
3. Снять/ослабить `doStop` GUARD (≈328-330) для force-пути: сейчас он глотает повторный stop при `Stopping` → force должен пройти guard.

### Открытые вопросы (решить ДО кода) — предлагаемые дефолты
1. **Teardown ядра при force-kill.** НЕ пропускать целиком (иначе Clash-порт 63130 зависнет на след. старте — см. `stopAndAlert`, ≈356-360). → **Дефолт: best-effort `withTimeout(~1-2с)` на каждый teardown-вызов, потом `stopSelf()` несмотря ни на что.**
2. **Процесс НЕ убивать.** Force-kill = `stopSelf()` сервиса, НЕ `Process.killProcess` всего app (снесёт Flutter UI + Debug API). → **Дефолт: только `stopSelf()`.**
3. **`onStartCommand` guard.** После force-`stopSelf()` выставить `currentStatus = Stopped`, иначе следующий start молча проигнорится. → **Дефолт: `setStatus(Stopped)` явно в forceStop.**
4. **Двойной stop / race.** Dart зовёт `forceStopVPN` из таймаута; что если параллельно прилетел реальный `Stopped` от ядра? → **Дефолт: `forceStop` идемпотентен (guard «уже Stopped → no-op»), как существующий `stopAwait` ≈99-101.**

---

## Скоуп

**В скоупе:** реактивный force-stop VpnService в точке таймаута
`_armTransientTimeout` (Dart) + новый Kotlin force-путь (`forceStopVPN` →
`forceStop` → `stopSelf()`). Best-effort teardown ядра с коротким deadline.
**БЕЗ** периодического watchdog/поллинга трафика (расход батареи).

**Вне скоупа:** фикс самого зависания ядра на detour AWG→WireGuard — это issue
[#2](https://github.com/Leadaxe/sing-box-lx/issues/2), правится в форке sing-box, не в приложении. Эта таска
делает приложение **устойчивым** к зависшему ядру, не устраняет причину
зависания.

---

## Файлы

| Файл | Роль |
|---|---|
| [`app/lib/controllers/home_controller.dart`](../../../app/lib/controllers/home_controller.dart) | `_armTransientTimeout` (207-224), `_transientTimeout` (71), `_stopInternal` (267) |
| [`app/android/.../vpn/VpnPlugin.kt`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/VpnPlugin.kt) | `stopVpn` (596), `startVpn` (573) |
| [`app/android/.../vpn/BoxVpnService.kt`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxVpnService.kt) | `stopAwait` (97), `stop` (76), `completeStopIfWaiting` (61) |
| [`app/android/.../vpn/BoxService.kt`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxService.kt) | `doStop` (326), `stopAndAlert` (354), `setStatus` (380) |
