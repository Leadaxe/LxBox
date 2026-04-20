package com.leadaxe.lxbox.vpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager.NameNotFoundException
import android.net.ProxyInfo
import android.net.VpnService
import android.os.Build
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat
import go.Seq
import io.nekohasekai.libbox.BoxService
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.SystemProxyStatus
import io.nekohasekai.libbox.TunOptions
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext

class BoxVpnService : VpnService(), PlatformInterfaceWrapper, CommandServerHandler {

    companion object {
        private const val TAG = "BoxVpnService"
        const val ACTION_START = "com.leadaxe.lxbox.ACTION_START"
        const val ACTION_STOP = "com.leadaxe.lxbox.ACTION_STOP"
        const val BROADCAST_STATUS = "com.leadaxe.lxbox.BROADCAST_STATUS"
        const val EXTRA_STATUS = "status"

        /// Mirror of the live service status, readable from anywhere.
        /// VpnPlugin.getVpnStatus читает это чтобы Flutter мог пересинхрониться
        /// после re-attach (process killed но service выжил из-за keep-on-exit).
        @Volatile
        var currentStatus: VpnStatus = VpnStatus.Stopped
            private set

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
    }

    /// Scoped to service lifetime — all child coroutines are cancelled in onDestroy / doStop.
    /// Recreated on each start since cancel() is terminal for a scope.
    private var serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private fun resetScope() {
        serviceScope.cancel()
        serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    }

    @Volatile private var fileDescriptor: ParcelFileDescriptor? = null
    private var boxService: BoxService? = null
    private var commandServer: CommandServer? = null
    private var receiverRegistered = false
    private var status = VpnStatus.Stopped

    private val notification: ServiceNotification by lazy { ServiceNotification(this) }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            Log.d(TAG, "[vpn] service.receiver.onReceive action=${intent.action} status=${status.name} registered=$receiverRegistered")
            when (intent.action) {
                ACTION_STOP -> doStop()
                PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) onIdleModeChanged()
                }
            }
        }
    }

    // -------------------------------------------------------------------------
    // Android lifecycle
    // -------------------------------------------------------------------------

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
            Log.d(TAG, "[vpn] registerReceiver from onStartCommand")
            ContextCompat.registerReceiver(this, receiver, IntentFilter().apply {
                addAction(ACTION_STOP)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    addAction(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
                }
            }, ContextCompat.RECEIVER_NOT_EXPORTED)
            receiverRegistered = true
        } else {
            Log.d(TAG, "[vpn] onStartCommand: receiver already registered, skipping")
        }

        serviceScope.launch {
            try {
                startCommandServer()
                startSingbox()
            } catch (e: Exception) {
                Log.e(TAG, "Start failed", e)
                stopAndAlert(e.message ?: "Unknown error")
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
        // Clean up libbox resources synchronously
        fileDescriptor?.runCatching { close() }
        fileDescriptor = null
        boxService?.apply {
            runCatching { close() }
            Seq.destroyRef(refnum)
        }
        commandServer?.apply {
            setService(null)
            runCatching { close() }
            Seq.destroyRef(refnum)
        }
        boxService = null
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

    /** Force-close any leftover libbox resources from a previous run (e.g. after onRevoke). */
    private fun cleanupStaleResources() {
        boxService?.let { svc ->
            Log.w(TAG, "cleanupStaleResources: closing leftover boxService")
            runCatching { svc.close() }
            runCatching { Seq.destroyRef(svc.refnum) }
            boxService = null
        }
        commandServer?.let { cs ->
            Log.w(TAG, "cleanupStaleResources: closing leftover commandServer")
            cs.setService(null)
            runCatching { cs.close() }
            runCatching { Seq.destroyRef(cs.refnum) }
            commandServer = null
        }
        fileDescriptor?.let { fd ->
            Log.w(TAG, "cleanupStaleResources: closing leftover fileDescriptor")
            runCatching { fd.close() }
            fileDescriptor = null
        }
    }

    private suspend fun startSingbox() {
        val config = ConfigManager.load()
        if (config.isBlank() || config == "{}") {
            stopAndAlert("Empty configuration")
            return
        }

        cleanupStaleResources()
        // Give OS time to release the port after closing stale resources
        delay(500)

        DefaultNetworkMonitor.start(serviceScope)
        Libbox.setMemoryLimit(true)

        val svc = try {
            Libbox.newService(config, this as PlatformInterfaceWrapper)
        } catch (e: Exception) {
            stopAndAlert("Failed to create service: ${e.message}")
            return
        }

        try { svc.start() } catch (e: Exception) {
            stopAndAlert("Failed to start service: ${e.message}")
            return
        }

        boxService = svc
        commandServer?.setService(svc)
        setStatus(VpnStatus.Started)

        withContext(Dispatchers.Main) {
            notification.show(ConfigManager.notificationTitle, "Connected")
        }
    }

    private fun startCommandServer() {
        val cs = CommandServer(this, 300)
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

        serviceScope.launch {
            fileDescriptor?.close()
            fileDescriptor = null
            boxService?.apply {
                runCatching { close() }
                Seq.destroyRef(refnum)
            }
            commandServer?.setService(null)
            boxService = null
            DefaultNetworkMonitor.stop()
            commandServer?.apply {
                runCatching { close() }
                Seq.destroyRef(refnum)
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
        sendBroadcast(
            Intent(BROADCAST_STATUS).apply {
                `package` = packageName
                putExtra(EXTRA_STATUS, newStatus.name)
                if (error != null) putExtra("error", error)
            }
        )
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

    override fun serviceReload() {
        notification.stop()
        setStatus(VpnStatus.Starting)
        fileDescriptor?.close(); fileDescriptor = null
        boxService?.apply { runCatching { close() }; Seq.destroyRef(refnum) }
        commandServer?.setService(null); commandServer?.resetLog()
        boxService = null
        runBlocking { startSingbox() }
    }

    override fun postServiceClose() {}

    override fun getSystemProxyStatus(): SystemProxyStatus = SystemProxyStatus()

    override fun setSystemProxyEnabled(isEnabled: Boolean) { serviceReload() }

    @RequiresApi(Build.VERSION_CODES.M)
    private fun onIdleModeChanged() {
        if (BoxApplication.powerManager.isDeviceIdleMode) boxService?.pause() else boxService?.wake()
    }

    override fun writeLog(message: String) { commandServer?.writeMessage(message) }

    override fun sendNotification(notification: io.nekohasekai.libbox.Notification) {
        Log.d(TAG, "Notification: ${notification.title}")
    }
}
