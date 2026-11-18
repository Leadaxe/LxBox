package com.leadaxe.lxbox.vpn

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.VpnService
import android.os.Build
import android.os.SystemClock
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class VpnPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
    PluginRegistry.ActivityResultListener {

    companion object {
        private const val TAG = "VpnPlugin"
        private const val METHOD_CHANNEL = "com.leadaxe.lxbox/methods"
        private const val STATUS_CHANNEL = "com.leadaxe.lxbox/status_events"
        private const val CORE_LOG_CHANNEL = "lxbox/coreLog"   // §043
        // §122 Фаза 0 — каналы CommandClient.
        private const val CC_STATUS_CHANNEL = "lxbox/cc/status"
        private const val CC_OUTBOUNDS_CHANNEL = "lxbox/cc/outbounds"
        private const val CC_GROUPS_CHANNEL = "lxbox/cc/groups"
        private const val CC_CONNECTIONS_CHANNEL = "lxbox/cc/connections"
        private const val CC_DNS_CHANNEL = "lxbox/cc/dns" // §180
        private const val CC_TAILSCALE_CHANNEL = "lxbox/cc/tailscale" // §579
        private const val CC_TAILSCALE_PING_CHANNEL = "lxbox/cc/tailscale_ping" // §581
        private const val CC_CONNECTION_TEST_CHANNEL = "lxbox/cc/connection_test" // §687
        private const val CC_OPENCONNECT_CHANNEL = "lxbox/cc/openconnect" // §654
        private const val CC_TAILDROP_INBOX_CHANNEL = "lxbox/cc/taildrop_inbox" // §707

        /// §747 — потоки данных из `:bg`: лог ядра и потоки клиентов ядра.
        /// Имя потока в канале событий — имя `EventChannel`.
        private val STREAM_CHANNELS = listOf(
            CORE_LOG_CHANNEL, CC_STATUS_CHANNEL, CC_OUTBOUNDS_CHANNEL, CC_GROUPS_CHANNEL,
            CC_CONNECTIONS_CHANNEL, CC_DNS_CHANNEL, CC_TAILSCALE_CHANNEL,
            CC_TAILSCALE_PING_CHANNEL, CC_CONNECTION_TEST_CHANNEL, CC_OPENCONNECT_CHANNEL,
            CC_TAILDROP_INBOX_CHANNEL,
        )
        private const val TAILDROP_PICK_CODE = 25 // §707
        private const val TAILDROP_SAVE_CODE = 26 // §707
        private const val VPN_REQUEST_CODE = 24

        /// §747 — методы Dart, которые `:bg` вправе вызвать с ответом
        /// (`UiCalls`): шлюз ассистента §750.
        private val REVERSE_METHODS = setOf("assistantCall")

        /// §747 — повторы подключения к `:bg`, если он не ответил.
        private const val ATTACH_RETRIES = 6
        private const val ATTACH_RETRY_MS = 500L
        private const val ATTACH_RETRY_MAX_MS = 8_000L

        /// §747 — Binder-метка живого процесса окна: `:bg` вешает на неё
        /// `linkToDeath`. Одна на процесс.
        private val uiToken = android.os.Binder()
    }

    private lateinit var methodChannel: MethodChannel
    private lateinit var statusEventChannel: EventChannel
    /// §707 — ждущий выбор файлов «Send file…» (тег, пир, имя пира, ответ).
    private var pendingTaildropPick: Pair<Triple<String, String, String>, MethodChannel.Result>? = null
    /// §707 — ждущий «Сохранить как» (API 24–28): тег, имя файла, ответ.
    private var pendingTaildropSave: Triple<String, String, MethodChannel.Result>? = null
    private lateinit var context: Context
    private var activity: Activity? = null
    private var statusSink: EventChannel.EventSink? = null
    private var pendingVpnResult: MethodChannel.Result? = null
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    /// Scope для suspend-обработчиков method channel — сейчас нужен только
    /// для stopVPN (async wait на setStatus(Stopped)), но переиспользуем
    /// для любых будущих awaitable операций. Отменяется в onDetachedFromEngine.
    private val pluginScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    /// 693 итер. 3: кодирование иконок (отрисовка + PNG + base64) — не больше
    /// 4 одновременно. Вкладка Tunnel apps и пикер просят иконки пачкой;
    /// без предела десятки битмапов рисуются разом на общем IO-пуле.
    /// getInstalledApps / getAppInfo идут на Dispatchers.IO и в эту очередь
    /// не встают.
    @OptIn(ExperimentalCoroutinesApi::class)
    private val appIconDispatcher = Dispatchers.IO.limitedParallelism(4)

    private val statusReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) {
            if (intent?.action != BoxVpnService.BROADCAST_STATUS) return
            val name = intent.getStringExtra(BoxVpnService.EXTRA_STATUS) ?: return
            val error = intent.getStringExtra("error")
            // §276 — признак перехвата слота чужим VPN (едет рядом со Stopped).
            val revoked = intent.getBooleanExtra(BoxVpnService.EXTRA_REVOKED, false)
            // Фича 478 / Д-1 — сырой текст ядра без обёрток приложения.
            val coreError = intent.getStringExtra(BoxVpnService.EXTRA_CORE_ERROR)
            Log.d(TAG, "[vpn] plugin.statusReceiver.onReceive name=$name${if (error != null) " error=$error" else ""}${if (revoked) " revoked=true" else ""} sink=${statusSink != null}")
            // §747 — копия состояния туннеля в окне: её пишут только этот
            // приёмник и запрос снимка. Клиент ядра экрана живёт в `:bg`.
            BgEvents.wireOf(intent)?.let { applyTunnelWire(it) }
            mainHandler.post {
                val event = mutableMapOf<String, Any>("status" to name)
                if (error != null) event["error"] = error
                if (revoked) event[BoxVpnService.EXTRA_REVOKED] = true
                if (!coreError.isNullOrEmpty()) {
                    event[BoxVpnService.EXTRA_CORE_ERROR] = coreError
                }
                // §155 — sink может указывать на мёртвый Dart-engine (process
                // killed / engine detached между post и доставкой). success()
                // тогда бросает DeadObjectException на main thread → краш всего
                // приложения. Глотаем: статус всё равно пере-эмитится при
                // следующем onListen после реконнекта.
                runCatching { statusSink?.success(event) }
                    .onFailure { Log.w(TAG, "[vpn] statusSink.success failed: $it") }
            }
        }
    }

    /// Движок подключён (между onAttachedToEngine и onDetachedFromEngine).
    private var attached = false

    /// Метка запуска `:bg` из последнего принятого снимка: смена — процесс
    /// `:bg` перезапущен.
    private var bgEpoch: Long? = null

    /// Идёт подключение к `:bg` ([attachToBg]): второе не начинается.
    private var attaching = false

    /// Пока шло подключение, процесс `:bg` снова сменился: повторить.
    private var reattachNeeded = false

    /// Подряд неудавшихся подключений (`:bg` не ответил).
    private var attachFailures = 0

    /// §747 — подписи уведомления, которые Dart передал `:bg` (метод → его
    /// аргументы): `:bg` держит их в памяти, и после его перезапуска окно
    /// передаёт их заново.
    private val notificationLabels = LinkedHashMap<String, Map<String, Any?>?>()

    /// §747 — потоки данных, которые Dart сейчас слушает (имя `EventChannel`).
    /// Главный поток.
    private val listening = HashSet<String>()

    /// Каналы потоков данных: нужны только ради onListen / onCancel — сами
    /// события уходят в [messenger] готовыми конвертами из `:bg`.
    private val streamChannels = ArrayList<EventChannel>()

    private var messenger: io.flutter.plugin.common.BinaryMessenger? = null

    // -------------------------------------------------------------------------
    // FlutterPlugin
    // -------------------------------------------------------------------------

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        Log.d(TAG, "onAttachedToEngine")
        context = binding.applicationContext
        attached = true
        BoxApplication.initialize(context)

        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
        methodChannel.setMethodCallHandler(this)
        // §047 — статические bridge-ссылки для LxBoxIntentReceiver.
        AutomationBridge.bridgeChannel = methodChannel
        AutomationBridge.appContext = context

        statusEventChannel = EventChannel(binding.binaryMessenger, STATUS_CHANNEL)
        statusEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                Log.d(TAG, "[vpn] statusEventChannel.onListen — sink installed")
                statusSink = sink
            }
            override fun onCancel(args: Any?) {
                Log.d(TAG, "[vpn] statusEventChannel.onCancel — sink cleared")
                statusSink = null
            }
        })

        // §747 — потоки данных окна (лог ядра §043, потоки клиентов ядра §122)
        // рождаются в `:bg` и приходят каналом событий (pipe) готовыми
        // конвертами `EventChannel`: окно отдаёт их в свой канал того же имени,
        // не декодируя. Каналы здесь — ради onListen / onCancel: подписка и
        // отписка Dart уходят в `:bg`, и ядро не шлёт то, что никто не читает.
        messenger = binding.binaryMessenger
        // Строки журнала от стороны окна (повтор вызова после гибели `:bg`) —
        // тем же потоком `lxbox/coreLog`, что строки сервиса.
        BgClient.journal = { line ->
            val payload = BgCodec.encodeEventEnvelope(listOf(line))
            mainHandler.post { onFrame(CORE_LOG_CHANNEL, payload) }
        }
        for (name in STREAM_CHANNELS) {
            val channel = EventChannel(binding.binaryMessenger, name)
            channel.setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink?) = streamListen(name)
                override fun onCancel(args: Any?) = streamCancel(name)
            })
            streamChannels.add(channel)
        }

        Log.d(TAG, "[vpn] onAttachedToEngine: registerReceiver(statusReceiver)")
        // §155 — на отдельных OEM-прошивках registerReceiver может бросить
        // (например при гонке с фоновыми ограничениями) → краш прямо в
        // onAttachedToEngine, до того как плагин готов. Симметрично к
        // runCatching на unregisterReceiver в onDetachedFromEngine.
        runCatching {
            context.registerReceiver(
                statusReceiver,
                IntentFilter(BoxVpnService.BROADCAST_STATUS),
                Context.RECEIVER_NOT_EXPORTED
            )
        }.onFailure { Log.e(TAG, "[vpn] registerReceiver(statusReceiver) failed: $it") }
        attachToBg()
    }

    private fun streamListen(name: String) {
        listening.add(name)
        val ctx = context
        BgClient.onLane { BgClient.callOr(ctx, "streamListen", mapOf("stream" to name), false) }
    }

    private fun streamCancel(name: String) {
        listening.remove(name)
        val ctx = context
        BgClient.onLane { BgClient.callOr(ctx, "streamCancel", mapOf("stream" to name), false) }
    }

    /// §747 — открыть канал событий и назвать себя `:bg` (Binder-метка: `:bg`
    /// узнает и о гибели процесса окна), затем забрать снимок состояния
    /// туннеля (broadcast не липкий — окно, открытое при работающем туннеле,
    /// иначе видело бы `Stopped`).
    ///
    /// Зовётся при подключении движка и всякий раз, когда процесс `:bg`
    /// оказался другим: оборвался канал событий (`:bg` перезапустился, чтобы
    /// сбросить ядро после остановки туннеля, или умер) либо в снимке новая
    /// метка запуска. Новый процесс ничего не знает об окне, поэтому ему
    /// заново передаётся всё, что `:bg` держит в памяти от окна: слушаемые
    /// потоки данных и подписи уведомления. Dart этого не замечает.
    private fun attachToBg() {
        if (attaching) {
            // Подключение уже идёт, а процесс `:bg` снова оказался другим
            // (канал оборвался, пока мы подключались): по окончании повторить,
            // иначе окно осталось бы без потоков данных до следующей смены
            // процесса.
            reattachNeeded = true
            return
        }
        attaching = true
        reattachNeeded = false
        val ctx = context
        val streams = listening.toList()
        val labels = notificationLabels.toMap()
        BgClient.onLane {
            val connected = BgClient.connect(
                ctx, uiToken,
                onFrame = { stream, payload -> onFrame(stream, payload) },
                onLost = { onBgLost() },
            )
            var wire: TunnelState.Wire? = null
            if (connected) {
                for (name in streams) {
                    BgClient.callOr(ctx, "streamListen", mapOf("stream" to name), false)
                }
                for ((method, args) in labels) BgClient.callOr(ctx, method, args, true)
                wire = fetchTunnelWire()
            }
            BgClient.onMain { attachFinished(connected, wire) }
        }
    }

    /// Главный поток. Итог подключения к `:bg`: принять снимок; если процесс
    /// за время подключения сменился или `:bg` не ответил — подключиться
    /// снова (при отказе — с растущей паузой и не бесконечно).
    private fun attachFinished(connected: Boolean, wire: TunnelState.Wire?) {
        attaching = false
        if (!attached) return
        val ok = connected && wire != null
        if (wire != null) {
            // Метка запуска процесса, к которому подключились. Если по
            // broadcast'у уже видели метку новее — подключились к прежнему.
            val seen = bgEpoch
            if (seen != null && seen > wire.epoch) reattachNeeded = true
            applyTunnelWire(wire)
        }
        when {
            reattachNeeded -> attachToBg()
            !ok -> {
                attachFailures++
                if (attachFailures > ATTACH_RETRIES) {
                    Log.e(TAG, "[bg] cannot attach to the service process — giving up after $ATTACH_RETRIES retries")
                    return
                }
                val delay = (ATTACH_RETRY_MS shl (attachFailures - 1)).coerceAtMost(ATTACH_RETRY_MAX_MS)
                Log.w(TAG, "[bg] attach failed (connected=$connected) — retry $attachFailures in ${delay}ms")
                mainHandler.postDelayed({ if (attached && !attaching) attachToBg() }, delay)
            }
            else -> attachFailures = 0
        }
    }

    /// Главный поток. Канал событий оборвался, а движок подключён: процесс
    /// `:bg` ушёл — подключиться к новому.
    private fun onBgLost() {
        if (!attached) return
        Log.i(TAG, "[bg] event channel ended — re-attaching to the service process")
        attachToBg()
    }

    /// Главный поток. Кадр канала событий: поток Dart — готовый конверт события
    /// его `EventChannel` — уходит в движок как есть; служебный кадр
    /// автоматизации (команда нативного входа или «нативный Stop» из `:bg`) —
    /// в `AutomationBridge`.
    private fun onFrame(stream: String, payload: ByteArray) {
        if (stream == EventFrames.CALL) {
            reverseCall(payload)
            return
        }
        if (stream == EventFrames.AUTOMATION) {
            val m = runCatching { BgCodec.decode(payload) as? Map<*, *> }.getOrNull() ?: return
            val name = m["name"] as? String ?: return
            val args = (m["args"] as? Map<*, *>).orEmpty().entries
                .associate { (k, v) -> k.toString() to v }
            AutomationBridge.handleAutomationAction(name, args)
            return
        }
        if (stream !in listening) return
        val out = messenger ?: return
        // Движок ждёт direct-буфер с позицией в конце данных (как у EventChannel).
        // §155 — движок может быть уже мёртв: глотаем.
        runCatching {
            out.send(stream, java.nio.ByteBuffer.allocateDirect(payload.size).apply { put(payload) })
        }
    }

    /// Главный поток. §747/§750 — обратный вызов `:bg` → Dart с ответом
    /// (`UiCalls`): подтвердить получение (окно живо и не заморожено),
    /// исполнить метод на канале плагина и вернуть итог по номеру. Методы —
    /// только из [REVERSE_METHODS]. Аргументы и ответ в лог не пишутся.
    private fun reverseCall(payload: ByteArray) {
        val m = runCatching { BgCodec.decode(payload) as? Map<*, *> }.getOrNull() ?: return
        val id = (m["id"] as? Number)?.toLong() ?: return
        val method = m["method"] as? String ?: return
        val ctx = context
        fun reply(kind: String, value: Any? = null, code: String? = null, message: String? = null) {
            BgClient.onLane {
                BgClient.callOr(
                    ctx, "uiCallReply",
                    mapOf("id" to id, "kind" to kind, "value" to value, "code" to code, "message" to message),
                    false,
                )
            }
        }
        BgClient.onLane { BgClient.callOr(ctx, "uiCallAck", mapOf("id" to id), false) }
        if (method !in REVERSE_METHODS) {
            reply("missing")
            return
        }
        runCatching {
            methodChannel.invokeMethod(method, m["args"], object : MethodChannel.Result {
                override fun success(result: Any?) = reply("ok", value = result)
                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) =
                    reply("error", code = errorCode, message = errorMessage)
                override fun notImplemented() = reply("missing")
            })
        }.onFailure {
            Log.w(TAG, "[bg] reverse call $method failed: ${it.javaClass.simpleName}")
            reply("missing")
        }
    }

    /// Снимок состояния туннеля из `:bg`; null — вызов не удался. Блокирует.
    private fun fetchTunnelWire(): TunnelState.Wire? = runCatching {
        (BgClient.call(context, "tunnelSnapshot") as? Map<*, *>)?.let { BgEvents.wireOf(it) }
    }.getOrNull()

    /// Главный поток. Принять снимок в копию состояния окна. Метка запуска
    /// `:bg` новее виденной — процесс новый: он не знает ни об окне, ни о его
    /// подписках, нужно подключиться заново. Снимок со старой меткой
    /// (запоздавший broadcast прежнего процесса) копия отбрасывает, и
    /// переподключения он не вызывает — оно оборвало бы идущие долгие вызовы.
    private fun applyTunnelWire(w: TunnelState.Wire) {
        val accepted = TunnelState.acceptMirror(w)
        val prev = bgEpoch
        if (prev == null || w.epoch > prev) bgEpoch = w.epoch
        if (accepted && prev != null && w.epoch > prev && !attaching) {
            Log.i(TAG, "[bg] service process restarted — re-attaching")
            attachToBg()
        }
    }

    /// §747 — переслать вызов Dart в `:bg` под тем же именем (`BgMethods`).
    private fun toBg(call: MethodCall, result: MethodChannel.Result, long: Boolean = false) =
        BgClient.forward(context, call.method, call.arguments, result, long)

    private fun mimeOfName(name: String): String {
        val ext = name.substringAfterLast('.', "").lowercase(java.util.Locale.ROOT)
        return android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
            ?: "application/octet-stream"
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        Log.d(TAG, "[vpn] onDetachedFromEngine: unregisterReceiver(statusReceiver)")
        attached = false
        attaching = false
        BgClient.journal = null
        methodChannel.setMethodCallHandler(null)
        statusEventChannel.setStreamHandler(null)
        for (channel in streamChannels) channel.setStreamHandler(null)
        streamChannels.clear()
        listening.clear()
        messenger = null
        statusSink = null
        // §047 — обнуляем bridge-ссылки (engine detached).
        AutomationBridge.bridgeChannel = null
        AutomationBridge.appContext = null
        runCatching { context.unregisterReceiver(statusReceiver) }
        // §747 — канал событий закрыт; `:bg` узнаёт, что окна больше нет
        // («окно закрыто»): он снимает потоки данных, закрывает клиента экрана
        // и больше не держит процесс ради окна.
        BgClient.disconnect()
        val ctx = context
        BgClient.onLane { BgClient.callOr(ctx, "uiDetached", null, true) }
        pluginScope.cancel()
    }

    // -------------------------------------------------------------------------
    // MethodCallHandler
    // -------------------------------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        Log.d(TAG, "onMethodCall: ${call.method}")
        if (call.method == "setNotificationTitle" || call.method == "setNotificationText") {
            @Suppress("UNCHECKED_CAST")
            notificationLabels[call.method] = call.arguments as? Map<String, Any?>
        }
        when (call.method) {
            // §747 — обработчики, которым нужна сервисная сторона (файлы
            // настроек, состояние туннеля, ядро и его клиенты, проба, Taildrop):
            // тело — в `BgMethods` / `BgCcMethods`, здесь пересылка под тем же
            // именем. Форма ответа прежняя. Окно ядро не грузит вовсе.
            // Быстрые — синхронным вызовом на упорядоченной полосе.
            "forceStopVPN", "getTunnelUptimeMs", "isForeignVpnActive", "reloadVPN", "resetNetwork",
            "setQuicKnob", "clearDnsCache", "setNotificationTitle", "setNotificationText",
            "setAutoStart", "getAutoStart", "setKeepOnExit", "getKeepOnExit",
            "setNotificationStop", "getNotificationStop", "setNotificationRestart",
            "getNotificationRestart", "setNotificationSend", "getNotificationSend",
            "setCoreLogsEnabled", "getCoreLogsEnabled", "setCoreLogsVerbose", "getCoreLogsVerbose",
            "setAllowBypass", "getAllowBypass", "setAutoRedirect", "getAutoRedirect", "setHasTun",
            "getCurrentSessionAllowBypass", "startVpnHeadless", "getBackgroundMode",
            "setBackgroundMode", "getMemoryLimit", "setMemoryLimit", "getAppLanguageState",
            "setAutomationEnabled", "setAppFunctionsEnabled", "setAutomationActiveState",
            "taildropServiceStats", "taildropBuildServiceFile", "taildropClipState",
            "setTaildropTags", "deleteLegacyPrefs", "ccGetOpenConnectStatus",
            "ccStopOpenConnectCallback", "setAppLanguage", "ccCancelPing", "ccConnectProfiler",
            "ccConnectScreen", "ccDisconnectProfiler", "ccDisconnectScreen", "ccPauseClients",
            "ccResumeClients", "ccResyncForReopen", "ccSetStatusFast", "ccStartConnectionTest",
            "ccStartTaildropInbox", "ccStartTailscalePing", "ccStartTailscaleStatus",
            "ccStopConnectionTest", "ccStopTaildropInbox", "ccStopTailscalePing",
            "ccStopTailscaleStatus" -> toBg(call, result)
            // Долгие (остановка туннеля, блокирующий gRPC к ядру, замеры, проба,
            // проверка конфига, профиль, отправка) — запуск той же полосой,
            // исполнение на своём потоке `:bg`, ответ кадром канала событий:
            // сотня параллельных замеров не занимает пул Binder.
            "stopVPN", "getMemoryInfo", "ccSubmitOpenConnectForm", "ccCancelOpenConnectChallenge",
            "ccStartOpenConnectCallback", "ccCloseConnection", "ccCloseConnections",
            "ccGetDnsGroups", "ccGetGroups", "ccGetOutbounds", "ccGetPool", "ccGetRules",
            "ccGetRunningConfig", "ccGetTailscaleStatus", "ccGetUrlViaOutbound",
            "ccGetWireGuardStatus", "ccSelectOutbound", "ccSetEndpointEnabled",
            "ccSetTailscaleExitNode", "ccTaildropCancelReceiving", "ccTaildropDelete",
            "ccTaildropInboxSnapshot", "ccTaildropMarkRead", "ccTaildropSendBytes",
            "ccTailscaleLogin", "ccTailscaleLogout", "ccUrlTestGroup", "ccUrlTestOutbound",
            "checkConfig", "formatConfig", "getCoreVersion", "pprofProfile", "probeCancel",
            "probeGetUrl", "probeStart", "probeStop", "probeUrlTest",
            // §750 — операции ассистента (Debug API): исполняет `:bg`.
            "assistantOverview", "assistantListExits", "assistantCheckUrl", "assistantCheckExit",
            "assistantFindApps", "assistantAppRoute", "assistantSelectExit" -> toBg(call, result, long = true)
            // §747 — конфиг бывает больше предела Binder: файл пишет и читает само
            // окно (запись атомарная), а сервису уходит «конфиг сохранён» — он
            // сбрасывает кэш. Запись и вызов — на полосе: следующий за ними
            // `startVPN` / `reloadVPN` увидит уже новый файл.
            "saveConfig" -> {
                val config = call.argument<String>("config") ?: ""
                BgClient.onLane {
                    val ok = ConfigFile.write(context, config) != null
                    if (ok) BgClient.callOr(context, "configSaved", null, true)
                    BgClient.onMain { result.success(ok) }
                }
            }
            "getConfig" -> BgClient.onLane {
                val text = ConfigFile.read(context) ?: "{}"
                BgClient.onMain { result.success(text) }
            }
            // §316 — РЕАЛЬНЫЙ `Context.filesDir`, куда ядро пишет краш-репорты
            // и stderr. НЕ равен Dart-овскому `getApplicationDocumentsDirectory()`
            // (у Flutter это `app_flutter`, у native — `files`): из-за этой
            // подмены §038-канал stderr и краш-репорты ядра были недостижимы.
            "getFilesDir" -> result.success(context.filesDir.path)
            "startVPN" -> startVpn(result)
            "getVpnStatus" -> {
                // Pull-метод для re-sync UI после reattach Flutter-процесса
                // (broadcast'ятся только переходы — если service уже Started,
                // новый плагин ничего не получит без явного запроса).
                // §276 — map вместо голой строки: иначе UI, вернувшийся из фона
                // после перехвата слота, потеряет revoked и покажет нейтральный
                // Disconnected вместо «Taken by another VPN».
                // §747 — правду знает `:bg`: снимок берётся вызовом, заодно
                // обновляет копию состояния в окне (и клиента ядра по ней).
                // Вызов не удался — отвечаем по копии.
                BgClient.onLane {
                    val wire = fetchTunnelWire()
                    BgClient.onMain {
                        if (wire != null) applyTunnelWire(wire)
                        val st = wire?.snapshot ?: TunnelState.snapshot
                        result.success(
                            mapOf(
                                "status" to st.status.name,
                                BoxVpnService.EXTRA_REVOKED to st.revoked,
                            )
                        )
                    }
                }
            }
            "quitApp" -> {
                // §043 follow-up: завершить приложение целиком, чтобы следующий
                // запуск пересоздал libbox с новым флагом `debug` (setup зовётся
                // один раз за жизнь процесса).
                //
                // §747 — процессов два. Сервисная половина (`BgMethods.quitApp`):
                // снять признак «VPN желателен» и будильник сторожа (§638),
                // остановить сервис штатным путём и дождаться Stopped не дольше
                // бюджета (§639: иначе уведомление id=1 висит в шторке), затем
                // завершить `:bg`. Здесь: закрыть activities и завершить `:ui`
                // (не раньше прежних 250 мс; некоторые OEM-launchers иначе
                // оставляют zombie). Вызов идёт полосой — записи настроек,
                // отправленные раньше, дойдут до `:bg` до его завершения.
                result.success(true)
                val quitStartedAt = SystemClock.elapsedRealtime()
                val ctx = context
                BgClient.onLane {
                    // Окно закрывается только после подтверждения `:bg`, что
                    // «VPN желателен» и сторож сняты: если вызов не прошёл,
                    // закрыться и убить себя значило бы оставить сторожу
                    // повод поднять VPN. Тогда окно остаётся открытым.
                    val prepared = runCatching { BgClient.call(ctx, "quitPrepare") }
                        .onFailure { Log.e(TAG, "[vpn] quitApp: the service side did not confirm — not quitting: ${it.message}") }
                        .isSuccess
                    if (!prepared) return@onLane
                    mainHandler.post { activity?.finishAffinity() }
                    BgClient.callOr(ctx, "quitApp", null, false)
                    // `:bg` завершается; новых вызовов не делаем.
                    BgClient.shutDown()
                    val elapsed = SystemClock.elapsedRealtime() - quitStartedAt
                    mainHandler.postDelayed({
                        android.os.Process.killProcess(android.os.Process.myPid())
                        kotlin.system.exitProcess(0)
                    }, (250L - elapsed).coerceAtLeast(0L))
                }
            }
            "getInstalledApps" -> {
                // Lightweight metadata only — иконки лениво подгружаются
                // через getAppIcon по пакету. PNG-encode всех иконок в одном
                // проходе — 500*20ms = 10s блокировки UI, недопустимо.
                // 693 итер. 2: обход PackageManager и getApplicationLabel — на
                // Dispatchers.IO, ответ — на главном. На сотнях приложений это
                // секунды; на главном потоке за ними вставали все getAppIcon
                // (таймауты 5 с) и грозил ANR.
                val pm = context.packageManager
                pluginScope.launch {
                    val apps = try {
                        withContext(Dispatchers.IO) {
                            pm.getInstalledApplications(0).map { info ->
                                val isSystem = (info.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0
                                mapOf(
                                    "packageName" to info.packageName,
                                    "appName" to (pm.getApplicationLabel(info)?.toString() ?: info.packageName),
                                    "isSystemApp" to isSystem,
                                    // Общий UID (sharedUserId) — ядро и VpnService
                                    // различают приложения по UID, не по пакету.
                                    "uid" to info.uid,
                                )
                            }
                        }
                    } catch (e: Throwable) {
                        Log.w(TAG, "getInstalledApps failed", e)
                        null
                    }
                    if (apps != null) {
                        result.success(apps)
                    } else {
                        result.error("INSTALLED_APPS_ERROR", "getInstalledApps failed", null)
                    }
                }
            }
            "getAppIcon" -> {
                val pkg = call.argument<String>("packageName") ?: ""
                // 693 итер. 2: отрисовка + PNG + base64 — вне главного потока;
                // итер. 3: не больше 4 иконок одновременно (appIconDispatcher).
                pluginScope.launch {
                    val icon = withContext(appIconDispatcher) { encodeAppIcon(pkg) }
                    result.success(icon)
                }
            }
            "getAppInfo" -> {
                // §109: metadata-only — иконку НЕ тащим (PNG-encode на main
                // thread сериализовал очередь и выбивал Dart-side timeout на
                // длинных списках; иконка грузится отдельно через getAppIcon).
                // Контракт ответа:
                //   {packageName, appName, isSystemApp} — установлен
                //   {"notFound": true}  — подтверждённо не установлен
                //   result.error(...)   — проверить не удалось, Dart считает
                //                         retryable (НЕ «не установлен»)
                val pkg = call.argument<String>("packageName") ?: ""
                // 693 итер. 2: запрос к PackageManager — на Dispatchers.IO,
                // ответ (тот же контракт) — на главном.
                val pm = context.packageManager
                pluginScope.launch {
                    val reply: Result<Map<String, Any>> = withContext(Dispatchers.IO) {
                        try {
                            val info = pm.getApplicationInfo(pkg, 0)
                            val isSystem = (info.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0
                            Result.success(mapOf<String, Any>(
                                "packageName" to pkg,
                                "appName" to (pm.getApplicationLabel(info)?.toString() ?: pkg),
                                "isSystemApp" to isSystem,
                                "uid" to info.uid,
                            ))
                        } catch (_: android.content.pm.PackageManager.NameNotFoundException) {
                            Result.success(mapOf<String, Any>("notFound" to true))
                        } catch (e: Throwable) {
                            Result.failure(e)
                        }
                    }
                    reply.fold(
                        onSuccess = { result.success(it) },
                        onFailure = { result.error("APP_INFO_ERROR", it.message, null) },
                    )
                }
            }
            "isIgnoringBatteryOptimizations" -> {
                val pm = context.getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
                result.success(pm.isIgnoringBatteryOptimizations(context.packageName))
            }
            "openBatteryOptimizationSettings" -> {
                // Primary — system one-tap prompt («Allow L×Box to ignore
                // battery optimizations?»). It targets exactly our package via
                // `package:` URI, requires REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
                // permission (declared in manifest), and is the path used by
                // SFA / NekoBox.
                // Fallback — общая страница battery-optimization с списком
                // всех apps (юзеру нужно ткнуть в L×Box). Срабатывает на OEM
                // (ColorOS/MIUI/HyperOS), где direct-prompt молча отбрасывается.
                result.success(openSystemSettings(
                    primaryAction = android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    primaryWithPackage = true,
                    fallbackAction = android.provider.Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS,
                ))
            }
            "openAppDetailsSettings" -> {
                result.success(openSystemSettings(
                    primaryAction = android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    primaryWithPackage = true,
                ))
            }
            "areNotificationsEnabled" -> {
                result.success(androidx.core.app.NotificationManagerCompat.from(context).areNotificationsEnabled())
            }
            "openNotificationSettings" -> {
                // API 26+ имеет прямой action ACTION_APP_NOTIFICATION_SETTINGS,
                // он передаёт пакет через extra, а не через data URI.
                // Fallback — ACTION_APPLICATION_DETAILS_SETTINGS (pre-26 или
                // если прямой action не найден OEM).
                result.success(openNotificationSettings())
            }
            "openVpnSettings" -> {
                // §241 — системный экран Settings → VPN: активный VPN там
                // помечен «Connected», юзер видит, кто держит слот. Action
                // public с API 24 (minSdk), package в URI не нужен.
                result.success(openSystemSettings(
                    primaryAction = android.provider.Settings.ACTION_VPN_SETTINGS,
                    primaryWithPackage = false,
                ))
            }
            "requestAddTile" -> {
                // §032 Quick Connect. API 33+ позволяет приложению попросить
                // систему показать prompt «Add L×Box to Quick Settings?».
                // На API < 33 возвращаем "unsupported" — Dart-сторона покажет
                // текстовую инструкцию вместо кнопки.
                requestAddQuickSettingsTile(result)
            }
            "sendAutomationBroadcast" -> {
                val action = call.argument<String>("action") ?: ""
                @Suppress("UNCHECKED_CAST")
                val extras = (call.argument<Map<String, Any?>>("extras")
                    ?: emptyMap())
                if (action.isNotEmpty()) {
                    AutomationBridge.sendAutomationBroadcast(action, extras)
                }
                result.success(true)
            }
            "getApplicationExitInfo" -> result.success(readApplicationExitInfo())
            "getLogcatTail" -> {
                val count = (call.argument<Int>("count") ?: 1000).coerceIn(50, 5000)
                val level = (call.argument<String>("level") ?: "E")
                    .filter { it.isLetter() }
                    .ifEmpty { "E" }
                result.success(readLogcatTail(count, level))
            }
            "showToast" -> {
                // §031 Debug API. Вызов со стороны Dart через
                // /action/toast?msg=...&duration=short|long. Безопасно на
                // любом потоке — android.widget.Toast требует main looper,
                // постим туда.
                val msg = call.argument<String>("msg") ?: ""
                val duration = when (call.argument<String>("duration")) {
                    "long" -> android.widget.Toast.LENGTH_LONG
                    else -> android.widget.Toast.LENGTH_SHORT
                }
                mainHandler.post {
                    android.widget.Toast.makeText(context, msg, duration).show()
                }
                result.success(true)
            }
            "ccTaildropSave" -> {
                val tag = call.argument<String>("tag") ?: ""
                val name = call.argument<String>("name") ?: ""
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                    taildropSave(tag, name, null, result)
                } else if (call.argument<Boolean>("downloads_only") == true) {
                    // §707 итер. 5 — Debug API: без системного «Сохранить как».
                    result.success(mapOf("status" to "error", "error" to "needs Android 10 or later"))
                } else {
                    val act = activity
                    if (act == null) {
                        result.success(mapOf("status" to "error", "error" to "no activity"))
                    } else {
                        pendingTaildropSave?.third?.success(mapOf("status" to "cancelled"))
                        pendingTaildropSave = Triple(tag, name, result)
                        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = mimeOfName(name)
                            putExtra(Intent.EXTRA_TITLE, name)
                        }
                        runCatching { act.startActivityForResult(intent, TAILDROP_SAVE_CODE) }
                            .onFailure {
                                pendingTaildropSave = null
                                result.success(mapOf("status" to "error", "error" to (it.message ?: "no file picker")))
                            }
                    }
                }
            }
            "ccTaildropPickAndSend" -> {
                val tag = call.argument<String>("tag") ?: ""
                val peerId = call.argument<String>("peer_id") ?: ""
                val peerName = call.argument<String>("peer_name") ?: ""
                val act = activity
                if (act == null) {
                    result.success(mapOf("status" to "error", "error" to "no activity"))
                } else {
                    pendingTaildropPick?.second?.success(mapOf("status" to "cancelled"))
                    pendingTaildropPick = Triple(tag, peerId, peerName) to result
                    val open = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                        putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                    }
                    val started = runCatching { act.startActivityForResult(open, TAILDROP_PICK_CODE) }.isSuccess ||
                        runCatching {
                            // Без системного DocumentsUI (TV) — GET_CONTENT.
                            val get = Intent(Intent.ACTION_GET_CONTENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "*/*"
                                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                            }
                            act.startActivityForResult(get, TAILDROP_PICK_CODE)
                        }.isSuccess
                    if (!started) {
                        pendingTaildropPick = null
                        result.success(mapOf("status" to "error", "error" to "no file picker"))
                    }
                }
            }
            "ccTakeTaildropOpenRequest" -> {
                val tag = UiLaunchRequests.taildropOpenRequest
                UiLaunchRequests.taildropOpenRequest = null
                result.success(tag)
            }
            "ccTakeOpenConnectOpenRequest" -> {
                val tag = UiLaunchRequests.openConnectOpenRequest
                UiLaunchRequests.openConnectOpenRequest = null
                result.success(tag)
            }

            else -> result.notImplemented()
        }
    }

    /// §038 — `getHistoricalProcessExitReasons` lazy reader. На API <30 →
    /// пустой список (метод недоступен); на любую ошибку — тоже пустой
    /// (никогда не валим caller'а из-за этого).
    private fun readApplicationExitInfo(): List<Map<String, Any?>> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return emptyList()
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as? android.app.ActivityManager
            ?: return emptyList()
        val infos = runCatching {
            am.getHistoricalProcessExitReasons(context.packageName, 0, 5)
        }.getOrElse {
            Log.w(TAG, "getHistoricalProcessExitReasons failed: ${it.message}")
            return emptyList()
        }
        return infos.map { info ->
            mapOf(
                "timestamp" to info.timestamp,
                "reason" to exitReasonName(info.reason),
                "description" to info.description,
                "importance" to info.importance,
                "pss" to info.pss,
                "rss" to info.rss,
                "status" to info.status,
                "trace" to runCatching {
                    info.traceInputStream?.use { it.bufferedReader().readText() }
                }.getOrNull(),
            )
        }
    }

    /// §038 — снимок последних N строк logcat'а нашего процесса. logd
    /// UID-фильтрует автоматически (READ_LOGS не нужен). Timeout 2s
    /// страхует от зависания на проблемных ROM.
    private fun readLogcatTail(count: Int, level: String): String {
        return runCatching {
            val proc = ProcessBuilder("logcat", "-d", "-t", count.toString(), "*:$level")
                .redirectErrorStream(true)
                .start()
            val out = proc.inputStream.bufferedReader().readText()
            proc.waitFor(2, java.util.concurrent.TimeUnit.SECONDS)
            out
        }.getOrElse {
            Log.w(TAG, "logcat tail failed: ${it.message}")
            ""
        }
    }

    /// §038 — `ApplicationExitInfo.REASON_*` коды → читаемые имена.
    @androidx.annotation.RequiresApi(Build.VERSION_CODES.R)
    private fun exitReasonName(code: Int): String = when (code) {
        android.app.ApplicationExitInfo.REASON_UNKNOWN -> "UNKNOWN"
        android.app.ApplicationExitInfo.REASON_EXIT_SELF -> "EXIT_SELF"
        android.app.ApplicationExitInfo.REASON_SIGNALED -> "SIGNALED"
        android.app.ApplicationExitInfo.REASON_LOW_MEMORY -> "LOW_MEMORY"
        android.app.ApplicationExitInfo.REASON_CRASH -> "CRASH"
        android.app.ApplicationExitInfo.REASON_CRASH_NATIVE -> "CRASH_NATIVE"
        android.app.ApplicationExitInfo.REASON_ANR -> "ANR"
        android.app.ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "INITIALIZATION_FAILURE"
        android.app.ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "PERMISSION_CHANGE"
        android.app.ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "EXCESSIVE_RESOURCE_USAGE"
        android.app.ApplicationExitInfo.REASON_USER_REQUESTED -> "USER_REQUESTED"
        android.app.ApplicationExitInfo.REASON_USER_STOPPED -> "USER_STOPPED"
        android.app.ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "DEPENDENCY_DIED"
        android.app.ApplicationExitInfo.REASON_OTHER -> "OTHER"
        android.app.ApplicationExitInfo.REASON_PACKAGE_UPDATED -> "PACKAGE_UPDATED"
        else -> "REASON_$code"
    }

    /// Запуск системного settings-activity. Сперва через activity-context
    /// (если есть), иначе через app-context с FLAG_ACTIVITY_NEW_TASK.
    /// Пакет в URI добавляется автоматически для actions требующих его
    /// (REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, APPLICATION_DETAILS_SETTINGS).
    private fun openSystemSettings(
        primaryAction: String,
        primaryWithPackage: Boolean,
        fallbackAction: String? = null,
    ): Boolean {
        val act = activity
        val launchCtx: Context = act ?: context
        val useNewTask = act == null

        fun needsPackage(action: String) = action in setOf(
            android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
        )

        fun tryLaunch(action: String, withPackage: Boolean): Boolean {
            val intent = android.content.Intent(action).apply {
                if (withPackage) {
                    data = android.net.Uri.parse("package:${context.packageName}")
                }
                if (useNewTask) addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            return try {
                launchCtx.startActivity(intent)
                Log.d(TAG, "openSystemSettings launched: $action")
                true
            } catch (e: Exception) {
                Log.e(TAG, "openSystemSettings failed for $action: ${e.message}", e)
                false
            }
        }

        if (tryLaunch(primaryAction, primaryWithPackage)) return true
        if (fallbackAction != null &&
            tryLaunch(fallbackAction, needsPackage(fallbackAction))) return true
        return false
    }

    /// Открывает per-app notification settings. На API 26+ идёт прямой action,
    /// пакет передаётся через `EXTRA_APP_PACKAGE` (не через data URI —
    /// поэтому helper `openSystemSettings` не подходит). Если активити не
    /// найдена (старый Android / OEM без экрана) — fallback на app details.
    private fun openNotificationSettings(): Boolean {
        val act = activity
        val launchCtx: Context = act ?: context
        val useNewTask = act == null
        val intent = Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
            putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, context.packageName)
            if (useNewTask) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return try {
            launchCtx.startActivity(intent)
            true
        } catch (_: Exception) {
            openSystemSettings(
                primaryAction = android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                primaryWithPackage = true,
            )
        }
    }

    /// API 33+ — попросить систему показать «Add tile to Quick Settings»
    /// prompt. Async через Consumer-callback системы, success() в Dart
    /// идёт ровно один раз. Возможные значения:
    ///   "added"        — юзер согласился
    ///   "already"      — tile уже в шторке
    ///   "dismissed"    — юзер отказался
    ///   "unsupported"  — API < 33
    ///   "no_activity"  — нет attached activity
    ///   "error: ..."   — exception от системы
    private fun requestAddQuickSettingsTile(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success("unsupported")
            return
        }
        val act = activity
        if (act == null) {
            result.success("no_activity")
            return
        }
        try {
            val sbm = act.getSystemService(android.app.StatusBarManager::class.java)
            if (sbm == null) {
                result.success("error: status_bar_unavailable")
                return
            }
            val component = android.content.ComponentName(
                context, com.leadaxe.lxbox.vpn.LxBoxTileService::class.java
            )
            val icon = android.graphics.drawable.Icon.createWithResource(
                context, android.R.drawable.ic_lock_lock
            )
            // Защита от двойного success() если система зовёт consumer
            // несколько раз (наблюдалось на отдельных OEM).
            val replied = java.util.concurrent.atomic.AtomicBoolean(false)
            sbm.requestAddTileService(
                component,
                context.getString(com.leadaxe.lxbox.R.string.app_name),
                icon,
                { runnable -> mainHandler.post(runnable) },
                { code ->
                    if (!replied.compareAndSet(false, true)) return@requestAddTileService
                    val mapped = when (code) {
                        android.app.StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED -> "added"
                        android.app.StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED -> "already"
                        android.app.StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_NOT_ADDED -> "dismissed"
                        else -> "error: result=$code"
                    }
                    mainHandler.post { result.success(mapped) }
                }
            )
        } catch (e: Exception) {
            Log.e(TAG, "requestAddTile failed", e)
            result.success("error: ${e.message}")
        }
    }

    /// PNG-base64 иконки одного приложения. Пустая строка если не удалось.
    /// Выделено в функцию чтобы переиспользовать из getAppIcon и getAppInfo.
    private fun encodeAppIcon(pkg: String): String {
        return try {
            val pm = context.packageManager
            val drawable = pm.getApplicationIcon(pkg)
            val bitmap = if (drawable is android.graphics.drawable.BitmapDrawable) {
                // 693 итер. 2: родной битмап бывает 192–512 px — в пикере
                // хватает 96, крупнее только тратит память и PNG-encode.
                val src = drawable.bitmap
                if (src.width > 96 || src.height > 96) {
                    android.graphics.Bitmap.createScaledBitmap(src, 96, 96, true)
                } else {
                    src
                }
            } else {
                val bmp = android.graphics.Bitmap.createBitmap(
                    48, 48, android.graphics.Bitmap.Config.ARGB_8888
                )
                val canvas = android.graphics.Canvas(bmp)
                drawable.setBounds(0, 0, 48, 48)
                drawable.draw(canvas)
                bmp
            }
            val stream = java.io.ByteArrayOutputStream()
            bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 80, stream)
            android.util.Base64.encodeToString(stream.toByteArray(), android.util.Base64.NO_WRAP)
        } catch (_: Throwable) {
            // Throwable, а не Exception: OutOfMemoryError на огромной иконке.
            ""
        }
    }

    private fun startVpn(result: MethodChannel.Result) {
        if (activity == null) {
            result.error("NO_ACTIVITY", "No activity", null)
            return
        }
        // §192 — proxy-режим (port-only, без TUN): НЕ зовём VpnService.prepare()
        // — он зря забирает системный VPN-слот и отзывает чужой активный VPN
        // (onRevoke). Стартуем сервис напрямую; ядро в proxy не зовёт openTun.
        // §747 — `has_tun` хранит `:bg`; вопрос идёт той же полосой, что
        // предшествующий `setHasTun`, диалог согласия — на главном потоке.
        BgClient.onLane {
            val hasTun = BgClient.callOr(context, "getHasTun", null, true)
            if (!hasTun) {
                val ok = startService()
                BgClient.onMain { result.success(ok) }
                return@onLane
            }
            BgClient.onMain {
                val act = activity
                if (act == null) {
                    result.error("NO_ACTIVITY", "No activity", null)
                    return@onMain
                }
                val intent = VpnService.prepare(act)
                if (intent != null) {
                    pendingVpnResult = result
                    act.startActivityForResult(intent, VPN_REQUEST_CODE)
                } else {
                    BgClient.onLane {
                        val ok = startService()
                        BgClient.onMain { result.success(ok) }
                    }
                }
            }
        }
    }

    /// Команда старта сервису — вызовом `:bg` на полосе: к этому моменту до
    /// него дошли все предыдущие записи настроек и «конфиг сохранён».
    /// Блокирует; звать с полосы.
    private fun startService(): Boolean =
        BgClient.callOr(context, "startVpnService", null, false)

    // -------------------------------------------------------------------------
    // ActivityAware
    // -------------------------------------------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }
    override fun onDetachedFromActivity() { activity = null }

    // -------------------------------------------------------------------------
    // ActivityResultListener
    // -------------------------------------------------------------------------

    /// §707 — сохранить принятый файл (в Downloads или в [target]) и
    /// ответить Dart `{status, where?, name?, error?}`; `name` — имя записи
    /// в Downloads (итер. 5, Debug API). §747 — сохраняет `:bg` (сервисный
    /// клиент ядра); доступ к документу [target] выдан UID приложения.
    private fun taildropSave(tag: String, name: String, target: android.net.Uri?, result: MethodChannel.Result) {
        BgClient.forward(
            context, "taildropSave",
            mapOf("tag" to tag, "name" to name, "target" to target?.toString()),
            result, long = true,
        )
    }

    /// §707 — ответы выбора файлов и «Сохранить как».
    private fun onTaildropResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == TAILDROP_SAVE_CODE) {
            val p = pendingTaildropSave ?: return
            pendingTaildropSave = null
            val uri = data?.data
            if (resultCode != Activity.RESULT_OK || uri == null) {
                p.third.success(mapOf("status" to "cancelled"))
            } else {
                taildropSave(p.first, p.second, uri, p.third)
            }
            return
        }
        val p = pendingTaildropPick ?: return
        pendingTaildropPick = null
        val result = p.second
        val uris = ArrayList<android.net.Uri>()
        if (resultCode == Activity.RESULT_OK && data != null) {
            val clip = data.clipData
            if (clip != null) {
                for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let { uris.add(it) }
            } else {
                data.data?.let { uris.add(it) }
            }
        }
        if (uris.isEmpty()) {
            result.success(mapOf("status" to "cancelled"))
            return
        }
        val (tag, peerId, peerName) = p.first
        // §747 — файлы открывает и отправляет `:bg` (сервисный клиент ядра);
        // доступ к выбранным документам выдан UID приложения, не процессу.
        BgClient.forward(
            context, "taildropSendUris",
            mapOf(
                "tag" to tag, "peer_id" to peerId, "peer_name" to peerName,
                "uris" to uris.map { it.toString() },
            ),
            result, long = true,
        )
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == TAILDROP_PICK_CODE || requestCode == TAILDROP_SAVE_CODE) {
            onTaildropResult(requestCode, resultCode, data)
            return true
        }
        if (requestCode != VPN_REQUEST_CODE) return false
        val r = pendingVpnResult
        pendingVpnResult = null
        if (resultCode == Activity.RESULT_OK) {
            BgClient.onLane {
                val ok = startService()
                BgClient.onMain { r?.success(ok) }
            }
        } else {
            r?.success(false)
        }
        return true
    }
}
