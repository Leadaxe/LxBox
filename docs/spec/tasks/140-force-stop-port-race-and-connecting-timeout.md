# 140 — §129 force-stop: гонка с портом 63130 + force-kill здорового `Connecting`

| Поле | Значение |
|------|----------|
| Статус | **✅ Done — проверено на устройстве** (тест-телефон CE8XX48PCI79U4XG, 2026-06-16) |
| Verification | Dart analyze чистый; Kotlin release arm64 build ×2 OK. On-device: (1) прямой `force-stop-vpn` при `connected` → `doForceStop` отработал в НОВОМ порядке (`teardown завершён → stopSelf()`, `onDestroy` ПОСЛЕ teardown), повторный старт `Starting→Started` чисто; (2) естественный путь — `set-transient-timeout?connecting=50` → старт → `_armTransientTimeout` сработал ВО ВРЕМЯ `connecting` (`forceStop status=Starting`) = точный сценарий жалобы → повторный старт поднялся за ~385мс; (3) `force-stop-vpn` при `Stopped` = идемпотентный no-op. **За всю сессию НИ ОДНОЙ `address already in use` / `external controller listen error`.** См. лог ниже. |
| Дата старта | 2026-06-16 |
| Тип | Регресс-фикс на стороне приложения (Dart + Kotlin), НЕ фикс ядра |
| Регресс | v2.3.0 → v2.3.1 (внесён §129, commit `3d54c1d`) |
| Симптом (с §4PDA) | После апдейта на v2.3.1 «поверх» сервис не стартует: левый скрин — `Clash API: Connection refused`; правый — `VPN tunnel lost — another VPN may have taken over` + системный баннер `VPN taken by another app`. На v2.3.0 не было. |
| Связанные | [§129](129-vpnservice-force-stop-on-stuck-core.md) (force-stop, чей дефект чиним), [§049](#) (AtomicReference teardown), issue [#2](https://github.com/Leadaxe/sing-box-lx/issues/2) (зависание ядра — оригинальный триггер §129) |

---

## TL;DR

> §129 добавил force-stop зависшего ядра. Реализация содержит **две независимые
> дыры**, обе ломают именно **старт** (а не стоп, ради которого §129 писалась):
>
> **Дыра 1 — гонка с портом 63130.** `doForceStop` вызывает `service.stopSelf()`
> **до** того, как фоновый teardown освободил Clash-порт 63130. `stopSelf()` →
> `onDestroy` → `serviceScope.cancel()` отменяет ещё не доработавшую teardown-
> корутину на полпути. Сокет 63130 (открыт Go-кодом sing-box внутри **процесса**,
> а не «внутри сервиса») остаётся занят, потому что процесс жив (UI на экране),
> а система fd не закрывает. Следующий старт → `bind: address already in use` →
> Clash API не поднимается → `Clash API: Connection refused`, затем heartbeat-
> таймаут → `another VPN may have taken over`. Спека §129 **сама предупреждала**
> про этот порт (open question #1), но реализация всё равно оставила гонку.
>
> **Дыра 2 — force-kill здорового `Connecting`.** Таймаут `_armTransientTimeout`
> армится не только на `stopping`, но и на `connecting` (native `Starting` →
> `connecting`). Порог один — 10с. Медленный, но **живой** старт (сотовая сеть,
> WARP-gen/AWG handshake) превышает 10с → force-stop убивает рабочее
> подключение. На v2.3.0 этот таймаут делал только `_emit(disconnected)`, native
> не трогал — отсюда «на 2.3.0 не было».

---

## Корневой анализ

### Дыра 1 — порядок `stopSelf()` / teardown в `doForceStop`

[`BoxService.kt`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxService.kt) `doForceStop` (≈374-406):
```kotlin
setStatus(VpnStatus.Stopped)
service.stopSelf()                       // ← (1) планирует onDestroy → serviceScope.cancel()
...
serviceScope.launch {                    // ← (2) teardown в ОТМЕНЯЕМОМ scope
    withTimeout(2_000) { closeFileDescriptor() }
    withTimeout(2_000) { DefaultNetworkMonitor.stop() }
    withTimeout(2_000) { closeCommandServerAtomic("doForceStop") }   // ← освобождает порт 63130
}
```
Гонка: (1) на Main ставит `onDestroy` в очередь; `onDestroy` (≈173-185) делает
`serviceScope.cancel()`. (2) только-только запланирована на IO-диспетчер. Если
`onDestroy` добегает до `cancel()` раньше, чем корутина дошла до
`closeCommandServerAtomic` — корутина отменяется, **порт 63130 не освобождён**.
При зависшем ядре (целевой сценарий §129) `withTimeout` отменяется по cancel
scope **раньше** дедлайна — leak практически гарантирован.

**Почему система не спасает:** `stopSelf()` демонтирует Android-компонент Service,
но **не убивает процесс** `com.leadaxe.lxbox` (в нём живёт Flutter UI/Activity —
юзер на экране). Сокет 63130 открыт Go-кодом sing-box и принадлежит процессу, а
не сервису. Пока процесс жив, ядро Linux fd не закрывает → закрыть может только
явный `closeCommandServerAtomic()`.

**Эталоны в том же файле делают правильно** (`stopSelf` ПОСЛЕ закрытия порта):
- `doStop` (≈344-354): `stopSelf()` **внутри** корутины, после `closeCommandServerAtomic`.
- `stopAndAlert` (≈408-432): teardown **синхронно**, `stopSelf()` в конце; комментарий прямо: *«CommandServer держал binding на порт 63130 … retry start failed с `bind: address already in use`»*.
- `onRevoke` (≈194-208): `closeCommandServerAtomic("revoke")` синхронно **до** `serviceScope.cancel()` + `stopSelf()`.

`doForceStop` — единственный путь с инвертированным порядком.

### Дыра 2 — `_armTransientTimeout` бьёт по `connecting`

[`home_controller.dart`](../../../app/lib/controllers/home_controller.dart):
- native `Starting` → `TunnelStatus.connecting` ([`tunnel_status.dart:23`](../../../app/lib/models/tunnel_status.dart)).
- `_handleStatusEvent` (≈189): `if (tunnel == stopping || tunnel == connecting) → _armTransientTimeout`.
- `_transientTimeout = Duration(seconds: 10)` (≈71), общий для обеих фаз.
- callback (≈209-233): по таймауту `await _vpn.forceStopVPN()`.

Для `stopping` force-stop оправдан (ядро не отдало Stopped). Для `connecting`
10с — это просто медленный, но валидный старт на сотовой → force-kill убивает
рабочее подключение.

### Цепочка к экранным сообщениям

```
Старт (сотовая, медленный узел) → connecting висит >10с
  → _armTransientTimeout → forceStopVPN → doForceStop
  → stopSelf() обгоняет teardown → порт 63130 занят (Дыра 1)
  → UI снова показывает кнопку, юзер жмёт Start
  → новый sing-box: bind 63130 → address already in use → Clash API не поднялся
  → reloadProxies (home_controller.dart:476): "Clash API: Connection refused"  [левый скрин]
  → через 40с heartbeat (2 фейла /traffic) → _onTunnelDead (heartbeat.dart:100):
     "VPN tunnel lost — another VPN may have taken over"  [правый скрин]
```

**Важно:** «another VPN» — **ложная атрибуция** нашего heartbeat'а, а НЕ системный
`onRevoke`. Реальный системный revoke пишет другой текст (`"VPN revoked by
another app"`, `BoxService.kt:205`). Туннель никто не захватывал — порт занят
нами же.

---

## Решение

### Правка 1 (Kotlin) — `doForceStop`: закрыть порт ДО `stopSelf`, teardown в неотменяемом scope

Сохранить замысел §129 (UI разблокируется немедленно, не ждём зависшее ядро на
Main), но гарантировать освобождение порта:
1. UI/нотификацию гасить синхронно сразу: `unregisterReceiver`, `notification.stop()`, `setStatus(Stopped)` — это дёшево и не виснет → кнопка разблокируется немедленно (как и раньше).
2. teardown + `stopSelf()` — в **отдельном** `forceStopScope`, который `onDestroy` **НЕ** отменяет. Каждый teardown-вызов в `withTimeout(2_000)` (как сейчас — защита от зависшего ядра). `service.stopSelf()` — **внутри** корутины, **после** `closeCommandServerAtomic` (как `doStop`).
3. `forceStopScope` — новое поле класса `CoroutineScope(SupervisorJob() + Dispatchers.IO)`, пересоздаётся в `resetScope` (как `serviceScope`), `onDestroy` его **не** трогает. Корутина сама завершается после `stopSelf`.

Идемпотентность teardown подтверждена: `closeFileDescriptor` (≈214) и
`closeCommandServerAtomic` (≈219) используют `AtomicReference.getAndSet(null)` →
повторный вызов = no-op. Двойной teardown безопасен.

### Правка 2 (Dart) — раздельные пороги stopping/connecting

[`home_controller.dart`](../../../app/lib/controllers/home_controller.dart):
```dart
static const _stoppingTimeout   = Duration(seconds: 10);  // было _transientTimeout, значение то же
static const _connectingTimeout = Duration(seconds: 15);  // НОВОЕ: медленная сотовая
```
В `_armTransientTimeout` выбирать порог по `expected` (stopping→10, connecting→15).

### Правка 4 (Dart) — Debug API для on-device теста force-stop'а (постоянные)

Само зависание ядра (issue #2) не воспроизводится синтетически (sing-box с
обычным узлом стартует мгновенно в `Started`, `connecting` не виснет). Чтобы
`doForceStop`-путь был тестируемым на устройстве **постоянно** (не только сейчас),
добавлены два `/action/*` эндпоинта:

1. **`POST /action/force-stop-vpn`** — напрямую дёргает native `forceStopVPN`
   (минуя transient-таймаут). Тот же `doForceStop`-путь, что при зависшем ядре.
   `{ok, action, native_ok}`. Для проверки, что после force-stop повторный старт
   НЕ падает с `bind: address already in use`.
2. **`POST /action/set-transient-timeout?connecting=<ms>&stopping=<ms>`** —
   переопределяет пороги (в **миллисекундах**). Пороги в `HomeController` стали
   **instance-переменными** (`_stoppingTimeout`/`_connectingTimeout`),
   инициализируются из `static const`-дефолтов (10с/15с). Любой параметр
   опционален. Позволяет поставить, напр., `connecting=500` и спровоцировать
   `_armTransientTimeout`-force-stop без реального зависона ядра.

`HomeController` получил публичные debug-методы: `debugForceStopVpn()`,
`debugSetTransientTimeouts({connectingMs, stoppingMs})`, `debugTransientTimeouts`
(getter). Эндпоинты добавлены в `/help`.

### Правка 3 (Dart) — убрать ложный текст «another VPN»

[`heartbeat.dart:100`](../../../app/lib/controllers/home_controller/heartbeat.dart) `_onTunnelDead`:
текст `'VPN tunnel lost — another VPN may have taken over'` → нейтральный, не
вводящий в заблуждение (туннель не отвечает / соединение потеряно). Статус
`revoked` оставляем — меняется только пользовательский текст. Системный
`onRevoke`-текст НЕ трогаем (он про реальный revoke).

---

## Скоуп

**В скоупе:** (1) порядок teardown/`stopSelf` в `doForceStop` + неотменяемый
`forceStopScope`; (2) раздельный порог `connecting`=15с; (3) косметика текста
heartbeat-cliff.

**Вне скоупа:** само зависание ядра (issue #2); общий рефактор lifecycle
VpnService; изменение heartbeat-интервалов/порога фейлов.

---

## Тайминги — было / стало

| Константа | Было | Стало | Файл |
|---|---|---|---|
| transient (stopping) | `10s` | `10s` (без изменений) | `home_controller.dart:71` |
| transient (connecting) | `10s` | **`15s`** | `home_controller.dart:71` |
| `withTimeout` teardown (×3) | `2_000` | `2_000` (без изменений) | `BoxService.kt` doForceStop |
| `_heartbeatInterval` | `20s` | `20s` (не трогаем) | `heartbeat.dart:23` |
| `_heartbeatTimeout` | `4s` | `4s` (не трогаем) | `heartbeat.dart:24` |
| `_maxHeartbeatFailures` | `2` | `2` (не трогаем) | `heartbeat.dart:25` |

---

## Файлы

| Слой | Файл | Изменение |
|---|---|---|
| Kotlin | `BoxService.kt` | новый `forceStopScope`; `doForceStop` — teardown+`stopSelf` в `forceStopScope`, `stopSelf` ПОСЛЕ `closeCommandServerAtomic`; `resetScope` пересоздаёт и `forceStopScope` |
| Dart | `home_controller.dart` | пороги — instance-переменные (`_stoppingTimeout`/`_connectingTimeout`) из дефолтов 10с/15с; `_armTransientTimeout` выбирает порог по фазе; debug-методы `debugForceStopVpn`/`debugSetTransientTimeouts`/`debugTransientTimeouts` |
| Dart | `heartbeat.dart` | нейтральный текст в `_onTunnelDead` (Правка 3) |
| Dart | `debug/handlers/action.dart` | `/action/force-stop-vpn` + `/action/set-transient-timeout` (Правка 4) |
| Dart | `debug/handlers/help.dart` | help-записи для двух новых эндпоинтов |

## Verification — выполнено on-device (2026-06-16)

Метод: dead-node конфиг (vless на `10.255.255.1:443`) через `PUT /config` +
новые debug-эндпоинты. Само зависание ядра (issue #2) синтетически не
воспроизводится (sing-box стартует в `Started` за ~400мс), поэтому force-stop
провоцировался двумя способами.

**Акт 1 — прямой `force-stop-vpn` при `connected`:**
```
doForceStop ENTER status=Started
setStatus(Stopped)                                    ← UI разблокирован сразу
doForceStop — UI/notification stopped, teardown+stopSelf на forceStopScope
doForceStop — teardown завершён → stopSelf()          ← порт 63130 закрыт ПЕРЕД stopSelf
onDestroy status=Stopped                              ← onDestroy ПОСЛЕ teardown (race закрыт)
...
companion.start() → setStatus(Starting) → setStatus(Started)   ← повторный старт ЧИСТО
```

**Акт 2 — естественный путь (порог `connecting=50ms`) = точный сценарий жалобы:**
```
setStatus(Starting)
onMethodCall: forceStopVPN                            ← _armTransientTimeout сработал
companion.forceStop() current status=Starting         ← force-stop ВО ВРЕМЯ connecting
doForceStop ENTER → teardown завершён → stopSelf() → onDestroy
state: disconnected | Connection timed out
...
повторный старт: Starting → Started за ~385мс          ← порт свободен, без bind-ошибки
```

**Негативный результат (главный):** за всю тест-сессию `logcat` — **0**
вхождений `address already in use` / `external controller listen error` /
`teardown в фоне` (старый паттерн удалён). Идемпотентность: `force-stop-vpn`
при `Stopped` → no-op.
