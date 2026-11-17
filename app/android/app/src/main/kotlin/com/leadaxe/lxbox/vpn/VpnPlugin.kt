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
        private const val TAILDROP_PICK_CODE = 25 // §707
        private const val TAILDROP_SAVE_CODE = 26 // §707
        private const val VPN_REQUEST_CODE = 24

        /// §747 — Binder-метка живого процесса окна: `:bg` вешает на неё
        /// `linkToDeath`. Одна на процесс.
        private val uiToken = android.os.Binder()
    }

    private lateinit var methodChannel: MethodChannel
    private lateinit var statusEventChannel: EventChannel
    private lateinit var coreLogEventChannel: EventChannel
    /// §122 Фаза 0 — EventChannel'ы нового CommandClient-канала.
    private lateinit var ccStatusEventChannel: EventChannel
    private lateinit var ccOutboundsEventChannel: EventChannel
    private lateinit var ccGroupsEventChannel: EventChannel
    private lateinit var ccConnectionsEventChannel: EventChannel
    private lateinit var ccDnsEventChannel: EventChannel // §180
    private lateinit var ccTailscaleEventChannel: EventChannel // §579
    private lateinit var ccTailscalePingEventChannel: EventChannel // §581
    private lateinit var ccConnectionTestEventChannel: EventChannel // §687
    private lateinit var ccOpenConnectEventChannel: EventChannel // §654
    private lateinit var ccTaildropInboxEventChannel: EventChannel // §707
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
            // §745 — клиент ядра роли UI создаёт и закрывает сторона UI. На
            // Started — до передачи события в Dart (onReceive на главном
            // потоке, событие уходит следующим post): к первому `cc*` клиент
            // уже есть. На Stopped — закрыть, если ещё жив (обычно его уже
            // закрыл слушатель «перед закрытием»). Запоздалый Stopped прошлого
            // туннеля после нового Started (§122, быстрый перезапуск) клиента
            // нового туннеля не трогает: решает текущий статус, не событие.
            // §747 — сначала копия состояния туннеля (в процессе окна её пишет
            // только этот приёмник и запрос снимка), по ней — клиент ядра.
            val wire = BgEvents.wireOf(intent)
            if (wire != null) applyTunnelWire(wire) else syncUiClient()
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

    /// §747 — события `:bg` → `:ui` (`BgEvents`); зарегистрирован, пока
    /// подключён движок. Данных, кроме имени и аргументов команды
    /// автоматизации, события не несут.
    private val bgEventsReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) {
            when (intent?.action) {
                // Состояние openconnect изменилось: забрать снимок вызовом и
                // отдать в sink (раньше сервис писал в него сам).
                BgEvents.ACTION_OPENCONNECT_CHANGED -> {
                    if (UiSinks.ccOpenConnectSink == null) return
                    val c = context
                    BgClient.onLane {
                        val snap = BgClient.callOr<Any?>(c, "ccGetOpenConnectStatus", null, null)
                        if (snap != null) BgClient.onMain {
                            runCatching { UiSinks.ccOpenConnectSink?.success(snap) }
                        }
                    }
                }
                // Команда автоматизации / «нативный Stop» для Dart.
                BgEvents.ACTION_AUTOMATION -> {
                    val name = intent.getStringExtra(BgEvents.EXTRA_NAME) ?: return
                    val args = runCatching {
                        BgCodec.decode(intent.getByteArrayExtra(BgEvents.EXTRA_ARGS)) as? Map<*, *>
                    }.getOrNull().orEmpty().entries.associate { (k, v) -> k.toString() to v }
                    AutomationBridge.handleAutomationAction(name, args)
                }
                // `:bg` поднимает туннель, а здесь идёт проба на том же сокете
                // ядра: остановить (остановка сама ответит `probeEnd`).
                BgEvents.ACTION_STOP_PROBE ->
                    Thread({ runCatching { ProbeSession.stop() } }, "lxbox-probe-stop")
                        .apply { isDaemon = true }.start()
            }
        }
    }

    /// Движок подключён (между onAttachedToEngine и onDetachedFromEngine).
    private var attached = false

    /// Метка запуска `:bg` из последнего принятого снимка: смена — процесс
    /// `:bg` перезапущен.
    private var bgEpoch: Long? = null

    /// Читатель потока лога из `:bg`; есть, пока Dart слушает `lxbox/coreLog`.
    private var logReader: UiLogPipeReader? = null

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

        // §043: core log pump из sing-box. Sing-box логи приходят через
        // PlatformInterface.writeDebugMessage в BoxService (`:bg`) → pipe
        // (`BgLogPipe` → `UiLogPipeReader`, §747) → UiSinks.coreLogSink → этот
        // EventChannel → ClashLogPump в Dart. Поток открыт, пока Dart слушает.
        coreLogEventChannel = EventChannel(binding.binaryMessenger, CORE_LOG_CHANNEL)
        coreLogEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                Log.d(TAG, "[vpn] coreLogEventChannel.onListen — sink installed")
                UiSinks.coreLogSink = sink
                openLogPipe()
            }
            override fun onCancel(args: Any?) {
                Log.d(TAG, "[vpn] coreLogEventChannel.onCancel — sink cleared")
                UiSinks.coreLogSink = null
                closeLogPipe()
            }
        })

        // §122 Фаза 0 — 4 канала CommandClient (status/outbounds/groups/connections).
        // BoxCommandClient.handler пушит снапшоты в BoxVpnService.cc*Sink → сюда → Dart.
        ccStatusEventChannel = EventChannel(binding.binaryMessenger, CC_STATUS_CHANNEL)
        ccStatusEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) { UiSinks.ccStatusSink = sink }
            override fun onCancel(args: Any?) { UiSinks.ccStatusSink = null }
        })
        ccOutboundsEventChannel = EventChannel(binding.binaryMessenger, CC_OUTBOUNDS_CHANNEL)
        ccOutboundsEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) { UiSinks.ccOutboundsSink = sink }
            override fun onCancel(args: Any?) { UiSinks.ccOutboundsSink = null }
        })
        ccGroupsEventChannel = EventChannel(binding.binaryMessenger, CC_GROUPS_CHANNEL)
        ccGroupsEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) { UiSinks.ccGroupsSink = sink }
            override fun onCancel(args: Any?) { UiSinks.ccGroupsSink = null }
        })
        ccConnectionsEventChannel = EventChannel(binding.binaryMessenger, CC_CONNECTIONS_CHANNEL)
        ccConnectionsEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                UiSinks.ccConnectionsSink = sink
                // §193 — connections single-shot: ядро шлёт reset-снапшот РОВНО
                // один раз при подписке screenClient (pull в libbox нет). Новый
                // Dart-подписчик (открытие Stats при уже живом screenClient) не
                // получает нового reset → пусто. Переэмитим накопленный
                // аккумулятор сразу, чтобы Stats увидел текущие соединения.
                UiCoreSession.client?.reEmitScreenConnections()
            }
            override fun onCancel(args: Any?) { UiSinks.ccConnectionsSink = null }
        })
        // §180 — DNS-журнал из ядра (SPEC 018).
        ccDnsEventChannel = EventChannel(binding.binaryMessenger, CC_DNS_CHANNEL)
        ccDnsEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) { UiSinks.ccDnsQueriesSink = sink }
            override fun onCancel(args: Any?) { UiSinks.ccDnsQueriesSink = null }
        })
        // §579 — состояние узлов Tailscale (псевдо-направление NETWORKS).
        ccTailscaleEventChannel = EventChannel(binding.binaryMessenger, CC_TAILSCALE_CHANNEL)
        ccTailscaleEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) { UiSinks.ccTailscaleSink = sink }
            override fun onCancel(args: Any?) { UiSinks.ccTailscaleSink = null }
        })
        // §581 — ответы проверки устройства Tailscale.
        ccTailscalePingEventChannel = EventChannel(binding.binaryMessenger, CC_TAILSCALE_PING_CHANNEL)
        ccTailscalePingEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) { UiSinks.ccTailscalePingSink = sink }
            override fun onCancel(args: Any?) { UiSinks.ccTailscalePingSink = null }
        })
        ccConnectionTestEventChannel = EventChannel(binding.binaryMessenger, CC_CONNECTION_TEST_CHANNEL)
        ccConnectionTestEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) { UiSinks.ccConnectionTestSink = sink }
            override fun onCancel(args: Any?) { UiSinks.ccConnectionTestSink = null }
        })
        // §654 C — состояние endpoint'ов openconnect (второй фактор / SSO).
        // §707 — входящие Taildrop узла.
        ccTaildropInboxEventChannel = EventChannel(binding.binaryMessenger, CC_TAILDROP_INBOX_CHANNEL)
        ccTaildropInboxEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) { UiSinks.ccTaildropInboxSink = sink }
            override fun onCancel(args: Any?) { UiSinks.ccTaildropInboxSink = null }
        })
        ccOpenConnectEventChannel = EventChannel(binding.binaryMessenger, CC_OPENCONNECT_CHANNEL)
        ccOpenConnectEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) { UiSinks.ccOpenConnectSink = sink }
            override fun onCancel(args: Any?) { UiSinks.ccOpenConnectSink = null }
        })

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
        runCatching {
            context.registerReceiver(
                bgEventsReceiver,
                IntentFilter().apply {
                    addAction(BgEvents.ACTION_OPENCONNECT_CHANGED)
                    addAction(BgEvents.ACTION_AUTOMATION)
                    addAction(BgEvents.ACTION_STOP_PROBE)
                },
                Context.RECEIVER_NOT_EXPORTED
            )
        }.onFailure { Log.e(TAG, "[vpn] registerReceiver(bgEventsReceiver) failed: $it") }
        // §747 D — проба без туннеля согласуется с `:bg` (сокет ядра общий).
        val appCtx = context
        ProbeSession.gateBegin = { BgClient.call(appCtx, "probeBegin") == true }
        ProbeSession.gateEnd = { BgClient.callOr(appCtx, "probeEnd", null, true) }
        // §745 — туннель уже поднят (движок подключился позже старта: плитка,
        // автозапуск, возврат после закрытия активити) — клиент UI создаётся
        // сейчас; без Started `ensure()` ничего не делает. §747 — в процессе
        // окна копия состояния ещё пуста: её заполнит ответ `attachToBg`
        // (broadcast не липкий), он же создаст клиента.
        UiCoreSession.ensure()
        attachToBg()
    }

    /// §747 — сообщить `:bg`, что окно живо (Binder-метка: `:bg` узнает и о
    /// гибели процесса), и забрать снимок состояния туннеля. Зовётся при
    /// подключении движка и когда `:bg` оказался перезапущен (новая метка
    /// запуска в снимке) — тогда же заново открывается поток лога.
    private fun attachToBg() {
        val ctx = context
        BgClient.onLane {
            runCatching {
                BgClient.raw(
                    ctx, BgControlProvider.METHOD_UI_ATTACHED,
                    android.os.Bundle().apply { putBinder(BgControlProvider.KEY_TOKEN, uiToken) },
                )
            }.onFailure { Log.w(TAG, "[bg] uiAttached failed: ${it.message}") }
            val wire = fetchTunnelWire()
            BgClient.onMain { if (wire != null && attached) applyTunnelWire(wire) }
        }
    }

    /// Снимок состояния туннеля из `:bg`; null — вызов не удался. Блокирует.
    private fun fetchTunnelWire(): TunnelState.Wire? = runCatching {
        (BgClient.call(context, "tunnelSnapshot") as? Map<*, *>)?.let { BgEvents.wireOf(it) }
    }.getOrNull()

    /// Главный поток. Принять снимок в копию состояния окна (в процессе, где
    /// живёт и сервис, состояние настоящее — копию не пишем) и привести к нему
    /// клиента ядра. Сменилась метка запуска `:bg` — процесс новый: он не
    /// знает ни об окне, ни о подписке на лог.
    private fun applyTunnelWire(w: TunnelState.Wire) {
        if (!ProcessRole.isBg) TunnelState.acceptMirror(w)
        val prev = bgEpoch
        bgEpoch = w.epoch
        if (prev != null && prev != w.epoch) {
            Log.w(TAG, "[bg] service process restarted — re-attaching")
            attachToBg()
            if (UiSinks.coreLogSink != null) openLogPipe()
        }
        syncUiClient()
    }

    /// §745 — клиент ядра роли UI создаёт и закрывает сторона UI по текущему
    /// статусу туннеля (не по событию: запоздалый Stopped прошлого туннеля
    /// после нового Started клиента нового туннеля не трогает).
    private fun syncUiClient() {
        when (TunnelState.status) {
            VpnStatus.Started -> UiCoreSession.ensure()
            // §747 — на Stopping сервис закрывает командный сервер: клиент
            // закрывается сразу, не дожидаясь Stopped.
            VpnStatus.Stopping, VpnStatus.Stopped -> UiCoreSession.closeOffMain()
            VpnStatus.Starting -> {}
        }
    }

    // ───────────── §747 — поток лога из `:bg` ─────────────

    /// Главный поток. Создать pipe, читающий конец оставить себе, пишущий
    /// отдать `:bg` (`openLogPipe`). Прежний поток закрывается.
    private fun openLogPipe() {
        logReader?.stop()
        logReader = null
        val pipe = runCatching { android.os.ParcelFileDescriptor.createPipe() }.getOrNull() ?: return
        lateinit var reader: UiLogPipeReader
        reader = UiLogPipeReader(
            pipe[0],
            post = { mainHandler.post(it) },
            // §155 — sink может указывать на мёртвый движок: глотаем.
            deliver = { batch -> runCatching { UiSinks.coreLogSink?.success(batch) } },
            onEnd = { mainHandler.post { if (logReader === reader) logReader = null } },
        )
        logReader = reader
        reader.start()
        val writeEnd = pipe[1]
        val ctx = context
        BgClient.onLane {
            runCatching {
                BgClient.raw(
                    ctx, BgControlProvider.METHOD_OPEN_LOG_PIPE,
                    android.os.Bundle().apply { putParcelable(BgControlProvider.KEY_PFD, writeEnd) },
                )
            }.onFailure { Log.w(TAG, "[bg] openLogPipe failed: ${it.message}") }
            // Свой экземпляр пишущего конца закрываем: у `:bg` — дубликат.
            runCatching { writeEnd.close() }
        }
    }

    private fun closeLogPipe() {
        logReader?.stop()
        logReader = null
        val ctx = context
        BgClient.onLane { BgClient.callOr(ctx, "closeLogPipe", null, true) }
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
        methodChannel.setMethodCallHandler(null)
        statusEventChannel.setStreamHandler(null)
        coreLogEventChannel.setStreamHandler(null)
        ccStatusEventChannel.setStreamHandler(null)
        ccOutboundsEventChannel.setStreamHandler(null)
        ccGroupsEventChannel.setStreamHandler(null)
        ccConnectionsEventChannel.setStreamHandler(null)
        ccDnsEventChannel.setStreamHandler(null) // §180
        ccTailscaleEventChannel.setStreamHandler(null) // §579
        ccTailscalePingEventChannel.setStreamHandler(null) // §581
        ccConnectionTestEventChannel.setStreamHandler(null) // §687
        ccOpenConnectEventChannel.setStreamHandler(null) // §654
        ccTaildropInboxEventChannel.setStreamHandler(null) // §707
        statusSink = null
        UiSinks.coreLogSink = null
        UiSinks.ccStatusSink = null
        UiSinks.ccOutboundsSink = null
        UiSinks.ccGroupsSink = null
        UiSinks.ccConnectionsSink = null
        UiSinks.ccDnsQueriesSink = null // §180
        UiSinks.ccTailscaleSink = null // §579
        UiSinks.ccTailscalePingSink = null // §581
        UiSinks.ccConnectionTestSink = null // §687
        UiSinks.ccOpenConnectSink = null // §654
        UiSinks.ccTaildropInboxSink = null // §707
        // §745 — движка нет, эмитить некуда: клиент UI закрыт, а не стоит на
        // паузе. При возврате `onAttachedToEngine` создаст новый.
        UiCoreSession.closeOffMain()
        // §047 — обнуляем bridge-ссылки (engine detached).
        AutomationBridge.bridgeChannel = null
        AutomationBridge.appContext = null
        runCatching { context.unregisterReceiver(statusReceiver) }
        runCatching { context.unregisterReceiver(bgEventsReceiver) }
        // §747 — поток лога закрыт; `:bg` узнаёт, что окна больше нет
        // («окно закрыто»): слать ему события и держать процесс ради окна незачем.
        logReader?.stop()
        logReader = null
        val ctx = context
        BgClient.onLane { BgClient.callOr(ctx, "uiDetached", null, true) }
        pluginScope.cancel()
    }

    // -------------------------------------------------------------------------
    // MethodCallHandler
    // -------------------------------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        Log.d(TAG, "onMethodCall: ${call.method}")
        when (call.method) {
            // §747 — обработчики, которым нужна память или права сервисной
            // стороны (файлы настроек, состояние туннеля, ядро процесса `:bg`,
            // сервисный клиент ядра, Taildrop): тело — в `BgMethods`, здесь
            // пересылка под тем же именем. Форма ответа прежняя. Быстрые идут
            // одной упорядоченной полосой, долгие — каждый на своём потоке.
            "forceStopVPN", "getTunnelUptimeMs", "isForeignVpnActive", "reloadVPN",
            "resetNetwork", "setQuicKnob", "clearDnsCache", "setNotificationTitle",
            "setNotificationText", "setAutoStart", "getAutoStart", "setKeepOnExit",
            "getKeepOnExit", "setNotificationStop", "getNotificationStop", "setNotificationRestart",
            "getNotificationRestart", "setNotificationSend", "getNotificationSend", "setCoreLogsEnabled",
            "getCoreLogsEnabled", "setCoreLogsVerbose", "getCoreLogsVerbose", "setAllowBypass",
            "getAllowBypass", "setAutoRedirect", "getAutoRedirect", "setHasTun",
            "getCurrentSessionAllowBypass", "startVpnHeadless", "getBackgroundMode", "setBackgroundMode",
            "getMemoryLimit", "setMemoryLimit", "getAppLanguageState",
            "setAutomationEnabled", "setAppFunctionsEnabled", "setAutomationActiveState", "taildropServiceStats",
            "taildropBuildServiceFile", "taildropClipState", "setTaildropTags", "deleteLegacyPrefs",
            "ccGetOpenConnectStatus", "ccStopOpenConnectCallback" -> toBg(call, result)
            // §279 Phase 6 — язык приложения: настройку, LocaleManager-пуш и
            // relabel нативных поверхностей делает `:bg`; здесь — локаль
            // рантайма ядра процесса окна.
            "setAppLanguage" -> {
                if (!ProcessRole.isBg && BoxApplication.libboxLoaded) {
                    L10n.setLibboxLocale(call.argument<String>("tag") ?: L10n.SETTING_SYSTEM)
                }
                toBg(call, result)
            }
            "stopVPN", "getMemoryInfo", "ccSubmitOpenConnectForm",
            "ccCancelOpenConnectChallenge", "ccStartOpenConnectCallback" -> toBg(call, result, long = true)
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
            "getCoreVersion" -> {
                // Libbox.version() — статический Go-side метод; возвращает
                // строку вида "1.13.11". Используется в About screen.
                // Не требует libbox.setup; safe to call в любой момент.
                try {
                    result.success(io.nekohasekai.libbox.Libbox.version())
                } catch (t: Throwable) {
                    Log.e(TAG, "getCoreVersion failed", t)
                    result.success("")
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
                mainHandler.postDelayed({
                    activity?.finishAffinity()
                }, 50)
                val quitStartedAt = SystemClock.elapsedRealtime()
                val ctx = context
                BgClient.onLane {
                    BgClient.callOr(ctx, "quitApp", null, false)
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
            // ───── §122 Фаза 0 — CommandClient lifecycle + императивы ─────
            // §185 — cold-start после swipe-keep: ВСЕ CC-клиенты осиротели
            // (PERSISTENT поля на companion, пережили swipe; Dart-движок умер,
            // disconnect/pause не вызвались). resyncForReopen переподнимает
            // screenClient (groups/connections, сброс протухшего refcount) +
            // statusClient (трафик/память, минуя ранний return setStatusFast)
            // на свежий движок — иначе стримы привязаны к мёртвым sink'ам →
            // пустой UI. Идемпотентно при первом старте. Профайлер: чистая
            // остановка осиротевшего клиента (буфер в Dart потерян by design).
            "ccResyncForReopen" -> {
                UiCoreSession.ensure()?.apply {
                    resyncForReopen()
                    disconnectProfiler()
                }
                result.success(true)
            }
            "ccConnectScreen" -> {
                UiCoreSession.ensure()?.connectScreen(); result.success(true)
            }
            "ccDisconnectScreen" -> {
                UiCoreSession.client?.disconnectScreen(); result.success(true)
            }
            "ccConnectProfiler" -> {
                UiCoreSession.ensure()?.connectProfiler(); result.success(true)
            }
            "ccDisconnectProfiler" -> {
                UiCoreSession.client?.disconnectProfiler(); result.success(true)
            }
            // §175 — отмена масс-пинга: disconnect pingClient → ядро рвёт per-call
            // ctx in-flight тестов (не дожидаясь TCPTimeout), другие стримы целы.
            // §579 — подписка SubscribeTailscaleStatus. Старт стрима — gRPC,
            // поэтому на Dispatchers.IO; ответ сразу (данные придут стримом).
            "ccStartTailscaleStatus" -> {
                val cc = UiCoreSession.ensure()
                if (cc != null) pluginScope.launch(Dispatchers.IO) { cc.startTailscaleStatus() }
                result.success(cc != null)
            }
            "ccStopTailscaleStatus" -> {
                val cc = UiCoreSession.client
                if (cc != null) pluginScope.launch(Dispatchers.IO) { cc.stopTailscaleStatus() }
                result.success(true)
            }
            // §581 — exit node на ходу и выход из аккаунта: блокирующий gRPC
            // на Dispatchers.IO; ответ — null (успех) или текст ошибки ядра.
            "ccSetTailscaleExitNode" -> {
                val cc = UiCoreSession.ensure()
                val tag = call.argument<String>("tag") ?: ""
                val id = call.argument<String>("stable_id") ?: ""
                pluginScope.launch {
                    val err = withContext(Dispatchers.IO) {
                        if (cc == null) "no command client" else cc.setTailscaleExitNode(tag, id)
                    }
                    result.success(err)
                }
            }
            // §645 — одиночный GetTailscaleStatus для опроса вкладки Network:
            // map записи, null — пропуск тика, ядро без метода — error
            // `unimplemented` (Dart останавливает опрос).
            "ccGetTailscaleStatus" -> {
                val cc = UiCoreSession.ensure()
                val tag = call.argument<String>("tag") ?: ""
                pluginScope.launch {
                    val r = withContext(Dispatchers.IO) {
                        runCatching { cc?.getTailscaleStatus(tag) }
                    }
                    r.fold(
                        onSuccess = { result.success(it) },
                        onFailure = {
                            if (it is UnsupportedOperationException) {
                                result.error("unimplemented", null, null)
                            } else {
                                result.success(null)
                            }
                        },
                    )
                }
            }
            "ccTailscaleLogout" -> {
                val cc = UiCoreSession.ensure()
                val tag = call.argument<String>("tag") ?: ""
                pluginScope.launch {
                    val err = withContext(Dispatchers.IO) {
                        if (cc == null) "no command client" else cc.tailscaleLogout(tag)
                    }
                    result.success(err)
                }
            }
            // §706 (ядро SPEC 149) — вход узла с новым ключом на лету. Успех →
            // null; отказ ядра → PlatformException с кодом как у
            // ccSetEndpointEnabled.
            "ccTailscaleLogin" -> {
                val cc = UiCoreSession.ensure()
                val tag = call.argument<String>("tag") ?: ""
                val key = call.argument<String>("auth_key") ?: ""
                pluginScope.launch {
                    val r = withContext(Dispatchers.IO) {
                        if (cc == null) {
                            mapOf("error" to "error", "message" to "no command client")
                        } else {
                            cc.tailscaleLogin(tag, key)
                        }
                    }
                    if (r == null) {
                        result.success(null)
                    } else {
                        result.error(r["error"] ?: "error", r["message"], null)
                    }
                }
            }
            "ccStartTailscalePing" -> {
                val cc = UiCoreSession.ensure()
                val tag = call.argument<String>("tag") ?: ""
                val ip = call.argument<String>("peer_ip") ?: ""
                if (cc != null) pluginScope.launch(Dispatchers.IO) { cc.startTailscalePing(tag, ip) }
                result.success(cc != null)
            }
            "ccStopTailscalePing" -> {
                val cc = UiCoreSession.client
                if (cc != null) pluginScope.launch(Dispatchers.IO) { cc.stopTailscalePing() }
                result.success(true)
            }
            // §687 — тест соединения: события идут в EventChannel connection_test.
            "ccStartConnectionTest" -> {
                val cc = UiCoreSession.ensure()
                val link = call.argument<String>("link") ?: ""
                val pkg = call.argument<String>("package_name") ?: ""
                val depth = call.argument<Int>("depth") ?: 0
                val fresh = call.argument<Boolean>("fresh") ?: false
                if (cc != null) pluginScope.launch(Dispatchers.IO) { cc.startConnectionTest(link, pkg, depth, fresh) }
                result.success(cc != null)
            }
            "ccStopConnectionTest" -> {
                val cc = UiCoreSession.client
                if (cc != null) pluginScope.launch(Dispatchers.IO) { cc.stopConnectionTest() }
                result.success(true)
            }
            // §707 — Taildrop: входящие узла, сохранение, удаление, отправка
            // из строки пира. Блокирующий gRPC — на Dispatchers.IO.
            "ccStartTaildropInbox" -> {
                val cc = UiCoreSession.ensure()
                val tag = call.argument<String>("tag") ?: ""
                if (cc != null) pluginScope.launch(Dispatchers.IO) { cc.startTaildropInbox(tag) }
                result.success(cc != null)
            }
            "ccStopTaildropInbox" -> {
                val cc = UiCoreSession.client
                if (cc != null) pluginScope.launch(Dispatchers.IO) { cc.stopTaildropInbox() }
                result.success(true)
            }
            "ccTaildropDelete", "ccTaildropCancelReceiving", "ccTaildropMarkRead" -> {
                val cc = UiCoreSession.ensure()
                val tag = call.argument<String>("tag") ?: ""
                val name = call.argument<String>("name") ?: ""
                val sender = call.argument<String>("sender_id") ?: ""
                val method = call.method
                pluginScope.launch {
                    val err = withContext(Dispatchers.IO) {
                        if (cc == null) {
                            "no command client"
                        } else {
                            when (method) {
                                "ccTaildropDelete" -> cc.taildropDelete(tag, name)
                                    .also {
                                        if (it == null) BgClient.callOr(
                                            context, "taildropDismissReceived",
                                            mapOf("tag" to tag, "name" to name), true,
                                        )
                                    }
                                "ccTaildropCancelReceiving" -> cc.taildropCancelReceiving(tag, sender, name)
                                else -> cc.taildropMarkRead(tag)
                            }
                        }
                    }
                    result.success(err)
                }
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
            // §707 итер. 5 — Debug API: отправка из байтов / заметки тем же
            // путём, что «Send file…» (уведомление, Cancel), с ожиданием итога.
            // §747 — отправляет `:bg`; байты больше предела Binder идут файлом.
            "ccTaildropSendBytes" -> {
                @Suppress("UNCHECKED_CAST")
                val args = HashMap((call.arguments as? Map<String, Any?>) ?: emptyMap())
                val ctx = context
                BgClient.onLong {
                    val reply = runCatching {
                        val bytes = args["bytes"] as? ByteArray
                        if (bytes != null && bytes.size > BgCodec.XFER_INLINE_MAX) {
                            val f = BgClient.xferFile(ctx, "taildrop-")
                            f.writeBytes(bytes)
                            args.remove("bytes")
                            args["bytes_file"] = f.path
                        }
                        BgClient.call(ctx, "ccTaildropSendBytes", args)
                    }
                    BgClient.onMain { BgClient.answer(result, reply) }
                }
            }
            // §707 итер. 5 — Debug API: снимок входящих узла с sha256 файлов
            // на диске (каталог узла — из последнего собранного конфига).
            "ccTaildropInboxSnapshot" -> {
                val cc = UiCoreSession.ensure()
                val tag = call.argument<String>("tag") ?: ""
                if (cc == null || tag.isEmpty()) {
                    result.success(null)
                } else {
                    pluginScope.launch {
                        val snap = withContext(Dispatchers.IO) { taildropInboxWithHashes(cc, tag) }
                        result.success(snap)
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
            "ccCancelPing" -> {
                UiCoreSession.client?.cancelPing(); result.success(true)
            }
            // §164 — энергомодель. ccSetStatusFast: FAST 0.1с (Stats открыт) /
            // NORMAL 0.5с (главный). ccPauseClients: фон — гасим status+screen
            // (profilerClient НЕ трогаем, recording живёт в фоне). ccResumeClients:
            // возврат из фона — поднимаем status(NORMAL)+screen(если refs>0).
            "ccSetStatusFast" -> {
                val fast = call.argument<Boolean>("fast") ?: false
                UiCoreSession.ensure()?.setStatusFast(fast); result.success(true)
            }
            "ccPauseClients" -> {
                UiCoreSession.client?.apply { pauseStatus(); pauseScreen() }
                result.success(true)
            }
            "ccResumeClients" -> {
                UiCoreSession.ensure()?.apply { resumeStatus(); resumeScreen() }
                result.success(true)
            }
            // §122 — unary CommandClient-RPC БЛОКИРУЮТ (gRPC ждёт ответ ядра до
            // timeout). Вызов прямо в handleMethodCall = на platform main thread →
            // mass-ping (worker-pool=10 блокирующих urlTestOutbound) подвешивал
            // приложение в ANR. Выносим на Dispatchers.IO; result.success обратно
            // на main (pluginScope = Dispatchers.Main).
            "ccUrlTestOutbound" -> {
                val cc = UiCoreSession.ensure()
                if (cc == null) { result.success(mapOf("delay" to 0, "error" to "not connected")); return }
                val tag = call.argument<String>("tag") ?: ""
                val link = call.argument<String>("link") ?: ""
                val timeoutMs = call.argument<Int>("timeoutMs") ?: 0
                pluginScope.launch {
                    val r = withContext(Dispatchers.IO) { cc.urlTestOutbound(tag, link, timeoutMs) }
                    result.success(r)
                }
            }
            // §392 — диагностический GET через узел боевого ядра (kernel SPEC
            // 058). Blocking unary → Dispatchers.IO, как ccUrlTestOutbound:
            // на main thread обмен с телом ответа = гарантированный ANR.
            "ccGetUrlViaOutbound" -> {
                val cc = UiCoreSession.ensure()
                if (cc == null) { result.success(mapOf("error" to "not connected")); return }
                val tag = call.argument<String>("tag") ?: ""
                val link = call.argument<String>("link") ?: ""
                val timeoutMs = call.argument<Int>("timeoutMs") ?: 0
                val maxBytes = call.argument<Int>("maxBytes") ?: 0
                val userAgent = call.argument<String>("userAgent") ?: ""
                pluginScope.launch {
                    val r = withContext(Dispatchers.IO) {
                        cc.getUrlViaOutbound(tag, link, timeoutMs, maxBytes, userAgent)
                    }
                    result.success(r)
                }
            }
            // §308 — групповой URLTest (force-тест всех членов + переселект в
            // ядре). Blocking unary → Dispatchers.IO, как ccUrlTestOutbound.
            "ccUrlTestGroup" -> {
                val cc = UiCoreSession.ensure()
                if (cc == null) { result.success(false); return }
                val tag = call.argument<String>("tag") ?: ""
                pluginScope.launch {
                    val ok = withContext(Dispatchers.IO) { cc.urlTestGroup(tag) }
                    result.success(ok)
                }
            }
            // §236 — headless probe-сессия (Test servers в папке при
            // ВЫКЛЮЧЕННОМ VPN). start/urlTest/cancel/stop; гейт «VPN не запущен» —
            // внутри ProbeSession. Все вызовы блокирующие → Dispatchers.IO.
            // §669 — probeStart отдаёт {error, runId}; остальные вызовы несут
            // runId владельца прогона, чужой/устаревший — no-op («stale run»).
            "probeStart" -> {
                val config = call.argument<String>("config") ?: ""
                pluginScope.launch {
                    val err = withContext(Dispatchers.IO) { ProbeSession.start(config) }
                    result.success(err)
                }
            }
            "probeUrlTest" -> {
                val tag = call.argument<String>("tag") ?: ""
                val link = call.argument<String>("link") ?: ""
                val timeoutMs = call.argument<Int>("timeoutMs") ?: 0
                pluginScope.launch {
                    val r = withContext(Dispatchers.IO) {
                        ProbeSession.urlTest(probeRunId(call), tag, link, timeoutMs)
                    }
                    result.success(r)
                }
            }
            // §392 — тот же диагностический GET, но в probe-сессии (VPN
            // выключен). Форма результата идентична ccGetUrlViaOutbound.
            "probeGetUrl" -> {
                val tag = call.argument<String>("tag") ?: ""
                val link = call.argument<String>("link") ?: ""
                val timeoutMs = call.argument<Int>("timeoutMs") ?: 0
                val maxBytes = call.argument<Int>("maxBytes") ?: 0
                val userAgent = call.argument<String>("userAgent") ?: ""
                pluginScope.launch {
                    val r = withContext(Dispatchers.IO) {
                        ProbeSession.getUrl(probeRunId(call), tag, link, timeoutMs, maxBytes, userAgent)
                    }
                    result.success(r)
                }
            }
            // §669 — обрыв начатых замеров (disconnect клиента сессии, §175).
            "probeCancel" -> {
                val runId = probeRunId(call)
                pluginScope.launch {
                    withContext(Dispatchers.IO) { runCatching { ProbeSession.cancel(runId) } }
                    result.success(null)
                }
            }
            "probeStop" -> {
                val runId = probeRunId(call)
                pluginScope.launch {
                    withContext(Dispatchers.IO) { runCatching { ProbeSession.stop(runId) } }
                    result.success(null)
                }
            }
            // §209 — null = клиент недоступен (различаем от [] = правил нет).
            // Dart getRules превращает null в пустой список (диагностика —
            // отсутствие данных там не отличают от пустых, см. CcChannel.getRules).
            "ccGetRules" -> {
                val cc = UiCoreSession.ensure()
                pluginScope.launch {
                    val r = withContext(Dispatchers.IO) { cc?.getRules() }
                    result.success(r)
                }
            }
            // §122/SPEC015 — unary pull-снапшот групп. null = не смогли прочитать
            // (не-STARTED/нет клиента) → Dart различает от пустого списка и не
            // трогает state. Закрывает потерянный стартовый push (pull-vs-push).
            "ccGetGroups" -> {
                val cc = UiCoreSession.ensure()
                pluginScope.launch {
                    val r = withContext(Dispatchers.IO) { cc?.getGroups() }
                    result.success(r)
                }
            }
            // §535 (ядро SPEC 097) — unary pull плоского списка: единственный
            // источник endpointState/idleSinceSeconds (дерево групп и поток
            // SubscribeOutbounds их не несут). null = не смогли прочитать.
            // Dispatchers.IO — unary RPC на main = ANR (§122).
            "ccGetOutbounds" -> {
                val cc = UiCoreSession.ensure()
                pluginScope.launch {
                    val r = withContext(Dispatchers.IO) { cc?.getOutbounds() }
                    result.success(r)
                }
            }
            // §311/SPEC036 — unary снапшот конфига работающего ядра. null =
            // недоступен (down / не-STARTED / attached / ядро < lx.16-rc.3) —
            // обёртка BoxCommandClient no-throw (runCatching внутри), Dart
            // различает null от строки и деградирует к saved-файлу.
            // Dispatchers.IO — unary RPC на main = ANR (§122).
            // §312/SPEC035 — unary снапшот состояния DNS-групп. null =
            // недоступен (Dart различает от [] «групп нет»); обёртка no-throw.
            // Dispatchers.IO — unary RPC на main = ANR (§122).
            "ccGetDnsGroups" -> {
                val cc = UiCoreSession.ensure()
                pluginScope.launch {
                    val r = withContext(Dispatchers.IO) { cc?.getDnsGroups() }
                    result.success(r)
                }
            }
            "ccGetRunningConfig" -> {
                val cc = UiCoreSession.ensure()
                pluginScope.launch {
                    val r = withContext(Dispatchers.IO) { cc?.getRunningConfig() }
                    result.success(r)
                }
            }
            // §324 — каноническая форма конфига: `Libbox.formatConfig()` прогоняет
            // текст через ТОТ ЖЕ парсер и энкодер, которым ядро делает снапшот
            // работающего конфига (kernel SPEC 037 §3). Даёт сравнимые формы без
            // клиентского списка «различий, которые игнорируем».
            //
            // Статический Go-метод: НЕ требует живого сервиса и libbox.setup —
            // safe в любой момент (как getCoreVersion выше). На Dispatchers.IO:
            // парс большого конфига на main = ANR (§122).
            //
            // КОНТРАКТ: null = ядро не смогло (невалидный конфиг, метод
            // отсутствует в старом .aar, любой throw). Caller деградирует
            // консервативно — «изменилось» (§324).
            "formatConfig" -> {
                val text = call.argument<String>("config") ?: ""
                if (text.isBlank()) {
                    result.success(null)
                } else {
                    pluginScope.launch {
                        val r = withContext(Dispatchers.IO) {
                            try {
                                io.nekohasekai.libbox.Libbox.formatConfig(text)?.value
                            } catch (t: Throwable) {
                                // Невалидный конфиг — ожидаемый случай, не шумим error'ом.
                                Log.d(TAG, "formatConfig failed: ${t.message}")
                                null
                            }
                        }
                        result.success(r)
                    }
                }
            }
            // §455 — проверка тела узла ядром: `Libbox.checkConfig()` = parse +
            // box.New со стабом платформы (experimental/libbox/config.go). Ворота
            // Save для узла с JSON-источником, который уходит в конфиг дословно
            // и гейты модели не проходит. Статический Go-метод, живой сервис не
            // нужен; на Dispatchers.IO — box.New на main = ANR (§122).
            //
            // КОНТРАКТ: {"ok": true} — ядро приняло; {"ok": false, "error": текст
            // ядра} — отвергло. Throw без сообщения — тоже отказ (текст класса).
            "checkConfig" -> {
                val text = call.argument<String>("config") ?: ""
                pluginScope.launch {
                    val r = withContext(Dispatchers.IO) {
                        try {
                            io.nekohasekai.libbox.Libbox.checkConfig(text)
                            mapOf("ok" to true)
                        } catch (t: Throwable) {
                            Log.d(TAG, "checkConfig rejected: ${t.message}")
                            mapOf("ok" to false, "error" to (t.message ?: t.toString()))
                        }
                    }
                    result.success(r)
                }
            }
            // §208/§209 — unary снапшот пула round_robin-группы. На Dispatchers.IO
            // (RPC может блокировать). КОНТРАКТ: null = клиент недоступен (сервис
            // down / pingClient не поднялся) → Dart рендерит «Pool unavailable» /
            // Debug API → 409. [] = пул пуст (не round_robin / нет данных). НЕ
            // затираем null на emptyList — различение критично (§209).
            "ccGetPool" -> {
                val cc = UiCoreSession.ensure()
                val tag = call.argument<String>("tag") ?: ""
                pluginScope.launch {
                    val r = withContext(Dispatchers.IO) { cc?.getPool(tag) }
                    result.success(r)
                }
            }
            "ccSelectOutbound" -> {
                val cc = UiCoreSession.ensure()
                val group = call.argument<String>("group") ?: ""
                val tag = call.argument<String>("tag") ?: ""
                pluginScope.launch {
                    val r = withContext(Dispatchers.IO) { cc?.selectOutbound(group, tag) ?: false }
                    result.success(r)
                }
            }
            // §557 (ядро SPEC 106) — вкл/выкл WG/AWG-узла на лету. Успех →
            // строка состояния узла; отказ ядра → PlatformException с кодом
            // (not_found / invalid_argument / failed_precondition / unavailable
            // / error). Dispatchers.IO — unary RPC на main = ANR (§122).
            "ccSetEndpointEnabled" -> {
                val cc = UiCoreSession.ensure()
                val tag = call.argument<String>("tag") ?: ""
                val enabled = call.argument<Boolean>("enabled") ?: true
                pluginScope.launch {
                    val r = withContext(Dispatchers.IO) {
                        cc?.setEndpointEnabled(tag, enabled)
                            ?: mapOf("error" to "error", "message" to "no command client")
                    }
                    val err = r["error"]
                    if (err != null) {
                        result.error(err, r["message"], null)
                    } else {
                        result.success(r["state"] ?: "")
                    }
                }
            }
            // §613 (ядро SPEC 114) — статус WG/AWG-узла и его пиров. Успех →
            // map состояния; отказ ядра → PlatformException с кодом
            // (not_found / invalid_argument / failed_precondition /
            // unavailable / unimplemented / error).
            "ccGetWireGuardStatus" -> {
                val cc = UiCoreSession.ensure()
                val tag = call.argument<String>("tag") ?: ""
                pluginScope.launch {
                    val r = withContext(Dispatchers.IO) {
                        cc?.getWireGuardStatus(tag)
                            ?: mapOf("error" to "error", "message" to "no command client")
                    }
                    val err = r["error"]
                    if (err != null) {
                        result.error(err.toString(), r["message"]?.toString(), null)
                    } else {
                        result.success(r)
                    }
                }
            }
            "ccCloseConnection" -> {
                val cc = UiCoreSession.ensure()
                val id = call.argument<String>("id") ?: ""
                pluginScope.launch {
                    val r = withContext(Dispatchers.IO) { cc?.closeConnection(id) ?: false }
                    result.success(r)
                }
            }
            "ccCloseConnections" -> {
                val cc = UiCoreSession.ensure()
                pluginScope.launch {
                    val r = withContext(Dispatchers.IO) { cc?.closeConnections() ?: false }
                    result.success(r)
                }
            }
            // §207 — снимок pprof ядра. Имя профиля проверяет по allowlist и сам
            // снимок делает `:bg` (в нём ядро); результат приходит файлом —
            // профиль бывает больше предела Binder. CPU `profile?seconds=N`
            // держит вызов N секунд → свой поток. Ошибка — `PPROF_FAILED`.
            "pprofProfile" -> {
                val args = call.arguments
                val ctx = context
                BgClient.onLong {
                    val reply = runCatching {
                        @Suppress("UNCHECKED_CAST")
                        val path = BgClient.call(ctx, "pprofProfile", args as? Map<String, Any?>) as String
                        val f = java.io.File(path)
                        try { f.readBytes() } finally { f.delete() }
                    }
                    BgClient.onMain { BgClient.answer(result, reply) }
                }
            }

            else -> result.notImplemented()
        }
    }

    /// §669 — runId владельца probe-прогона. Dart-int приезжает Integer или
    /// Long по величине, поэтому через Number; нет аргумента → 0 (ни одна
    /// сессия такого id не получает — вызов уйдёт в «stale run»).
    private fun probeRunId(call: MethodCall): Long =
        call.argument<Number>("runId")?.toLong() ?: 0L

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

    /// §707 итер. 5 — снимок входящих [tag] (форма потока вкладки Network) +
    /// `sha256` у каждого принятого файла (пусто — файла на диске нет или
    /// каталог узла неизвестен). Хэши считает `:bg` (каталог узла — из его
    /// конфига). Блокирующий — звать с IO.
    private fun taildropInboxWithHashes(cc: BoxCommandClient, tag: String): Map<String, Any>? {
        val snap = cc.taildropInboxOnce(tag, 3000L) ?: return null
        @Suppress("UNCHECKED_CAST")
        val list = (snap["files"] as? List<Map<String, Any>>).orEmpty()
        val names = list.map { it["name"] as? String ?: "" }
        val hashes = BgClient.callOr<Map<*, *>?>(
            context, "taildropFileHashes", mapOf("tag" to tag, "names" to names), null,
        ).orEmpty()
        val files = list.map { f ->
            f + ("sha256" to (hashes[f["name"] as? String ?: ""] as? String ?: ""))
        }
        return snap + ("files" to files)
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
