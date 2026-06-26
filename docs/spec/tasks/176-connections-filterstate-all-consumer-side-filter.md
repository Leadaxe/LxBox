# §176 — Connections-канал как честный источник: FilterState(All), фильтрация в потребителях

**Тип:** bug-fix + архитектура
**Статус:** Реализовано (device-verify впереди)
**Связано:** §168 (профайлер на CC), §170 (per-client accumulator), §166
(троттл ребилда), §122 (sink-война), §174 (chains)

## Симптом

Профайлер (Live) НЕ видит коротко-живущие TCP-соединения — видит только DNS.
`curl --interface tun0 2ip.io`: DNS-резолв в Live есть, TCP — нет.

## Корень

`acc.filterState(ConnectionStateActive)` в native (`BoxCommandClient.kt`) —
**одна политика на всех потребителей**, зашитая ДО Dart. Коротко-живущий conn
приходит в ОДИН `applyEvents`-батч как created + closed; к `filterState(Active)`
он уже `ClosedAt!=0` → выкидывается → `iterator()` его не отдаёт → Dart не видит
ни open, ни close. Оптимизация под Stats («только живые») протекла в канал
профайлера, которому нужны ОБЕ фазы.

DNS виден, потому что профайлер тянет DNS из core-логов (§171), а TCP — из этого
аккумулятора (теряется).

## Архитектурный принцип (решение)

Канал говорит «вот всё, что знает ядро» — **политику показа владеет каждый
потребитель**. Ядро (sing-box-lx) НЕ трогаем: `FilterState(All)`, TTL,
`evictClosedConnections` уже есть.

```
ядро (read-only)            native (BoxCommandClient)      Dart-потребители
ConnectionEvents ─дельты─►  applyEvents(events)            ┌ Profiler: всё, closed=tcpClose
(New/Update/Closed)         filterState(ALL) ◄─ был Active ├ ConnsView: closedAt>0 напрямую
closedConnectionMaxAge=5м   iterator → снапшот {closedAt}  └ Stats: where closedAt==0
evictClosedConnections      → один ccConnectionsSink ──broadcast──►
```

Семантика по потребителю:

| Потребитель | Хочет | Фильтр у себя |
|---|---|---|
| Profiler | event-log, обе фазы | ничего не режет |
| ConnectionsView | живые + недавно закрытые | `closedAt>0` напрямую (было: seenIds-diff) |
| Stats | только активные | `closedAt==0` |

## Изменения

**1. native** ([BoxCommandClient.kt](app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxCommandClient.kt)):
`filterState(Active)` → `filterState(All)`. closedAt уже эмитится в map. Памяти
не растит — ядро эвиктит closed через `closedConnectionMaxAge`=5 мин внутри
`ApplyEvents`. §170-риск не растёт — TTL ограничивает map ЯДРА.

**2. Profiler** ([traffic_profiler.dart](app/lib/services/traffic_profiler.dart)):
снята глушилка `if (c.isClosed) continue`. closed-дельта: НЕ кладём в `seenIds`
(diff-блок эмитит tcpClose), но open-код НЕ пропускаем — короткий conn (snap
нет) пройдёт open-ветку (tcpOpen + snap), diff закроет → обе фазы.
**Guard `_closedHandled`** (id→ts): ядро держит closed 5 мин → приходит каждый
тик; обрабатываем РОВНО раз (иначе лавина дублей). TTL-чистка 5 мин в
`_gcStaleConnIds`; clear на stop/dispose.

**3. Stats** ([stats_screen.dart](app/lib/screens/stats_screen.dart)):
`conns.where(closedAt==0)` на входе — `_totalConns`/byRule/perRule только по
живым (иначе раздулись бы closed-строками).

**4. ConnectionsView** ([connections_screen.dart](app/lib/screens/connections_screen.dart)):
`liveIds` строим только из живых (`closedAt==0`) — иначе closed попал бы в
liveIds и «пропал-из-снапшота»-детект его не закрыл (завис как живой). +явная
пометка `closedAt>0 → _closedIds`. Окно показа closed (30с) и diff-подстраховка
остаются.

## Границы

- **Ядро НЕ трогаем** — FilterState(All)/TTL/эвикт уже есть.
- **Контракт канала** — список `CcConnection` как сейчас (НЕ чистые дельты-
  события). Снапшот-All проще: профайлер diff'ит сам, три потребителя не
  переписываются с нуля. Чистые дельты (порядок/seq) — отдельная бо́льшая работа,
  если понадобится.
- **§164 энергомодель** — без изменений: частота тиков та же, меняется только
  состав снапшота (+closed≤5мин).

## Тесты

`traffic_profiler_test`: короткий conn сразу `closedAt>0` → обе фазы (open+close);
тот же closed 2 тика → ОДИН close (guard анти-дубль). Профайлер-сьют 35 зелёных,
analyze чист.

## Проверка (device)

`curl --interface tun0`... нет (ownerless, режется block_unknown — другой слой,
[[project_tun0_bind_ownerless_invisible]]). Нужен ОБЫЧНЫЙ короткий conn (curl
без --interface): Live должен показать tcpOpen+tcpClose. Conns — closed-строки
30с. Stats — счётчик только живых.
