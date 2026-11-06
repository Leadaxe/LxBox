# §639 — «Quit & reopen app» оставляет в шторке уведомление «VPN работает»

| Поле | Значение |
|------|----------|
| Тип | B (баг) |
| Статус | D (done), выпущено в v2.25.14 |
| Фичи | [010-VPN_SERVICE](../features/010-VPN_SERVICE/FEATURE.md) |
| Дата | 2026-10-13 |
| Связанные | §638 (Quit снимает признак «желателен» и сторожа), §637, §182, §430 |

Принцип: «не ломай то, что работает» — правка точечная.

## Проблема

Эмулятор, 13.10.2026, после §638. `VpnPlugin.quitApp` снимает признак «VPN
желателен» и будильник сторожа, затем `finishAffinity` и убийство процесса.
`BoxVpnService` умирает вместе с процессом без `stopForeground`: постоянное
уведомление id=1 «L×Box [final = …]» остаётся в шторке до следующего запуска
приложения (снимается только `ACTION_CLEAR_STALE_NOTIFICATION`, §430), хотя
`tun0` нет и в dumpsys у сервиса `app=null`. Пользователь видит «VPN
работает», когда он мёртв.

## Решение

В `quitApp` (после снятия признака и сторожа, как в §638) сервис
останавливается тем же путём, что обычный Stop из UI (`stopVPN`):
`BoxVpnService.stopAwait(context)` → `ACTION_STOP` → `BoxService.doStop`,
который сразу при переходе в Stopping делает `notification.stop()`
(`stopForeground(STOP_FOREGROUND_REMOVE)`). Ожидание `Stopped` ограничено
`QUIT_STOP_BUDGET_MS` = 3 с. Затем страховочно
`ServiceNotification.cancelServiceNotification()` (`cancel(1)`; после штатного
`stopForeground` это no-op) и убийство процесса — не раньше прежних 250 мс от
начала Quit. `finishAffinity` остаётся через 50 мс: окно закрывается сразу,
процесс доживает до остановки сервиса.

Ожидание идёт в собственном `CoroutineScope`, не в `pluginScope`:
`finishAffinity` может отсоединить engine, а `onDetachedFromEngine` отменяет
`pluginScope` — тогда процесс не был бы убит.

Не затронуто: §182 (`addAction` не идемпотентен) — только `cancel`; bounce
§428/§430 не срабатывает — признак «желателен» снят до остановки (§638).

## Проверка

CI (сборка Kotlin). На эмуляторе: VPN запущен → Diagnostics → «Quit & reopen
app» → в шторке нет уведомления id=1 (`dumpsys notification | grep lxbox`).
