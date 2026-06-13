package com.leadaxe.lxbox.vpn

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.SystemProxyStatus
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.atomic.AtomicReference

/// §049 F1 split — port из reference SagerNet
/// (`bg/BoxService.kt` commit 3b3883e, libbox 1.13.11).
///
/// `BoxService` — plain class, implements **только** `CommandServerHandler`.
/// Владеет state'ом (`fileDescriptor`, `commandServer`, `serviceScope`, etc.)
/// и lifecycle'ом libbox-runtime'а.
///
/// `BoxVpnService` (Android Service + `PlatformInterfaceWrapper`) держит
/// `private val service = BoxService(this, this)` в **field initializer** и
/// форвардит все Android lifecycle callbacks в `service.X()`.
///
/// `CommandServer(this, platformInterface)` создаётся с 2 разных Java
/// instance: `this` = CSH=BoxService, `platformInterface` = PI=BoxVpnService.
class BoxService(
    private val service: Service,
    private val platformInterface: PlatformInterface,
) : CommandServerHandler {

    companion object {
        private const val TAG = "BoxService"
    }

    /// Scoped to service lifetime — all child coroutines are cancelled in onDestroy / doStop.
    /// Recreated on each start since cancel() is terminal for a scope.
    private var serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private fun resetScope() {
        serviceScope.cancel()
        serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    }

    /// §049 F2 — `AtomicReference` вместо `@Volatile`. `getAndSet(null)?.close()`
    /// гарантирует что только один поток выполнит close(); остальные — no-op.
    /// Главный fix для §047 race condition на mutations `fileDescriptor`.
    /// Public для `BoxVpnService.openTun()` которому нужен `set(pfd)`.
    val fileDescriptor = AtomicReference<ParcelFileDescriptor?>(null)

    /// §049 F2/F3 — same atomic CAS pattern для commandServer.
    private val commandServer = AtomicReference<CommandServer?>(null)
    private var receiverRegistered = false
    private var status = VpnStatus.Stopped

    private val notification: ServiceNotification by lazy { ServiceNotification(service) }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            Log.d(TAG, "[vpn] service.receiver.onReceive action=${intent.action} status=${status.name} registered=$receiverRegistered")
            when (intent.action) {
                BoxVpnService.ACTION_STOP -> doStop()
                BoxVpnService.ACTION_RELOAD -> {
                    Log.d(TAG, "[vpn] receiver: ACTION_RELOAD → serviceReload()")
                    runCatching { serviceReload() }
                        .onFailure { Log.e(TAG, "ACTION_RELOAD failed", it) }
                }
                BoxVpnService.ACTION_RESET_NETWORK -> {
                    Log.d(TAG, "[vpn] receiver: ACTION_RESET_NETWORK → cs.resetNetwork()")
                    runCatching { commandServer.get()?.resetNetwork() }
                        .onFailure { Log.e(TAG, "ACTION_RESET_NETWORK failed", it) }
                }
                PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) onIdleModeChanged()
                }
                Intent.ACTION_SCREEN_OFF -> {
                    Log.d(TAG, "[vpn] SCREEN_OFF → pause")
                    commandServer.get()?.pause()
                }
                Intent.ACTION_SCREEN_ON -> {
                    Log.d(TAG, "[vpn] SCREEN_ON → wake")
                    commandServer.get()?.wake()
                }
            }
        }
    }

    // -------------------------------------------------------------------------
    // Android lifecycle (forwarded from BoxVpnService)
    // -------------------------------------------------------------------------

    fun onCreate() {
        // Сервис может стартануть в свежем процессе без UI (через QS-tile
        // или launcher shortcut, после того как Android прибил предыдущий
        // процесс из-за SIGABRT/OOM). В таком процессе VpnPlugin не
        // подключается, и `BoxApplication.initialize` сам по себе не
        // вызовется — а `application` lateinit, libbox setup отсутствует
        // → onStartCommand упадёт с UninitializedPropertyAccessException.
        // initialize() идемпотентен (if (initialized) return).
        BoxApplication.initialize(service.applicationContext)
    }

    fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "[vpn] onStartCommand action=${intent?.action} status=${status.name} startId=$startId receiverRegistered=$receiverRegistered")
        notification.show(ConfigManager.notificationTitle, "Starting...")

        if (status != VpnStatus.Stopped) {
            Log.w(TAG, "[vpn] onStartCommand GUARD — status=${status.name} != Stopped, silent return")
            return Service.START_NOT_STICKY
        }
        resetScope()
        setStatus(VpnStatus.Starting)

        if (!receiverRegistered) {
            val mode = BootReceiver.getBackgroundMode(service)
            Log.d(TAG, "[vpn] registerReceiver from onStartCommand mode=$mode")
            ContextCompat.registerReceiver(service, receiver, IntentFilter().apply {
                addAction(BoxVpnService.ACTION_STOP)
                addAction(BoxVpnService.ACTION_RELOAD)
                addAction(BoxVpnService.ACTION_RESET_NETWORK)
                when (mode) {
                    BootReceiver.BG_MODE_LAZY -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            addAction(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
                        }
                    }
                    BootReceiver.BG_MODE_ALWAYS -> {
                        addAction(Intent.ACTION_SCREEN_OFF)
                        addAction(Intent.ACTION_SCREEN_ON)
                    }
                }
            }, ContextCompat.RECEIVER_NOT_EXPORTED)
            receiverRegistered = true
        }

        serviceScope.launch {
            try {
                BoxApplication.libboxReady.await()
                startCommandServer()
                startSingbox()
            } catch (t: Throwable) {
                Log.e(TAG, "Start failed", t)
                stopAndAlert(t.message ?: "Unknown error")
            }
        }
        return Service.START_NOT_STICKY
    }

    fun onDestroy() {
        Log.d(TAG, "[vpn] onDestroy status=${status.name} receiverRegistered=$receiverRegistered")
        serviceScope.cancel()
        if (receiverRegistered) {
            runCatching { service.unregisterReceiver(receiver) }
            receiverRegistered = false
        }
        if (BoxVpnService.currentStatus != VpnStatus.Stopped) {
            BoxVpnService.setCurrentStatus(VpnStatus.Stopped)
            runCatching { LxBoxTileService.refreshTile(service.applicationContext) }
                .onFailure { Log.w(TAG, "refreshTile in onDestroy failed: ${it.message}") }
        }
    }

    fun onTaskRemoved(rootIntent: Intent?) {
        if (!BootReceiver.isKeepOnExit(service)) {
            Log.d(TAG, "App removed from recents — stopping VPN")
            doStop()
        }
    }

    fun onRevoke() {
        Log.d(TAG, "onRevoke — VPN taken by another app")
        // §049 F5 — atomic close, безопасно на любом thread'е.
        closeFileDescriptor()
        closeCommandServerAtomic("revoke")

        if (receiverRegistered) {
            runCatching { service.unregisterReceiver(receiver) }
            receiverRegistered = false
        }
        notification.stop()
        setStatus(VpnStatus.Stopped, error = "VPN revoked by another app")
        serviceScope.cancel()
        service.stopSelf()
    }

    // -------------------------------------------------------------------------
    // Start / stop sing-box
    // -------------------------------------------------------------------------

    private fun closeFileDescriptor() {
        fileDescriptor.getAndSet(null)?.runCatching { close() }
            ?.onFailure { Log.w(TAG, "closeFileDescriptor: close failed: ${it.message}") }
    }

    private fun closeCommandServerAtomic(reason: String) {
        val cs = commandServer.getAndSet(null) ?: return
        runCatching { cs.closeService() }.onFailure {
            Log.e(TAG, "closeCommandServerAtomic($reason): closeService failed", it)
            runCatching { cs.setError("android: $reason close service: ${it.message}") }
        }
        runCatching { cs.close() }
            .onFailure { Log.w(TAG, "closeCommandServerAtomic($reason): close failed: ${it.message}") }
    }

    private suspend fun startSingbox() {
        try {
            BoxApplication.libboxReady.await()
        } catch (t: Throwable) {
            stopAndAlert("Libbox init failed: ${t.message}")
            return
        }

        val config = ConfigManager.load()
        if (config.isBlank() || config == "{}") {
            stopAndAlert("Empty configuration")
            return
        }

        // §087 — на genuine смену интерфейса (WiFi↔LTE) дёргаем resetNetwork()
        // (ядро CloseAll + flush DNS + rebind): закрывает стейл-сокеты на мёртвом
        // NIC, иначе app виснет на них до TCP-таймаута. См. docs/spec/tasks/087.
        DefaultNetworkMonitor.start(serviceScope) {
            Log.d(TAG, "[vpn] interface switch → resetNetwork()")
            runCatching { commandServer.get()?.resetNetwork() }
                .onFailure { Log.e(TAG, "auto resetNetwork failed", it) }
        }
        Libbox.setMemoryLimit(true)

        val cs = commandServer.get() ?: run {
            stopAndAlert("CommandServer not initialized")
            return
        }

        try {
            cs.startOrReloadService(config, OverrideOptions())
        } catch (t: Throwable) {
            stopAndAlert("Failed to start service: ${t.message}")
            return
        }

        // §050 — port from reference SagerNet BoxService.kt 1.13.11
        // (`needWIFIState` block after startOrReloadService).
        //
        // Sing-box config may contain DNS/route rules with `wifi_ssid:`
        // or `wifi_bssid:` conditions. After config parse, sing-box exposes
        // whether wifi state is needed via `needWIFIState()`. If yes AND
        // Location permission is not granted (`ACCESS_BACKGROUND_LOCATION`
        // on API 29+, `ACCESS_FINE_LOCATION` on API 28-), then
        // `WifiManager.getConnectionInfo()` throws SecurityException which
        // propagates through JNI → process abort.
        //
        // Stop service with a structured alert prefix (`alert:permission:...`).
        // Flutter side detects prefix and shows native AlertDialog with
        // "Open Settings" button (see HomeController._handleStatusEvent).
        if (runCatching { cs.needWIFIState() }.getOrDefault(false)) {
            // Permission matrix for `WifiManager.connectionInfo`:
            //  - API 28-:  ACCESS_FINE_LOCATION
            //  - API 29-32: ACCESS_BACKGROUND_LOCATION (background access required)
            //  - API 33+:  ACCESS_BACKGROUND_LOCATION + NEARBY_WIFI_DEVICES
            //              (без NEARBY ssid возвращается как "<unknown ssid>"
            //               когда targetSdk >= 33).
            val needed = mutableListOf<String>()
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                needed += android.Manifest.permission.ACCESS_FINE_LOCATION
            } else {
                needed += android.Manifest.permission.ACCESS_BACKGROUND_LOCATION
            }
            if (Build.VERSION.SDK_INT >= 33) {
                needed += "android.permission.NEARBY_WIFI_DEVICES"
            }
            val missing = needed.filter {
                service.checkSelfPermission(it) !=
                    android.content.pm.PackageManager.PERMISSION_GRANTED
            }
            if (missing.isNotEmpty()) {
                Log.e(TAG, "[vpn] config requires WIFI state but missing: $missing")
                // Structured alert: `alert:<type>:<details>` — Flutter parses
                // type and shows AlertDialog with "Open Settings" button.
                stopAndAlert("alert:permission_location:${missing.joinToString(",")}")
                return
            }
            Log.d(TAG, "[vpn] sing-box uses WIFI state, all permissions granted: $needed")
        }

        setStatus(VpnStatus.Started)

        withContext(Dispatchers.Main) {
            // §123 — подтекст = тег активной ноды / route.final (из Dart через
            // setNotificationText). Пусто → fallback на статус "Connected".
            notification.show(
                ConfigManager.notificationTitle,
                ConfigManager.notificationText.ifEmpty { "Connected" },
            )
        }
    }

    /// §049 F1 — `CommandServer(handler=this, platform=platformInterface)`
    /// с двумя разными Java instances (port из reference 1.13.11).
    private fun startCommandServer() {
        val cs = CommandServer(this, platformInterface)
        cs.start()
        commandServer.set(cs)
    }

    private fun doStop() {
        Log.d(TAG, "[vpn] doStop ENTER status=${status.name} receiverRegistered=$receiverRegistered")
        if (status == VpnStatus.Stopped || status == VpnStatus.Stopping) {
            Log.w(TAG, "[vpn] doStop GUARD — already ${status.name}, return without action")
            return
        }
        setStatus(VpnStatus.Stopping)

        if (receiverRegistered) {
            Log.d(TAG, "[vpn] unregisterReceiver from doStop")
            runCatching { service.unregisterReceiver(receiver) }
            receiverRegistered = false
        }
        notification.stop()

        serviceScope.launch {
            closeFileDescriptor()
            DefaultNetworkMonitor.stop()
            closeCommandServerAtomic("doStop")

            withContext(Dispatchers.Main) {
                Log.d(TAG, "[vpn] doStop cleanup done → setStatus(Stopped) + stopSelf()")
                setStatus(VpnStatus.Stopped)
                service.stopSelf()
            }
        }
    }

    private suspend fun stopAndAlert(message: String) {
        Log.e(TAG, "stopAndAlert: $message")
        // CRITICAL: full sing-box teardown ДО stopSelf'а. Раньше пропускали
        // closeFileDescriptor / closeCommandServerAtomic / DefaultNetworkMonitor.stop —
        // CommandServer держал binding на Clash API port (63130) даже после
        // service stop, и retry start VPN failed с
        // `external controller listen error: bind: address already in use`.
        // Same teardown sequence что и `doStop`, но в Main thread без
        // serviceScope.launch (мы уже в suspend) и с error message в
        // `setStatus(Stopped)` вместо silent stop.
        closeFileDescriptor()
        DefaultNetworkMonitor.stop()
        closeCommandServerAtomic("stopAndAlert: $message")

        withContext(Dispatchers.Main) {
            notification.show("Error", message)
            if (receiverRegistered) {
                runCatching { service.unregisterReceiver(receiver) }
                receiverRegistered = false
            }
            notification.stop()
            setStatus(VpnStatus.Stopped, error = message)
            service.stopSelf()
        }
    }

    private fun setStatus(newStatus: VpnStatus, error: String? = null) {
        Log.d(TAG, "[vpn] setStatus(${newStatus.name})${if (error != null) " error=$error" else ""} — sendBroadcast")
        status = newStatus
        BoxVpnService.setCurrentStatus(newStatus)

        if (newStatus == VpnStatus.Stopped) {
            BoxVpnService.completeStopIfWaiting()
        }
        service.sendBroadcast(
            Intent(BoxVpnService.BROADCAST_STATUS).apply {
                `package` = service.packageName
                putExtra(BoxVpnService.EXTRA_STATUS, newStatus.name)
                if (error != null) putExtra("error", error)
            }
        )
        runCatching { LxBoxTileService.refreshTile(service.applicationContext) }
            .onFailure { Log.w(TAG, "refreshTile failed: ${it.message}") }
        runCatching { QuickShortcuts.refresh(service.applicationContext) }
            .onFailure { Log.w(TAG, "QuickShortcuts.refresh failed: ${it.message}") }
    }

    @RequiresApi(Build.VERSION_CODES.M)
    private fun onIdleModeChanged() {
        val cs = commandServer.get() ?: return
        if (BoxApplication.powerManager.isDeviceIdleMode) cs.pause() else cs.wake()
    }

    // -------------------------------------------------------------------------
    // CommandServerHandler overrides
    // -------------------------------------------------------------------------

    /// §049 F4 — без status-flap (Started → Starting → Started) при reload.
    /// Match reference (`BoxService.kt:192-249 serviceReload0`).
    override fun serviceReload() {
        val cs = commandServer.get() ?: run {
            Log.w(TAG, "serviceReload: commandServer == null, treating as fresh start")
            notification.stop()
            setStatus(VpnStatus.Starting)
            serviceScope.launch { startSingbox() }
            return
        }
        val config = ConfigManager.load()
        if (config.isBlank() || config == "{}") {
            Log.e(TAG, "serviceReload: empty config")
            return
        }
        runCatching { cs.startOrReloadService(config, OverrideOptions()) }
            .onFailure {
                Log.e(TAG, "serviceReload failed", it)
                runCatching { cs.setError("android: reload: ${it.message}") }
            }
    }

    override fun serviceStop() { doStop() }

    /// §049 F17 — реальный state HTTP-proxy для Clash dashboard.
    /// Match reference: cast service → VPNService и читаем флаги (у нас
    /// `BoxVpnService` хранит их как `@JvmField`-properties).
    override fun getSystemProxyStatus(): SystemProxyStatus = SystemProxyStatus().apply {
        if (service is BoxVpnService) {
            available = service.systemProxyAvailable
            enabled = service.systemProxyEnabled
        }
    }

    override fun setSystemProxyEnabled(isEnabled: Boolean) { serviceReload() }

    /// §043: sing-box log lines проходят сюда независимо от `log.level`
    /// в конфиге. INFO+ пушим в Flutter через EventChannel "lxbox/coreLog".
    ///
    /// **F22 part 2 — производственный pipeline:**
    /// - Никакого `@Synchronized`: `LinkedBlockingQueue.offer` thread-safe сам,
    ///   а `@Synchronized` сериализовал бы sing-box goroutines на mutex и
    ///   не давал ничего полезного.
    /// - **Back-pressure cap** `LOG_QUEUE_MAX = 4096`: при slow Dart consumer'е
    ///   очередь не растёт без предела. Drop newest когда полно — потеря
    ///   visibility одного-двух batch'ей лучше OOM.
    /// - Single lazy `coreLogDrainer` Runnable. Никаких per-call lambda /
    ///   anonymous class allocations.
    /// - **Batching**: drainer отдаёт `List<String>` в `sink.success(list)` —
    ///   один JNI marshal на N строк вместо N marshall'ов. Dart side
    ///   принимает `List<dynamic>` (см. `clash_log_pump.dart`).
    /// - **Yield** каждые `DRAIN_BATCH_MAX = 200` строк: re-post Runnable если
    ///   queue ещё не пуст. Длинный burst не блочит main looper > одного frame.
    override fun writeDebugMessage(message: String) {
        val plain = ansiEscapeRe.replace(message, "")
        if (traceDebugRe.containsMatchIn(plain)) return
        if (BoxVpnService.coreLogSink == null) return
        // Back-pressure: drop newest, не блокируем sing-box producer thread.
        if (coreLogQueue.size >= LOG_QUEUE_MAX) {
            coreLogDrops.incrementAndGet()
            return
        }
        coreLogQueue.offer(plain)
        if (drainerScheduled.compareAndSet(false, true)) {
            coreLogMainHandler.post(coreLogDrainer)
        }
    }

    private val ansiEscapeRe = Regex("\\[[0-9;]*[A-Za-z]")
    private val traceDebugRe = Regex("\\b(TRACE|DEBUG)\\b")

    /// Cap размера очереди — `4096 * ~80 chars ≈ 320KB` worst case в queue.
    /// Drop newest при переполнении (sing-box producer thread не блокируется).
    private val LOG_QUEUE_MAX = 4096

    /// Сколько строк drainer отдаёт за один main-looper run перед yield'ом.
    /// 200 строк ≈ 1 frame (~16ms) при типичной marshal-цене.
    private val DRAIN_BATCH_MAX = 200

    private val coreLogQueue: java.util.concurrent.LinkedBlockingQueue<String> by lazy {
        java.util.concurrent.LinkedBlockingQueue()
    }
    private val drainerScheduled = java.util.concurrent.atomic.AtomicBoolean(false)
    private val coreLogDrops = java.util.concurrent.atomic.AtomicLong(0)

    /// **F22 single Runnable** — создаётся ОДИН раз при first access (lazy),
    /// reused на каждый `Handler.post(coreLogDrainer)`. Никаких per-call
    /// Lambda/anonymous class allocations. Hold strong ref в field.
    ///
    /// Drains до `DRAIN_BATCH_MAX` строк, эмитит как `List<String>` одним
    /// JNI вызовом, потом если queue не пустой — re-post (yield для frame).
    private val coreLogDrainer: Runnable by lazy {
        Runnable {
            drainerScheduled.set(false)
            val sink = BoxVpnService.coreLogSink ?: run { coreLogQueue.clear(); return@Runnable }
            val batch = ArrayList<String>(DRAIN_BATCH_MAX.coerceAtMost(64))
            var taken = 0
            while (taken < DRAIN_BATCH_MAX) {
                val line = coreLogQueue.poll() ?: break
                batch.add(line)
                taken++
            }
            if (batch.isNotEmpty()) {
                runCatching { sink.success(batch) }
            }
            // Если queue ещё что-то держит — re-schedule, не блочим main looper.
            if (coreLogQueue.isNotEmpty() &&
                drainerScheduled.compareAndSet(false, true)) {
                coreLogMainHandler.post(coreLogDrainer)
            }
        }
    }

    private val coreLogMainHandler by lazy {
        android.os.Handler(android.os.Looper.getMainLooper())
    }

    /// `sendNotification` (spec §036) — system notification с clickable ссылкой.
    /// Sing-box зовёт `sendNotification` через PlatformInterface (на BoxVpnService),
    /// который форвардит сюда.
    fun sendNotification(notification: io.nekohasekai.libbox.Notification) {
        val context = service.applicationContext
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        val channelId = notification.identifier.ifBlank { "lxbox-core" }
        val channelName = notification.typeName.ifBlank { "Core notifications" }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                channelName,
                NotificationManager.IMPORTANCE_HIGH,
            )
            nm.createNotificationChannel(channel)
        }

        val pendingIntent: PendingIntent? = if (notification.openURL.isNotBlank()) {
            runCatching {
                val intent = Intent(Intent.ACTION_VIEW, Uri.parse(notification.openURL)).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                PendingIntent.getActivity(
                    context,
                    notification.typeID,
                    intent,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                )
            }.getOrNull()
        } else null

        val builder = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentTitle(notification.title)
            .setContentText(notification.body)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
        if (notification.subtitle.isNotBlank()) {
            builder.setSubText(notification.subtitle)
        }
        if (pendingIntent != null) {
            builder.setContentIntent(pendingIntent)
        }

        runCatching {
            nm.notify(notification.typeID, builder.build())
        }.onFailure {
            Log.e(TAG, "sendNotification.notify failed", it)
        }

        Log.d(TAG, "Notification: ${notification.title} → ${notification.openURL}")
        commandServer.get()?.writeMessage(
            0,
            "platform notification: ${notification.title} (${notification.openURL})",
        )
    }
}
