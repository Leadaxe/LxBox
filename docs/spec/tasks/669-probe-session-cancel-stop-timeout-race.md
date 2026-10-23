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

Три правки, по образцу уже принятых решений §175 и §287. Сделано так
(строки — на момент коммита `fix(669)`).

### Р1. Владелец сессии (гонка)

- Kotlin: живая сессия — один объект `Session(runId, server, client)` в
  `AtomicReference` (`ProbeSession.kt:48`); `start` выдаёт новый runId из
  монотонного счётчика и отдаёт `{error, runId}` (`ProbeSession.kt:89`).
  `urlTest`/`getUrl` (`:137`, `:167`) сверяют runId: чужой/устаревший →
  `{"error": "stale run"}` (`STALE_RUN`, `:68`), без исключения.
  `stop(runId)` (`:199`) с чужим id — no-op с записью в logcat; безымянный
  `stop()` (`:211`) остался принудительным для `BoxService.startCommandServer`
  и `serviceStop`. Канал: `probeStart` → Map, остальные вызовы несут `runId`
  (`VpnPlugin.kt:1045-1058`, разбор `probeRunId` — `:1317`, через `Number`).
- Dart: `CcProbeStart` и `kProbeStaleRun` (`cc_channel.dart:1560-1580`);
  `probeStart` возвращает `CcProbeStart`, `probeUrlTest`/`probeGetUrl`/
  `probeStop` требуют `runId` (`cc_channel.dart:462-517`).
- `ProbeRunner` помнит `_runId` текущего батча (`probe_runner.dart:65`),
  `finally` зовёт `probeStop(runId)` своей сессии (`:174`). Ответ «stale run»
  на замер = прогон вытеснен: раннер останавливается, вердикт узлу не пишет
  (`:202`). Диагностика узла (§392) тоже адресует свою сессию
  (`node_diagnostics_runner.dart:137-154`).
- Экраны: `_testing=false` и сброс таймера — только если завершился прогон,
  который сейчас активен (`identical(_runner, runner)`;
  `folder_detail_screen.dart:334,341`, `subscription_detail_screen.dart:320,326`).
  Stop ставит `_stopping` (`folder_detail_screen.dart:282`,
  `subscription_detail_screen.dart:281`): подпись `Stopping…` на месте
  `Testing… N done` (`:1390` / `:531`), кнопка неактивна и серая — так же,
  как она уже выглядит у пустой папки / подписки без узлов
  (`:1416` / `:577`). Строка `Stopping…` уже есть в переводах (статус
  туннеля), новых строк нет. Противоречия с features/009 нет; там дописано
  поведение отмены (`FUNCTIONS/server-list-test.md` / `.ru.md`, ревизия 13).
- Попутно: экран подписки при закрытии не отменял прогон (папка отменяла) —
  добавлена отмена в `dispose` (`subscription_detail_screen.dart:251`).

### Р2. Обрыв начатых замеров

- Замеры пробной сессии идут через её `CommandClient`, поэтому взят образец
  `BoxCommandClient.cancelPing` (§175): новый вызов `probeCancel(runId)` →
  `ProbeSession.cancel` (`ProbeSession.kt:153`) помечает сессию отменённой и
  делает `disconnect` клиента этой сессии — ядро отменяет per-call ctx уже
  ушедших dial'ов. Не synchronized: не ждёт монитора долгого `start`/`stop`.
  Последующие замеры этой сессии получают «probe run cancelled». Сервер
  закрывает `probeStop` владельца.
- `ProbeRunner.cancel()` остаётся синхронным (его зовёт
  `ProbeLifecycle.haltAll`), но кроме флага шлёт `probeCancel` текущего runId
  (`probe_runner.dart:75`). Stop во время `probeStart` — замеры не
  начинаются, сессия сразу закрывается.

### Р3. Потолок остановки

- `closeServerBounded` (`ProbeSession.kt:236`): `close()` → `closeService()` в
  потоке-демоне, ожидание `CountDownLatch` не дольше 3 с (`CLOSE_TIMEOUT_MS`,
  `:73`). По истечении — `Log.w("probe close timed out …, session released")`;
  ссылка на сессию снята до закрытия, так что монитор не держит `start`/`stop`
  и `BoxService.startCommandServer`. `withTimeout` не взят сознательно: вокруг
  блокирующего JNI-вызова он ничего не ограничивает (вывод §668, `StopTrace`).
- Порядок `close()` раньше `closeService()` — как §330 у VPN-службы:
  command.sock освобождается сразу, даже если разбор WG-узлов висит; иначе
  следующий старт (проба или VPN) не смог бы занять сокет.
- Snap-замер WG/AWG (пачки §523) не менялся.

## Проверка

- Unit (Dart), `test/probe/probe_runner_cancel_test.dart` на двойнике
  сессии `test/probe/probe_session_fake.dart` (семантика `ProbeSession.kt`:
  runId, «stale run», обрыв по `probeCancel`, рестарт по `probeStart`):
  `cancel()` при шести висящих dial'ах → `run()` завершается сразу,
  `probeCancel(1)` и `probeStop(1)`, вердиктов нет; `cancel()` до старта
  сессии; `probeStop` старого прогона после `probeStart` нового — no-op,
  новый домеряет все 8 узлов. All tests passed (3).
- Unit (Dart, экран), `test/screens/subscription_detail_probe_stop_test.dart`:
  Stop → `Stopping…` и неактивная кнопка (повторный тап не поднимает
  сессию), пока висит `probeStop` → после закрытия Start доступен → новый
  прогон в сессии 2 с индикатором `Testing…`, итог `8 ok`. All tests passed.
  Экран папки той же правки отдельным тестом не покрыт (код зеркальный).
- Обновлены моки под новый канал и прогнаны: `test/probe/probe_test.dart`
  (30), `test/services/node_diagnostics_runner_test.dart` (11, плюс проверка
  runId у GET/stop), `test/vpn/cc_get_url_test.dart` (9) — All tests passed.
- Kotlin: unit-теста нет (инфраструктуры JVM-тестов на libbox нет, APK не
  собирали); компиляцию проверит CI.
- Устройство — не проверено: папка с ≥ 8 WG + ≥ 8 vless, VPN выключен,
  Test servers → Stop через 2 с → Start сразу: второй прогон идёт, первый не
  вмешивается; `Stopping…` держится не дольше ~3 с; logcat `ProbeSession`
  без «probe close timed out» на обычных конфигах.

## Docs to update

- `docs/spec/features/009-NODE_HEALTH/FEATURE.md` / `FUNCTIONS/*` — отмена
  Test servers обрывает начатые замеры; состояние stopping.
- CHANGELOG `[Unreleased]`.
