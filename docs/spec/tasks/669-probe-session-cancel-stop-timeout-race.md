# 669 — Test servers при выключенном VPN: отмена начатых замеров, потолок времени остановки пробной сессии, гонка прогонов

| Поле | Значение |
|------|----------|
| Статус | In progress |
| Дата начала | 2026-10-23 |
| Дата конца | — |
| Коммиты | см. `git log --grep 669` |
| Связанные спеки | [features/009-NODE_HEALTH](../features/009-NODE_HEALTH/FEATURE.md); [175](175-ping-cancel-separate-client.md) — отмена массового пинга через отдельный pingClient; [287](287-stopping-timeout-mass-ping-wg.md) — потолок остановки VPN-службы; [523](523-probe-wg-batches.md) — пачки WG по 4 на сессию; [668](668-stop-teardown-trace-and-timeouts.md) — трасса teardown'а |

## Проблема

GitHub issue #171 п.17 (lolpoi, 20.10.2026): «ping tests freeze everything and
either the "stop" doesn't work, or takes a lot of time, or it does stop, but one
won't be able to start again — nothing happens. Got to force stop the whole app».

Разбор кода показал, что массовый пинг при поднятом туннеле после §175
отменяется чисто. Все три симптома даёт другой механизм — «Test servers» на
экране папки или подписки при **выключенном** VPN (`ProbeRunner` +
отдельная пробная сессия ядра `ProbeSession`).

## Диагностика

Факты по коду (без устройства):

1. **Stop не обрывает начатые замеры.** `ProbeRunner.cancel()`
   (`app/lib/services/probe/probe_runner.dart:66`) только ставит флаг
   `_cancelled`. До шести параллельных `probeUrlTest` (`:64`) дорабатывают до
   таймаута замера (`:175`). Аналога §175 (disconnect клиента → отмена
   контекста в ядре) у пробной сессии нет: `ProbeSession.urlTest`
   (`app/android/.../ProbeSession.kt:88-99`).
2. **Остановка сессии без потолка.** `ProbeSession.stop` помечен
   `@Synchronized` и вызывает `closeService()` без таймаута (`ProbeSession.kt:133-141`).
   Это механизм §287: `closeService` синхронно ждёт разбора всех WG-узлов,
   на устройстве 10–17 с. Фикс §287 (потолок 3 с + force) сделан только для
   VPN-службы, пробную сессию не покрыл. Итоговая задержка Stop = таймаут
   замера × до 6 параллельных + `closeService`.
3. **Гонка «старый прогон закрывает новую сессию».** В UI флаг `_testing=false`
   ставится сразу при Stop (`app/lib/screens/subscription_detail_screen.dart:271-277`,
   `app/lib/screens/folder_detail_screen.dart:274-277`), хотя старый
   `runner.run()` ещё не завершился. Повторный Start создаёт новый
   `ProbeRunner`; его `probeStart` закрывает старую сессию и ждёт `closeService`
   (`ProbeSession.kt:58-62`). Когда старый прогон доходит до `finally`, его
   `probeStop` (`probe_runner.dart:147-152`) **закрывает уже новую сессию**:
   новые замеры получают «probe session not running», а `setState(_testing=false)`
   из старого прогона (`subscription_detail_screen.dart:322`,
   `folder_detail_screen.dart:336`) гасит индикатор нового. У сессии нет
   отметки владельца прогона.
4. **Залипание под монитором.** Если `closeService` повис (та же неразобранная
   часть §668), `@Synchronized` на `ProbeSession` блокирует все `probeStart` /
   `probeStop`; `BoxService.startCommandServer` тоже зовёт `ProbeSession.stop()`
   (`BoxService.kt:733`), поэтому виснет и старт VPN. Выход только force stop
   приложения — ровно как в жалобе.

Отмена массового пинга при поднятом VPN (`cancelMassPing`,
`app/lib/controllers/home_controller/ping_orchestration.dart:451-466`) — не
трогать, там дефекта нет.

## Решение

Три правки, по образцу уже принятых решений §175 и §287.

### Р1. Владелец сессии (гонка)

- У пробной сессии появляется идентификатор прогона (`runId`/token):
  `probeStart` возвращает его, `probeUrlTest`/`probeStop` принимают его.
  Вызов с чужим или устаревшим идентификатором — no-op с кодом «stale run»
  (без исключения в UI).
- `ProbeRunner` помнит свой идентификатор; `finally` старого прогона не может
  закрыть сессию нового.
- Экраны папки/подписки: `_testing=false` и сброс индикаторов — только из
  того прогона, который сейчас активен (сравнение по экземпляру `ProbeRunner`
  или runId). Stop переводит UI в состояние «stopping» (кнопка неактивна,
  подпись «Stopping…») до фактического завершения старого прогона, затем
  Start снова доступен. Если это противоречит текущему UX в features/009 —
  согласовать: спеку править, UI не изобретать.

### Р2. Обрыв начатых замеров

- По образцу §175: отдельный клиент/контекст у пробной сессии, `cancel()`
  обрывает контекст в ядре → начатые dial'ы падают сразу, не дожидаясь
  таймаута. Если в `ProbeSession` замеры идут через `CommandClient` —
  `disconnect` его экземпляра; если напрямую — контекст с отменой на Kotlin
  стороне. Выбрать то, что уже есть в биндинге (`BoxCommandClient.kt:347-350`
  как образец).

### Р3. Потолок остановки

- `ProbeSession.stop`: `closeService` под `withTimeout` (ориентир — тот же
  потолок, что у §287 для VPN-службы, 3 с), по истечении — принудительное
  освобождение сессии (обнулить ссылку, залогировать «probe close timed out»),
  чтобы монитор не держал `probeStart` и `startCommandServer`.
- Snap-замер WG/AWG (пачки §523) не менять.

## Проверка

- Unit (Dart): `probe_runner` — `cancel()` во время прогона → `run()`
  завершается ≤ одного замера; `probeStop` старого прогона после `probeStart`
  нового не закрывает новую сессию (мок канала с runId).
- Unit (Dart, экран): Stop → состояние stopping → старый прогон завершён →
  Start доступен; индикатор нового прогона не гасится старым.
- Kotlin: таймаут `closeService` → `stop` возвращается, следующая `start`
  не блокируется.
- Устройство: папка с ≥ 8 WG + ≥ 8 vless, VPN выключен, Test servers → Stop
  через 2 с → Start сразу: второй прогон идёт, первый не вмешивается.

## Docs to update

- `docs/spec/features/009-NODE_HEALTH/FEATURE.md` / `FUNCTIONS/*` — отмена
  Test servers обрывает начатые замеры; состояние stopping.
- CHANGELOG `[Unreleased]`.
