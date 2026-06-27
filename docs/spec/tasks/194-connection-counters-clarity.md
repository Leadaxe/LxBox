# §194 — Ясность счётчиков соединений (главный / Stats / Conns)

**Тип:** UX-fix (косметика, рассогласование чисел)
**Статус:** ✅ Реализовано (analyze чист), device-verify pending
**Связано:** §122 (CC-каналы), §176 (FilterState), §193 (re-emit)

## Боль (юзер 4PDA, скриншоты)

Три экрана показывают РАЗНЫЕ числа соединений, юзер не понимает кому верить:
- Главный «🔗13»; Stats «6»; Conns — своё число.

## Что значит каждое (по коду ядра sing-box-lx)

- **`connectionsIn`** = `trafficManager.ConnectionsLen()` (`started_service.go:418`)
  — трафик-трекер ядра, ТЕ ЖЕ соединения, что в списке `CommandConnections` →
  **= то, что видно на Stats** (соединения приложений).
- **`connectionsOut`** = `connectionManager.Count()` (`started_service.go:413`,
  `route/conn.go:49`) — route-менеджер, **физические соединения наружу к
  серверам** (через outbound).
- Главный «🔗13» был **суммой** In+Out — ни с чем не бьётся, путал.
- Stats «6» = активные из списка (`closedAt==0`) ≈ connectionsIn.
- Conns = живые + closed-история (своё число).

## Решение

**(1) Главный шапка — РАЗДЕЛЬНО** (`traffic_bar.dart`):
- `🔗 connectionsIn` (соединения приложений = Stats) + `🗄 connectionsOut`
  (`Icons.dns`, серверы наружу). Вместо суммы «13».
- Модель `TrafficSnapshot` +поля `connectionsIn`/`connectionsOut`
  (`traffic_snapshot.dart`); контроллер заполняет из `CcStatus`
  (`home_controller.dart`). `activeConnections` (сумма) оставлена для диалога
  «N connections will be closed».

**(2) Conns заголовок — «N active / M total»** (`connections_screen.dart`):
- active = живые (`closedAt==0`, не в `_closedIds`); total = весь набор (живые +
  closed-история). Связывает Stats-число (active) и общее.

## Итог по числам (после фикса)

- Главный: `🔗 6` (приложений) `🗄 7` (серверов) — честно, видно из чего.
- Stats: `6` (активные) — совпадает с `🔗` главного.
- Conns: `6 active / 13 total` — явно показывает обе грани.

## Границы
- НЕ подписывать главный на connections-стрим (энергомодель §164) — числа из
  status (`connectionsIn/Out`), дёшево.
- НЕ трогать Stats-логику (она верна — активные из списка).
