# §261 — DNS-стрим: переход на command-мультиплекс ядра (смена парадигмы)

**Статус:** Open — блокирован новым AAR (см. §0)
**Заменяет:** [§260](260-profiler-dns-stream-reconnect.md) — Kotlin-заплатка (`profilerWanted`
+ reconnect-хук) отменяется; корень чинится в ядре переносом DNS в мультиплекс, клиентский
reconnect-код удаляется (см. §1.5).
**Ядро:** sing-box-lx SPEC 018 v2, ветка `lx-spec018-dns-multiplex`
**Файлы LxBox:** `BoxCommandClient.kt` (основное), `VpnPlugin.kt` (откат §259)
**Тип:** смена парадигмы — DNS-поток из отдельной подписки становится обычным членом мультиплекса

---

## 0. Контекст: что изменилось в ядре

Ядро sing-box-lx перенесло §180 DNS-стрим (SPEC 018) из **отдельной ручной подписки**
(`subscribeDNSQueries()` → `DnsQuerySubscription` + `DnsQueryHandler`) в **command-мультиплекс**,
где DNS теперь устроен **идентично `CommandConnections`**.

**Почему** (полный разбор — в ядре: `SPECS/018-DNS_QUERY_STREAM/HISTORY.md`): старая
standalone-подписка не переживала уход в фон/Doze — её gRPC-стрим не был в
`dispatchCommands`, поэтому `Connect()` при реконнекте её не переподнимал. Симптом:
§180-поток эмитил ~47с после старта и замолкал навсегда, хотя TCP/UDP шли. Наш §259-патч
(`profilerWanted` + reconnect-хук) был симптоматической заплаткой — теперь он **не нужен и
удаляется**, потому что DNS живёт на общем `c.ctx` клиента и авто-восстанавливается вместе
со всеми стримами профайлера.

**Парадигма после перехода:** DNS-стрим поднимается через `addCommand(CommandDNS)` вместе с
`CommandConnections`, живёт ровно пока жив `profilerClient`, гаснет с ним, авто-реконнектится
через `Connect()`. Никакой отдельной подписки, никакого `Close()`, никакого reconnect-кода
на клиенте. DNS-события приходят через `CommandClientHandler.writeDNSQuery(...)` — как
connections через `writeConnectionEvents`.

**Блокировка:** нужен новый `libbox.aar` со сборки ветки `lx-spec018-dns-multiplex`.
- Артефакт (workflow): https://github.com/Leadaxe/sing-box-lx/actions/runs/28930130775
  → `android-aar-lx-spec018-dns-multiplex` (`libbox.aar` + `libbox-legacy.aar`).
- Для локальной проверки: скачать артефакт, положить `libbox.aar` в
  `app/android/app/libs/libbox.aar` вручную (в обход `fetch-libbox.sh`, который тянет из
  Releases по тегу — а тега пока нет).
- Для CI/релиза: ядро должно нарезать lx-тег с этим AAR как release-ассетом, затем
  `app/android/libbox.version` бампится на новый тег (штатный `fetch-libbox.sh`).

## 0.1. Проверенные сигнатуры из нового AAR (`javap`, НЕ предположения)

```
io.nekohasekai.libbox.Libbox:
  public static final int CommandDNS = 6;              // рядом с CommandConnections = 4

io.nekohasekai.libbox.CommandClientOptions:
  public native void addCommand(int);
  public final native void setDNSIncludeAnswers(boolean);   // как setStatusInterval

io.nekohasekai.libbox.CommandClientHandler:                 // расширен
  public abstract void writeConnectionEvents(ConnectionEvents);
  public abstract void writeDNSQuery(io.nekohasekai.libbox.DnsQuery);   // НОВЫЙ, per-event

io.nekohasekai.libbox.DnsQuery:                             // без изменений vs старый onQuery
  getDomain() getQueryType() getRcode() getTTL() getSource()
  getFailed() getError() getDNSServer() getDNSServerType()
  getProcessInfo() : ProcessInfo
  answers() : DnsAnswerIterator
  outbound() : StringIterator

УДАЛЕНЫ ИЗ AAR (старый код с ними НЕ скомпилится — компилятор укажет всё, что чистить):
  - интерфейс DnsQueryHandler
  - класс DnsQuerySubscription
  - метод CommandClient.subscribeDNSQueries(...)
```

`writeDNSQuery` принимает **один `DnsQuery` на событие** (per-event), НЕ батч-итератор.
Маппинг тот же, что был в `DnsHandler.onQuery(query)` — переносится 1:1.

---

## 1. Правки в `BoxCommandClient.kt`

### 1.1. `connectProfilerClient()` (≈:334-347) — DNS через мультиплекс

```kotlin
// БЫЛО: addCommand(CommandConnections) + отдельный subscribeDNSQueries поверх connect()
val options = CommandClientOptions().apply {
    addCommand(Libbox.CommandConnections)
    addCommand(Libbox.CommandDNS)            // ← НОВОЕ: DNS как член мультиплекса
    setDNSIncludeAnswers(true)               // ← НОВОЕ: CNAME-цепочка (Q3), как раньше includeAnswers=true
}
val client = CommandClient(ProfilerHandler(gen), options)
client.connect()
profilerClient.getAndSet(client)?.runCatching { disconnect() }
// УДАЛИТЬ ВЕСЬ блок runCatching { subscribeDNSQueries(true, DnsHandler()) ... } (:342-347)
```

### 1.2. Перенести маппинг `DnsHandler.onQuery` → `ProfilerHandler.writeDNSQuery`

`ProfilerHandler` (≈:697) уже реализует `writeConnectionEvents`. Добавить рядом
`writeDNSQuery`, тело — 1:1 из старого `DnsHandler.onQuery` (:735-802):

```kotlin
private inner class ProfilerHandler(gen: Int) : BaseHandler(gen) {
    override fun writeConnectionEvents(message: ConnectionEvents?) {
        applyConnectionEvents(message, profilerGen, gen, profilerAccumulator)
    }
    override fun writeDNSQuery(query: DnsQuery?) {
        runCatching {
            val q = query ?: return
            if (BoxVpnService.ccDnsQueriesSink == null) return
            // ... ВЕСЬ маппинг из старого DnsHandler.onQuery БЕЗ ИЗМЕНЕНИЙ:
            //     processInfo, answers[], dnsServer/Type, outbound, rcode как есть (-1),
            //     dnsQueriesEmitter.offer(mapOf(...))
        }.onFailure { Log.w(TAG, "writeDNSQuery failed: ${it.message}") }
    }
}
```

### 1.3. Удалить старую standalone-модель

- `import io.nekohasekai.libbox.DnsQueryHandler` (:13) — удалить.
- `import ...DnsQuerySubscription` (если есть) — удалить.
- поле `dnsSubscription` (:95) — удалить.
- `dnsSubscription.getAndSet(null)?.close()` в `disconnectProfiler()` (:276) и `shutdownAll()` (:287) — удалить.
- inner class `DnsHandler : DnsQueryHandler` целиком (:729-808) — удалить (тело переехало в 1.2; `onError` :805 просто исчезает — обрыв идёт через общий `disconnected`).

### 1.4. no-op `writeDNSQuery` во ВСЕХ реализаторах `CommandClientHandler`

`CommandClientHandler` теперь требует `writeDNSQuery`. Реализаторов **ДВА** (не
только `BaseHandler` — грепни `: CommandClientHandler` перед правкой):

1. **`BaseHandler`** (`BoxCommandClient.kt`) — база для Status/Screen/Ping. Добавить
   no-op рядом с `writeConnectionEvents(...) { runCatching { } }`:
   ```kotlin
   override fun writeDNSQuery(query: DnsQuery?) { runCatching { } }
   ```
   Только `ProfilerHandler` переопределяет реально (1.2).

2. **`ProbeSession.ProbeClientHandler`** (`ProbeSession.kt`, §236 headless probe) —
   отдельный объект-реализатор, НЕ через BaseHandler. Тоже добавить no-op +
   `import io.nekohasekai.libbox.DnsQuery`. **Забыть = build FAILED** («not abstract
   and does not implement abstract member writeDNSQuery»).

### 1.5. ОТКАТ §259-патча (reconnect-хук больше не нужен)

DNS теперь авто-реконнектится ядром через мультиплекс → Kotlin-хук избыточен. Удалить:
- поле `profilerWanted` (:113) + 3 присваивания (:266, :274, :283).
- `ProfilerHandler.disconnected()` override (:713-722) целиком — вернуть к унаследованному
  из `BaseHandler` (просто убрать override).

⚠️ Перед удалением — `git diff` §259-патча: убедиться, что он не трогал ничего сверх этих
точек. §259-патч был незакоммичен/в отдельной ветке — свериться.

---

## 2. `VpnPlugin.kt` — проверить, НЕ откатывать лишнего

`ccPauseClients`/`ccResumeClients` (:655-662) трогают только status+screen — profiler не
трогают. Это КОРРЕКТНО и остаётся: profilerClient (с DNS внутри) живёт в фоне через
recording, DNS теперь переживает реконнект сам. **Правок не требуется** — только подтвердить,
что §259-откат (1.5) не потребовал менять pause/resume.

---

## 3. Dart — НЕ трогается

DNS-события идут тем же путём: `writeDNSQuery` → `dnsQueriesEmitter` → `ccDnsQueriesSink`
(EventChannel `_dnsChannel`) → `cc.dnsQueries` broadcast-стрим. Потребители
(`traffic_profiler.dart`, `dns_direct_detector.dart §259`) видят тот же
`Stream<List<CcDnsQuery>>`. Refcount §259 (`acquireProfiler`/`releaseProfiler`) — без
изменений: он управляет profilerClient целиком, DNS теперь его штатная часть. **0 правок в Dart.**

---

## 4. Критерии готовности + device-verify

- [ ] Проект компилится на новом AAR; компилятор не ругается на `DnsQueryHandler`/
      `DnsQuerySubscription`/`subscribeDNSQueries` (всё удалено).
- [ ] `writeDNSQuery` маппит те же поля, что старый `onQuery` (domain, rcode=-1 как есть,
      processInfo, answers[] CNAME, dnsServer/Type, outbound).
- [ ] §259-патч (`profilerWanted`, reconnect-хук) удалён; pause/resume не менялись.
- [ ] **Device-verify (главный критерий, ради него всё):**
  1. Поднять VPN, открыть профайлер (recording). §180-поток идёт (DNS-события с атрибуцией).
  2. Свернуть приложение / уйти в Doze на минуту, вернуть.
  3. **§180-поток ОЖИВАЕТ сам, БЕЗ §259-хука** — DNS-события возобновляются после фона.
     Это доказывает, что мультиплекс-реконнект ядра переподнял DNS. (Инструмент проверки:
     Debug API `/profiler/live/unattributed` — DNS только там, НЕ в attributed `/profiler/live`.)
  4. Проверить паритет: DNS и connections гаснут/оживают синхронно при connect/disconnect
     профайлера (одна модель lifecycle).

## 5. Ссылки

- Ядро: `SPECS/018-DNS_QUERY_STREAM/SPEC.md` (v2 архитектура), `HISTORY.md` (почему переделали).
- AAR-артефакт: https://github.com/Leadaxe/sing-box-lx/actions/runs/28930130775
- Диагностические ловушки (из ядрового HISTORY.md): `/logs/core` на ColorOS обрезан; DNS
  только в `/profiler/live/unattributed`; `ping`/`nslookup` идут мимо TUN (тест через `am start`).
