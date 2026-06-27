# §193 — Stats теряет connections со временем (нет re-emit при подписке)

**Тип:** bug-fix (CommandClient connections-канал; усугублён §185)
**Статус:** ✅ Реализовано (re-emit + resync-гейт). analyze чист, device-verify pending.
**Приоритет:** Medium (косметика — VPN работает, но Stats показывает 0 conns)
**Связано:** §122 (CC-миграция), §170 (аккумулятор), §176 (FilterState), §185
(resyncForReopen — частичный регресс)

## Симптом (юзер 4PDA, скриншот)

Туннель жив (Connected, трафик ↑47KB↓499KB течёт), главный экран показывает
группы/ноды + счётчик «👁14» connections. НО вкладка Stats: Connections=0,
«No active connections», «No rule data». «Первое время работали, потом пропали.»

## Корень (подтверждён код-инспекцией LxBox + ядра sing-box-lx)

**Connections принципиально хрупче groups у ОДНОГО `screenClient`:**

| | Groups | Connections |
|---|---|---|
| Стартовый снапшот | при подписке + повторно на каждый urlTest-тик | **РОВНО ОДИН раз** (reset на момент подписки) |
| Pull-страховка | ✅ `getGroups()` unary (Dart `_startGroupsPull`) | ❌ **`getConnections()` в ядре НЕТ** (javap rc.10 подтвердил) |
| Дальше | eager push, дублируется pull | только дельты; трафик-тик молчит без дельты |

→ Groups **дважды самоисцеляются** (eager push + pull). Connections — **единственный
shot**; потерян → восстановить нечем до органической дельты (новое/закрытое
соединение).

**File:line (ядро `sing-box-lx`):**
- `daemon/started_service.go:696-700` — `SubscribeConnections` шлёт
  `buildInitialConnectionState` РОВНО ОДИН раз (reset=true) на подписке.
- `started_service.go:439-453` — `SubscribeGroups` шлёт снапшот при подписке И
  повторно на каждый urlTest-тик (асимметрия).
- `started_service.go:746-748` — трафик-тик connections молчит без дельты
  (`if len(protoEvents)==0 { continue }`).
- `experimental/libbox/command_types.go:143-145` — `ApplyEvents` reset → replace map.
- javap `libbox.aar` rc.10: `CommandClient` имеет `getGroups/getOutbounds/getRules`,
  **`getConnections` ОТСУТСТВУЕТ**.

**File:line (LxBox) — где single-shot теряется:**
- `BoxCommandClient.kt:703` — `applyConnectionEvents`: накопление в acc ВСЕГДА
  (687-700), но эмит в Dart `if (ccConnectionsSink == null) return` — только при
  живом sink. Если reset-снапшот лёг когда sink был null → в Dart ничего не ушло.
- `VpnPlugin.kt:202` — `onListen` connections ставит sink, но **НЕ пушит текущий
  аккумулятор** → новый подписчик не получает накопленное.

## Механизм «работало → пропало»

1. `ccConnectionsSink` ставится впервые только при ПЕРВОМ открытии Stats (главный
   на connections не подписан — `home_controller.dart:598-603` слушает status+groups).
2. Home держит ПОСТОЯННЫЙ screen-ref весь сеанс (`connectScreen()` на каждый
   `connected`). При ПОВТОРНОМ открытии Stats `connectScreen()` → refs 1→2 →
   `wasZero=false` (`BoxCommandClient.kt:161-162`) → **screenClient НЕ
   пересоздаётся → ядро НЕ шлёт новый reset** → Stats зависит от replay
   `_sharedStream`, а он пуст/протух.
3. **Усугубляет §185 `resyncForReopen()`**: зовётся БЕЗУСЛОВНО на каждый
   `connected` (`home_controller.dart:611`, не только cold-start) →
   `screenRefs.set(0)`+disconnect screenClient. На каждой реконнект-итерации рвёт
   connections-доставку; groups самоисцеляются pull'ом, connections — нет.

## Решение (чистое, 3 части)

**(1) Re-emit аккумулятора при подписке — главное.**
- Вынести сериализацию connections (`BoxCommandClient.kt:704-768`) в отдельный
  метод `serializeConnections(acc): List<Map>` (без дублирования).
- Новый `reEmitScreenConnections()`: сериализует `screenAccumulator` → offer в
  emitter. Идемпотентен (null/пустой acc → пустой list, безопасно).
- `VpnPlugin.kt:202` onListen connections: после установки sink дёрнуть
  `BoxService.commandClient?.reEmitScreenConnections()`. Свежий подписчик сразу
  получает текущий снапшот (из накопленного acc), не дожидаясь дельты. Закрывает
  И timing-гонку sink, И refs-piggyback (повторное открытие Stats).

**(2) Сузить `resyncForReopen` до реального cold-start.**
- Сейчас зовётся на каждый `connected`. Нужен только когда native-refcount реально
  протух (новый Dart-движок после swipe), НЕ на штатном реконнекте.
- Гейт: resync только на ПЕРВЫЙ `_startCcStreams` нового движка (флаг
  `_didColdStartResync`), дальше — обычный connectScreen без disconnect.
- Сохраняет §185-фикс (cold-start работает), убирает разрыв connections на
  обычных реконнектах.

**(3) Проверить `resetCaches()`** — не сбрасывает ли replay connections не вовремя
(на `_stopCcStreams`). Если да — re-emit (1) всё равно перекрывает, но свериться.

## ✅ Реализовано

**(1) Re-emit при подписке** (`BoxCommandClient.kt`, `VpnPlugin.kt`):
- Сериализация connections вынесена в `serializeConnections(acc): List<Map>`
  (единый код для applyConnectionEvents-дельт и re-emit, без дублирования).
- Новый `reEmitScreenConnections()` — сериализует `screenAccumulator` → offer в
  connectionsEmitter. Идемпотентен (null/пустой acc → пустой list).
- `VpnPlugin.onListen` connections-канала после установки sink →
  `commandClient?.reEmitScreenConnections()`. Свежий подписчик (открытие Stats)
  сразу получает накопленный снапшот.

**(2) Resync-гейт** (`home_controller.dart`):
- Флаг `_didColdStartResync` — `resyncForReopen()` зовётся ТОЛЬКО на ПЕРВЫЙ
  `_startCcStreams` нового движка (cold-start). На реконнектах — обычный
  `connectScreen` без disconnect. Убирает разрыв connections на каждый `connected`.

**(3) resetCaches** — проверено: зовётся только в `_stopCcStreams` (разрыв
туннеля), не при открытии Stats. Re-emit (1) перекрывает любой пустой replay.
Изменений не требует.

**Корректность по сценариям:**
- Первое открытие Stats: sink ставится → re-emit отдаёт текущий acc. ✅
- Повторное открытие Stats (screenClient жив, refs>0, нового reset нет): re-emit
  отдаёт накопленный acc — главный фикс. ✅
- Реконнект: resync не зовётся (гейт) → connectScreen не рвёт connections. ✅
- Stop→Start: native shutdownAll обнуляет acc; connectScreen (wasZero=true)
  переподнимает screenClient → ядро шлёт свежий reset. ✅
- Cold-start (swipe): resync (первый раз) переподнимает + re-emit. ✅

**Файлы:** `BoxCommandClient.kt` (serializeConnections + reEmitScreenConnections),
`VpnPlugin.kt` (onListen re-emit), `home_controller.dart` (_didColdStartResync).
Ядро НЕ трогается (pull в ядре нет — фикс целиком на нашей стороне).

## Границы

- НЕ ломать §185 cold-start (resync остаётся, но гейтнут).
- НЕ трогать groups-путь (он рабочий, самоисцеляется).
- Pull `getConnections` в ядре НЕТ — фикс целиком на нашей стороне (re-emit acc).
  Честный pull = долг ядра (unary `GetConnections`, симметрично `getGroups`) —
  записать как долг, но НЕ блокирует.
- Хотфикс → следующий релиз.
