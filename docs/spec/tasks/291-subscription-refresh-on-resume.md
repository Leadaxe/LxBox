# §291 — Автообновление подписок при разворачивании приложения (resume-триггер)

**Тип:** bugfix (энергонейтральный) · **Статус:** ✅ реализовано · **Размер:** S · **Область:** `AutoUpdater` / lifecycle

Автообновление подписок (`AutoUpdater`, [`auto_updater.dart`](../../../app/lib/services/subscription/auto_updater.dart)) вызывает `maybeUpdateAll` по 5 триггерам: `appStart` / `vpnConnected` / `periodic` / `vpnStopped` / `manual`. Триггера на **возврат приложения из фона** (`AppLifecycleState.resumed`) нет.

`periodic` — это `Timer.periodic(1h)` **внутри процесса приложения**. Пока процесс жив, он тикает. Но когда VPN выключен и приложение просто свёрнуто, Android со временем замораживает/выгружает процесс — таймер засыпает вместе с ним. Нативного фонового механизма (WorkManager/JobScheduler) нет и он **сознательно вне скопа** ([§027 spec](../features/027%20subscription%20auto%20update/spec.md), строки 31 и 271) — постоянный резидентный процесс ради обновления подписок бьёт по батарее.

## Проблема

Юзер-репро (4PDA #1149): утром вручную обновил все подписки, весь день приложение висело свёрнутым (VPN выкл.), вечером развернул — «последнее обновление 14 часов назад». Процесс был заморожен → `periodic` не тикал. При разворачивании приложение пере-синхронизирует **только статус туннеля** — обновление подписок не досматривается.

Call-site resume:
[`home_screen.dart:451`](../../../app/lib/screens/home_screen.dart) `AppLifecycleState.resumed` → `_controller.onAppResumed()` → [`home_controller.dart:1150`](../../../app/lib/controllers/home_controller.dart) `_resyncOnResume()`. `_resyncOnResume` тянет `getVpnStatus`, поднимает CC-клиенты, рестартует heartbeat. `AutoUpdater` не трогается вообще.

Это дырка, а не «фон вне скопа»: когда пользователь **сам открыл приложение**, проверка «не пора ли обновить?» ничего не стоит по батарее (процесс уже на переднем плане, UI виден), а вся защита от спама провайдеру (`shouldUpdatePure`: `updateIntervalHours`, `minRetryInterval` 15 мин, fail-cap) уже встроена и отработает как обычно.

## Решение

Добавить шестой триггер `resumed` в `enum UpdateTrigger` и звать `maybeUpdateAll(UpdateTrigger.resumed)` из resume-пути.

- `UpdateTrigger.resumed` в [`auto_updater.dart:11`](../../../app/lib/services/subscription/auto_updater.dart).
- Вызов из `onAppResumed` (после `_resyncOnResume`, не блокируя его) — через уже связанный `AutoUpdater` (`SubscriptionController.bindAutoUpdater`). Либо из `home_screen`-ветки `resumed` после `_controller.onAppResumed()`, симметрично `_autoUpdater.start()`. Выбрать точку, где `AutoUpdater` в scope без циклической зависимости.
- `resumed` **не** force: проходит глобальный тумблер `auto_update_subs` и весь `shouldUpdatePure`-гейт — обновит ровно те подписки, которым реально пора. Ничего нового по нагрузке на провайдера: `minRetryInterval`/`_running`-guard/`_inFlight`-dedup уже защищают от частых разворачиваний.

Полноценный фоновый апдейт при **полностью выгруженном** приложении (WorkManager) остаётся вне скопа — это отдельная бОльшая задача (permissions, battery optimizations по прошивкам). Здесь только закрываем resume-случай.

## Файлы

- `lib/services/subscription/auto_updater.dart` — `UpdateTrigger.resumed` + doc.
- `lib/screens/home_screen.dart` — вызов `maybeUpdateAll(resumed)` в
  `didChangeAppLifecycleState` (ветка `resumed`), рядом с `_controller.onAppResumed()`.

**Реализация:** call-site выбран в `home_screen` (не в контроллере), симметрично
`_autoUpdater.start()` — единственному другому lifecycle-инициируемому вызову
`AutoUpdater` (оба живут в экране). Контроллер держит `_autoUpdater` для
VPN-**transition** callback'ов (connected/stopped приходят как события статуса в
контроллер), а resume — чистое lifecycle-событие виджета, которое `home_screen`
уже обрабатывает. `unawaited` — не блокирует `_resyncOnResume`; `_running`-guard
и min-retry защищают от частых сворачиваний.

## Приёмка

- Разворачивание приложения из фона (VPN выкл., процесс жив) → подписки, которым пора по `updateIntervalHours`, обновляются без ручного действия.
- Частые сворачивания/разворачивания за < 15 мин **не** порождают повторных fetch'ей (min-retry держит).
- Глобальный тумблер `auto_update_subs = off` → resume-триггер молчит, как и остальные не-manual.
- `updateIntervalHours == 0` (файловые подписки) → resume не обновляет.
- Существующие тесты `auto_updater` / `shouldUpdatePure` зелёные (логика решения не менялась, добавился лишь вход).

## Docs to update

- [`docs/spec/features/027 subscription auto update/spec.md`](../features/027%20subscription%20auto%20update/spec.md) — добавить `resumed` в список триггеров (5 → 6); уточнить, что resume-refresh ≠ background-fetch (последний остаётся вне скопа).
