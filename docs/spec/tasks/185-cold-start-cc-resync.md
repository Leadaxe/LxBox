# §185 — Cold-start не пересинхронизирует CommandClient (swipe-reopen → пустой UI)

**Тип:** bug-fix (lifecycle / regression в v2.5.0)
**Статус:** ✅ DEVICE-VERIFIED (dev, vc=2876). После фикса swipe-reopen не
воспроизводит ни пустой UI, ни подвисание Stats. Релиз v2.5.1.
**Приоритет:** High (продакшен-баг в свежем релизе v2.5.0; хотфикс → v2.5.1)
**Связано:** §122 (CommandClient-миграция), §164 (энергомодель pause/resume),
§168 (profilerClient), [ARCHITECTURE.md → «Lifecycle CommandClient — ТРИ точки»](../../ARCHITECTURE.md)

## Симптом (юзер, v2.5.0 на устройстве)

«Смахиваю приложение из недавних → открываю иконкой → статус **Connected**, но
`Channel: Select channel` пустой + **No nodes in this channel** + `↑0B ↓0B 0s`;
Stats — вечный спиннер. Через время появляется (особенно если уйти-вернуться).
Рестарт VPN лечит. **Все подписчики кроме VpnService broadcast слетают.**»

## Корень (подтверждён — device + код-инспекция)

**Ключевой факт:** PID процесса **не меняется** при swipe (Android держит из-за
foreground VPN-сервиса). Умирает **только Flutter-движок** внутри процесса. Все
CC-клиенты (поля на companion `BoxService`) переживают swipe, но остаются
привязаны к sink'ам **мёртвого** движка → новый движок не получает данные, хотя
статус-broadcast горит `Connected`.

**Замки** (все надо снять):

### Замок A — Dart-триггер resubscribe завязан на фронт `connected`
`_startCcStreams()` зовётся только из `_handleStatusEvent` на переходе
`disconnected→connected` (`home_controller.dart:199,206`). При swipe-keep туннель
**всё время `connected`** — фронта не было.

**РАЗРЕШЕНО код-инспекцией (не-блокер):** на cold-start новый движок стартует в
`_state.tunnel = disconnected` (дефолт), `init()` пуллит native-статус
(`getVpnStatus`, `:146`) и прогоняет через `_handleStatusEvent` (`:147`). Поскольку
`prevTunnel=disconnected`, а pulled=`connected` — это проходит как **переход** →
connected-ветка → `_startCcStreams()` срабатывает. Значит Dart-сторона на reopen
**уже** делает resubscribe + `getGroups`-pull. Замок A в текущем коде **закрыт**.
Реальный единственный корень — Замок B (native refcount протух глубже Dart).

### Замок B — native refcount протух (главный, ПОДТВЕРЖДЁН)
`screenRefs: AtomicInteger` (`BoxCommandClient.kt:156`) — поле объекта CC, живущего
в companion `BoxService` (переживает swipe) → **persistent**.
- При swipe `disconnectScreen()` НЕ вызывается (Dart мёртв) → `screenRefs` остаётся 1.
- Reopen → новый `connectScreen()` → `screenRefs.getAndIncrement()` 1→2 →
  `wasZero=false` → `connectScreenClient()` **НЕ вызывается**
  (`BoxCommandClient.kt:161-162`).
- Старый `screenClient` физически жив, но ядро шлёт `writeGroups`/`writeOutbounds`
  **только по изменению** (push по подписке) — спонтанного re-push на новый sink
  нет → экран пуст **до первого изменения групп** (= «через время появляется»).
- Сброс `screenRefs`=0 только в `shutdownAll()` (полный stop туннеля) → «рестарт
  VPN лечит». **Каждый swipe→reopen смещает refs на +1 безвозвратно.**

### Висячие sink'и — связанный, но НЕ корневой
companion-sink'и (`BoxVpnService.cc*Sink`) переживают движок; при swipe `onCancel`
не гарантирован. Но эмиттеры читают sink **лениво** (`sinkProvider()` per drain) +
`runCatching` глотает DeadObject (§155) → краша нет, и новый `onListen` на reopen
перезаписывает sink. Самовосстанавливается ПРИ УСЛОВИИ что приходит новый push —
а он не приходит из-за Замка B. Sink готов, данных нет.

## Профайлер — отдельная семантика (НЕ восстанавливать)

Буфер профайлера — **в Dart** → при swipe потерян безвозвратно. НО native
`profilerClient` (§164 не паузит — пишет в фоне) остаётся **осиротевшим**: пишет в
мёртвый sink, держит connections/DNS-подписку. Cold-start профайлера = **сначала
ПРИНУДИТЕЛЬНАЯ чистая остановка** осиротевшего native-клиента + подписок + sink'ов
(мог быть некорректно остановлен), **потом** чистый старт (буфер пуст, off).
Ограничение by design: профайлер пишет только пока приложение открыто.

## Замок B2 — statusClient осиротел на cold-start (память/трафик мертвы) [device-confirmed]

Device-факты (dev, §186-сборка, первая итерация resync — только screenClient):
1. **Connections грузится верно** → screenClient переподнят (Замок B закрыт). ✓
2. **Память на Stats — нет** (грузится только после сворачивания/разворачивания).
3. **Скорость ↑↓ в ШАПКЕ главного — тоже висит** на cold-start.

Факт №3 — решающий: и шапка, и Stats питаются `CcStatus` из **statusClient**
(отдельный CC-клиент: `CommandStatus`, НЕ refcounted, НЕ screenClient). Раз ОБА
мертвы сразу на cold-start (ещё до захода на Stats) — корень не в Stats и не в
интервале, а в том что **statusClient остался привязан к МЁРТВОМУ движку прошлой
сессии**. Первая итерация resync переподнимала только screenClient → statusClient
осиротел → ни шапка, ни Stats не получают тики. Сворачивание→разворачивание зовёт
`resumeStatus()` → `connectStatus()` → воскрешает на свежий движок → пошло.

Это тот же класс что Замок B (клиент пережил swipe, привязан к мёртвым sink'ам),
но statusClient НЕ refcounted — лечится не сбросом refs, а форс-`connectStatus()`.

Фикс: `resyncForReopen()` дополнительно форсит `connectStatus()` (сняв
`statusPaused`), сбросив интервал на NORMAL (дефолт главного — cold-start ВСЕГДА
на HomeScreen, навигация не восстанавливается). connectStatus сам закроет старый
осиротевший + поднимет новый. Заход на Stats ПОЗЖЕ штатно переключит на FAST
(`setStatusFast` видит NORMAL≠FAST → переподнимет; resync давно отработал, гонки
нет — cold-start и навигация-на-Stats разнесены во времени).

## ✅ Реализованный фикс

Замок A оказался уже закрыт (см. выше). Фиксим **Замок B (screenClient)** +
**Замок B2 (statusClient)** — оба осиротели на cold-start. `getGroups`-pull (б)
не понадобился (есть и теперь работает, т.к. screenClient переподнимается).

Cold-start обрабатывает ВСЕ 4 CC-клиента:

| Клиент | Действие | Где |
|---|---|---|
| statusClient | пере-поднят в NORMAL | `connectStatus()` в resync |
| screenClient | почищен + пере-поднимется | `refs=0`+close в resync → `connectScreen` |
| profilerClient | остановлен + почищен (+DNS-подписка) | `disconnectProfiler()` (handler) |
| pingClient | остановлен + почищен | `disconnectClient(pingClient)` в resync |

**1. `BoxCommandClient.resyncForReopen()`** (новый, рядом с refcount-блоком):
```kotlin
fun resyncForReopen() {
    // screenClient (groups/connections) — сброс протухшего refcount + close осиротевшего.
    screenRefs.set(0)        // застрял на 1 при swipe (disconnectScreen не вызвался)
    screenPaused = false     // снять зависшую паузу (onAppPaused без onAppResumed)
    disconnectClient(screenClient, "resyncForReopen")
    // pingClient — мог остаться живым (масс-пинг шёл в момент swipe). Unary, без
    // sink → UI не ломает, но висящий gRPC держит ресурс ядра. Чистим.
    disconnectClient(pingClient, "resyncForReopen")
    // statusClient (скорость+память шапки И Stats) — форс-переподнятие. Сброс
    // интервала на NORMAL (дефолт HomeScreen; cold-start всегда на нём).
    statusPaused = false
    statusIntervalNs = STATUS_INTERVAL_NORMAL
    if (tunnelAlive) connectStatus()   // сам close старый осиротевший + connect новый
}
```
- screenClient: НЕ инкрементит — следующий `connectScreen()` увидит `refs=0` →
  `wasZero=true` → переподнимет на свежие sink'и → ядро даст стартовый push.
- statusClient: НЕ refcounted → форс `connectStatus()` (минуя ранний return
  `setStatusFast`). NORMAL корректен (HomeScreen); заход на Stats позже → FAST.
- pingClient: НЕ refcounted, без sink → просто disconnect осиротевшего.
- Идемпотентно при первом старте: refs=0/клиенты=null (no-op), connectStatus
  поднимет statusClient штатно (как `startStatus`).

**2. `VpnPlugin` handler `ccResyncForReopen`** → `commandClient?.apply {
resyncForReopen(); disconnectProfiler() }`. Профайлер: чистая остановка
осиротевшего native-клиента + DNS-подписки (буфер в Dart потерян by design).

**3. `CcChannel.resyncForReopen()`** → `_invoke('ccResyncForReopen')`.

**4. `HomeController._startCcStreams()`** стал `async`: после установки Dart-
подписок (sink'и) и ПЕРЕД `connectScreen()` — `await _cc.resyncForReopen()`.
Порядок критичен: подписки (ставят sink'и) → resync (чистит refcount+старый
клиент) → connectScreen (переподнимает на свежие sink'и). На штатном переходе
`disconnected→connected` resync = no-op (refs уже 0). Call-site обёрнут в
`unawaited(_startCcStreams())`.

**Почему resume из фона не задет:** `_resyncOnResume` зовёт `_handleStatusEvent`
ТОЛЬКО при расхождении native↔state. При swipe-keep+возврат-из-фона (движок жив)
статус совпадает (`connected`) → `_startCcStreams`/resync НЕ зовутся; вместо них
`resumeClients()` (resumeScreen с валидным refs). resync строго на новый движок.

**Файлы:** `BoxCommandClient.kt` (+метод), `VpnPlugin.kt` (+handler),
`cc_channel.dart` (+обёртка), `home_controller.dart` (`_startCcStreams` async +
call-site). Ядро (libbox rc.10) НЕ трогается.

## Долг ядра — connections-pull (прелоадер Stats на cold-start)

Device (dev): после фикса Stats на cold-start не пустой, но **прелоадер крутится
долго** — потом прогружается. Корень: connections (`CommandConnections`) — **чисто
push**, ядро шлёт первый снапшот по своему тику/изменению, не мгновенно при
подписке. Главный экран спасает unary `getGroups()`-pull; у connections аналога
НЕТ (`javap io.nekohasekai.libbox.CommandClient` rc.10: только `closeConnection`/
`closeConnections`, нет `getConnections`).

**На нашей стороне не чинится** (частоту/стартовый re-push задаёт ядро). Обход
(synthetic poll) — хрупкий, не делаем. **Долг ядра sing-box-lx:** добавить
unary `getConnections()` (как `getGroups()`), тогда Dart дёрнет pull-снапшот
connections на cold-start → Stats мгновенно.

**Device-итог (vc=2876):** после resync всех 4 клиентов подвисание Stats
**больше не воспроизводится** — гонка `Stats.connectScreen ↔ resync` снята тем,
что resync чисто переподнимает screenClient до того как Stats успевает
смонтироваться. connections-pull остаётся долгом ядра как страховка, но на
практике не требуется.

## Device-проверка фикса (на устройстве, перед коммитом релиза)

Сценарий: connected → swipe из недавних → открыть иконкой → **сразу** видны
Channel/Nodes + трафик тикает + Stats не вечный спиннер. Повторить 3-4 раза
(каждый swipe раньше смещал refs на +1 — теперь reset на каждый reopen).
Дополнительно: уйти в фон не закрывая → вернуться (resume-путь, refs валиден) —
не должно сломаться. Recording: включить → swipe → reopen → recording off, буфер
пуст (by design), повторный START пишет чисто.

## Точки правки (реализовано)

- `BoxCommandClient.kt` — `resyncForReopen()` (рядом с refcount-блоком,
  `screenRefs`/`connectScreen`); зовёт `connectStatus()` для statusClient.
- `VpnPlugin.kt` — handler `ccResyncForReopen` (рядом с `ccConnectScreen`).
- `cc_channel.dart` — `resyncForReopen()` обёртка.
- `home_controller.dart` — `_startCcStreams` стал async, `await resyncForReopen()`
  ПЕРЕД `connectScreen()`; call-site `unawaited(_startCcStreams())`.

## Границы

- НЕ трогать рабочий путь pause/resume (§164) — фон↔возврат работает.
- НЕ трогать keep-VPN / `onTaskRemoved` — верное поведение.
- НЕ восстанавливать буфер профайлера (потерян by design) — только чистая остановка
  осиротевшего native-клиента.
- Хотфикс → **v2.5.1**.
