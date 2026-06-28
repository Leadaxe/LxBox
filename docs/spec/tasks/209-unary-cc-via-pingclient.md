# §209 — unary CC-методы через незасыпающий pingClient

> **СТАТУС: РЕАЛИЗОВАНО (28.06.2026).** Ветка `feat/urltest-balancer-208`
> (продолжение §208). Native (Kotlin) + Dart + Debug API + docs. 1402 теста
> (+5), Dart analyze чист, Kotlin compile OK. НЕ device-verified (нужен прогон
> `/pool` в фоне → 409 вместо пустого 200).

## Корень (обнаружен при device-отладке §208)

`BoxCommandClient.anyClient()` = `statusClient ?: screenClient ?: profilerClient`.
В фоне `ccPauseClients` (§164 энергомодель, `onAppPaused`) гасит `statusClient` +
`screenClient`; `profilerClient` жив только под recording. Значит когда
приложение НЕ на переднем плане и recording off → **`anyClient()` == null** →
все unary-методы молча возвращают пусто (`emptyList`/`false`/`null`).

**Симптом:** `GET /pool` (Debug API) и UI-попап «View pool» при приложении в
фоне отдают `count:0, slots:[]` — неотличимо от «пул реально пуст». Полчаса
ушло на ложную диагностику «бага ядра», который оказался парковкой CC-клиента.
То же касается `getGroups`/`getRules`/`select`/`close*`.

## Решение

`pingClient` (§175) — голый `CommandClient(PingHandler())` без подписок,
поднимается лениво под unary-вызов. **lifecycle-независим:** `pauseStatus`/
`pauseScreen` его НЕ трогают (проверено — дисконнект только в `cancelPing` /
`resyncForReopen` / `shutdownAll`, ни одно не lifecycle-парковка). Без подписок
= 0 нагрузки в покое. → идеальный носитель для **всех unary RPC**.

### 1. Все unary-методы CC → `ensurePingClient()` вместо `anyClient()`

| метод | тип | было при null | станет |
|---|---|---|---|
| `getPool(tag)` | снапшот | `emptyList()` (тихо) | `null` (недоступно) / `[]` (пусто) |
| `getGroups()` | снапшот | `null` (уже различал) | `null` (через ping) |
| `getRules()` | снапшот | `emptyList()` (тихо) | `null` (недоступно) / `[]` (пусто) |
| `selectOutbound` | действие | `false` | `false` + лог |
| `closeConnection` | действие | `false` | `false` + лог |
| `closeConnections` | действие | `false` | `false` + лог |

`urlTestOutbound` уже на `pingClient` — не трогаем (эталон).

### 2. paused / нет-клиента → ОШИБКА, не пустота (Решение A: null-путь)

При `ensurePingClient() == null`:
- **лог** `Log.w(TAG, "<method>: no command client (paused/down)")`;
- **в ответном канале** маркер недоступности — для List-методов это **`null`**
  (как уже делает `getGroups`), НЕ `emptyList`. Контракт: `null` = «клиент
  недоступен», `[]` = «данных нет (пул пуст / групп нет)». Минимальное
  изменение — getGroups уже так, распространяем на getPool/getRules.
- действия (`select`/`close*`) — `false` уже значит «не сработало», добавляем
  только лог.

**Dart-сторона:**
- `CcChannel.getPool` сейчас `Future<List<CcPoolSlot>>` (r ?? const []). Меняем
  на `Future<List<CcPoolSlot>?>` — `null` пробрасывается как «недоступно».
- `HomeController.getPool` → `Future<List<CcPoolSlot>?>`.
- **Debug `/pool`**: `null` → HTTP **409 Conflict** «cc clients unavailable
  (app backgrounded?)»; непустой/пустой список → 200 как сейчас.
- **UI-попап** `pool_view_dialog`: `null` → «Pool unavailable (open the app)»;
  `[]` → «Pool not available» (как сейчас, пул пуст); список → слоты.

### 3. pingClient остаётся жив после unary-get (Решение B)

`ensurePingClient` идемпотентен: первый unary-вызов в фоне ПОДНИМЕТ pingClient
(откроет сокет к ядру) и оставит жить до `cancelPing`/`shutdownAll`. Это
осознанное изменение энергомодели: в фоне может появиться ОДИН резидентный
сокет (если кто-то дёрнул unary RPC). Нагрузка ≈0 (без подписок, без тиков).
НЕ делаем ping-and-drop — проще, меньше гонок. Документировать в §164-контексте.

### 4. Документация — pingClient повышается в статусе

`pingClient` из «ping-only» (§175) → **«unary CC-резидент»**: единственный
незасыпающий клиент для ВСЕХ one-shot RPC (ping + снапшоты + действия).
Отразить:
- docstring класса `BoxCommandClient` (список клиентов, роль pingClient);
- `docs/ARCHITECTURE.md` (раздел CC-клиентов / энергомодель §164);
- комментарий у `ensurePingClient` (теперь не только ping).

## Файлы

| Слой | Файл | Изменение |
|---|---|---|
| native | `BoxCommandClient.kt` | 6 методов: `anyClient()` → `ensurePingClient()`; null → лог + (List)`null`/(bool)`false`; docstring класса + ensurePingClient |
| Dart | `vpn/cc_channel.dart` | `getPool` → `Future<List<CcPoolSlot>?>` (null при недоступности); getRules аналогично если нужно |
| Dart | `controllers/home_controller.dart` | `getPool` → `Future<List<CcPoolSlot>?>` |
| Dart | `widgets/pool_view_dialog.dart` | null → «Pool unavailable (open the app)» |
| Dart | `services/debug/handlers/pool.dart` | null → 409 Conflict |
| docs | `docs/ARCHITECTURE.md` | pingClient = unary CC-резидент |

## НЕ трогаем

- Стрим-клиенты (`statusClient`/`screenClient`/`profilerClient`) и их парковку —
  энергомодель §164 для подписок остаётся (они дренят в фоне, гасить правильно).
- Ядро / балансировщик — это чисто обвязка LxBox.

## Тесты

- `CcPoolSlot.fromMap` уже есть. Добавить: `getPool` возвращает `null` при
  native null-ответе vs `[]` при пустом списке (мок MethodChannel).
- Debug `/pool`: null → 409, [] → 200 count:0, список → 200 (handler-тест если
  есть инфраструктура; иначе ручная device-проверка).
- Device: в фоне `GET /pool` → 409 (не пустой 200); на переднем плане → слоты.

## Связанные

- [§208 round-robin balancer](208-urltest-balancer-round-robin.md) — здесь
  обнаружен корень (getPool через anyClient гас в фоне).
- §175 — pingClient (отдельный ping-клиент); §164 — энергомодель парковки.
- §185 — resyncForReopen (тоже дисконнектит pingClient — учесть в логе).
