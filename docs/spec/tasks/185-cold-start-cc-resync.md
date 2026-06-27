# §185 — Cold-start не пересинхронизирует CommandClient (swipe-reopen → пустой UI)

**Тип:** bug-fix (lifecycle / regression в v2.5.0)
**Статус:** 🔬 Диагноз подтверждён (device-logs + код-инспекция), фикс не написан
**Приоритет:** High (продакшен-баг в свежем релизе v2.5.0; хотфикс → v2.5.1)
**Связано:** §122 (CommandClient-миграция), §164 (энергомодель pause/resume),
§168 (profilerClient), [ARCHITECTURE.md → «Lifecycle CommandClient — ТРИ точки»](../../ARCHITECTURE.md)

## Симптом (юзер, v2.5.0 на устройстве)

«Смахиваю приложение из недавних → открываю иконкой → статус **Connected**, но
`Channel: Select channel` пустой + **No nodes in this channel** + `↑0B ↓0B 0s`;
Stats — вечный спиннер. Через время появляется (особенно если уйти-вернуться).
Рестарт VPN лечит. **Все подписчики кроме VpnService broadcast слетают.**»

## Корень (подтверждён — device-logs + 5-агентная код-инспекция)

**Ключевой факт из логов:** PID процесса **не меняется** при swipe (Android держит
из-за foreground VPN-сервиса). Умирает **только Flutter-движок** внутри процесса.
`ccGetGroups` от нового движка **ретраит каждые ~400мс бесконечно** — данные не
приходят.

**ДВА замка** (оба надо снять):

### Замок A — Dart-триггер resubscribe завязан на фронт `connected`
`_startCcStreams()` зовётся только из `_handleStatusEvent` на переходе
`disconnected→connected` (`home_controller.dart:199,206`). При swipe-keep туннель
**всё время `connected`** — фронта не было. На cold-start вопрос: проходит ли
reopen-pull `connected` как **переход** (тогда resubscribe срабатывает) или
инициализируется в `connected` без прохода через стартовую ветку.

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

### Запасной канал тоже не спасает
`getGroups()` unary-pull (`BoxCommandClient.kt:355`) не зависит от подписки и
**должен** наполнять группы. Но в логах он ретраит вечно: `ccGetGroups` →
`cc?.getGroups()` (`VpnPlugin.kt:606`) тихо возвращает `null` (либо
`commandClient` null, либо pull пуст в момент reopen — `cc?.` глотает null без
лога). Если Замок A не дал стартовать pull — полный разрыв.

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

## План фикса (комбинация, низкий риск — НЕ финализирован)

Рекомендация из инспекции — **(а)+(б)**, оба нужны (закрывают оба замка):

**(а) Reset на `onAttachedToEngine`** — надёжная точка (всегда при reopen, в
отличие от `onAppPaused` при swipe). Сбросить `screenRefs`=0 + снять висячие
подписки/sink'и + **чистая остановка осиротевшего profilerClient**. Тогда новый
`connectScreen()` увидит `refs=0` → `wasZero=true` → переподнимет screenClient →
ядро даст стартовый push (закрывает Замок B + connections для Live/Stats).

**(б) Форс `getGroups`-pull на cold-start** независимо от refcount/фронта —
мгновенное наполнение групп, не дожидаясь push (страховка от Замка A).

**Риски, которые проверить:** двойной `connectScreenClient()` без декремента
старого = утечка/двойная подписка в ядре (reset до connect → `wasZero=true`
штатно, риск снят); `onAttachedToEngine` vs первый-легитимный-старт (reset должен
быть идемпотентен и безопасен при первом запуске, не только reopen).

## Device-проверка ПЕРЕД фиксом (диагностические логи)

Добавить временные логи и подтвердить на устройстве (CPH2411, wifi-adb
`192.168.10.181`):
1. `screenRefs` до/после `connectScreen()` на reopen → подтвердить `1→2,
   wasZero=false, connectScreenClient НЕ вызван`.
2. Что возвращает `getGroups()` на reopen (null? пусто? бросает?) + жив ли
   `BoxService.commandClient`.
3. Вызывается ли `_startCcStreams()` / проходит ли `connected` как фронт на
   cold-start (Замок A — реальный или нет).
4. Был ли `onDetachedFromEngine`/`onCancel` при swipe (обнулились sink'и или
   висели) — определяет, нужен ли reset на detach или только на attach.

## Точки правки (по инспекции — якоря)

- `BoxCommandClient.kt:156-168` — `screenRefs`, `connectScreen`/`connectScreenClient`
  (refcount-блок), `:205` `shutdownAll`, `:355` `getGroups`.
- `VpnPlugin.kt:144` `onAttachedToEngine` (точка reset), `:225-241`
  `onDetachedFromEngine`, `:547` `ccConnectScreen`, `:606` `ccGetGroups`.
- `BoxVpnService.kt:82-92` companion sink'и; `BoxService.kt:61` `commandClient`
  companion, `:254` close.
- `home_controller.dart` — resubscribe-триггер (`:199,206`), `_startGroupsPull`
  (`:593,603`), resume (`:1009`), cold-start init (`:137-148`).

## Границы

- НЕ трогать рабочий путь pause/resume (§164) — фон↔возврат работает.
- НЕ трогать keep-VPN / `onTaskRemoved` — верное поведение.
- НЕ восстанавливать буфер профайлера (потерян by design) — только чистая остановка
  осиротевшего native-клиента.
- Хотфикс → **v2.5.1**.
