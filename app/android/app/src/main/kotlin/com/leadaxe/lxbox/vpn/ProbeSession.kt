package com.leadaxe.lxbox.vpn

import android.util.Log
import io.nekohasekai.libbox.CommandClient
import io.nekohasekai.libbox.CommandClientHandler
import io.nekohasekai.libbox.CommandClientOptions
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.ConnectionEvents
import io.nekohasekai.libbox.DnsQuery
import io.nekohasekai.libbox.LogIterator
import io.nekohasekai.libbox.OutboundGroupIterator
import io.nekohasekai.libbox.OutboundGroupItemIterator
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.StatusMessage
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.SystemProxyStatus
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking

/// §236 — headless probe-сессия: ВРЕМЕННЫЙ CommandServer + конфиг БЕЗ tun,
/// чтобы гонять `urlTestOutbound` по нодам папки, пока VPN ВЫКЛЮЧЕН.
///
/// Ограничение, диктующее модель: command.sock живёт в глобальном basePath
/// (`Libbox.setup` — один на процесс) → два CommandServer одновременно
/// невозможны. Поэтому:
///  - probe стартует ТОЛЬКО при выключенном VPN (гейт по
///    `BoxService.commandClient == null`);
///  - старт VPN всегда приоритетнее: `BoxService` зовёт [stop] перед своим
///    `startCommandServer()` (закрывает забытую/висящую сессию).
///
/// НЕ Android-сервис: VpnStatus-broadcast, уведомления и tun не затрагиваются.
/// Все колбэки из Go — no-throw (JNI: unchecked exception = Runtime::Abort).
object ProbeSession : CommandServerHandler {
    private const val TAG = "ProbeSession"

    /// §669 — живая сессия одним объектом: владелец прогона ([runId]),
    /// сервер и клиент меняются вместе, поэтому отмена/остановка с чужим
    /// runId не может задеть сессию, поднятую позже.
    private class Session(
        val runId: Long,
        val server: CommandServer,
        val client: CommandClient,
    ) {
        @Volatile var cancelled = false
        private val clientClosed = AtomicBoolean(false)

        fun disconnectClient() {
            if (clientClosed.compareAndSet(false, true)) {
                runCatching { client.disconnect() }
            }
        }
    }

    private val session = AtomicReference<Session?>(null)
    private val nextRunId = AtomicLong(0)

    /// §669 — ответ на вызов с устаревшим/чужим runId: прогон вытеснен новым,
    /// вызов ничего не делает. Dart сверяет строку дословно (`kProbeStaleRun`).
    const val STALE_RUN = "stale run"

    /// §669 — потолок закрытия сервера probe-сессии, как у остановки
    /// VPN-службы (§287/§668): `closeService` синхронно разбирает все
    /// WG-узлы конфига (10–17 с на устройстве).
    private const val CLOSE_TIMEOUT_MS = 3_000L

    /// §237-fix — `LocalResolver` отвечает SERVFAIL, пока
    /// `DefaultNetworkMonitor.defaultNetwork == null`, а монитор поднимает
    /// только боевой VPN-flow. Probe-сессия стартует его сама (и гасит только
    /// свой — если к моменту stop VPN уже жив, монитор принадлежит ему).
    private var probeScope: CoroutineScope? = null
    private var monitorOwned = false

    val active: Boolean get() = session.get() != null

    /// Запуск сессии с готовым probe-конфигом (без inbound'ов). Возвращает
    /// `{error, runId}`: error '' при успехе, иначе текст ошибки (runId 0).
    /// Повторный вызов поверх живой сессии — рестарт: старая закрывается, её
    /// владелец дальше получает [STALE_RUN].
    @Synchronized
    fun start(config: String): Map<String, Any> {
        if (BoxService.commandClient != null) {
            return startResult("VPN is running — test uses the live tunnel instead")
        }
        stopInternal("restart")
        var cs: CommandServer? = null
        var cl: CommandClient? = null
        return runCatching {
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            probeScope = scope
            // Без монитора local-DNS (§049 F26) мертв → каждый lookup из
            // probe-конфига падал SERVFAIL (device-репро 04.07.2026).
            runBlocking { DefaultNetworkMonitor.start(scope) { } }
            monitorOwned = true
            val server = CommandServer(this, ProbePlatform)
            cs = server
            server.start()
            server.startOrReloadService(config, OverrideOptions())
            val client = CommandClient(ProbeClientHandler, CommandClientOptions())
            cl = client
            client.connect()
            val id = nextRunId.incrementAndGet()
            session.set(Session(id, server, client))
            Log.d(TAG, "probe session started (run=$id)")
            startResult("", id)
        }.getOrElse {
            Log.e(TAG, "probe start failed", it)
            cl?.let { c -> runCatching { c.disconnect() } }
            cs?.let { s -> closeServerBounded(s, "start failed") }
            stopInternal("start failed")
            startResult(it.message ?: "probe start failed")
        }
    }

    private fun startResult(error: String, runId: Long = 0): Map<String, Any> =
        mapOf("error" to error, "runId" to runId)

    /// Сессия прогона [runId] либо `null` и причина отказа.
    private fun sessionFor(runId: Long): Pair<Session?, String> {
        val s = session.get() ?: return null to "probe session not running"
        if (s.runId != runId) return null to STALE_RUN
        if (s.cancelled) return null to "probe run cancelled"
        return s to ""
    }

    /// Синхронный тест одной ноды (SPEC 014, Variant B: провал — в `error`
    /// результата, не в исключении). Конкурентные вызовы допустимы — unary
    /// gRPC мультиплексируется на одном клиенте (как pingClient §209).
    fun urlTest(runId: Long, tag: String, link: String, timeoutMs: Int): Map<String, Any> {
        val (s, why) = sessionFor(runId)
        if (s == null) return mapOf("delay" to 0, "error" to why)
        return runCatching {
            val r = s.client.urlTestOutbound(tag, link, timeoutMs)
            mapOf("delay" to r.delay, "error" to (r.error ?: ""))
        }.getOrElse {
            mapOf("delay" to 0, "error" to (it.message ?: "urlTestOutbound failed"))
        }
    }

    /// §669 — отмена прогона по образцу §175 (`BoxCommandClient.cancelPing`):
    /// disconnect клиента → ядро отменяет per-call ctx уже ушедших в dial
    /// замеров, они возвращаются сразу, не дожидаясь таймаута. Сервер живёт
    /// до [stop] своего владельца. Не synchronized: монитор может держать
    /// долгий [start]/[stop], отмена его ждать не должна.
    fun cancel(runId: Long) {
        val s = session.get() ?: return
        if (s.runId != runId) return
        s.cancelled = true
        s.disconnectClient()
        Log.d(TAG, "probe run $runId cancelled")
    }

    /// §392 — диагностический HTTP GET через узел probe-сессии (kernel SPEC
    /// 058). Тело ответа возвращается как есть; парсинг — сторона Dart.
    ///
    /// Провал обмена приезжает исключением (libbox-обёртка мапит payload-error
    /// в Go-error), не-2xx — обычный результат со статусом. Форма Map зеркалит
    /// [BoxCommandClient.getUrlViaOutbound]: у Dart один разбор на обе ветки.
    fun getUrl(
        runId: Long,
        tag: String,
        link: String,
        timeoutMs: Int,
        maxBytes: Int,
        userAgent: String,
    ): Map<String, Any> {
        val (s, why) = sessionFor(runId)
        if (s == null) return mapOf("error" to why)
        return runCatching {
            val r = s.client.getURLViaOutbound(
                tag, link, timeoutMs, maxBytes, userAgentHeaders(userAgent),
            )
            // Геттеры без `get`-префикса — см. BoxCommandClient.getUrlViaOutbound.
            mapOf(
                "status" to r.status(),
                "content" to r.content(),
                "truncated" to r.truncated(),
                "contentType" to r.contentType(),
                "remoteAddr" to r.remoteAddr(),
                "elapsedMs" to r.elapsedMs(),
                "error" to "",
            )
        }.getOrElse {
            mapOf("error" to (it.message ?: "getURLViaOutbound failed"))
        }
    }

    /// §669 — остановка своей сессии: чужой/устаревший [runId] — no-op
    /// (старый прогон не закрывает сессию нового).
    @Synchronized
    fun stop(runId: Long) {
        val s = session.get()
        if (s != null && s.runId != runId) {
            Log.d(TAG, "probe stop ignored: run=$runId is stale (live=${s.runId})")
            return
        }
        stopInternal("run=$runId")
    }

    /// Принудительная остановка любой сессии: старт VPN (`BoxService`),
    /// просьба ядра ([serviceStop]).
    @Synchronized
    fun stop() = stopInternal("forced")

    private fun stopInternal(reason: String) {
        session.getAndSet(null)?.let {
            it.disconnectClient()
            closeServerBounded(it.server, reason)
        }
        if (monitorOwned) {
            monitorOwned = false
            // VPN мог уже перехватить монитор (start VPN глушит probe и
            // стартует монитор сам) — гасим только пока туннеля нет.
            if (BoxService.commandClient == null) {
                runCatching { runBlocking { DefaultNetworkMonitor.stop() } }
            }
        }
        probeScope?.cancel()
        probeScope = null
    }

    /// §669 — закрытие сервера под потолком [CLOSE_TIMEOUT_MS] (образец —
    /// шаги `StopTrace` §668). Блокирующий JNI-вызов потолок не прерывает:
    /// зависший `closeService` остаётся в своём потоке-демоне, а сессия уже
    /// снята — монитор не держит `start`/`stop` и `BoxService.startCommandServer`.
    /// Порядок `close()` → `closeService()` — как §330: command.sock
    /// освобождается сразу, даже если разбор WG-узлов висит.
    private fun closeServerBounded(cs: CommandServer, reason: String) {
        val done = CountDownLatch(1)
        Thread({
            runCatching { cs.close() }
            runCatching { cs.closeService() }
            done.countDown()
        }, "lxbox-probe-close").apply { isDaemon = true }.start()
        if (done.await(CLOSE_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
            Log.d(TAG, "probe session stopped ($reason)")
        } else {
            Log.w(TAG, "probe close timed out after ${CLOSE_TIMEOUT_MS}ms ($reason), session released")
        }
    }

    // ─── CommandServerHandler (probe-инстанс) — минимальные no-op'ы ──────

    override fun serviceReload() {}

    /// Ядро может попросить остановиться. НЕ synchronized-путь напрямую:
    /// колбэк приходит из Go-потока, а монитор может держать start() —
    /// разносим на отдельный поток, чтобы не словить deadlock через JNI.
    override fun serviceStop() {
        Thread { runCatching { stop() } }.start()
    }

    override fun getSystemProxyStatus(): SystemProxyStatus = SystemProxyStatus()
    override fun setSystemProxyEnabled(isEnabled: Boolean) {}

    /// Error-метод: gomobile ловит исключение и вернёт его как Go error —
    /// до JNI Runtime::Abort не доходит (паттерн BoxService).
    override fun connectSSHAgent(): Int =
        throw UnsupportedOperationException("SSH agent not supported")

    override fun triggerNativeCrash() {}

    override fun writeDebugMessage(message: String) {
        runCatching { Log.d(TAG, "[core] $message") }
    }

    /// Платформа probe-инстанса: конфиг без tun → `openTun` не вызывается
    /// (§119-инвариант); дефолты `PlatformInterfaceWrapper` покрывают
    /// остальное. Уведомления глушим — сессия невидимая.
    private object ProbePlatform : PlatformInterfaceWrapper {
        override fun sendNotification(notification: io.nekohasekai.libbox.Notification) {}
    }

    /// Клиент без подписок — только unary urlTestOutbound (аналог PingHandler).
    private object ProbeClientHandler : CommandClientHandler {
        override fun connected() { runCatching { Log.d(TAG, "client connected") } }
        override fun disconnected(message: String) {
            runCatching { Log.d(TAG, "client disconnected: $message") }
        }
        override fun clearLogs() { runCatching { } }
        override fun setDefaultLogLevel(level: Int) { runCatching { } }
        override fun initializeClashMode(modeList: StringIterator?, currentMode: String?) {
            runCatching { }
        }
        override fun updateClashMode(newMode: String?) { runCatching { } }
        override fun writeLogs(messageList: LogIterator?) { runCatching { } }
        override fun writeStatus(message: StatusMessage?) { runCatching { } }
        override fun writeGroups(groups: OutboundGroupIterator?) { runCatching { } }
        override fun writeOutbounds(outbounds: OutboundGroupItemIterator?) { runCatching { } }
        override fun writeConnectionEvents(message: ConnectionEvents?) { runCatching { } }
        // §261 — CommandClientHandler расширен writeDNSQuery. Probe DNS не слушает.
        override fun writeDNSQuery(query: DnsQuery?) { runCatching { } }
    }
}
