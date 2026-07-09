# §260 — реконнект profilerClient: восстановление §180 DNS-подписки после обрыва gRPC

> **СТАТУС: ОТМЕНЕНО (08.07.2026) — заменено [§261](261-dns-stream-to-command-multiplex.md).**
> Этот Kotlin-фикс (`profilerWanted` + reconnect-хук в `ProfilerHandler.disconnected`) был
> симптоматической заплаткой. Более глубокий разбор показал: корень — АРХИТЕКТУРНЫЙ и в ЯДРЕ
> (не «ядро невиновно»): §180 DNS-стрим был единственной streaming-подпиской, ошибочно
> оформленной как отдельный метод в классе unary Get-методов, вне command-мультиплекса —
> поэтому `Connect()` не переподнимал его при реконнекте (в отличие от `CommandConnections`).
> Правильный фикс — перенести DNS в мультиплекс (ядро SPEC 018 v2), тогда клиентский
> reconnect-код НЕ нужен вовсе. §261 удаляет этот патч. Файл оставлен как летопись
> диагностики (device-факты ниже верны и ценны).
>
> _Прежний статус: РЕАЛИЗОВАНО, НЕ device-verified. Найдено при device-отладке детектора
> §259 (детектор молчал — слушал мёртвый DNS-поток)._

## Проблема (device CPH2411, ColorOS)

§180 DNS-стрим (`subscribeDNSQueries`, SPEC 018) эмитит DNS-события **~47с
после старта VPN и глохнет навсегда**. TCP/UDP-события через тот же
profilerClient продолжают идти. Детектор §259 в итоге слушает пустой DNS-поток
и не срабатывает — при том что формула верна.

### Факты с устройства (Debug API)

| Источник | Наблюдение |
|---|---|
| §180-поток (`/profiler/live/unattributed`) | последнее DNS-событие `07:00:57`, старт `07:00:09` → жил ~48с, дальше 0 |
| attributed live (`/profiler/live`) | `tcpOpen/tcpClose/udpOpen` идут в реальном времени, DNS — 0 |
| core-лог | `ERROR dns: lookup failed for cp.cloudflare.com: context deadline exceeded` — ядро резолвит, **пишет в лог** |
| §180 `dnsFail` для того же домена | **0** — лог есть, структурного события нет |
| детектор §259 (app-лог) | `[dns-detect] window closed: fail=0 total_direct=0` — поток пуст |
| logcat | `OplusHansManager: pkg=com.leadaxe.lxbox cannot transition ...`, `LinkPower S_OFF` — ColorOS душит фон |

## Корень (подтверждён кодом)

DNS-подписка и TCP/UDP-поток заданы по-разному (это отдельные поколения API
libbox):

- **TCP/UDP** = `CommandConnections` в `CommandClientOptions.addCommand(...)` —
  legacy-команда, открывается вместе с `client.connect()`. Живёт у ДВУХ
  клиентов (`profilerClient` + `screenClient`).
- **DNS §180** = `client.subscribeDNSQueries(true, DnsHandler())` — отдельный
  gRPC-стрим (`-lx` расширение, SPEC 018), **ручная method-подписка** поверх
  клиента ПОСЛЕ `connect()`, привязанная к ОДНОМУ вызову
  `connectProfilerClient()`. Не в `addCommand` by-design: legacy-протокол не
  трогают ради forward-compat (старое ядро без `with_lx_command` → `Unimplemented`
  → тихий fallback).

Ни один из них не воскресает сам (в libbox нет reconnect — см. ниже). Разница в
том, что TCP/UDP дублируется через `screenClient` (у него есть resume-путь), а
DNS-подписка висит ТОЛЬКО на `profilerClient`, у которого пути восстановления
не было.

`ProfilerHandler.disconnected()` был **no-op** (наследовал пустой `BaseHandler`),
в отличие от `StatusHandler.disconnected()`, который делает
`scheduleReconnect { connectStatus() }`.

**Механизм:** ColorOS/Doze/смена сети рвёт gRPC profilerClient (в фоне/при
screen-off) → `disconnected()` приходит, но reconnect не запускается →
`connectProfilerClient()` не вызывается заново → `subscribeDNSQueries` не
переустанавливается. DNS-подписка мертва навсегда до ручного disconnect/connect
профайлера.

**Важно — в libbox НЕТ авто-reconnect (подтверждено кодом ядра,
`command_client.go`):** при обрыве стрима handler-горутина зовёт
`Disconnected(...)` и `return` — умирает, не перезванивая. `dialWithRetry` —
retry только на ПЕРВИЧНЫЙ dial (ждёт старт сервера), не на восстановление. Это
одинаково для ВСЕХ стримов (Connections/Outbounds/DNS). Значит первоначальная
гипотеза «libbox сам ре-стримит CommandConnections» — **неверна**.

**Почему тогда TCP/UDP выжили, а DNS нет — они шли через РАЗНЫЕ клиенты:**
`CommandConnections` (TCP/UDP) есть у ДВУХ клиентов — `profilerClient` И
`screenClient`. `screenClient` при экране профайлера активен и воскресает через
`resumeScreen()` (возврат из фона, refcount+screenPaused). `profilerClient` —
единственный носитель DNS-подписки — не имел НИ reconnect (no-op
`disconnected`), НИ resume-пути → умер и не воскрес. TCP/UDP-события в UI шли
через `screenClient`, создавая иллюзию «клиент жив».

**Ядро невиновно:** `HasSubscribers()→false` после гибели горутины подписки —
эмиссия by-design молчит без слушателя.

| Было | Стало (§260) |
|---|---|
| `ProfilerHandler.disconnected` = no-op | reconnect по образцу `StatusHandler` |
| DNS-стрим мёртв после первого обрыва | reconnect переподнимает `subscribeDNSQueries` |
| детектор §259 слеп (пустой поток) | детектор получает DNS-события |

## Фикс (BoxCommandClient.kt)

Native не знал «нужен ли ещё профайлер» (refcount живёт в Dart, §259
`_profilerRefs`). Наивный безусловный reconnect воскрешал бы зомби-клиент после
намеренного `disconnectProfiler()`. Решение — **зеркалировать намерение** во
`@Volatile profilerWanted`, ставя его в тех же двух точках, где Dart меняет
refcount 0↔1.

1. **`@Volatile profilerWanted`** — рядом с `tunnelAlive`.
2. **`connectProfiler()`** → `profilerWanted = true` перед `connectProfilerClient()`.
3. **`disconnectProfiler()`** → `profilerWanted = false` **ДО** disconnect
   (колбэк `disconnected()` из libbox-потока увидит false и не реконнектит —
   порядок важен, как и закрытие `dnsSubscription` до disconnect клиента).
4. **`shutdownAll()`** → `profilerWanted = false` (рядом с `tunnelAlive = false`,
   двойная защита teardown'а).
5. **`ProfilerHandler.disconnected()`** → reconnect с двойным гейтом:
   ```kotlin
   if (gen == profilerGen.get() && profilerWanted && tunnelAlive) {
       scheduleReconnect(RECONNECT_BACKOFF_START_MS) {
           if (profilerWanted && tunnelAlive) connectProfilerClient()
       }
   }
   ```
   + `Log.w` («profiler disconnected …») — виден в release logcat для
   device-верификации обрыва/reconnect.

### Почему закрыты все гонки

| Путь | Гейт | Итог |
|---|---|---|
| **A** реальный обрыв (ColorOS/Doze) | `gen` актуален, `wanted=true`, `alive=true` | reconnect → DNS-подписка встаёт заново ✅ |
| **B** намеренный `disconnectProfiler` (Dart refcount→0) | `wanted=false` выставлен ДО disconnect | reconnect не запускается ✅ |
| **C** пересоздание клиента | `gen` устарел | reconnect не запускается ✅ |
| **teardown** `shutdownAll` | `wanted=false` + `alive=false` | двойная защита ✅ |

Тонкая гонка `disconnected()` (libbox-поток) ↔ `disconnectProfiler()` (main):
если reconnect уже запланирован через `postDelayed`, а `profilerWanted` станет
`false` через мгновение — спасает **перепроверка внутри лямбды** (`if
(profilerWanted && tunnelAlive)` в момент ИСПОЛНЕНИЯ, не планирования). Тот же
приём двойной проверки, что в `connectStatus` (§163).

### Resume-из-фона — отдельная правка НЕ нужна

Профайлер намеренно **не паузится** в фоне (§164: «profilerClient НЕ трогаем —
recording живёт в фоне»), в отличие от status (`pauseStatus`) / screen
(`pauseScreen`). Значит `profilerWanted` остаётся `true` всю сессию recording, и
reconnect-хук покрывает **фоновый** обрыв сам — resume не требуется.

## Связь с §259

Детектор direct-DNS-глушения (§259) зависит от §180-потока. Пока стрим глох,
детектор был слеп (`total_direct=0`) — это выглядело как «§259 не работает», но
формула §259 верна. §260 чинит источник данных; §259 без §260 не может ловить
глушение на прошивках с агрессивным power-management.

## Проверка (device)

1. **logcat** (`Log.w` виден в release): `adb logcat | grep "profiler disconnected"`
   — увидеть обрыв и последующий reconnect при уходе в фон / screen-off.
2. **§180-поток переживает фон**: свернуть app на >1мин, вернуть, открыть сайты
   → `/profiler/live/unattributed` должен показывать СВЕЖИЕ `dnsResolve`/`dnsFail`
   (не только первые ~48с).
3. **Детектор §259 получает данные**: `[dns-detect] window closed` с
   `total_direct > 0` (а не 0) после фонового цикла.
4. Убедиться, что намеренный Stop VPN / закрытие recording НЕ порождает
   зомби-reconnect (нет бесконечных `profiler disconnected` в logcat после stop).

## Что НЕ трогаем

- Ядро sing-box — невиновно, эмиссия by-design без подписчика.
- Dart-refcount §259 (`acquireProfiler`/`releaseProfiler`) — корректен, native
  лишь зеркалит намерение через `profilerWanted`.
- TCP/UDP-путь — работал через `screenClient` (свой resume-lifecycle); §260
  добавляет `profilerClient`-путь ради DNS-подписки.
- `ScreenHandler`/`StatusHandler` — их восстановление (resume / собственный
  reconnect) не трогаем.

## Дальнейший путь (обсуждается, НЕ финализировано)

Рассматривается перенос DNS-стрима в **legacy-мультиплекс** — сделать его
полноценной командой `addCommand(CommandDNS)` рядом с `CommandConnections` в
`connectProfilerClient()` (требует поддержки в ядре: новая команда в
`command.go`-enum + dispatch). Тогда:

- `subscribeDNSQueries()` / `DnsQuerySubscription` / `DnsHandler.onError` —
  **удаляются** (DNS едет через тот же dispatch, что и Connections);
- reconnect-хук §260 в `disconnected()` **остаётся полезен** — он и так нужен,
  чтобы `Connect()` перезвался и переустановил ВСЕ команды мультиплекса; теперь
  он покрывает DNS **автоматически, без спец-кода** (переподписки вручную);
- `profilerWanted` **остаётся** — гейт против зомби при Dart refcount→0
  актуален для всего `profilerClient`, независимо от механизма DNS.

То есть §260 **не выброс**: `profilerWanted` + reconnect-хук переживают
миграцию; исчезнет только ручная переподписка DNS (она станет не нужна). Решение
о переносе — за владельцем (влияет на ядро и forward-compat: `CommandDNS` в
мультиплексе ломает совместимость со стоковым libbox сильнее, чем нынешний
опциональный `-lx`-стрим с тихим `Unimplemented`-fallback).
