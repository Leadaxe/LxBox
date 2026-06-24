package com.leadaxe.lxbox.vpn

import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.nekohasekai.libbox.CommandClient
import io.nekohasekai.libbox.CommandClientHandler
import io.nekohasekai.libbox.CommandClientOptions
import io.nekohasekai.libbox.ConnectionEvents
import io.nekohasekai.libbox.Connections
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LogIterator
import io.nekohasekai.libbox.OutboundGroupIterator
import io.nekohasekai.libbox.OutboundGroupItemIterator
import io.nekohasekai.libbox.RuleIterator
import io.nekohasekai.libbox.StatusMessage
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.URLTestOutboundResult
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/// §122 Фаза 0 — нативный канал управления UI↔ядро через libbox `CommandClient`
/// (gRPC поверх `command.sock`), замена Clash API HTTP-петли.
///
/// **Три клиента (§2.8)** — разный lifecycle под реальные нужды (разведано: что
/// работает в фоне vs гасится с экраном):
///  - `statusClient`   — `CommandStatus` + `setStatusInterval(1e8 нс=0.1с)`. **always-on**
///    пока туннель up. Питает dead-tunnel watchdog + скорость на главном.
///  - `screenClient`   — `CommandOutbounds`+`CommandGroup`+`CommandConnections`.
///    connect/disconnect по сигналу из Dart (открытие/закрытие экрана узлов/stats/conn).
///  - `profilerClient` — `CommandConnections`. connect/disconnect по recording (§048).
///
/// **Подписка в gomobile-фасаде** = `CommandClientOptions.addCommand(int)` + колбэки
/// `CommandClientHandler.write*` (НЕ прямые `subscribe*`-методы — их в AAR нет).
///
/// **JNI-no-throw** ([[project_jni_callbacks_must_not_throw]]): КАЖДЫЙ колбэк handler'а
/// обёрнут в try/catch — unchecked exception через JNI = `Runtime::Abort` всего процесса.
///
/// **Эмиттеры** — по образцу `BoxService` core-log drainer: `LinkedBlockingQueue` + cap +
/// drop-newest (не блокируем producer-thread ядра) + single Runnable + main-Handler + batch.
///
/// Sink'и читаются из `BoxVpnService`-companion (`cc*Sink`, @Volatile) — инвариант §2.1:
/// эмиттер живёт во Flutter-процессе.
class BoxCommandClient {

    companion object {
        private const val TAG = "BoxCommandClient"

        /// §2.3 ИСПРАВЛЕНО — `setStatusInterval` = НАНОСЕКУНДЫ, НЕ миллисекунды.
        /// Сервер ядра: `time.Duration(request.Interval)` + `time.NewTicker`
        /// (daemon/started_service.go:374) — Go `time.Duration` это int64 НС.
        /// Прежнее `1000L` ⇒ `time.Duration(1000)` = 1000нс = 1мкс → стрим
        /// эмитил статус/connections максимально часто → память «прыгала»,
        /// лишняя нагрузка. 100мс = живой UI скорости/соединений; память на
        /// Stats отдельно троттлится в UI (медленная метрика). 0.1с = 1e8 нс.
        private const val STATUS_INTERVAL_NS = 100_000_000L

        /// Cap очереди эмиттера — drop-newest при переполнении (producer не блокируется).
        /// Эмиттер coalesce'ит до последнего снапшота, так что cap — страховка.
        private const val QUEUE_MAX = 4096

        private const val RECONNECT_BACKOFF_START_MS = 500L
        private const val RECONNECT_BACKOFF_MAX_MS = 8_000L
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    // ───────────────────────── клиенты ─────────────────────────
    private val statusClient = AtomicReference<CommandClient?>(null)
    private val screenClient = AtomicReference<CommandClient?>(null)
    private val profilerClient = AtomicReference<CommandClient?>(null)

    /// §2.8 reset-синхронизация: каждый connect инкрементит поколение; снапшоты/события
    /// из устаревшего поколения игнорируются (защита от гонки connect/disconnect, §141 P1.2).
    private val statusGen = AtomicInteger(0)
    private val screenGen = AtomicInteger(0)
    private val profilerGen = AtomicInteger(0)

    /// Туннель считается живым — гейтит реконнект statusClient (не дёргать после stop).
    @Volatile
    private var tunnelAlive = false

    // ═══════════════════════ Public lifecycle API ═══════════════════════

    /// Поднять always-on `statusClient`. Вызывать ПОСЛЕ `BoxService.startCommandServer()`
    /// и когда сервис в статусе `Started` (сокет существует только после старта сервера).
    fun startStatus() {
        tunnelAlive = true
        connectStatus()
    }

    fun stopStatus() {
        tunnelAlive = false
        disconnectClient(statusClient, "stopStatus")
    }

    /// §2.8 — `screenClient` поднимается при открытии экрана узлов/stats/connections.
    /// §122 — REF-COUNTED: и главный экран (groups-стрим), и StatsScreen/Connections
    /// — независимые потребители. connectScreen поднимает клиент при ПЕРВОМ
    /// потребителе; disconnectScreen гасит при ПОСЛЕДНЕМ. Без refcount закрытие
    /// StatsScreen гасило бы screenClient, нужный главному экрану.
    private val screenRefs = AtomicInteger(0)

    fun connectScreen() {
        if (screenRefs.getAndIncrement() == 0) connectScreenClient()
    }

    fun disconnectScreen() {
        // decrementAndGet с полом 0 (defensive против лишних disconnect).
        val n = screenRefs.updateAndGet { if (it > 0) it - 1 else 0 }
        if (n == 0) disconnectClient(screenClient, "disconnectScreen")
    }

    /// §2.8 — `profilerClient` поднимается при `startGlobalRecording` (§048).
    fun connectProfiler() = connectProfilerClient()
    fun disconnectProfiler() = disconnectClient(profilerClient, "disconnectProfiler")

    /// Полный teardown — из `BoxService.doStop`/`closeCommandServerAtomic`.
    fun shutdownAll() {
        tunnelAlive = false
        screenRefs.set(0) // §122 — туннель умер, все экраны логически отвалились
        disconnectClient(statusClient, "shutdownAll")
        disconnectClient(screenClient, "shutdownAll")
        disconnectClient(profilerClient, "shutdownAll")
        connectionsAccumulator.set(null)
    }

    // ═══════════════════════ connect helpers ═══════════════════════

    private fun connectStatus() {
        val gen = statusGen.incrementAndGet()
        runCatching {
            val options = CommandClientOptions().apply {
                addCommand(Libbox.CommandStatus)
                setStatusInterval(STATUS_INTERVAL_NS) // НАНОСЕКУНДЫ (0.1с)
            }
            val client = CommandClient(StatusHandler(gen), options)
            client.connect()
            statusClient.getAndSet(client)?.runCatching { disconnect() }
        }.onFailure {
            Log.w(TAG, "connectStatus failed (gen=$gen): ${it.message}")
            scheduleReconnect(RECONNECT_BACKOFF_START_MS) { if (tunnelAlive) connectStatus() }
        }
    }

    private fun connectScreenClient() {
        val gen = screenGen.incrementAndGet()
        ensureAccumulator()
        runCatching {
            val options = CommandClientOptions().apply {
                addCommand(Libbox.CommandOutbounds)
                addCommand(Libbox.CommandGroup)
                addCommand(Libbox.CommandConnections)
            }
            val client = CommandClient(ScreenHandler(gen), options)
            client.connect()
            screenClient.getAndSet(client)?.runCatching { disconnect() }
        }.onFailure { Log.w(TAG, "connectScreen failed (gen=$gen): ${it.message}") }
    }

    private fun connectProfilerClient() {
        val gen = profilerGen.incrementAndGet()
        ensureAccumulator()
        runCatching {
            val options = CommandClientOptions().apply {
                addCommand(Libbox.CommandConnections)
            }
            val client = CommandClient(ProfilerHandler(gen), options)
            client.connect()
            profilerClient.getAndSet(client)?.runCatching { disconnect() }
        }.onFailure { Log.w(TAG, "connectProfiler failed (gen=$gen): ${it.message}") }
    }

    private fun disconnectClient(ref: AtomicReference<CommandClient?>, reason: String) {
        ref.getAndSet(null)?.runCatching { disconnect() }
            ?.onFailure { Log.w(TAG, "disconnect($reason) failed: ${it.message}") }
    }

    private fun scheduleReconnect(delayMs: Long, action: () -> Unit) {
        val capped = delayMs.coerceAtMost(RECONNECT_BACKOFF_MAX_MS)
        mainHandler.postDelayed({ runCatching { action() } }, capped)
    }

    // ═══════════════════════ Imperative (unary) ═══════════════════════
    // Прямые методы CommandClient. Дёргаются из VpnPlugin через MethodChannel.
    // Используем любой живой клиент (унарные RPC не зависят от подписок).

    private fun anyClient(): CommandClient? =
        statusClient.get() ?: screenClient.get() ?: profilerClient.get()

    /// §4.6 — per-node delay. ИНВАРИАНТ: `error` — единственный признак провала,
    /// `delay==0 && error==""` = успех 0мс. `timeout` — МИЛЛИСЕКУНДЫ.
    fun urlTestOutbound(tag: String, link: String, timeoutMs: Int): Map<String, Any> {
        val client = anyClient() ?: return mapOf("delay" to 0, "error" to "command client not connected")
        return runCatching {
            val r: URLTestOutboundResult = client.urlTestOutbound(tag, link, timeoutMs)
            mapOf("delay" to r.getDelay(), "error" to r.getError())
        }.getOrElse { mapOf("delay" to 0, "error" to (it.message ?: "urlTestOutbound failed")) }
    }

    /// §4.7 — снапшот route+DNS правил (только для диагностики).
    fun getRules(): List<Map<String, Any>> {
        val client = anyClient() ?: return emptyList()
        return runCatching {
            val out = ArrayList<Map<String, Any>>()
            val it: RuleIterator = client.getRules()
            while (it.hasNext()) {
                val r = it.next()
                out.add(mapOf(
                    "type" to r.getType(),
                    "payload" to r.getPayload(),
                    "action" to r.getAction(),
                    "isDNS" to r.getIsDNS(),
                ))
            }
            out
        }.getOrElse {
            Log.w(TAG, "getRules failed: ${it.message}")
            emptyList()
        }
    }

    fun selectOutbound(group: String, tag: String): Boolean =
        runCatching { anyClient()?.selectOutbound(group, tag); true }
            .getOrElse { Log.w(TAG, "selectOutbound failed: ${it.message}"); false }

    fun closeConnection(id: String): Boolean =
        runCatching { anyClient()?.closeConnection(id); true }
            .getOrElse { Log.w(TAG, "closeConnection failed: ${it.message}"); false }

    fun closeConnections(): Boolean =
        runCatching { anyClient()?.closeConnections(); true }
            .getOrElse { Log.w(TAG, "closeConnections failed: ${it.message}"); false }

    // ═══════════════════════ Native Connections accumulator ═══════════════════════
    // §3.2 — connections приходят ДЕЛЬТАМИ (writeConnectionEvents), не снапшотом.
    // Аккумулятор держится в Kotlin, эмитит в Dart полный снапшот. refcount под
    // screenClient+profilerClient (оба на CommandConnections).

    private val connectionsAccumulator = AtomicReference<Connections?>(null)

    private fun ensureAccumulator() {
        if (connectionsAccumulator.get() == null) {
            runCatching { connectionsAccumulator.compareAndSet(null, Connections()) }
                .onFailure { Log.w(TAG, "ensureAccumulator failed: ${it.message}") }
        }
    }

    // ═══════════════════════ Handlers ═══════════════════════
    // Базовый no-op handler — все 11 колбэков в try/catch fail-safe. Конкретные
    // клиенты переопределяют только нужные write*.

    private abstract inner class BaseHandler(protected val gen: Int) : CommandClientHandler {
        override fun connected() { runCatching { Log.d(TAG, "connected gen=$gen") } }
        override fun disconnected(message: String) {
            runCatching { Log.d(TAG, "disconnected gen=$gen: $message") }
        }
        override fun clearLogs() { runCatching { } }
        override fun setDefaultLogLevel(level: Int) { runCatching { } }
        override fun initializeClashMode(modeList: StringIterator?, currentMode: String?) { runCatching { } }
        override fun updateClashMode(newMode: String?) { runCatching { } }
        override fun writeLogs(messageList: LogIterator?) { runCatching { } }
        override fun writeStatus(message: StatusMessage?) { runCatching { } }
        override fun writeGroups(groups: OutboundGroupIterator?) { runCatching { } }
        override fun writeOutbounds(outbounds: OutboundGroupItemIterator?) { runCatching { } }
        override fun writeConnectionEvents(message: ConnectionEvents?) { runCatching { } }
    }

    /// statusClient — только writeStatus + реконнект на disconnected.
    private inner class StatusHandler(gen: Int) : BaseHandler(gen) {
        override fun disconnected(message: String) {
            runCatching {
                Log.d(TAG, "status disconnected gen=$gen: $message")
                if (gen == statusGen.get() && tunnelAlive) {
                    scheduleReconnect(RECONNECT_BACKOFF_START_MS) { if (tunnelAlive) connectStatus() }
                }
            }
        }

        override fun writeStatus(message: StatusMessage?) {
            runCatching {
                if (gen != statusGen.get()) return  // устаревшее поколение
                val m = message ?: return
                if (BoxVpnService.ccStatusSink == null) return
                val snap = HashMap<String, Any>(10)
                snap["uplink"] = m.getUplink()
                snap["downlink"] = m.getDownlink()
                snap["uplinkTotal"] = m.getUplinkTotal()
                snap["downlinkTotal"] = m.getDownlinkTotal()
                snap["memory"] = m.getMemory()
                snap["goroutines"] = m.getGoroutines()
                snap["connectionsIn"] = m.getConnectionsIn()
                snap["connectionsOut"] = m.getConnectionsOut()
                statusEmitter.offer(snap)
            }.onFailure { Log.w(TAG, "writeStatus failed: ${it.message}") }
        }
    }

    /// screenClient — outbounds (плоский node-list) + groups (дерево) + connections.
    private inner class ScreenHandler(gen: Int) : BaseHandler(gen) {
        override fun writeOutbounds(outbounds: OutboundGroupItemIterator?) {
            runCatching {
                if (gen != screenGen.get()) return
                val it = outbounds ?: return
                if (BoxVpnService.ccOutboundsSink == null) return
                val list = ArrayList<Map<String, Any>>()
                while (it.hasNext()) {
                    val item = it.next()
                    list.add(mapOf(
                        "tag" to item.getTag(),
                        "type" to item.getType(),
                        "urlTestDelay" to item.getURLTestDelay(),
                        "urlTestTime" to item.getURLTestTime(),
                    ))
                }
                outboundsEmitter.offer(list)
            }.onFailure { Log.w(TAG, "writeOutbounds failed: ${it.message}") }
        }

        override fun writeGroups(groups: OutboundGroupIterator?) {
            runCatching {
                if (gen != screenGen.get()) return
                val it = groups ?: return
                if (BoxVpnService.ccGroupsSink == null) return
                val list = ArrayList<Map<String, Any>>()
                while (it.hasNext()) {
                    val g = it.next()
                    val items = ArrayList<Map<String, Any>>()
                    val gi = g.getItems()
                    while (gi.hasNext()) {
                        val item = gi.next()
                        items.add(mapOf(
                            "tag" to item.tag,
                            "type" to item.type,
                            "urlTestDelay" to item.urlTestDelay,
                            "urlTestTime" to item.urlTestTime,
                        ))
                    }
                    list.add(mapOf(
                        "tag" to g.getTag(),
                        "type" to g.getType(),
                        "selectable" to g.getSelectable(),
                        "selected" to g.getSelected(),
                        "isExpand" to g.getIsExpand(),
                        "items" to items,
                    ))
                }
                groupsEmitter.offer(list)
            }.onFailure { Log.w(TAG, "writeGroups failed: ${it.message}") }
        }

        override fun writeConnectionEvents(message: ConnectionEvents?) {
            applyConnectionEvents(message, screenGen, gen)
        }
    }

    /// profilerClient — только connections (для §048 per-app live).
    private inner class ProfilerHandler(gen: Int) : BaseHandler(gen) {
        override fun writeConnectionEvents(message: ConnectionEvents?) {
            applyConnectionEvents(message, profilerGen, gen)
        }
    }

    /// §3.2 — применить дельты к аккумулятору, эмитить снапшот. getReset()=replace.
    ///
    /// КРИТИЧНО (§122): `ConnectionEvents` — это ДЕЛЬТА между вызовами. Аккумулятор
    /// ОБЯЗАН применять КАЖДОЕ событие по порядку, иначе рассинхрон навсегда.
    /// Раньше тут стоял ранний `if (ccConnectionsSink == null) return` — он
    /// отбрасывал дельты, пока никто в Dart не слушал `connections` (главный
    /// экран слушает только status+groups, НЕ connections). Симптом: главный
    /// видит N соединений (из status), а Stats при открытии — 0/мало, потому что
    /// все «created»-дельты до подписки были потеряны и аккумулятор пуст.
    /// Фикс: накапливать ВСЕГДА (пока screenClient жив), эмитить — только если
    /// есть Dart-подписчик (sink). Тогда Stats при подписке получит ПОЛНЫЙ снапшот.
    private fun applyConnectionEvents(message: ConnectionEvents?, genRef: AtomicInteger, gen: Int) {
        runCatching {
            if (gen != genRef.get()) return
            val events = message ?: return
            val acc = connectionsAccumulator.get() ?: run { ensureAccumulator(); connectionsAccumulator.get() } ?: return
            // applyEvents учитывает getReset() внутри (replace при reset). ВСЕГДА —
            // даже без Dart-подписчика, иначе пропуск дельты ломает аккумулятор.
            acc.applyEvents(events)
            // filterState(Active) держит аккумулятор компактным (только живые
            // соединения) — closed-историю ведёт Dart-сторона (ConnectionsView
            // `_accumulate`/`_closed*`), чтобы не копить закрытые бесконечно в
            // native. ConnectionStateActive — long (1L), filterState принимает int.
            acc.filterState(Libbox.ConnectionStateActive.toInt())
            // Эмиссия в Dart — только если кто-то слушает. Накопление выше уже
            // случилось, так что первый же подписчик получит полный снапшот.
            if (BoxVpnService.ccConnectionsSink == null) return
            val list = ArrayList<Map<String, Any>>()
            val it = acc.iterator()
            while (it.hasNext()) {
                val c = it.next()
                // §122 — ProcessInfo (app-attribution): package для иконки +
                // processPath. getProcessInfo() может быть null/кинуть — best-effort.
                var pkg = ""
                var processPath = ""
                runCatching {
                    val pi = c.getProcessInfo()
                    if (pi != null) {
                        processPath = pi.getProcessPath() ?: ""
                        val pkgIt = pi.packageNames()
                        if (pkgIt != null && pkgIt.hasNext()) pkg = pkgIt.next() ?: ""
                    }
                }
                // getID() — аббревиатура ЗАГЛАВНАЯ (снято с rc.2 AAR); явные геттеры.
                // §122 — uplink/downlink = НАКОПЛЕННЫЙ итог (getUplinkTotal/Total),
                // не дельта за тик (getUplink — у idle 0 → массовые 0/0).
                // outbound/outboundType — цепочка (chain-инфо есть в Connection).
                list.add(mapOf(
                    "id" to c.getID(),
                    "network" to c.getNetwork(),
                    "domain" to c.getDomain(),
                    "destination" to c.getDestination(),
                    "rule" to c.getRule(),
                    "uplink" to c.getUplinkTotal(),
                    "downlink" to c.getDownlinkTotal(),
                    "uplinkDelta" to c.getUplink(),
                    "downlinkDelta" to c.getDownlink(),
                    "outbound" to c.getOutbound(),
                    "outboundType" to c.getOutboundType(),
                    "protocol" to c.getProtocol(),
                    "packageName" to pkg,
                    "processPath" to processPath,
                    "createdAt" to c.getCreatedAt(),
                    "closedAt" to c.getClosedAt(),
                ))
            }
            connectionsEmitter.offer(list)
        }.onFailure { Log.w(TAG, "applyConnectionEvents failed: ${it.message}") }
    }

    // ═══════════════════════ Emitters (по образцу core-log drainer) ═══════════════════════

    private val statusEmitter = SnapshotEmitter { BoxVpnService.ccStatusSink }
    private val outboundsEmitter = SnapshotEmitter { BoxVpnService.ccOutboundsSink }
    private val groupsEmitter = SnapshotEmitter { BoxVpnService.ccGroupsSink }
    private val connectionsEmitter = SnapshotEmitter { BoxVpnService.ccConnectionsSink }

    /// Дросселированный эмиттер: queue + drop-newest + single Runnable + main-Handler + batch.
    /// Для status/outbounds/groups/connections эмитим ПОСЛЕДНИЙ снапшот (coalesce —
    /// промежуточные не нужны, UI рисует актуальное). sink.success на main-looper.
    private inner class SnapshotEmitter(private val sinkProvider: () -> EventChannel.EventSink?) {
        private val queue = LinkedBlockingQueue<Any>()
        private val scheduled = AtomicBoolean(false)

        fun offer(snapshot: Any) {
            // coalesce: держим только последний снапшот (drop старые).
            queue.clear()
            if (queue.size < QUEUE_MAX) queue.offer(snapshot)
            if (scheduled.compareAndSet(false, true)) {
                mainHandler.post(drainer)
            }
        }

        private val drainer = Runnable {
            scheduled.set(false)
            val sink = sinkProvider() ?: run { queue.clear(); return@Runnable }
            val latest = queue.poll() ?: return@Runnable
            queue.clear()
            runCatching { sink.success(latest) }
                .onFailure { Log.w(TAG, "emitter sink.success failed: ${it.message}") }
        }
    }
}
