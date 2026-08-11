# §387 — зомби-`Started` после force-stop (старт, зависший в JNI, доезжает позже)

| Поле | Значение |
|------|----------|
| Статус | Done, DEVICE-PENDING |
| Дата старта | 2026-08-11 |
| Дата завершения | 2026-08-11 |
| Связанные spec'ы | [§361](361-late-started-status-after-service-destroy.md) — первый guard этого же класса (отменённая корутина); §129/§140 — `doForceStop`; §122 — stale-terminal guard в Dart |

## Проблема

Репорт с 4PDA (10.08.2026): под «белыми списками» мобильного интернета старт
WARP-ноды с доменным endpoint'ом виснет, а после таймаута приложение
«подвисает, корректно остановиться не может, корректно потом запустить».

Лог пользователя (существенное):

```
21:11:00.830  status=Starting
21:11:15.830  Timeout in connecting, forcing disconnect
21:11:15.834  [vpn] forceStopVPN sent
21:11:15.849  status=Stopped   ← из doForceStop, проглочен stale-terminal guard'ом
21:11:23.888  status=Started   ← ЗОМБИ: принят как connected (prev=disconnected)
21:11:40.333  getTunnelUptimeMs timed out after 3s
```

## Диагностика

Таймлайн гонки:

1. `startSingbox` блокируется в JNI-вызове `cs.startOrReloadService` — резолв
   доменного endpoint'а не отвечает (DNS срезан), дедлайн ядра **длиннее**
   15-секундного `_connectingTimeout` обвязки.
2. Dart-таймаут → `forceStopVPN` → `doForceStop`: синхронно `setStatus(Stopped)`
   (это `Stopped` в 21:11:15.849), teardown уходит на `forceStopScope`.
3. Teardown (`closeFileDescriptor` / `closeCommandServerAtomic`) упирается в тот
   же занятый ядром JNI → `stopSelf()` ещё НЕ вызван → `onDestroy` не было →
   `serviceScope` НЕ отменён.
4. 21:11:23 — `startOrReloadService` возвращается (резолв дожил/отвалился),
   корутина старта идёт дальше. Guard §361 (`currentCoroutineContext().isActive`)
   **проходит** — корутину никто не отменял. `setStatus(VpnStatus.Started)` →
   broadcast.
5. Dart: `prev=disconnected`, событие выглядит легитимным → `connected`,
   CC-стримы, heartbeat. Сервис при этом умирает (teardown догоняет ядро) →
   все unary-RPC виснут (`getTunnelUptimeMs timed out`), UI держит «Connected»,
   стоп не работает.

§361 закрыл ordering «`stopSelf` → отмена scope → поздний return»; здесь
ordering другой: **поздний return → (потом) `stopSelf`**. Отмена корутины как
признак смерти сессии недостаточна — признак состояния (`status`) надёжнее:
любой stop-путь (`doStop` / `doForceStop` / `stopAndAlert` / `onRevoke`)
уводит `status` из `Starting` **до** того, как начинает teardown.

## Фикс

[`BoxService.kt`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxService.kt),
`startSingbox`, рядом с guard'ом §361: после возврата из
`startOrReloadService` дополнительно проверяем `status == Starting`. Любое
другое значение = пока старт висел, сессию уже остановили → поздний `Started`
не выставляем и не бродкастим, выходим. Добивает свежестартовавшее ядро уже
запущенный teardown соответствующего stop-пути (у `doForceStop` он гарантированно
в полёте — это он и разблокируется тем же возвратом из JNI).

Dart-слой не трогаем: единственный оставшийся ordering — broadcast `Started`,
ушедший в полёт **до** `doForceStop`, — самоисцеляется следующим за ним
`Stopped` (очередь broadcast'ов упорядочена, `doForceStop` шлёт `Stopped`
поверх только что выставленного `Started`).

## Почему guard по `status`, а не по generation-счётчику

Поколение сессии закрыло бы ещё и ordering «юзер успел нажать start заново, и
старая корутина видит чужой `Starting`» — но новый `onStartCommand` возможен
только из `status == Stopped` (guard в `onStartCommand`) и делает `resetScope()`,
отменяя старый `serviceScope` — старую корутину поймает §361. Два guard'а в
паре покрывают все ordering'и без нового состояния.

## Verify

Юнит-тестов на `BoxService` нет (Android service, в репо не тестируется) —
верификация устройством, сценарий из репорта:

1. WARP-нода с доменным endpoint'ом, DNS для домена срезать (правило/фаервол,
   либо режим «белых списков»).
2. Старт → ждать `Timeout in connecting` (15с) → синтезированный disconnected.
3. До фикса: через несколько секунд прилетает `Started`, UI показывает
   Connected, RPC виснут. После: в logcat
   `[vpn §387] status=Stopped after start returned — skip setStatus(Started)`,
   UI остаётся disconnected, повторный старт работает.
