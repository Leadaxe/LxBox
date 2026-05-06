package com.leadaxe.lxbox.vpn

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager.NameNotFoundException
import android.net.ProxyInfo
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.IBinder
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
import io.nekohasekai.libbox.SystemProxyStatus
import io.nekohasekai.libbox.TunOptions
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class BoxVpnService : VpnService(), PlatformInterfaceWrapper, CommandServerHandler {

    companion object {
        private const val TAG = "BoxVpnService"
        const val ACTION_START = "com.leadaxe.lxbox.ACTION_START"
        const val ACTION_STOP = "com.leadaxe.lxbox.ACTION_STOP"
        const val ACTION_RELOAD = "com.leadaxe.lxbox.ACTION_RELOAD"
        const val ACTION_RESET_NETWORK = "com.leadaxe.lxbox.ACTION_RESET_NETWORK"
        const val BROADCAST_STATUS = "com.leadaxe.lxbox.BROADCAST_STATUS"
        const val EXTRA_STATUS = "status"

        /// Mirror of the live service status, readable from anywhere.
        /// VpnPlugin.getVpnStatus читает это чтобы Flutter мог пересинхрониться
        /// после re-attach (process killed но service выжил из-за keep-on-exit).
        @Volatile
        var currentStatus: VpnStatus = VpnStatus.Stopped
            private set

        /// Completer для `stopAwait` — completes когда `setStatus(Stopped)`
        /// отработал, т.е. все cleanup стадии завершились. Null когда stop
        /// никем не ожидается. Volatile т.к. читается/пишется из разных
        /// потоков (caller plugin scope + service main/IO).
        @Volatile
        private var stopCompleter: CompletableDeferred<Unit>? = null

        /// §043: Sink для core logs от sing-box → Flutter EventChannel
        /// "lxbox/coreLog". Подписывается VpnPlugin при onListen.
        /// `writeDebugMessage` зовётся sing-box'ом из любого потока — sink
        /// должен быть Volatile для thread-safe чтения. Worst case:
        /// одна потерянная log line при swap'е sink — acceptable.
        @Volatile
        var coreLogSink: io.flutter.plugin.common.EventChannel.EventSink? = null

        fun start(context: Context) {
            Log.d(TAG, "[vpn] companion.start() → startForegroundService, current status=${currentStatus.name}")
            val intent = Intent(context, BoxVpnService::class.java).apply { action = ACTION_START }
            ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context) {
            Log.d(TAG, "[vpn] companion.stop() → sendBroadcast(ACTION_STOP), current status=${currentStatus.name}")
            context.sendBroadcast(
                Intent(ACTION_STOP).setPackage(context.packageName)
            )
        }

        /// In-place reload sing-box runtime (через CommandServer.startOrReloadService).
        /// Не убивает Android Service. Tunnel дропается на ~3s. См. spec 030.
        fun reload(context: Context) {
            Log.d(TAG, "[vpn] companion.reload() current status=${currentStatus.name}")
            context.sendBroadcast(
                Intent(ACTION_RELOAD).setPackage(context.packageName)
            )
        }

        /// Reset network sub-state роутера (outbound dialer bindings, DNS upstream
        /// tracking) без recreate'а box runtime. Experimental, см. spec 031.
        fun resetNetwork(context: Context) {
            Log.d(TAG, "[vpn] companion.resetNetwork() current status=${currentStatus.name}")
            context.sendBroadcast(
                Intent(ACTION_RESET_NETWORK).setPackage(context.packageName)
            )
        }

        /// Async stop с гарантированным ack'ом: возвращает `Deferred<Unit>`
        /// который completes когда `setStatus(Stopped)` реально отработал
        /// (после async cleanup'а libbox-ресурсов). Caller должен обернуть
        /// в `withTimeout(...)` чтобы не зависнуть навсегда при ошибке
        /// native-пути.
        ///
        /// Если service уже Stopped — возвращает immediately-completed.
        ///
        /// Почему через Completer, а не просто ждать broadcast Stopped на
        /// plugin-стороне: broadcast-канал unreliable (см. историю с
        /// statusSink). Direct Completer — гарантированный signal
        /// "stop реально завершён".
        fun stopAwait(context: Context): Deferred<Unit> {
            Log.d(TAG, "[vpn] companion.stopAwait() current status=${currentStatus.name}")
            if (currentStatus == VpnStatus.Stopped) {
                return CompletableDeferred(Unit)
            }
            val completer = CompletableDeferred<Unit>()
            // Отменяем предыдущий ожидающий, если есть — защита от re-entry
            // (напр. два одновременных stopVPN вызова).
            stopCompleter?.cancel()
            stopCompleter = completer
            context.sendBroadcast(
                Intent(ACTION_STOP).setPackage(context.packageName)
            )
            return completer
        }
    }

    /// Scoped to service lifetime — all child coroutines are cancelled in onDestroy / doStop.
    /// Recreated on each start since cancel() is terminal for a scope.
    private var serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private fun resetScope() {
        serviceScope.cancel()
        serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    }

    @Volatile private var fileDescriptor: ParcelFileDescriptor? = null

    /// Sing-box 1.13: единый объект, владеющий и Unix-socket'ом для Clash
    /// dashboard, и box-runtime'ом. Раньше были два класса (BoxService +
    /// CommandServer); в 1.13 BoxService удалён, CommandServer теперь
    /// `startOrReloadService(config, opts)` создаёт box внутри себя.
    private var commandServer: CommandServer? = null
    private var receiverRegistered = false
    private var status = VpnStatus.Stopped

    private val notification: ServiceNotification by lazy { ServiceNotification(this) }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            Log.d(TAG, "[vpn] service.receiver.onReceive action=${intent.action} status=${status.name} registered=$receiverRegistered")
            when (intent.action) {
                ACTION_STOP -> doStop()
                ACTION_RELOAD -> {
                    Log.d(TAG, "[vpn] receiver: ACTION_RELOAD → serviceReload()")
                    runCatching { serviceReload() }
                        .onFailure { Log.e(TAG, "ACTION_RELOAD failed", it) }
                }
                ACTION_RESET_NETWORK -> {
                    Log.d(TAG, "[vpn] receiver: ACTION_RESET_NETWORK → cs.resetNetwork()")
                    runCatching { commandServer?.resetNetwork() }
                        .onFailure { Log.e(TAG, "ACTION_RESET_NETWORK failed", it) }
                }
                PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) onIdleModeChanged()
                }
                Intent.ACTION_SCREEN_OFF -> {
                    Log.d(TAG, "[vpn] SCREEN_OFF → pause")
                    commandServer?.pause()
                }
                Intent.ACTION_SCREEN_ON -> {
                    Log.d(TAG, "[vpn] SCREEN_ON → wake")
                    commandServer?.wake()
                }
            }
        }
    }

    // -------------------------------------------------------------------------
    // Android lifecycle
    // -------------------------------------------------------------------------

    override fun onCreate() {
        super.onCreate()
        // Сервис может стартануть в свежем процессе без UI (через QS-tile
        // или launcher shortcut, после того как Android прибил предыдущий
        // процесс из-за SIGABRT/OOM). В таком процессе VpnPlugin не
        // подключается, и `BoxApplication.initialize` сам по себе не
        // вызовется — а `application` lateinit, libbox setup отсутствует
        // → onStartCommand упадёт с UninitializedPropertyAccessException.
        // initialize() идемпотентен (if (initialized) return).
        BoxApplication.initialize(applicationContext)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "[vpn] onStartCommand action=${intent?.action} status=${status.name} startId=$startId receiverRegistered=$receiverRegistered")
        notification.show(ConfigManager.notificationTitle, "Starting...")

        if (status != VpnStatus.Stopped) {
            Log.w(TAG, "[vpn] onStartCommand GUARD — status=${status.name} != Stopped, silent return (no setStatus, no broadcast)")
            return START_NOT_STICKY
        }
        resetScope()
        setStatus(VpnStatus.Starting)

        if (!receiverRegistered) {
            val mode = BootReceiver.getBackgroundMode(this)
            Log.d(TAG, "[vpn] registerReceiver from onStartCommand mode=$mode")
            ContextCompat.registerReceiver(this, receiver, IntentFilter().apply {
                addAction(ACTION_STOP)
                addAction(ACTION_RELOAD)
                addAction(ACTION_RESET_NETWORK)
                // Подписка на сигналы засыпания зависит от режима:
                //   never  — только ACTION_STOP, pause/wake не зовём никогда
                //   lazy   — deep Doze (текущее sing-box-android поведение)
                //   always — screen off/on (самое агрессивное энергосбережение)
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
        } else {
            Log.d(TAG, "[vpn] onStartCommand: receiver already registered, skipping")
        }

        serviceScope.launch {
            try {
                // Sync barrier: libbox setup должен завершиться ДО любого
                // вызова libbox-классов (`CommandServer` ctor, startOrReloadService).
                // На S10 Lite (Android 13) этот await завершается мгновенно,
                // на A50/A10/Y9 даёт фоновому `initializeLibbox` дотянуть
                // до конца — иначе нативный crash без stderr-stacktrace.
                BoxApplication.libboxReady.await()
                // Очищаем недозакрытые ресурсы из прошлой сессии (если она была)
                // ДО создания нового CommandServer'а. Иначе свежий cs закрылся бы
                // же в этом cleanupStaleResources вызове — was bug в первоначальной
                // 1.13-миграции.
                cleanupStaleResources()
                startCommandServer()
                startSingbox()
            } catch (t: Throwable) {
                // Throwable — ловит и Error (OOM, VerifyError при class
                // load из libbox), не только Exception. Без этого
                // unhandled Error в корутине отравил бы scope и юзер
                // увидел бы «приложение закрылось» вместо error-toast'а.
                Log.e(TAG, "Start failed", t)
                stopAndAlert(t.message ?: "Unknown error")
            }
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent): IBinder? = super.onBind(intent) ?: android.os.Binder()

    override fun onDestroy() {
        Log.d(TAG, "[vpn] onDestroy status=${status.name} receiverRegistered=$receiverRegistered")
        serviceScope.cancel()
        if (receiverRegistered) {
            Log.d(TAG, "[vpn] unregisterReceiver from onDestroy")
            runCatching { unregisterReceiver(receiver) }
            receiverRegistered = false
        }
        // Если сервис умер не через doStop (OOM, system kill в фоне),
        // currentStatus может остаться Started — tile тогда соврёт.
        // Сбрасываем здесь как страховка, и просим перерисовать tile.
        if (currentStatus != VpnStatus.Stopped) {
            currentStatus = VpnStatus.Stopped
            runCatching { LxBoxTileService.refreshTile(applicationContext) }
                .onFailure { Log.w(TAG, "refreshTile in onDestroy failed: ${it.message}") }
        }
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // App swiped from recents — stop VPN unless "keep on exit" is enabled
        if (!BootReceiver.isKeepOnExit(this)) {
            Log.d(TAG, "App removed from recents — stopping VPN")
            doStop()
        }
        super.onTaskRemoved(rootIntent)
    }

    override fun onRevoke() {
        Log.d(TAG, "onRevoke — VPN taken by another app")
        // Cleanup libbox-ресурсов синхронно (revoke — экстренный путь). Two-phase
        // shutdown: сначала `closeService()` (останавливает box-runtime), потом
        // `close()` (закрывает Unix-socket). Если первый бросит — фиксируем
        // ошибку через setError, чтобы dashboard'ы её увидели; close() даже
        // на failure обязан отработать.
        fileDescriptor?.runCatching { close() }
        fileDescriptor = null
        commandServer?.apply {
            runCatching { closeService() }.onFailure {
                runCatching { setError("android: revoke close service: ${it.message}") }
            }
            runCatching { close() }
        }
        commandServer = null

        if (receiverRegistered) {
            runCatching { unregisterReceiver(receiver) }
            receiverRegistered = false
        }
        notification.stop()
        setStatus(VpnStatus.Stopped, error = "VPN revoked by another app")
        serviceScope.cancel()
        stopSelf()
        super.onRevoke()
    }

    // -------------------------------------------------------------------------
    // Start / stop sing-box
    // -------------------------------------------------------------------------

    /// Force-close любого недозакрытого CommandServer'а из прошлого запуска
    /// (например после onRevoke в свежем процессе). Two-phase: closeService()
    /// первым (остановить box-runtime), close() — закрыть Unix-socket. Без
    /// `Seq.destroyRef` — Go runtime в 1.13 self-cleans refnum'ы; manual вызов
    /// ведёт к double-free.
    private fun cleanupStaleResources() {
        commandServer?.let { cs ->
            Log.w(TAG, "cleanupStaleResources: closing leftover commandServer")
            runCatching { cs.closeService() }
            runCatching { cs.close() }
            commandServer = null
        }
        fileDescriptor?.let { fd ->
            Log.w(TAG, "cleanupStaleResources: closing leftover fileDescriptor")
            runCatching { fd.close() }
            fileDescriptor = null
        }
    }

    private suspend fun startSingbox() {
        // Дожидаемся завершения `Libbox.setup` из BoxApplication.initialize.
        // Без этого на медленных девайсах (A50/A10/Y9) box-runtime в
        // `startOrReloadService` мог стартануть до того как Go-сторона
        // зарегистрировала окружение → нативный crash в JNI без stderr.
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

        // Note: cleanupStaleResources() уже отработал в onStartCommand до
        // startCommandServer() — здесь второй вызов закрыл бы свежий cs.
        // Небольшая пауза чтобы OS успел релизнуть socket'ы старой сессии.
        delay(500)

        DefaultNetworkMonitor.start(serviceScope)
        Libbox.setMemoryLimit(true)

        val cs = commandServer ?: run {
            stopAndAlert("CommandServer not initialized")
            return
        }

        // Sing-box 1.13 unified entry: `startOrReloadService` стартует box-runtime
        // внутри уже работающего CommandServer'а. Тот же метод используется и для
        // hot-reload конфига — sing-box сам решает create vs reload.
        //
        // OverrideOptions — переопределяет include/exclude packages и auto-redirect
        // (наша логика передаёт это через PlatformInterface.openTun/TunOptions,
        // поэтому overrides пустые).
        //
        // Throwable, не Exception — config init может бросить OutOfMemoryError
        // (большие geosite/geoip rule-sets), на старых Android class verifier
        // libbox-классов может отдать VerifyError. Ловим всё, чтобы юзер увидел
        // «Failed to start» вместо тихого исчезновения процесса.
        //
        // ВАЖНО: это НЕ защищает от Go panic без recover в нативном коде — такой
        // краш улетает SIGABRT'ом мимо JVM. Защита от него — редирект stderr в
        // BoxApplication.initializeLibbox + валидация конфига (см. §038).
        try {
            cs.startOrReloadService(config, OverrideOptions())
        } catch (t: Throwable) {
            stopAndAlert("Failed to start service: ${t.message}")
            return
        }

        setStatus(VpnStatus.Started)

        withContext(Dispatchers.Main) {
            notification.show(ConfigManager.notificationTitle, "Connected")
        }
    }

    /// Создаёт и стартует CommandServer (Unix-socket для Clash dashboard'ов +
    /// box-runtime owner). Sing-box 1.13: конструктор `(handler, platform)` —
    /// мы передаём `this` дважды, потому что implement'им оба интерфейса.
    /// Box-runtime сам не запускается — это делает `startSingbox()` через
    /// `cs.startOrReloadService(config, opts)`.
    private fun startCommandServer() {
        val cs = CommandServer(this, this)
        cs.start()
        commandServer = cs
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
            runCatching { unregisterReceiver(receiver) }
            receiverRegistered = false
        }
        notification.stop()

        // Two-phase shutdown на Dispatchers.IO. Порядок критичен:
        //   1. fileDescriptor.close()       — освободить TUN fd, system route
        //   2. closeService() throwing      — остановить box-runtime; на failure
        //                                     отдать ошибку через setError()
        //                                     чтобы dashboard'ы её увидели
        //   3. close() non-throwing         — закрыть Unix-socket
        //   4. Drop reference + stopSelf()  — release memory; Go owns refnum
        //
        // ⚠ НЕ Seq.destroyRef — Go runtime в 1.13 self-cleans; manual вызов
        //   = double-free (см. SFA BoxService.kt:292 commented).
        //
        // ⚠ Dispatchers.IO обязательно — Go callbacks при closeService() могут
        //   ждать host'a; main thread → ANR.
        serviceScope.launch {
            fileDescriptor?.close()
            fileDescriptor = null
            DefaultNetworkMonitor.stop()
            commandServer?.let { cs ->
                runCatching { cs.closeService() }.onFailure {
                    Log.e(TAG, "doStop: closeService failed", it)
                    runCatching { cs.setError("android: close service: ${it.message}") }
                }
                runCatching { cs.close() }
            }
            commandServer = null

            withContext(Dispatchers.Main) {
                Log.d(TAG, "[vpn] doStop cleanup done → setStatus(Stopped) + stopSelf()")
                setStatus(VpnStatus.Stopped)
                stopSelf()
            }
        }
    }

    private suspend fun stopAndAlert(message: String) {
        Log.e(TAG, "stopAndAlert: $message")
        withContext(Dispatchers.Main) {
            // CRITICAL: must call startForeground before stopSelf, otherwise
            // Android kills the app with ForegroundServiceDidNotStartInTimeException.
            notification.show("Error", message)
            if (receiverRegistered) {
                runCatching { unregisterReceiver(receiver) }
                receiverRegistered = false
            }
            notification.stop()
            setStatus(VpnStatus.Stopped, error = message)
            stopSelf()
        }
    }

    private fun setStatus(newStatus: VpnStatus, error: String? = null) {
        Log.d(TAG, "[vpn] setStatus(${newStatus.name})${if (error != null) " error=$error" else ""} — sendBroadcast")
        status = newStatus
        currentStatus = newStatus
        // Ack для `stopAwait` caller'ов — broadcast-канал мы считаем unreliable
        // (см. историю с statusSink), поэтому finality-signal идёт через
        // direct Completer, а не через broadcast. Идемпотентно: если
        // completer уже completed или cancelled, повторный complete no-op.
        if (newStatus == VpnStatus.Stopped) {
            stopCompleter?.complete(Unit)
            stopCompleter = null
        }
        sendBroadcast(
            Intent(BROADCAST_STATUS).apply {
                `package` = packageName
                putExtra(EXTRA_STATUS, newStatus.name)
                if (error != null) putExtra("error", error)
            }
        )
        // Quick Connect-побочка строго опциональна — на старых Android
        // (или при OEM-багах в TileService binding) этот вызов может
        // выкинуть исключение, но это не должно валить старт VPN.
        runCatching { LxBoxTileService.refreshTile(applicationContext) }
            .onFailure { Log.w(TAG, "refreshTile failed: ${it.message}") }
        // Перерисовываем launcher long-press shortcuts: «Connect» когда
        // VPN off, «Disconnect» когда on, оба в transient состояниях.
        runCatching { QuickShortcuts.refresh(applicationContext) }
            .onFailure { Log.w(TAG, "QuickShortcuts.refresh failed: ${it.message}") }
    }

    // -------------------------------------------------------------------------
    // PlatformInterface overrides (VpnService-specific)
    // -------------------------------------------------------------------------

    override fun autoDetectInterfaceControl(fd: Int) {
        protect(fd)
    }

    override fun openTun(options: TunOptions): Int {
        if (prepare(this) != null) error("android: missing vpn permission")

        val builder = Builder()
            .setSession("sing-box")
            .setMtu(options.mtu)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)

        val inet4 = options.inet4Address
        while (inet4.hasNext()) { val a = inet4.next(); builder.addAddress(a.address(), a.prefix()) }
        val inet6 = options.inet6Address
        while (inet6.hasNext()) { val a = inet6.next(); builder.addAddress(a.address(), a.prefix()) }

        if (options.autoRoute) {
            builder.addDnsServer(options.dnsServerAddress.value)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val r4 = options.inet4RouteAddress
                if (r4.hasNext()) { while (r4.hasNext()) builder.addRoute(r4.next().toIpPrefix()) }
                else if (options.inet4Address.hasNext()) builder.addRoute("0.0.0.0", 0)

                val r6 = options.inet6RouteAddress
                if (r6.hasNext()) { while (r6.hasNext()) builder.addRoute(r6.next().toIpPrefix()) }
                else if (options.inet6Address.hasNext()) builder.addRoute("::", 0)

                val x4 = options.inet4RouteExcludeAddress
                while (x4.hasNext()) builder.excludeRoute(x4.next().toIpPrefix())
                val x6 = options.inet6RouteExcludeAddress
                while (x6.hasNext()) builder.excludeRoute(x6.next().toIpPrefix())
            } else {
                val r4 = options.inet4RouteRange
                if (r4.hasNext()) { while (r4.hasNext()) { val a = r4.next(); builder.addRoute(a.address(), a.prefix()) } }
                val r6 = options.inet6RouteRange
                if (r6.hasNext()) { while (r6.hasNext()) { val a = r6.next(); builder.addRoute(a.address(), a.prefix()) } }
            }

            val incl = options.includePackage
            if (incl.hasNext()) { while (incl.hasNext()) { try { builder.addAllowedApplication(incl.next()) } catch (_: NameNotFoundException) {} } }
            val excl = options.excludePackage
            if (excl.hasNext()) { while (excl.hasNext()) { try { builder.addDisallowedApplication(excl.next()) } catch (_: NameNotFoundException) {} } }
        }

        if (options.isHTTPProxyEnabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setHttpProxy(
                ProxyInfo.buildDirectProxy(
                    options.httpProxyServer,
                    options.httpProxyServerPort,
                    options.httpProxyBypassDomain.toList()
                )
            )
        }

        val pfd = builder.establish() ?: error("android: the application is not prepared or is revoked")
        fileDescriptor = pfd
        return pfd.fd
    }

    override fun protect(fd: Int): Boolean = super.protect(fd)

    // -------------------------------------------------------------------------
    // CommandServerHandler
    // -------------------------------------------------------------------------

    /// Sing-box 1.13: reload — это просто `startOrReloadService(newConfig, opts)`
    /// на тот же CommandServer. Manual close/destroy не нужен — sing-box сам
    /// тейкаунтит box-runtime. Зовётся когда внешний клиент (Clash dashboard)
    /// просит перечитать конфиг.
    override fun serviceReload() {
        notification.stop()
        setStatus(VpnStatus.Starting)
        val cs = commandServer ?: run {
            Log.w(TAG, "serviceReload: commandServer == null, treating as fresh start")
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
            .onSuccess { setStatus(VpnStatus.Started) }
        notification.show(ConfigManager.notificationTitle, "Connected")
    }

    // Sing-box 1.13: `postServiceClose()` удалён из CommandServerHandler.
    // Добавлен `serviceStop()` — зовётся когда удалённый клиент (например, Clash
    // dashboard) просит остановить сервис. Привязываем к нашей штатной shutdown-
    // последовательности `doStop()`.
    override fun serviceStop() { doStop() }

    override fun getSystemProxyStatus(): SystemProxyStatus = SystemProxyStatus()

    override fun setSystemProxyEnabled(isEnabled: Boolean) { serviceReload() }

    @RequiresApi(Build.VERSION_CODES.M)
    private fun onIdleModeChanged() {
        // Sing-box 1.13: pause/wake переехали на CommandServer (BoxService удалён).
        if (BoxApplication.powerManager.isDeviceIdleMode) commandServer?.pause() else commandServer?.wake()
    }

    /// Sing-box 1.13: WriteLog (был на PlatformInterface) переехал сюда как
    /// writeDebugMessage. Логически — то же: транзит строк лога в command-server
    /// для подписчиков. writeMessage теперь требует int level (sing-box slog
    /// levels: 0=Info, 4=Warn, 8=Error). Используем 0=Info — это общий debug.
    /// §043: sing-box log lines проходят сюда независимо от `log.level`
    /// в конфиге (sing-box специально гарантирует platformWriter получает
    /// все уровни — см. log/observable.go).
    ///
    /// Удалён старый `commandServer.writeMessage(0, message)` forward —
    /// мёртвый, нет subscriber'ов которым это нужно (Clash API на 63130
    /// у нас только для self-fetch, не WebSocket /logs subscribers).
    ///
    /// Фильтр уровня прямо здесь: TRACE/DEBUG отбрасываем (volume reduction
    /// — на busy traffic десятки строк/сек). INFO+ пушим в Flutter через
    /// EventChannel "lxbox/coreLog". Уровень определяется substring search'ем
    /// по sing-box формату `+0300 2026-05-06 12:34:56 INFO  router: ...`.
    ///
    /// **ВАЖНО:** sing-box зовёт этот callback из Go-goroutine'ов на
    /// background-thread'ах. `EventChannel.EventSink.success()` **требует
    /// main thread** (Flutter platform thread) — вызов с background'а
    /// бросает `@UiThread` exception, который sing-box интерпретирует как
    /// failure при `openTun` ("configure tun interface: Methods marked with
    /// @UiThread must be executed on the main thread"). Поэтому диспатчим
    /// в main handler.
    override fun writeDebugMessage(message: String) {
        // Sing-box форматтер вставляет ANSI color escapes (`\x1b[36mINFO\x1b[0m`),
        // strip'аем для plain-text storage и для корректного level-filter'а.
        val plain = ansiEscapeRe.replace(message, "")
        // Volume reduction: skip trace/debug. После strip'а уровень формата
        // `... TRACE[0017]` или `... TRACE 0017]` — ищем boundary либо пробел,
        // либо `[`. Используем word-boundary regex для надёжности.
        if (traceDebugRe.containsMatchIn(plain)) return
        val sink = coreLogSink ?: return
        coreLogMainHandler.post {
            runCatching { sink.success(plain) }
        }
    }

        /// CSI ANSI escape sequence (sing-box terminal colors). Sing-box посылает
    /// `[36mINFO[0m`. Regex захватывает ESC + `[` + params + letter.
    private val ansiEscapeRe = Regex("\\[[0-9;]*[A-Za-z]")

    /// Word-boundary поиск TRACE / DEBUG для volume-reduction filter'а
    /// (после strip'а ANSI escape codes).
    private val traceDebugRe = Regex("\\b(TRACE|DEBUG)\\b")

    /// Handler на main looper для dispatch'а EventChannel.success() из
    /// background-thread'ов sing-box'а. Lazy чтоб init только при первом
    /// log call'е.
    private val coreLogMainHandler by lazy {
        android.os.Handler(android.os.Looper.getMainLooper())
    }

    /// `sendNotification` (spec §036) — показываем system notification с
    /// clickable ссылкой на `openURL` (открывает default-браузер).
    /// Sing-box зовёт это для protocol auth flow'ов — в 1.13.x только Tailscale
    /// outbound (см. `protocol/tailscale/endpoint.go:438`). После успешной
    /// auth юзера в браузере sing-box-side polling сам подхватывает state,
    /// deep-link callback в app не нужен.
    override fun sendNotification(notification: io.nekohasekai.libbox.Notification) {
        val context = applicationContext
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        val channelId = notification.identifier.ifBlank { "lxbox-core" }
        val channelName = notification.typeName.ifBlank { "Core notifications" }

        // Channel — idempotent (createNotificationChannel игнорирует дубликат).
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                channelName,
                NotificationManager.IMPORTANCE_HIGH,
            )
            nm.createNotificationChannel(channel)
        }

        // PendingIntent для tap → browser. ACTION_VIEW + http(s) URI ⇒
        // Android запускает default-browser с этим URL.
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

        // Build & show. typeID — id для notify() ⇒ повторный вызов с тем же id
        // обновляет existing notification вместо stacking'а.
        val builder = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(android.R.drawable.ic_lock_lock)  // та же что у FGS
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

        // Дубль в commandServer log — observability через /logs?source=core
        // (если POST_NOTIFICATIONS denied на API 33+, юзер всё равно увидит URL).
        Log.d(TAG, "Notification: ${notification.title} → ${notification.openURL}")
        commandServer?.writeMessage(
            0,
            "platform notification: ${notification.title} (${notification.openURL})",
        )
    }
}
