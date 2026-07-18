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

    private val server = AtomicReference<CommandServer?>(null)
    private val client = AtomicReference<CommandClient?>(null)

    /// §237-fix — `LocalResolver` отвечает SERVFAIL, пока
    /// `DefaultNetworkMonitor.defaultNetwork == null`, а монитор поднимает
    /// только боевой VPN-flow. Probe-сессия стартует его сама (и гасит только
    /// свой — если к моменту stop VPN уже жив, монитор принадлежит ему).
    private var probeScope: CoroutineScope? = null
    private var monitorOwned = false

    val active: Boolean get() = server.get() != null

    /// Запуск сессии с готовым probe-конфигом (без inbound'ов). Возвращает ''
    /// при успехе, иначе текст ошибки. Повторный вызов поверх живой сессии —
    /// рестарт (старая закрывается).
    @Synchronized
    fun start(config: String): String {
        if (BoxService.commandClient != null) {
            return "VPN is running — test uses the live tunnel instead"
        }
        stopInternal()
        return runCatching {
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            probeScope = scope
            // Без монитора local-DNS (§049 F26) мертв → каждый lookup из
            // probe-конфига падал SERVFAIL (device-репро 04.07.2026).
            runBlocking { DefaultNetworkMonitor.start(scope) { } }
            monitorOwned = true
            val cs = CommandServer(this, ProbePlatform)
            cs.start()
            server.set(cs)
            cs.startOrReloadService(config, OverrideOptions())
            val cl = CommandClient(ProbeClientHandler, CommandClientOptions())
            cl.connect()
            client.set(cl)
            Log.d(TAG, "probe session started")
            ""
        }.getOrElse {
            Log.e(TAG, "probe start failed", it)
            stopInternal()
            it.message ?: "probe start failed"
        }
    }

    /// Синхронный тест одной ноды (SPEC 014, Variant B: провал — в `error`
    /// результата, не в исключении). Конкурентные вызовы допустимы — unary
    /// gRPC мультиплексируется на одном клиенте (как pingClient §209).
    fun urlTest(tag: String, link: String, timeoutMs: Int): Map<String, Any> {
        val cl = client.get()
            ?: return mapOf("delay" to 0, "error" to "probe session not running")
        return runCatching {
            val r = cl.urlTestOutbound(tag, link, timeoutMs)
            mapOf("delay" to r.delay, "error" to (r.error ?: ""))
        }.getOrElse {
            mapOf("delay" to 0, "error" to (it.message ?: "urlTestOutbound failed"))
        }
    }

    /// §284 — сырая проба WARP-endpoint по IP (WG-handshake / QUIC-h3 / TLS-h2).
    /// Variant B: провал — в `error` результата, не в исключении. Требует
    /// активной probe-сессии (headless ядро поднято через [start]).
    ///
    /// ВНИМАНИЕ: реальный вызов `client.warpProbe(...)` появится только в libbox
    /// с kernel SPEC 028 (≥ v1.14.0-lx.10). До re-pin `libbox.version` символа
    /// в .aar нет → Kotlin не скомпилировался бы с прямым вызовом, поэтому пока
    /// graceful-заглушка: Dart/UI показывают «probe unavailable», скан живой.
    /// TODO(§284): после re-pin на .aar с WarpProbe — заменить тело на реальный
    /// вызов (шаблон в комментарии ниже).
    fun warpProbe(args: Map<String, Any?>): Map<String, Any> {
        if (client.get() == null) {
            return mapOf(
                "alive" to false, "rttMs" to 0, "error" to "probe session not running",
            )
        }
        // return runCatching {
        //     val ip = args["ip"] as? String ?: ""
        //     val port = (args["port"] as? Number)?.toInt() ?: 0
        //     val protocol = (args["protocol"] as? Number)?.toInt() ?: 0
        //     val sni = args["sni"] as? String ?: ""
        //     val utlsFp = args["utlsFp"] as? String ?: ""
        //     val timeoutMs = (args["timeoutMs"] as? Number)?.toInt() ?: 0
        //     val reserved = (args["reserved"] as? List<*>)
        //         ?.map { (it as Number).toByte() }?.toByteArray() ?: ByteArray(0)
        //     val r = client.get()!!.warpProbe(ip, port, protocol, sni, utlsFp, timeoutMs, reserved)
        //     mapOf("alive" to r.alive, "rttMs" to r.rttMs, "error" to (r.error ?: ""))
        // }.getOrElse {
        //     mapOf("alive" to false, "rttMs" to 0, "error" to (it.message ?: "warpProbe failed"))
        // }
        return mapOf("alive" to false, "rttMs" to 0, "error" to "probe unavailable")
    }

    @Synchronized
    fun stop() = stopInternal()

    private fun stopInternal() {
        client.getAndSet(null)?.let { runCatching { it.disconnect() } }
        server.getAndSet(null)?.let {
            runCatching { it.closeService() }
            runCatching { it.close() }
            Log.d(TAG, "probe session stopped")
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
