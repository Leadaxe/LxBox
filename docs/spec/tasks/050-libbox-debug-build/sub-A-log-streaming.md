# §050 Sub-task A — Log streaming via CommandClient (vs writeDebugMessage callback)

| Поле | Значение |
|---|---|
| Статус | **Discovered** — находка после полного behavioral diff с reference SagerNet 1.13.11 |
| Дата | 2026-05-10 |
| Parent | [`050 libbox debug build`](./spec.md), [`049 sing-box wrapper deep audit`](../049-singbox-wrapper-deep-audit/spec.md) |
| Затронутые файлы | `vpn/BoxService.kt` (writeDebugMessage), `vpn/BoxApplication.kt` (SetupOptions.debug), VpnPlugin (coreLogSink), Flutter live_events_tab |

## TL;DR

**Reference SFA не использует `writeDebugMessage` callback вообще** для UI log display.

Они получают log entries через **streaming Unix socket subscription** к sing-box's CommandServer (`Libbox.CommandLog` connection type). Это **fundamentally different architecture** — нет cgo upcalls per log line.

У нас Flutter UI core logs forwarding устроен через `writeDebugMessage` callback (cgo upcall на каждой log line). Это main vector race condition refnum 42 которую мы расследуем в §050.

## Discovery context

После 7+ часов §050 investigation (debug AAR build, addr2line, gomobile patching), полный line-by-line behavioral diff с reference SagerNet 1.13.11 (`bg/BoxService.kt`) revealed критическую архитектурную delta которую я раньше пропускал.

Triggered observation: SFA installed на phone с identical libbox stack, активный F12.3 wifi-rule config — **работает stable без crash refnum 42**. Significant signal что проблема не в environment, а в нашем коде.

## Reference architecture (SFA 1.13.11)

```
[Sing-box Go runtime]
  ↓ logger emits LogEntry through Go channel
[CommandServer (sing-box internal)]
  ↓ Unix socket listener for subscribers
  ↓ command type: Libbox.CommandLog
  ↓ streams LogEntry as serialized binary frames

[SFA Java side]
  CommandClient(handler, options)
    options.addCommand(Libbox.CommandLog)
    options.statusInterval = 1s
    connect()  ← TCP connection к local socket
  ↓ background thread reads frames
  ↓ parses LogEntry (level: int, message: String)
  ↓ calls handler.updateLogEntry(entry)

[SFA UI]
  LogViewModel → updates LogScreen LazyColumn
```

**Key properties**:
- **Один long-lived socket connection** (vs cgo upcall per log line)
- LogEntry parsing in background thread (не main thread)
- `SetupOptions.debug = BuildConfig.DEBUG` — false в release builds!
- `s.handler.WriteDebugMessage(message)` callback в gate `if s.debug` — **никогда** не вызывается в production SFA
- Hence `Log.d("sing-box", message!!)` тоже never runs in production — это dead code в release

## Наша current architecture

```
[Sing-box Go runtime]
  if s.debug:                                  ← gate s.debug = isCoreLogsEnabled() (default false)
    s.handler.WriteDebugMessage(message)
      ↓ cgo upcall: Java→Go bridge
      ↓ JNI cross
[Java side BoxService]
  override fun writeDebugMessage(message: String) {
    // regex strip ANSI, filter trace/debug
    coreLogMainHandler.post {                  ← async post per log line
      sink.success(plain)
    }
  }
  ↓
[Flutter EventChannel "lxbox/coreLog"]
  ↓
[Dart isolate AppLog buffer]
  ↓ in-memory quotas (300 app + 500 core)
[UI LiveTab / DebugScreen]
```

**Key properties**:
- **cgo upcall per log line** — 1000+/sec возможно на active traffic
- Каждый upcall: `cproxylibbox_CommandServerHandler_WriteDebugMessage` → `go_seq_from_refnum(42)` → Java `Seq.getRef`/`Seq.decRef`
- Race condition window: между Go-side `incRef` и Java-side `getRef+decRef` есть JNI hop — параллельные goroutines могут довести refcnt до 0 → `RefMap.remove(42)` → next callback `getRef(42)` returns null → `LOG_FATAL("Unknown reference: 42")` → SIGABRT
- Gate `s.debug` requires process restart to apply (SetupOptions.debug snapshot at Libbox.setup time)

## Why it matters для refnum 42 race

Refnum 42 = `BoxService` instance (CSH handler) в `Seq.RefMap`. CSH callback methods (writeDebugMessage, serviceReload, serviceStop, getSystemProxyStatus, setSystemProxyEnabled, sendNotification) делают cgo upcalls.

**writeDebugMessage** — самый частый callback (rate ~1000/sec на active traffic + debug logs). Other CSH methods вызываются **редко**:
- serviceReload — один раз per user reload action
- serviceStop — один раз per user stop
- getSystemProxyStatus — Clash dashboard polling, ~1-3/sec
- setSystemProxyEnabled — rare
- sendNotification — rare

Если **убрать** writeDebugMessage callback (set s.debug=false always), частота cgo upcalls на CSH refnum упадёт с 1000/sec до **<5/sec**. Race window практически закрывается.

## Confirmed: SFA в production не имеет race потому что callback off

Empirical evidence (this session):
- SFA's libbox.so extracted from running APK on phone — это **release build**, identical libbox 1.13.11 что у нас
- SFA's `BuildConfig.DEBUG = false` в release → `Setup.debug = false` → callback dead code
- SFA active с wifi rule config (наш sfa-test.json) — running stable, no crashes
- LxBox v13xxx с F12.3 enabled + Setup.debug=true (для diagnostic) — crash refnum 42 в первые секунды

## Migration proposal

### Step 1 — Disable writeDebugMessage callback by default

В `BoxApplication.kt`:
```kotlin
// Было:
debug = BootReceiver.isCoreLogsEnabled(context)

// Стало:
debug = false   // Permanent — callback не используется для log forwarding
```

`SetupOptions.debug = false` навсегда → sing-box не зовёт `WriteDebugMessage` → race window закрывается на этом vector.

В `BoxService.writeDebugMessage` остаётся как **defensive stub** (на случай если другой path в sing-box зовёт):
```kotlin
override fun writeDebugMessage(message: String) {
    Log.d("sing-box", message)  // fallback в logcat если sing-box почему-то всё ещё зовёт
}
```

### Step 2 — Implement CommandClient.Log subscription для Flutter forwarding

Создать `vpn/CoreLogStreamer.kt`:
```kotlin
class CoreLogStreamer(private val service: Service, private val scope: CoroutineScope) {
    private var client: CommandClient? = null
    
    fun start() {
        scope.launch(Dispatchers.IO) {
            try {
                val c = CommandClient(handler, CommandClientOptions().apply {
                    addCommand(Libbox.CommandLog)
                    statusInterval = 1_000_000_000L  // 1s
                })
                c.connect()  // Unix socket к local CommandServer
                client = c
            } catch (t: Throwable) {
                Log.e("CoreLogStreamer", "connect failed", t)
            }
        }
    }
    
    fun stop() {
        scope.launch(Dispatchers.IO) {
            runCatching { client?.disconnect() }
            client = null
        }
    }
    
    private val handler = object : CommandClientHandler {
        override fun connected() {}
        override fun disconnected(message: String) {}
        override fun setLogIterator(iterator: LogIterator) {
            while (iterator.hasNext()) {
                val entry = iterator.next()
                BoxVpnService.coreLogSink?.let { sink ->
                    coreLogMainHandler.post { 
                        runCatching { sink.success("${levelName(entry.level)} ${entry.message}") } 
                    }
                }
            }
        }
        // ... other CommandClientHandler stub methods
    }
}
```

### Step 3 — Hook lifecycle

В `BoxService.startSingbox()` (после `cs.startOrReloadService` succeeds):
```kotlin
coreLogStreamer.start()
```

В `BoxService.doStop()`:
```kotlin
coreLogStreamer.stop()
```

### Step 4 — Удалить старый writeDebugMessage forwarding code

- Drainer pattern (coreLogQueue, drainerScheduled, coreLogDrainer)
- Старый async post в writeDebugMessage
- Возможно simplify writeDebugMessage до одной строки `Log.d`

### Step 5 — Обновить App Settings UI

- Убрать "Forward sing-box logs" toggle (или превратить его в no-op informational note)
- Документировать что core logs всегда доступны через CommandClient Log subscription
- Live tab всегда работает независимо от toggle

## Alternative — keep writeDebugMessage callback с rate limit

Если migration на CommandClient слишком инвазивный, минимальный fix:
- Set `SetupOptions.debug = true` permanently (callback always works)
- Add **synchronous `Log.d`** в writeDebugMessage первой строкой (rate limit closes race window)
- Filter trace/debug **after** Log.d (optional через runtime toggle)

Но это всё ещё имеет cgo upcall per log line — fragile fix.

## Estimated cost

| Path | Cost | Risk |
|---|---|---|
| Step 1-5 (full migration to CommandClient) | 2-4 hours implementation + testing | Medium — нужно verify CommandClient lifecycle integration с our Service |
| Alternative (sync Log.d) | 5-10 minutes | Higher — все ещё работает на edge of race window |

Рекомендация: **full migration на CommandClient**. Это reference architecture которая проверена в production. Eliminates root cause race vector. Совпадает с design intent reference SFA.

## References

- `/tmp/sfa-recheck/sfa/app/src/main/java/io/nekohasekai/sfa/utils/CommandClient.kt` — reference CommandClient wrapper
- `/tmp/sfa-recheck/sfa/app/src/main/java/io/nekohasekai/sfa/compose/screen/log/LogViewModel.kt` — reference UI integration
- `/tmp/sfa-recheck/sfa/app/src/main/java/io/nekohasekai/sfa/Application.kt:initialize()` — `Setup.debug = BuildConfig.DEBUG` decision
- `/tmp/libbox-build/sing-box/daemon/started_service.go:1048-1049` — `if s.debug` gate
- `/tmp/libbox-build/sing-box/experimental/libbox/command_server.go:42,274` — CommandServerHandler interface + WriteDebugMessage proxy
