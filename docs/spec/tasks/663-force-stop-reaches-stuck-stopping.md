# 663 — forceStop не доходит до сервиса, застрявшего в Stopping

Статус: Done (17.10.2026). Источник: 4PDA, k-dmitriy, 13.10 и 17.10.2026 (прокси-режим, простой ~6 ч).

## Проблема

После долгого простоя кнопка Start не работает: при каждом возврате в приложение
`onAppResumed` видит `native=stopping`, через 12 с срабатывает таймаут,
`forceStopVPN` уходит, но статус остаётся `stopping`; `startVPN returned true`,
а служба не стартует. Лечит только принудительная остановка приложения.

Лог пользователя (17.10): три цикла resume → stopping → timeout → forceStop →
stopping; между ними `startVPN returned true` без последующего `status=running`.

## Диагностика (по коду, без стенда)

1. `BoxService.doStop()` переводит статус в `Stopping` и **сразу** снимает
   broadcast-приёмник (`unregisterReceiver`), а teardown ядра
   (`closeFileDescriptor` → `DefaultNetworkMonitor.stop` → `closeCommandServerAtomic`)
   уходит в `serviceScope.launch` без таймаутов. Если Go-вызов виснет,
   `setStatus(Stopped)` и `stopSelf()` не наступают никогда; процесс жив, статус
   `Stopping` держится часами.
2. `BoxVpnService.forceStop()` шлёт `ACTION_FORCE_STOP` **broadcast'ом**.
   Приёмник уже снят в п. 1 → `doForceStop()` не вызывается. Ровно это и видно
   в логе: после `forceStopVPN sent` статус не меняется.
3. `onStartCommand` при `status != Stopped` молча возвращает `START_STICKY`
   (гард), а `startVpn` в плагине отдаёт Dart `true` до любой проверки —
   отсюда «startVPN returned true» и тишина.
4. `stopAwait` для этого случая уже имеет второй эшелон (§361: нет приёмника →
   принудительно `Stopped`), но путь таймаута в Dart использует `forceStopVPN`,
   а не `stopAwait`, и §361 на него не распространяется.

Почему teardown повис в Go у пользователя — по логу не установить (нужен
logcat нативной стороны); это первый эшелон и в задачу не входит. Порт, занятый
другой программой во время простоя, не при чём: LxBox в это время не слушал.

## Решение

Второй эшелон: force-stop обязан доходить до службы независимо от приёмника.

- `BoxVpnService.forceStop()`: если `!stopReceiverAlive` — вместо broadcast'а
  доставить команду через `startService(Intent(ACTION_FORCE_STOP))`, который
  попадает в `onStartCommand`; там ветка `ACTION_FORCE_STOP` → `doForceStop()`
  **до** гарда `status != Stopped` и до `notification.show(...)`. Если
  приёмник жив — поведение прежнее (broadcast).
- `doForceStop()` уже без гарда на `Stopping` и с `withTimeout(2 с)` на каждый
  Go-вызов; менять не нужно. Зависшую корутину `serviceScope` он не отменяет —
  это допустимо: `stopSelf()` → `onDestroy()` → `serviceScope.cancel()`.
- `VpnPlugin.startVpn`: не трогать (гард в службе остаётся; после фикса
  к моменту старта статус уже `Stopped`).

Условия, при которых ветка срабатывает (явно):
- статус `Stopping` или `Starting`/`Started`, приёмник снят (`doStop` уже
  прошёл первую фазу, либо `onRevoke`/`exit`);
- процесс приложения жив (иначе статус и так `Stopped`).
Исключения: статус `Stopped` → `doForceStop` no-op, как сейчас.

## Проверка

- Юнит на Kotlin не нужен; логика в службе. На эмуляторе: поднять прокси-режим,
  в `doStop` искусственно задержать `closeCommandServerAtomic` (временный
  `delay(60_000)` в ветке отладки, в коммит не вносить), нажать Stop, свернуть,
  развернуть: раньше — вечный `stopping`; после — через 12 с таймаута
  `doForceStop ENTER` в logcat, статус `Stopped`, следующий Start поднимает
  службу.
- Лог приложения: после `forceStopVPN sent` должен прийти `status=stopped`.

## Документация

- `docs/ARCHITECTURE.md`: раздел о жизненном цикле службы — строка про два
  канала доставки force-stop (broadcast при живом приёмнике, startService без).
- CHANGELOG: «Start after a long idle could hang in “stopping” until the app
  was force-closed; force-stop now reaches the service even after its receiver
  is gone».

## Итог

Сделано по решению: `BoxVpnService.forceStop` при снятом приёмнике шлёт
`startService(ACTION_FORCE_STOP)`, `BoxService.onStartCommand` ведёт его в
`doForceStop()` до `notification.show` и гарда; пустой экземпляр (статус
`Stopped`) делает `stopSelf(startId)`.

Эмулятор (release-сборка с временным `delay(60_000)` перед
`closeCommandServerAtomic` в `doStop`, прокси-режим): Stop → свернуть →
развернуть; через 12 с `forceStopVPN` → `startService` → `doForceStop ENTER
status=Stopping` → `setStatus(Stopped)` → `onDestroy`, экран «Disconnected»;
следующий Start поднял службу (`Started`), отложенная корутина старого
экземпляра отменилась с его scope и новую сессию не тронула. Строку
`status=stopped` в логе приложения отдельно не смотрели — статус виден по
нативному broadcast и экрану. Живой сценарий с повисшим Go-вызовом (первый
эшелон) не воспроизводили.
На реальном устройстве (телефоне) не проверено.
