package com.leadaxe.lxbox.vpn

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.VpnService
import android.os.Build
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
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout

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
        private const val VPN_REQUEST_CODE = 24

        // §047 — статические ссылки для bridge'а из LxBoxIntentReceiver (он
        // живёт вне Flutter-плагина). Заполняются в onAttachedToEngine,
        // обнуляются в onDetachedFromEngine. null = Flutter-engine не активен.
        @Volatile
        private var bridgeChannel: MethodChannel? = null
        @Volatile
        private var appContext: Context? = null
        private val bridgeHandler =
            android.os.Handler(android.os.Looper.getMainLooper())

        /// §047 incoming bridge: LxBoxIntentReceiver форвардит intent-action +
        /// extras → Dart (`box_vpn_client` `automationAction` handler) → shared
        /// action-handlers. Если engine не запущен — silently skip.
        fun handleAutomationAction(name: String, args: Map<String, Any?>) {
            val channel = bridgeChannel
            if (channel == null) {
                Log.w(TAG, "[automation] handleAutomationAction($name) — no Flutter engine, skip")
                return
            }
            bridgeHandler.post {
                runCatching {
                    channel.invokeMethod(
                        "automationAction",
                        mapOf("name" to name, "args" to args),
                    )
                }.onFailure {
                    Log.e(TAG, "[automation] invokeMethod(automationAction) failed", it)
                }
            }
        }

        /// §047 outgoing emit: Dart (`AutomationEventEmitter`) шлёт событие
        /// наружу. action — короткое имя (`VPN_CONNECTED`), namespace'ится в
        /// `com.leadaxe.lxbox.event.<action>`. Открыт всем подписчикам — события
        /// не содержат секретов (только лейблы: теги нод, группы, статус); см.
        /// §157 (permission-фильтр удалён вместе с нерабочей галкой).
        fun sendAutomationBroadcast(action: String, extras: Map<String, Any?>) {
            val ctx = appContext ?: return
            val intent = Intent("com.leadaxe.lxbox.event.$action")
            for ((k, v) in extras) {
                when (v) {
                    null -> {}
                    is String -> intent.putExtra(k, v)
                    is Boolean -> intent.putExtra(k, v)
                    is Int -> intent.putExtra(k, v)
                    is Long -> intent.putExtra(k, v)
                    is Double -> intent.putExtra(k, v)
                    else -> intent.putExtra(k, v.toString())
                }
            }
            // setPackage намеренно не выставляем — broadcast открыт всем
            // подписчикам (события без секретов, только лейблы).
            ctx.sendBroadcast(intent)
            Log.d(TAG, "[automation] emit $action (${extras.size} extras)")
        }
    }

    private lateinit var methodChannel: MethodChannel
    private lateinit var statusEventChannel: EventChannel
    private lateinit var coreLogEventChannel: EventChannel
    /// §122 Фаза 0 — EventChannel'ы нового CommandClient-канала.
    private lateinit var ccStatusEventChannel: EventChannel
    private lateinit var ccOutboundsEventChannel: EventChannel
    private lateinit var ccGroupsEventChannel: EventChannel
    private lateinit var ccConnectionsEventChannel: EventChannel
    private lateinit var context: Context
    private var activity: Activity? = null
    private var statusSink: EventChannel.EventSink? = null
    private var pendingVpnResult: MethodChannel.Result? = null
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    /// Scope для suspend-обработчиков method channel — сейчас нужен только
    /// для stopVPN (async wait на setStatus(Stopped)), но переиспользуем
    /// для любых будущих awaitable операций. Отменяется в onDetachedFromEngine.
    private val pluginScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    private val statusReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) {
            if (intent?.action != BoxVpnService.BROADCAST_STATUS) return
            val name = intent.getStringExtra(BoxVpnService.EXTRA_STATUS) ?: return
            val error = intent.getStringExtra("error")
            Log.d(TAG, "[vpn] plugin.statusReceiver.onReceive name=$name${if (error != null) " error=$error" else ""} sink=${statusSink != null}")
            mainHandler.post {
                val event = mutableMapOf<String, Any>("status" to name)
                if (error != null) event["error"] = error
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

    // -------------------------------------------------------------------------
    // FlutterPlugin
    // -------------------------------------------------------------------------

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        Log.d(TAG, "onAttachedToEngine")
        context = binding.applicationContext
        BoxApplication.initialize(context)

        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
        methodChannel.setMethodCallHandler(this)
        // §047 — статические bridge-ссылки для LxBoxIntentReceiver.
        bridgeChannel = methodChannel
        appContext = context

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
        // PlatformInterface.writeDebugMessage в BoxVpnService → coreLogSink
        // (Volatile companion field) → этот EventChannel → ClashLogPump в Dart.
        coreLogEventChannel = EventChannel(binding.binaryMessenger, CORE_LOG_CHANNEL)
        coreLogEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                Log.d(TAG, "[vpn] coreLogEventChannel.onListen — sink installed")
                BoxVpnService.coreLogSink = sink
            }
            override fun onCancel(args: Any?) {
                Log.d(TAG, "[vpn] coreLogEventChannel.onCancel — sink cleared")
                BoxVpnService.coreLogSink = null
            }
        })

        // §122 Фаза 0 — 4 канала CommandClient (status/outbounds/groups/connections).
        // BoxCommandClient.handler пушит снапшоты в BoxVpnService.cc*Sink → сюда → Dart.
        ccStatusEventChannel = EventChannel(binding.binaryMessenger, CC_STATUS_CHANNEL)
        ccStatusEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) { BoxVpnService.ccStatusSink = sink }
            override fun onCancel(args: Any?) { BoxVpnService.ccStatusSink = null }
        })
        ccOutboundsEventChannel = EventChannel(binding.binaryMessenger, CC_OUTBOUNDS_CHANNEL)
        ccOutboundsEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) { BoxVpnService.ccOutboundsSink = sink }
            override fun onCancel(args: Any?) { BoxVpnService.ccOutboundsSink = null }
        })
        ccGroupsEventChannel = EventChannel(binding.binaryMessenger, CC_GROUPS_CHANNEL)
        ccGroupsEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) { BoxVpnService.ccGroupsSink = sink }
            override fun onCancel(args: Any?) { BoxVpnService.ccGroupsSink = null }
        })
        ccConnectionsEventChannel = EventChannel(binding.binaryMessenger, CC_CONNECTIONS_CHANNEL)
        ccConnectionsEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) { BoxVpnService.ccConnectionsSink = sink }
            override fun onCancel(args: Any?) { BoxVpnService.ccConnectionsSink = null }
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
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        Log.d(TAG, "[vpn] onDetachedFromEngine: unregisterReceiver(statusReceiver)")
        methodChannel.setMethodCallHandler(null)
        statusEventChannel.setStreamHandler(null)
        coreLogEventChannel.setStreamHandler(null)
        ccStatusEventChannel.setStreamHandler(null)
        ccOutboundsEventChannel.setStreamHandler(null)
        ccGroupsEventChannel.setStreamHandler(null)
        ccConnectionsEventChannel.setStreamHandler(null)
        statusSink = null
        BoxVpnService.coreLogSink = null
        BoxVpnService.ccStatusSink = null
        BoxVpnService.ccOutboundsSink = null
        BoxVpnService.ccGroupsSink = null
        BoxVpnService.ccConnectionsSink = null
        // §047 — обнуляем bridge-ссылки (engine detached).
        bridgeChannel = null
        appContext = null
        runCatching { context.unregisterReceiver(statusReceiver) }
        pluginScope.cancel()
    }

    // -------------------------------------------------------------------------
    // MethodCallHandler
    // -------------------------------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        Log.d(TAG, "onMethodCall: ${call.method}")
        when (call.method) {
            "saveConfig" -> {
                val config = call.argument<String>("config") ?: ""
                result.success(ConfigManager.save(config))
            }
            "getConfig" -> result.success(ConfigManager.load())
            "startVPN" -> startVpn(result)
            "stopVPN" -> stopVpn(result)
            "forceStopVPN" -> {
                // §129 — жёсткая остановка при зависшем-вхолостую ядре. Fire-and-
                // forget: BoxService.doForceStop сам делает stopSelf() не дожидаясь
                // setStatus(Stopped) от ядра. Не ждём (в отличие от stopVPN).
                BoxVpnService.forceStop(context)
                result.success(true)
            }
            "getVpnStatus" -> {
                // Pull-метод для re-sync UI после reattach Flutter-процесса
                // (broadcast'ятся только переходы — если service уже Started,
                // новый плагин ничего не получит без явного запроса).
                result.success(BoxVpnService.currentStatus.name)
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
            "reloadVPN" -> {
                // Spec 030: in-place reload sing-box runtime через
                // CommandServer.startOrReloadService — без recreate'а Android Service.
                BoxVpnService.reload(context)
                result.success(true)
            }
            "resetNetwork" -> {
                // Spec 031 (experimental): box.Router().ResetNetwork() — gentle
                // reset network sub-state без drop'а runtime.
                BoxVpnService.resetNetwork(context)
                result.success(true)
            }
            "setNotificationTitle" -> {
                val title = call.argument<String>("title") ?: "L×Box"
                ConfigManager.setNotificationTitle(title)
                result.success(true)
            }
            "setNotificationText" -> {
                // §123 — подтекст уведомления (тег активной ноды / route.final).
                val text = call.argument<String>("text") ?: ""
                ConfigManager.setNotificationText(text)
                result.success(true)
            }
            "setAutoStart" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                BootReceiver.setEnabled(context, enabled)
                result.success(true)
            }
            "getAutoStart" -> {
                result.success(BootReceiver.isEnabled(context))
            }
            "setKeepOnExit" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                BootReceiver.setKeepOnExit(context, enabled)
                result.success(true)
            }
            "getKeepOnExit" -> {
                result.success(BootReceiver.isKeepOnExit(context))
            }
            "setCoreLogsEnabled" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                BootReceiver.setCoreLogsEnabled(context, enabled)
                result.success(true)
            }
            "getCoreLogsEnabled" -> {
                result.success(BootReceiver.isCoreLogsEnabled(context))
            }
            // §049 F15 fix: allowBypass opt-in toggle (применяется при следующем
            // openTun → требует reload VPN после изменения).
            "setAllowBypass" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                BootReceiver.setAllowBypass(context, enabled)
                result.success(true)
            }
            "getAllowBypass" -> {
                result.success(BootReceiver.isAllowBypass(context))
            }
            // §069: runtime applied value (от последнего establish()), в отличие
            // от persisted getAllowBypass() который меняется до VPN reload.
            "getCurrentSessionAllowBypass" -> {
                result.success(BoxVpnService.currentSessionAllowBypass)
            }
            "quitApp" -> {
                // §043 follow-up: завершить процесс целиком, чтобы при следующем
                // запуске `BoxApplication.initialize` пересоздал libbox с новым
                // флагом `debug` (см. SetupOptions в BoxApplication.kt — setup
                // зовётся ровно один раз за жизнь процесса).
                //
                // 1. finishAffinity() закрывает все наши activities,
                // 2. через 200ms killProcess + exitProcess убивают процесс
                //    (некоторые OEM-launchers иначе оставляют zombie).
                //
                // VPN service ещё может быть активен — Android сам его
                // остановит как только процесс умрёт (foreground service binding
                // с процессом). KEEP_ON_EXIT не реактивируем здесь: если юзер
                // явно запросил Quit, ему нужен полный рестарт, не fall-through
                // в keep-alive путь.
                result.success(true)
                mainHandler.postDelayed({
                    activity?.finishAffinity()
                }, 50)
                mainHandler.postDelayed({
                    android.os.Process.killProcess(android.os.Process.myPid())
                    kotlin.system.exitProcess(0)
                }, 250)
            }
            "getInstalledApps" -> {
                // Lightweight metadata only — иконки лениво подгружаются
                // через getAppIcon по пакету. PNG-encode всех иконок в одном
                // проходе — 500*20ms = 10s блокировки UI, недопустимо.
                val pm = context.packageManager
                val apps = pm.getInstalledApplications(0).map { info ->
                    val isSystem = (info.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0
                    mapOf(
                        "packageName" to info.packageName,
                        "appName" to (pm.getApplicationLabel(info)?.toString() ?: info.packageName),
                        "isSystemApp" to isSystem,
                    )
                }
                result.success(apps)
            }
            "getAppIcon" -> {
                val pkg = call.argument<String>("packageName") ?: ""
                result.success(encodeAppIcon(pkg))
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
                val pm = context.packageManager
                try {
                    val info = pm.getApplicationInfo(pkg, 0)
                    val isSystem = (info.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0
                    result.success(mapOf(
                        "packageName" to pkg,
                        "appName" to (pm.getApplicationLabel(info)?.toString() ?: pkg),
                        "isSystemApp" to isSystem,
                    ))
                } catch (_: android.content.pm.PackageManager.NameNotFoundException) {
                    result.success(mapOf("notFound" to true))
                } catch (e: Exception) {
                    result.error("APP_INFO_ERROR", e.message, null)
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
            "getBackgroundMode" -> {
                result.success(BootReceiver.getBackgroundMode(context))
            }
            "setBackgroundMode" -> {
                val mode = call.argument<String>("mode") ?: BootReceiver.BG_MODE_NEVER
                BootReceiver.setBackgroundMode(context, mode)
                result.success(null)
            }
            "openNotificationSettings" -> {
                // API 26+ имеет прямой action ACTION_APP_NOTIFICATION_SETTINGS,
                // он передаёт пакет через extra, а не через data URI.
                // Fallback — ACTION_APPLICATION_DETAILS_SETTINGS (pre-26 или
                // если прямой action не найден OEM).
                result.success(openNotificationSettings())
            }
            "requestAddTile" -> {
                // §032 Quick Connect. API 33+ позволяет приложению попросить
                // систему показать prompt «Add L×Box to Quick Settings?».
                // На API < 33 возвращаем "unsupported" — Dart-сторона покажет
                // текстовую инструкцию вместо кнопки.
                requestAddQuickSettingsTile(result)
            }
            // §047 Automation API — Dart → native control + outgoing emit.
            "setAutomationEnabled" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                LxBoxIntentReceiver.setEnabled(context, enabled)
                result.success(true)
            }
            "sendAutomationBroadcast" -> {
                val action = call.argument<String>("action") ?: ""
                @Suppress("UNCHECKED_CAST")
                val extras = (call.argument<Map<String, Any?>>("extras")
                    ?: emptyMap())
                if (action.isNotEmpty()) {
                    sendAutomationBroadcast(action, extras)
                }
                result.success(true)
            }
            // §047 Шаг 2 — зеркалим активную ноду/группу + списки нод/групп в
            // native-кеш. Активное состояние нужно LocaleConditionReceiver
            // (синхронный ответ на QUERY_CONDITION); списки — edit-Activity
            // плагина (Spinner выбора ноды/группы вместо ручного ввода).
            // Flutter-engine при чтении может спать, потому именно prefs.
            "setAutomationActiveState" -> {
                val node = call.argument<String>("node")
                val group = call.argument<String>("group")
                val nodes = call.argument<List<String>>("nodes")
                val groups = call.argument<List<String>>("groups")
                val edit = context
                    .getSharedPreferences("lxbox_automation", Context.MODE_PRIVATE)
                    .edit()
                    .putString("active_node", node)
                    .putString("active_group", group)
                // Списки сериализуем как JSON-массив строк. null → не трогаем
                // (caller мог обновить только активное состояние).
                if (nodes != null) {
                    edit.putString("all_nodes", org.json.JSONArray(nodes).toString())
                }
                if (groups != null) {
                    edit.putString("all_groups", org.json.JSONArray(groups).toString())
                }
                edit.apply()
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
            "ccConnectScreen" -> {
                BoxService.commandClient?.connectScreen(); result.success(true)
            }
            "ccDisconnectScreen" -> {
                BoxService.commandClient?.disconnectScreen(); result.success(true)
            }
            "ccConnectProfiler" -> {
                BoxService.commandClient?.connectProfiler(); result.success(true)
            }
            "ccDisconnectProfiler" -> {
                BoxService.commandClient?.disconnectProfiler(); result.success(true)
            }
            "ccUrlTestOutbound" -> {
                val cc = BoxService.commandClient
                if (cc == null) { result.success(mapOf("delay" to 0, "error" to "not connected")); return }
                val tag = call.argument<String>("tag") ?: ""
                val link = call.argument<String>("link") ?: ""
                val timeoutMs = call.argument<Int>("timeoutMs") ?: 0
                result.success(cc.urlTestOutbound(tag, link, timeoutMs))
            }
            "ccGetRules" -> {
                result.success(BoxService.commandClient?.getRules() ?: emptyList<Map<String, Any>>())
            }
            "ccSelectOutbound" -> {
                val group = call.argument<String>("group") ?: ""
                val tag = call.argument<String>("tag") ?: ""
                result.success(BoxService.commandClient?.selectOutbound(group, tag) ?: false)
            }
            "ccCloseConnection" -> {
                val id = call.argument<String>("id") ?: ""
                result.success(BoxService.commandClient?.closeConnection(id) ?: false)
            }
            "ccCloseConnections" -> {
                result.success(BoxService.commandClient?.closeConnections() ?: false)
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
                "L×Box",
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
                drawable.bitmap
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
        } catch (_: Exception) {
            ""
        }
    }

    private fun startVpn(result: MethodChannel.Result) {
        val act = activity
        if (act == null) {
            result.error("NO_ACTIVITY", "No activity", null)
            return
        }
        val intent = VpnService.prepare(act)
        if (intent != null) {
            pendingVpnResult = result
            act.startActivityForResult(intent, VPN_REQUEST_CODE)
        } else {
            BoxVpnService.start(context)
            result.success(true)
        }
    }

    /// Blocking stop: на native-стороне ждём пока setStatus(Stopped) реально
    /// отработает (после async cleanup libbox-ресурсов), чтобы caller в Dart
    /// мог последовательно сделать `await stopVPN()` → `await startVPN()`
    /// без race'а в onStartCommand guard (`status != Stopped` → silent).
    ///
    /// Таймаут 5с — если doStop не доиграл, возвращаем `false`. Caller
    /// (обычно reconnect) сам решит отменить или повторить.
    private fun stopVpn(result: MethodChannel.Result) {
        pluginScope.launch {
            val ok = try {
                withTimeout(5_000) {
                    BoxVpnService.stopAwait(context).await()
                }
                true
            } catch (e: TimeoutCancellationException) {
                Log.w(TAG, "[vpn] stopVPN: 5s timeout — native did not report Stopped")
                false
            } catch (e: Exception) {
                Log.e(TAG, "[vpn] stopVPN: exception $e")
                false
            }
            result.success(ok)
        }
    }

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

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != VPN_REQUEST_CODE) return false
        val r = pendingVpnResult
        pendingVpnResult = null
        if (resultCode == Activity.RESULT_OK) {
            BoxVpnService.start(context)
            r?.success(true)
        } else {
            r?.success(false)
        }
        return true
    }
}
