package com.leadaxe.lxbox.vpn

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager.NameNotFoundException
import android.net.ProxyInfo
import android.net.VpnService
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.content.ContextCompat
import io.nekohasekai.libbox.TunOptions
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Deferred

/// §049 F1 split (mirror reference SagerNet 1.13.11).
///
/// `BoxVpnService` — Android `VpnService` + `PlatformInterfaceWrapper` (PI only).
/// Хранит `service: BoxService` в field initializer и форвардит Android
/// lifecycle callbacks в `service.X()`. Весь state и CSH-implementation
/// живут в `BoxService` — это даёт `CommandServer(this, platformInterface)`
/// с двумя разными Java instance, как у reference.
class BoxVpnService : VpnService(), PlatformInterfaceWrapper {

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

        /// Internal — для BoxService.setStatus() обновлять companion-state.
        internal fun setCurrentStatus(s: VpnStatus) {
            currentStatus = s
        }

        /// Completer для `stopAwait` — completes когда `setStatus(Stopped)`
        /// отработал, т.е. все cleanup стадии завершились.
        @Volatile
        private var stopCompleter: CompletableDeferred<Unit>? = null

        /// Internal — BoxService.setStatus() при переходе в Stopped зовёт этот.
        internal fun completeStopIfWaiting() {
            stopCompleter?.complete(Unit)
            stopCompleter = null
        }

        /// §043: Sink для core logs от sing-box → Flutter EventChannel.
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

        fun reload(context: Context) {
            Log.d(TAG, "[vpn] companion.reload() current status=${currentStatus.name}")
            context.sendBroadcast(
                Intent(ACTION_RELOAD).setPackage(context.packageName)
            )
        }

        fun resetNetwork(context: Context) {
            Log.d(TAG, "[vpn] companion.resetNetwork() current status=${currentStatus.name}")
            context.sendBroadcast(
                Intent(ACTION_RESET_NETWORK).setPackage(context.packageName)
            )
        }

        fun stopAwait(context: Context): Deferred<Unit> {
            Log.d(TAG, "[vpn] companion.stopAwait() current status=${currentStatus.name}")
            if (currentStatus == VpnStatus.Stopped) {
                return CompletableDeferred(Unit)
            }
            val completer = CompletableDeferred<Unit>()
            stopCompleter?.cancel()
            stopCompleter = completer
            context.sendBroadcast(
                Intent(ACTION_STOP).setPackage(context.packageName)
            )
            return completer
        }
    }

    /// §049 F1 — field initializer (как `VPNService.kt:26` reference): инстанс
    /// создаётся при создании Android Service, до onCreate(). Это держит
    /// strong-ref на `platformInterface (= this)` через `private val` в
    /// BoxService — препятствует преждевременному GC Go-side wrapper'а.
    private val service = BoxService(this, this)

    /// §049 F17 — state HTTP-proxy для `BoxService.getSystemProxyStatus()`.
    @JvmField var systemProxyAvailable = false
    @JvmField var systemProxyEnabled = false

    // -------------------------------------------------------------------------
    // Android lifecycle — forward в BoxService
    // -------------------------------------------------------------------------

    override fun onCreate() {
        super.onCreate()
        service.onCreate()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return service.onStartCommand(intent, flags, startId)
    }

    override fun onBind(intent: Intent): IBinder? = super.onBind(intent) ?: android.os.Binder()

    override fun onDestroy() {
        service.onDestroy()
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        service.onTaskRemoved(rootIntent)
        super.onTaskRemoved(rootIntent)
    }

    override fun onRevoke() {
        service.onRevoke()
        super.onRevoke()
    }

    // -------------------------------------------------------------------------
    // PlatformInterfaceWrapper overrides — VPN-specific
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

        // §049 F15: allowBypass opt-in toggle.
        if (BootReceiver.isAllowBypass(this)) {
            builder.allowBypass()
        }

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

        // §049 F17: треккаем state HTTP-proxy для CommandServerHandler.getSystemProxyStatus.
        if (options.isHTTPProxyEnabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            systemProxyAvailable = true
            systemProxyEnabled = true
            builder.setHttpProxy(
                ProxyInfo.buildDirectProxy(
                    options.httpProxyServer,
                    options.httpProxyServerPort,
                    options.httpProxyBypassDomain.toList()
                )
            )
        } else {
            systemProxyAvailable = false
            systemProxyEnabled = false
        }

        val pfd = builder.establish() ?: error("android: the application is not prepared or is revoked")
        // **§049 F1**: state живёт в BoxService — храним там.
        service.fileDescriptor.set(pfd)
        return pfd.fd
    }

    override fun protect(fd: Int): Boolean = super.protect(fd)

    /// `sendNotification` форвард в `service` — там логика построения Android Notification.
    override fun sendNotification(notification: io.nekohasekai.libbox.Notification) {
        service.sendNotification(notification)
    }
}
