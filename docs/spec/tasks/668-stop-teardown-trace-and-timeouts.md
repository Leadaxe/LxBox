# 668 — остановка: трасса шагов teardown'а, дамп горутин при зависании, потолок времени

Статус: Done (19.10.2026), на устройстве не проверено. Продолжение §663
(второй эшелон), источник тот же: 4PDA, k-dmitriy, прокси-режим, простой ~6 ч,
в конфиге WG/AWG/WARP.

**23.10.2026, ядро `v1.14.3-lx.23`:** основная гипотеза (п. 2 диагностики)
подтвердилась по коду ядра и исправлена там (SPEC 030, Leadaxe/sing-box-lx#50).
Пре-пасс выключения не закрывал сокеты WG/AWG начиная с `v1.14.0-lx.37`,
поэтому каждый `Endpoint.Close` ждал свой receive-воркер, один за другим.
Теперь это явный обход `QuiesceForShutdown`. Кроме того, ядро само пишет
дамп горутин в свой лог, если закрытие не вернулось за 20 с. Наш сторож не
меняется и остаётся основным источником дампа. На устройстве исправление не
проверено: если зависание остановки повторится на lx.23, нужен дамп из пака
поддержки.

## Проблема

§663 довёл force-stop до службы, но причину не нашёл: какой Go-вызов в
`doStop()` не возвращается, по присланному логу не видно. Logcat пользователю
без adb недоступен, а в журнал приложения `doStop` не пишет ничего. Ядерная
часть заведена отдельно (Leadaxe/sing-box-lx#50) и чинится только по дампу
горутин с устройства.

Вторая половина: штатный `doStop()` не ограничен по времени. Пока Dart не
пришлёт force-stop (12 с), служба висит в `Stopping`, а если force-stop не
пришёл (UI закрыт), то навсегда.

## Диагностика (по коду, без стенда)

1. `doStop()` (`BoxService.kt`) запускает три шага подряд в `serviceScope`:
   `closeFileDescriptor` → `DefaultNetworkMonitor.stop` →
   `closeCommandServerAtomic`. Ни маркеров, ни таймаутов. `DefaultNetworkMonitor.stop()`
   без `runCatching`: исключение (мёртвый актор `DefaultNetworkListener`) молча
   завершает корутину, и `setStatus(Stopped)` не наступает.
2. В прокси-режиме `closeFileDescriptor` — no-op, `DefaultNetworkMonitor.stop`
   не ждёт ничего дольше ~1 с. Остаётся `closeCommandServerAtomic`:
   `cs.close()` и `cs.closeService()`. Основная гипотеза (разбор кода ядра lx.21):
   `closeService` → `instance.Close()` → `Endpoint.Close` WG/AWG ждёт
   `bindAccess`/`pauseOpAccess`/`stopping.Wait()`, а receive-воркер стоит в
   `ReadFrom` на detour-соединении. Подтверждается только стеком горутин.
3. Комментарий §330 в `closeCommandServerAtomic` неверен для lx.21: `cs.close()`
   → `StartedService.Close()` (`daemon/started_service.go:318-327`) тоже берёт
   `serviceAccess`, как и `closeService()`. Отсюда разделитель для разбора:
   строки `[fd §330] listener closed` нет — завис уже `close()` на
   `serviceAccess`; есть, но нет конца `closeService` — завис `instance.Close()`.
4. `withTimeout` вокруг блокирующего JNI-вызова не работает: таймаут
   кооперативный, блок не проверяет отмену, и `withTimeout` возвращается только
   когда вызов сам вернётся. Это относится и к существующему `doForceStop()`
   (§129/§140): его `withTimeout(2_000)` ничего не ограничивает, комментарий
   «отваливается по withTimeout» обещает то, чего нет.

## Решение

Правки: `BoxService.kt`, новый `StopTrace.kt` (тот же пакет `vpn`), чтение
файла дампа в `dump_builder.dart`, строка в таблице полей пака
(`features/013-DIAGNOSTICS/FUNCTIONS/diagnostic-dump.md`).

### Шаг teardown'а: `runStopStep`

Каждый шаг остановки выполняется в своём потоке-демоне; корутина ждёт его
`CompletableDeferred` через `withTimeoutOrNull`. Так потолок времени
настоящий: зависший JNI-вызов остаётся в своём потоке, корутина идёт дальше.
Исключение шага ловится в потоке и пишется в трассу.

Потолки: `closeFileDescriptor` 3 с, `DefaultNetworkMonitor.stop` 3 с,
`closeCommandServerAtomic` 20 с на `doStop`. Нижняя граница для последнего —
15 с: нормальное закрытие конфига с многими WG длится 10–17 с (§287, SPEC 030),
короткий потолок объявил бы `Stopped` раньше, чем ядро отпустило порт.
`doForceStop` сохраняет свои 2 с на шаг, теперь они действуют.

### Трасса (лог приложения)

На каждом шаге — строки `[stop] <step> begin / done in N ms / failed in N ms: …
/ TIMEOUT after N ms, abandoned` с меткой `SystemClock.elapsedRealtime()`.
Строки уходят в logcat и в поток core-лога (`lxbox/coreLog` → `AppLog`,
источник core). Внутри `closeCommandServer` — подшаг `listener closed, closeService begin`
(разделитель двух половин, см. п. 3 диагностики). Брошенный по потолку шаг,
если вернётся позже, пишет `returned late after N ms`. WARN-строки идут в
logcat уровнем E: `logcat_tail` пака снимается с уровнем E.
Штатная остановка пишет их уровнем INFO: в журнале текущей
сессии видны, в `corelog.txt` не сохраняются, файлов не трогают.

На входе — снимок контекста одной строкой: путь (`doStop`/`doForceStop`),
число endpoint'ов `wireguard` в отправленном конфиге (WG, AWG и WARP — один тип
ядра) и всего endpoint'ов, сколько секунд назад были последние `pause`,
`wake`, `resetNetwork`, `serviceReload` (или `never`), `isDeviceIdleMode`.

### Сторож

Шаг не завершился за 5 с (или за свой потолок, если он меньше) — один раз на
остановку:
- WARN-строка `[stop] stuck at <step> after N ms` и вся трасса к этому
  моменту одной WARN-записью — она попадает в `corelog.txt` и переживает
  перезапуск приложения;
- в отдельном потоке `PProfClient.goroutineDump()` (свой `PProfServer`, от
  `CommandServer` не зависит). Итог: WARN-запись со сводкой — число горутин и до
  8 горутин в состояниях `semacquire` / `sync.Mutex` / `sync.RWMutex` /
  `sync.WaitGroup` / `sync.Cond` или со стеком через `CloseService` /
  `Endpoint).Close` / `closeBindLocked` (каждая ≤ 30 строк, сводка ≤ ~24 КБ); полный дамп с
  трассой — в `filesDir/stop_stuck_goroutines.txt` (перезаписывается, ≤ 1 МБ).
- `DumpBuilder` кладёт этот файл в пак поддержки полем `stop_stuck_goroutines`
  (≤ 512 КБ, обрезка помечена). Без этой строки Dart полный дамп из Kotlin в
  пак не попадает: `goroutines_stack` снимается только при поднятом туннеле.

Штатная остановка сторож не будит: ни дампа, ни файла, ни WARN.

### Завершение

`doStop` теперь крутит teardown на `forceStopScope` (его `onDestroy` не
отменяет), а не на `serviceScope`. После всех шагов — успешных, упавших или
брошенных по потолку — `setStatus(Stopped)` + `stopSelf()` на Main, если
одновременно:
- экземпляр не уничтожен (`onDestroy` не было);
- его статус всё ещё `Stopping` (force-stop не опередил).

Иначе — только строка в трассе: поздний `Stopped` от старого экземпляра
перезаписал бы глобальный статус (`BoxVpnService.setCurrentStatus`) новой
службы. Тот же гард добавлен в конец `doForceStop` (`stopSelf` только у
неуничтоженного экземпляра).

### Метки времени для снимка

`@Volatile`-поля `lastPauseAt` / `lastWakeAt` / `lastResetNetworkAt` /
`lastReloadAt` (elapsedRealtime) ставятся перед вызовом: SCREEN_OFF →
`pause`, SCREEN_ON → `wake`, `onIdleModeChanged`, `ACTION_RESET_NETWORK`,
колбэк `DefaultNetworkMonitor`, `serviceReload`.

### Комментарий §330

Исправлен: в lx.21 `close()` тоже берёт `serviceAccess`; порядок
`close` → `closeService` по-прежнему правилен (если залип `serviceAccess`,
порт не освободит ни один порядок), а пропавшая строка
`[fd §330] listener closed` — разделитель двух классов зависания.

## Известный риск (не новый)

После потолка Go-горутина teardown'а продолжает висеть в своём потоке и может
держать порт mixed-inbound, Clash-порт или `lifecycleAccess`/`serviceAccess`
ядра. Следующий Start в том же процессе может не подняться: упадёт с
`bind: address already in use` (покажет ошибку через `stopAndAlert`) или
повиснет в `Starting` внутри Go. Это тот же риск, что у существующего
`doForceStop` (§129/§663); задача его не добавляет — до неё служба просто
оставалась в `Stopping`. Если на устройстве окажется, что после реального
зависания Start не встаёт, лечение — перезапуск процесса или ядро
(Leadaxe/sing-box-lx#50), не эта задача.

Проверено по коду: Kotlin-сторона следующего Start после брошенной остановки
не виснет.
- `stopSelf()` → `onDestroy`; следующий старт создаёт новый `BoxVpnService` с
  новым `BoxService` (поле `service = BoxService(this, this)`): статус
  `Stopped`, `receiverRegistered = false`, свежие scope'ы. Гард
  `status != Stopped` пропускает.
- Если экземпляр тот же (`stopSelf` ещё не довёл до `onDestroy`): статус уже
  `Stopped`, `resetScope()` отменяет старые scope'ы — брошенный поток шага
  к ним не привязан и ничего не блокирует; `receiverRegistered` снят в `doStop`.
- Общих Kotlin-мьютексов между stop и start нет; `commandServer` уже `null`
  (`getAndSet` в начале `closeCommandServerAtomic`), новый `CommandServer`
  создаётся заново. Поток брошенного шага позже пишет только в трассу и не
  трогает статус (гарды выше).
- Блокироваться может только Go: `CommandServer.start()` / `startOrReloadService`
  на захваченном ядре. Это класс риска выше.

## Условия срабатывания (явно)

- Трасса и снимок: каждый `doStop` и `doForceStop`, кроме гарда «уже
  `Stopped`/`Stopping`» у `doStop` и «уже `Stopped`» у `doForceStop`.
- Сторож и дамп: шаг дольше 5 с или дольше своего потолка, один раз на
  остановку.
- Запись в журнал приложения: только пока Flutter подписан на core-лог
  (`coreLogSink != null`); без UI — только logcat и файл дампа.
- `onRevoke` и `stopAndAlert` не трогали.

## Проверка

На устройстве и эмуляторе не проверено (решение владельца: без эмулятора и
сборок). CI компилирует Kotlin. Ожидаемое на устройстве: штатный Stop даёт в
журнале 7 INFO-строк `[stop]`, без WARN и без файла; при зависании через 5 с —
WARN `stuck at closeCommandServer`, затем сводка горутин, через 20 с —
`TIMEOUT … abandoned` и статус `Stopped` (если force-stop не пришёл раньше).
