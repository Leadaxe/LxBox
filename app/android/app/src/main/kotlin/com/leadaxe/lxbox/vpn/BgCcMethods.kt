package com.leadaxe.lxbox.vpn

import android.content.Context
import android.util.Log
import io.nekohasekai.libbox.Libbox
import java.io.File
import java.util.concurrent.Executors

/// Аргументы вызова `:ui` → `:bg` — карта `MethodChannel`.
internal class BgArgs(private val m: Map<*, *>?) {
    @Suppress("UNCHECKED_CAST")
    fun <T> get(key: String): T? = m?.get(key) as? T
    fun bool(key: String, def: Boolean): Boolean = m?.get(key) as? Boolean ?: def
    fun str(key: String, def: String = ""): String = m?.get(key) as? String ?: def
    fun int(key: String, def: Int): Int = (m?.get(key) as? Number)?.toInt() ?: def
    fun long(key: String, def: Long): Long = (m?.get(key) as? Number)?.toLong() ?: def
    fun strings(key: String): List<String> =
        (m?.get(key) as? List<*>)?.filterIsInstance<String>() ?: emptyList()
}

/// §747 (итерация 2) — обработчики окна, которые ходят в ядро: вызовы `cc*`
/// клиента экрана ([ScreenCoreSession]), проба без туннеля ([ProbeSession]),
/// `formatConfig` / `checkConfig` / `getCoreVersion`. До итерации 2 они
/// исполнялись в процессе окна, и окно грузило ради них `libbox.so`; теперь
/// ядро — только в `:bg`.
///
/// Тела перенесены из `VpnPlugin` без изменения формы ответа. Блокирующие
/// (gRPC к ядру, замеры) окно зовёт долгим вызовом — на своём потоке `:bg`,
/// ответ кадром канала событий; остальные — быстрым. Какой метод каким —
/// решает `VpnPlugin`; здесь любой метод просто исполняется в потоке вызова.
internal object BgCcMethods {
    private const val TAG = "BgCcMethods"

    /// Метод не из этого набора.
    val NOT_HANDLED = Any()

    private const val NO_CLIENT = "no command client"

    /// Запуски и остановки подписок: блокирующий gRPC, ответ Dart не ждёт.
    private val ioPool = Executors.newCachedThreadPool { r ->
        Thread(r, "lxbox-cc-io").apply { isDaemon = true }
    }

    private fun bg(block: () -> Unit) = ioPool.execute { runCatching(block) }

    /// Клиент экрана, создав его при необходимости (туннель `Started`, окно
    /// подключено), — для обработчиков, которые что-то запускают или читают.
    private fun ensure(): BoxCommandClient? = ScreenCoreSession.ensure()

    /// Существующий клиент — для обработчиков, которые только гасят.
    private fun current(): BoxCommandClient? = ScreenCoreSession.client

    private fun noClientError(): Map<String, String> =
        mapOf("error" to "error", "message" to NO_CLIENT)

    fun handle(ctx: Context, method: String, a: BgArgs): Any? {
        // §747 G — проба и работа с конфигом держат ядро «в деле»: процесс не
        // перезапускается ради его сброса посреди серии замеров или правок.
        if (method.startsWith("probe") || method == "formatConfig" || method == "checkConfig") {
            BoxApplication.noteCoreUse()
        }
        return dispatch(ctx, method, a)
    }

    private fun dispatch(ctx: Context, method: String, a: BgArgs): Any? = when (method) {
        // ───── потоки данных окна: подписка и отписка EventChannel ─────
        "streamListen" -> StreamSinks.listen(a.str("stream"))
        "streamCancel" -> { StreamSinks.cancel(a.str("stream")); true }

        // ───── §122 Фаза 0 — CommandClient lifecycle + императивы ─────
        // §185 — cold-start после swipe-keep: переподнять screenClient и
        // statusClient на свежий движок; профайлер — чистая остановка.
        "ccResyncForReopen" -> {
            ensure()?.apply {
                resyncForReopen()
                disconnectProfiler()
            }
            true
        }
        "ccConnectScreen" -> { ensure()?.connectScreen(); true }
        "ccDisconnectScreen" -> { current()?.disconnectScreen(); true }
        "ccConnectProfiler" -> { ensure()?.connectProfiler(); true }
        "ccDisconnectProfiler" -> { current()?.disconnectProfiler(); true }
        // §579 — подписка SubscribeTailscaleStatus: ответ сразу, данные потоком.
        "ccStartTailscaleStatus" -> {
            val cc = ensure()
            if (cc != null) bg { cc.startTailscaleStatus() }
            cc != null
        }
        "ccStopTailscaleStatus" -> {
            current()?.let { cc -> bg { cc.stopTailscaleStatus() } }
            true
        }
        // §581 — exit node на ходу и выход из аккаунта: ответ — null (успех)
        // или текст ошибки ядра.
        "ccSetTailscaleExitNode" -> {
            val cc = ensure()
            if (cc == null) NO_CLIENT else cc.setTailscaleExitNode(a.str("tag"), a.str("stable_id"))
        }
        "ccGetTailscaleStatus" -> {
            val cc = ensure()
            try {
                cc?.getTailscaleStatus(a.str("tag"))
            } catch (e: UnsupportedOperationException) {
                throw BgError("unimplemented", null)
            } catch (t: Throwable) {
                null
            }
        }
        "ccTailscaleLogout" -> {
            val cc = ensure()
            if (cc == null) NO_CLIENT else cc.tailscaleLogout(a.str("tag"))
        }
        "ccTailscaleLogin" -> {
            val cc = ensure()
            val r = if (cc == null) noClientError() else cc.tailscaleLogin(a.str("tag"), a.str("auth_key"))
            if (r != null) throw BgError(r["error"] ?: "error", r["message"])
            null
        }
        "ccStartTailscalePing" -> {
            val cc = ensure()
            val tag = a.str("tag")
            val ip = a.str("peer_ip")
            if (cc != null) bg { cc.startTailscalePing(tag, ip) }
            cc != null
        }
        "ccStopTailscalePing" -> {
            current()?.let { cc -> bg { cc.stopTailscalePing() } }
            true
        }
        "ccStartConnectionTest" -> {
            val cc = ensure()
            val link = a.str("link")
            val pkg = a.str("package_name")
            val depth = a.int("depth", 0)
            val fresh = a.bool("fresh", false)
            if (cc != null) bg { cc.startConnectionTest(link, pkg, depth, fresh) }
            cc != null
        }
        "ccStopConnectionTest" -> {
            current()?.let { cc -> bg { cc.stopConnectionTest() } }
            true
        }
        // §707 — Taildrop: входящие узла.
        "ccStartTaildropInbox" -> {
            val cc = ensure()
            val tag = a.str("tag")
            if (cc != null) bg { cc.startTaildropInbox(tag) }
            cc != null
        }
        "ccStopTaildropInbox" -> {
            current()?.let { cc -> bg { cc.stopTaildropInbox() } }
            true
        }
        "ccTaildropDelete", "ccTaildropCancelReceiving", "ccTaildropMarkRead" -> {
            val cc = ensure()
            val tag = a.str("tag")
            val name = a.str("name")
            if (cc == null) {
                NO_CLIENT
            } else {
                when (method) {
                    "ccTaildropDelete" -> cc.taildropDelete(tag, name)
                        .also { if (it == null) Taildrop.dismissReceived(ctx, tag, name) }
                    "ccTaildropCancelReceiving" -> cc.taildropCancelReceiving(tag, a.str("sender_id"), name)
                    else -> cc.taildropMarkRead(tag)
                }
            }
        }
        // §707 итер. 5 — Debug API: снимок входящих узла с sha256 файлов на
        // диске (каталог узла — из последнего собранного конфига).
        "ccTaildropInboxSnapshot" -> {
            val cc = ensure()
            val tag = a.str("tag")
            if (cc == null || tag.isEmpty()) null else taildropInboxWithHashes(cc, tag)
        }
        "ccCancelPing" -> { current()?.cancelPing(); true }
        // §164 — энергомодель: частота статус-стрима, пауза и возобновление
        // потоков, когда окно уходит в фон и возвращается.
        "ccSetStatusFast" -> { ensure()?.setStatusFast(a.bool("fast", false)); true }
        "ccPauseClients" -> {
            current()?.apply { pauseStatus(); pauseScreen() }
            true
        }
        "ccResumeClients" -> {
            ensure()?.apply { resumeStatus(); resumeScreen() }
            true
        }
        "ccUrlTestOutbound" -> {
            val cc = ensure()
            if (cc == null) mapOf("delay" to 0, "error" to "not connected")
            else cc.urlTestOutbound(a.str("tag"), a.str("link"), a.int("timeoutMs", 0))
        }
        "ccGetUrlViaOutbound" -> {
            val cc = ensure()
            if (cc == null) mapOf("error" to "not connected")
            else cc.getUrlViaOutbound(
                a.str("tag"), a.str("link"), a.int("timeoutMs", 0), a.int("maxBytes", 0),
                a.str("userAgent"),
            )
        }
        "ccUrlTestGroup" -> ensure()?.urlTestGroup(a.str("tag")) ?: false
        // §209 — null = клиент недоступен (различаем от [] = правил нет).
        "ccGetRules" -> ensure()?.getRules()
        "ccGetGroups" -> ensure()?.getGroups()
        "ccGetOutbounds" -> ensure()?.getOutbounds()
        "ccGetDnsGroups" -> ensure()?.getDnsGroups()
        "ccGetRunningConfig" -> ensure()?.getRunningConfig()
        "ccGetPool" -> ensure()?.getPool(a.str("tag"))
        "ccSelectOutbound" -> ensure()?.selectOutbound(a.str("group"), a.str("tag")) ?: false
        "ccSetEndpointEnabled" -> {
            val r = ensure()?.setEndpointEnabled(a.str("tag"), a.bool("enabled", true)) ?: noClientError()
            val err = r["error"]
            if (err != null) throw BgError(err, r["message"])
            r["state"] ?: ""
        }
        "ccGetWireGuardStatus" -> {
            val r: Map<String, Any> = ensure()?.getWireGuardStatus(a.str("tag")) ?: noClientError()
            val err = r["error"]
            if (err != null) throw BgError(err.toString(), r["message"]?.toString())
            r
        }
        "ccCloseConnection" -> ensure()?.closeConnection(a.str("id")) ?: false
        "ccCloseConnections" -> ensure()?.closeConnections() ?: false

        // ───── §236 — проба без туннеля (Test servers при выключенном VPN) ─────
        // Гейт «VPN не запущен» — внутри ProbeSession. §669 — probeStart отдаёт
        // {error, runId}; остальные несут runId владельца прогона.
        "probeStart" -> ProbeSession.start(a.str("config"))
        "probeUrlTest" -> ProbeSession.urlTest(
            a.long("runId", 0L), a.str("tag"), a.str("link"), a.int("timeoutMs", 0),
        )
        "probeGetUrl" -> ProbeSession.getUrl(
            a.long("runId", 0L), a.str("tag"), a.str("link"), a.int("timeoutMs", 0),
            a.int("maxBytes", 0), a.str("userAgent"),
        )
        "probeCancel" -> { runCatching { ProbeSession.cancel(a.long("runId", 0L)) }; null }
        "probeStop" -> { runCatching { ProbeSession.stop(a.long("runId", 0L)) }; null }

        // ───── ядро без туннеля: версия, форматирование и проверка конфига ─────
        "getCoreVersion" -> coreVersion(ctx)
        // §324 — каноническая форма конфига (`Libbox.formatConfig`); null — не
        // удалось (пустой текст, ядро не разобрало).
        "formatConfig" -> {
            val text = a.str("config")
            if (text.isBlank()) {
                null
            } else {
                try {
                    BoxApplication.ensureLibbox()
                    Libbox.formatConfig(text)?.value
                } catch (t: Throwable) {
                    Log.d(TAG, "formatConfig failed: ${t.message}")
                    null
                }
            }
        }
        // §455 — проверка тела узла ядром: `Libbox.checkConfig()` = parse + create.
        "checkConfig" -> try {
            BoxApplication.ensureLibbox()
            Libbox.checkConfig(a.str("config"))
            mapOf("ok" to true)
        } catch (t: Throwable) {
            Log.d(TAG, "checkConfig rejected: ${t.message}")
            mapOf("ok" to false, "error" to (t.message ?: t.toString()))
        }

        else -> NOT_HANDLED
    }

    /// Версия ядра (`Libbox.version()`, вида "1.13.11"). Запоминается на
    /// установленную сборку приложения: экран «О программе» и сборщик конфига
    /// спрашивают её и без туннеля, а грузить ради строки ядро в свежий `:bg`
    /// незачем. Ядро уже загружено — берётся у него.
    private fun coreVersion(ctx: Context): String {
        val stamp = runCatching {
            ctx.packageManager.getPackageInfo(ctx.packageName, 0).lastUpdateTime
        }.getOrDefault(0L)
        if (!BoxApplication.libboxLoaded) {
            NativeCache.coreVersion(ctx, stamp)?.let { return it }
        }
        return try {
            BoxApplication.ensureLibbox()
            Libbox.version().also { NativeCache.setCoreVersion(ctx, stamp, it) }
        } catch (t: Throwable) {
            Log.e(TAG, "getCoreVersion failed", t)
            ""
        }
    }

    /// §707 итер. 5 — снимок входящих [tag] (форма потока вкладки Network) +
    /// `sha256` у каждого принятого файла (пусто — файла на диске нет или
    /// каталог узла неизвестен).
    private fun taildropInboxWithHashes(cc: BoxCommandClient, tag: String): Map<String, Any>? {
        val snap = cc.taildropInboxOnce(tag, 3000L) ?: return null
        val dir = Taildrop.taildropDirectories(ConfigManager.load()).firstOrNull { it.first == tag }?.second
        @Suppress("UNCHECKED_CAST")
        val files = (snap["files"] as? List<Map<String, Any>>).orEmpty().map { f ->
            val name = f["name"] as? String ?: ""
            val hash = if (dir == null || name.isEmpty()) "" else sha256Hex(File(dir, name))
            f + ("sha256" to hash)
        }
        return snap + ("files" to files)
    }

    private fun sha256Hex(f: File): String = runCatching {
        if (!f.isFile) return ""
        val md = java.security.MessageDigest.getInstance("SHA-256")
        f.inputStream().use { input ->
            val buf = ByteArray(64 * 1024)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                md.update(buf, 0, n)
            }
        }
        md.digest().joinToString("") { "%02x".format(it) }
    }.getOrDefault("")
}
