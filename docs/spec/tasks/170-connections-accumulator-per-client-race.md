# §170 — Краш ядра при Live+Stats одновременно: разделить Connections-аккумулятор по клиентам

**Тип:** bug-fix (critical — SIGABRT, весь процесс)
**Статус:** Реализовано (device-verified)
**Связано:** [`168-profiler-on-commandclient-connections`] (спровоцировал), §122
(CC-аккумулятор), §048 (Live)

## Симптом (device-факт)

Открыть Statistics, зайти на Live, запустить recording → через ~20с
приложение **вылетает** (процесс умирает). Device CPH2411 / Android 15 /
Mali-G610 — мощное железо, НЕ OOM, НЕ Impeller.

## Корень (tombstone + Go-лог по USB)

```
F libc: Fatal signal 6 (SIGABRT) in tid (Thread-9), pid (m.leadaxe.lxbox)
#00 pc ... libbox.so
E Go: fatal error: concurrent map iteration and map write
E Go: libbox.(*Connections).ApplyEvents (command_types.go:170)
       → WriteConnectionEvents → handleConnectionsStream
```

Ядровая структура `Connections` держит `connectionMap` (Go map), и
`ApplyEvents`/`evictClosedConnections`/`FilterState` читают-пишут её **без
мьютекса**.

На НАШЕЙ стороне (`BoxCommandClient.kt`) был **ОДИН** общий
`connectionsAccumulator: Connections`, который использовали **ОБА** клиента:
- `screenClient` (Stats/главный, `CommandConnections`) — `ScreenHandler`;
- `profilerClient` (Live recording, `CommandConnections`) — `ProfilerHandler`.

Их `writeConnectionEvents` вызываются из **двух независимых gRPC-горутин ядра**
→ оба зовут `acc.applyEvents()`/`acc.filterState()`/`acc.iterator()` на одном
`Connections` → конкурентный доступ к `connectionMap` → `concurrent map
iteration and map write` → Go `fatal error` → `abort()` → SIGABRT.

**§168 спровоцировал:** до него connections-стрим слушал максимум один клиент
(profilerClient вообще не подключался), гонки не было. §168 поднял второго
подписчика на тот же общий аккумулятор.

Тайминг улики в логе: `ccConnectProfiler` → `BoxCommandClient connected gen=3`
(2-й клиент на connections) → через ~20с `fatal error`.

## Решение (клиент-сторона, «лечение причины» в нашем репо)

Отдельный `Connections` на КАЖДЫЙ клиент. Две горутины пишут в две независимые
map → пересечения по `connectionMap` нет → ядровая строка 170 не падает. Ядро
менять НЕ требуется (хотя мьютекс там — правильный долг ядра, отдельно).

**`BoxCommandClient.kt`:**
- `connectionsAccumulator` (один) → `screenAccumulator` + `profilerAccumulator`
  (оба `AtomicReference<Connections?>`).
- `ensureAccumulator()` → `ensureAccumulator(ref)`; зовётся с нужным ref в
  `connectScreenClient`/`connectProfilerClient`.
- `applyConnectionEvents(message, genRef, gen)` → `+ accRef` параметр;
  `ScreenHandler` передаёт `screenAccumulator`, `ProfilerHandler` —
  `profilerAccumulator`.
- `shutdownAll`: сбрасывает оба.
- Оба эмитят в один `ccConnectionsSink` (Dart broadcast). Когда Stats+Live
  открыты разом — двойной снапшот одного состояния; `SnapshotEmitter`
  coalesce'ит, Dart перерисовывает то же. Безвредно (решение пользователя:
  «оба эмитят, просто»).

## UI-троттл (отдельная польза, НЕ фикс краша)

`live_events_tab._onEvent` пересобирал список из global buffer (clear+addAll
≤3000 + `_trackApp` + setState) на КАЖДОЕ SSE-событие → на FAST-стриме
захлёбывание (перф-фриз, не краш). Добавлен троттл `_rebuildThrottle` 700мс,
окно от КОНЦА пересборки (`_rebuiltAt` ставится после setState, как в
`stats_screen` §170), + trailing-таймер чтобы последнее событие в окне дошло.
`stats_screen._connRecalcAt` тоже переведён на «от конца» (запрос
пользователя: считать от отработанного, не от старта). Это НЕ лечит SIGABRT —
краш в Go-ядре от двух подписчиков, не от частоты ребилдов Flutter.

## Проверка (device)

1. VPN up. Открыть Statistics.
2. Зайти на Live, START recording. **Подержать >60с под трафиком.**
3. Переключаться Stats↔Live, свернуть/развернуть. Процесс НЕ должен умирать.
4. USB logcat (`adb -s CE8XX48PCI79U4XG logcat`) — НЕТ `E Go: fatal error:
   concurrent map`, НЕТ SIGABRT/tombstone.
5. Live по-прежнему наполняется (buffer_count > 0), Stats считает.

## Результат (device CPH2411 wifi-adb, 2026-06-26, vc 2818)

✅ ПОДТВЕРЖДЁН. Воспроизведён точный краш-сценарий через Debug API:
- `ccConnectScreen` (screenClient, главный экран) + `ccConnectProfiler`
  (profilerClient, `/profiler/live/start`) — ОБА подписчика на connections живы
  разом (то самое условие, что на vc 2817 валило процесс за ~20с).
- Держали >70с под трафиком (active_connections 11-30): pid стабилен,
  `concurrent map`/`fatal error`/`SIGABRT` в логе = **0**.
- Стресс 4× stop/start recording (пересоздание profilerClient × gen-горутины
  при живом screenClient): pid стабилен, 0 краш-строк.
- buffer наполняется, connections считаются — функциональность цела.

## Долг ядра (отдельно)

sing-box-lx `experimental/libbox/command_types.go`: обернуть `connectionMap`
в `sync.Mutex` (ApplyEvents/evictClosedConnections/FilterState/iterator). Тогда
один `Connections` на N подписчиков стал бы безопасен. Наш per-client фикс
снимает проблему без ожидания релиза ядра.
