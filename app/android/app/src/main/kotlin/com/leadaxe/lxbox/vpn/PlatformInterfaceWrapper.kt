package com.leadaxe.lxbox.vpn

import android.net.NetworkCapabilities
import android.os.Build
import android.os.Process
import android.system.OsConstants
import androidx.annotation.RequiresApi
import io.nekohasekai.libbox.ConnectionOwner
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LocalDNSTransport
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.TunOptions
import io.nekohasekai.libbox.WIFIState
import java.net.Inet6Address
import java.net.InetSocketAddress
import java.net.InterfaceAddress
import java.net.NetworkInterface
import io.nekohasekai.libbox.NetworkInterface as LibboxNetworkInterface

interface PlatformInterfaceWrapper : PlatformInterface {

    override fun localDNSTransport(): LocalDNSTransport? = LocalResolver

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    override fun autoDetectInterfaceControl(fd: Int) {}

    override fun openTun(options: TunOptions): Int = error("invalid argument")

    override fun useProcFS(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q

    @RequiresApi(Build.VERSION_CODES.Q)
    override fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String, sourcePort: Int,
        destinationAddress: String, destinationPort: Int
    ): ConnectionOwner {
        // §128 (F12.3 generalization): этот callback зовётся Go на КАЖДОЕ
        // соединение (`find_process: true` — глобальный дефолт template). На
        // Android 10 без root `getConnectionOwnerUid` для недоступного владельца
        // бросает SecurityException; `getPackagesForUid` может бросить
        // RuntimeException. Без try/catch исключение пролетает через JNI →
        // Runtime::Abort (см. §050 findings F12.3). Fail-safe: вернуть owner с
        // INVALID_UID — sing-box трактует как «owner unknown», `find_process`
        // правило просто не матчит, routing продолжает работать.
        val uid = try {
            BoxApplication.connectivity.getConnectionOwnerUid(
                ipProtocol,
                InetSocketAddress(sourceAddress, sourcePort),
                InetSocketAddress(destinationAddress, destinationPort)
            )
        } catch (e: Exception) {
            android.util.Log.w("PIW", "findConnectionOwner: getConnectionOwnerUid failed: ${e.message}")
            Process.INVALID_UID
        }
        if (uid == Process.INVALID_UID) {
            return ConnectionOwner().apply { userId = Process.INVALID_UID }
        }
        // Sing-box 1.13 ушёл от двухступенчатого callback'а
        // (`packageNameByUid`/`uidByPackageName`) к одной структуре `ConnectionOwner`,
        // которую мы заполняем сразу: UID + список пакетов под ним. Process path и
        // username на Android неприменимы (нет /proc-доступа без root) — оставляем пустыми.
        val packages = try {
            BoxApplication.packageManager.getPackagesForUid(uid)?.toList() ?: emptyList()
        } catch (e: Exception) {
            android.util.Log.w("PIW", "findConnectionOwner: getPackagesForUid failed: ${e.message}")
            emptyList()
        }
        return ConnectionOwner().apply {
            userId = uid
            // §049 F12.1: userName заполняется первым package'ом (как в reference
            // `PlatformInterfaceWrapper.kt:60` 1.13.11). Видно в Clash API
            // `/connections` endpoint.
            userName = packages.firstOrNull() ?: ""
            setAndroidPackageNames(StringArray(packages.iterator()))
        }
    }

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        DefaultNetworkMonitor.setListener(listener)
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        DefaultNetworkMonitor.setListener(null)
    }

    override fun getInterfaces(): NetworkInterfaceIterator {
        // §128 (F12.3 generalization): зовётся Go ВСЕГДА при connect (init
        // маршрутизации). `allNetworks` / `getLinkProperties` /
        // `getNetworkCapabilities` могут бросить SecurityException на Android 10
        // без root / на кастомных прошивках; `getNetworkInterfaces` —
        // SocketException. Без try/catch → JNI Runtime::Abort (см. §050 F12.3).
        // Fail-safe: вернуть пустой итератор — sing-box деградирует к
        // auto-detect интерфейса без явного списка.
        return runCatching { buildInterfaces() }
            .getOrElse {
                android.util.Log.w("PIW", "getInterfaces failed, returning empty: ${it.message}")
                emptyInterfaceIterator()
            }
    }

    private fun buildInterfaces(): NetworkInterfaceIterator {
        val networks = BoxApplication.connectivity.allNetworks
        val sysInterfaces = NetworkInterface.getNetworkInterfaces().toList()
        val result = mutableListOf<LibboxNetworkInterface>()
        for (network in networks) {
            val lp = BoxApplication.connectivity.getLinkProperties(network) ?: continue
            val caps = BoxApplication.connectivity.getNetworkCapabilities(network) ?: continue
            val ni = sysInterfaces.find { it.name == lp.interfaceName } ?: continue
            val box = LibboxNetworkInterface().apply {
                name = lp.interfaceName
                dnsServer = StringArray(lp.dnsServers.mapNotNull { it.hostAddress }.iterator())
                type = when {
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> Libbox.InterfaceTypeWIFI
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> Libbox.InterfaceTypeCellular
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> Libbox.InterfaceTypeEthernet
                    else -> Libbox.InterfaceTypeOther
                }
                index = ni.index
                runCatching { mtu = ni.mtu }
                addresses = StringArray(ni.interfaceAddresses.map { it.toPrefix() }.iterator())
                var flags = 0
                if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET))
                    flags = OsConstants.IFF_UP or OsConstants.IFF_RUNNING
                if (ni.isLoopback) flags = flags or OsConstants.IFF_LOOPBACK
                if (ni.isPointToPoint) flags = flags or OsConstants.IFF_POINTOPOINT
                if (ni.supportsMulticast()) flags = flags or OsConstants.IFF_MULTICAST
                this.flags = flags
                metered = !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
            }
            result.add(box)
        }
        return object : NetworkInterfaceIterator {
            val iter = result.iterator()
            override fun hasNext() = iter.hasNext()
            override fun next() = iter.next()
        }
    }

    private fun emptyInterfaceIterator(): NetworkInterfaceIterator =
        object : NetworkInterfaceIterator {
            override fun hasNext() = false
            // §151 F1 — JNI no-throw: `NetworkInterfaceIterator.Next()` —
            // Go-метод БЕЗ `error`, поэтому throw отсюда НЕ ловится gomobile →
            // `Runtime::Abort` процесса (в отличие от error-возвращающих
            // callback'ов). Контракт — звать `Next()` лишь после `HasNext()==true`,
            // но если ядро нарушит — отдаём пустой интерфейс, а не бросаем.
            override fun next(): LibboxNetworkInterface = LibboxNetworkInterface()
        }

    override fun underNetworkExtension(): Boolean = false
    override fun includeAllNetworks(): Boolean = false
    override fun clearDNSCache() {}

    /// §049 F12.3 + §050 actual root cause fix:
    ///
    /// `WifiManager.connectionInfo` на API 29+ требует `ACCESS_BACKGROUND_LOCATION`
    /// permission. Без неё binder throws **`SecurityException`** через
    /// `Parcel.readException()`. У нас этой permission в Manifest нет.
    ///
    /// **Реальный crash mechanism (раскрыт в §050)**:
    /// 1. Sing-box (Go) → cgo → `cproxy_PlatformInterface_ReadWIFIState`
    /// 2. Java callback `readWIFIState()` invokes `WifiManager.connectionInfo`
    /// 3. SecurityException thrown без permission (API 29+)
    /// 4. Exception propagates through JNI boundary без handler в cproxy code
    /// 5. `Seq$RefTracker.incRefnum` пытается cleanup → JNI env corrupted
    /// 6. `ClassLinker::FindClass` fails → `Runtime::Abort`
    /// 7. abort message "Unknown reference: 42" — **misleading follow-up**
    ///    effect broken JNI state, не реальный refnum lookup issue.
    ///
    /// Reference SagerNet не падает потому что проверяет permission ДО
    /// `cs.startOrReloadService()` через `commandServer.needWIFIState() &&
    /// !hasPermission()` → stopAndAlert. Sing-box не запускается без permission.
    ///
    /// **Defensive fix**: try/catch SecurityException → return null. Sing-box
    /// получает null gracefully (как раньше когда readWIFIState всегда был null).
    ///
    /// Combined с permission check в `BoxService.startSingbox` (post-`startOrReloadService`
    /// `needWIFIState() && !hasPermission()` warning log) — F12.3 теперь
    /// fully functional когда permission granted, fails gracefully когда нет.
    /// Delegate to `WifiInfoReader` — single source of truth для defensive
    /// чтения wifi state. См. `WifiInfoReader.kt` docstring для детального
    /// контекста (3 call-sites consolidation, drift risk история).
    override fun readWIFIState(): WIFIState? {
        val state = WifiInfoReader.readAsState(BoxApplication.application)
        if (state == null) {
            android.util.Log.w("PIW",
                "readWIFIState: null (permission missing / no wifi / runtime error)")
        } else if (state.ssid.isEmpty()) {
            android.util.Log.w("PIW",
                "readWIFIState: <unknown ssid> — likely missing NEARBY_WIFI_DEVICES")
        } else {
            android.util.Log.d("PIW",
                "readWIFIState: ssid='${state.ssid}' bssid='${state.bssid}'")
        }
        return state
    }

    // §179 (rc.6) — `systemCertificates()` УДАЛЁН из PlatformInterface ядром
    // (javap AAR rc.6: метода нет). sing-box 1.14 апстрим-мердж перенёс сбор
    // системных CA внутрь Go-рантайма (читает AndroidCAStore сам через
    // platform-bridge), наш Kotlin-сборщик §128 больше не нужен и не вызывается.
    // Оставлять `override fun systemCertificates()` = 'overrides nothing' →
    // ошибка компиляции. Удалён целиком. Если TLS к серверам с системными
    // (не встроенными) CA сломается на rc.6 — вернуть как НЕ-override хук через
    // отдельный binding (маловероятно: ядро берёт CA само).

    // ─── libbox 1.14: новые методы PlatformInterface ────────────────────
    // sing-box 1.14 влил Tailscale/SSH-сервер. Для Android VPN-клиента этот
    // функционал не нужен — отдаём безопасные заглушки. Контракт §050/§151:
    // методы БЕЗ `throws Exception` (registerMyInterface, *NeighborMonitor,
    // usePlatformShell) бросать НЕЛЬЗЯ → no-op; error-возвращающие — пустые
    // значения, чтобы ядро деградировало gracefully, а не валилось.

    /** Tailscale identity hook — на Android не используем. */
    override fun registerMyInterface(name: String) {}

    override fun usePlatformShell(): Boolean = false

    override fun checkPlatformShell() {}

    override fun lookupUser(username: String): io.nekohasekai.libbox.PlatformUser =
        io.nekohasekai.libbox.PlatformUser()

    override fun lookupSFTPServer(): String = ""

    override fun readSystemSSHHostKey(): String = ""

    override fun tailscaleHostname(): String = ""

    override fun openShellSession(
        user: io.nekohasekai.libbox.PlatformUser,
        command: String,
        env: StringIterator,
        termType: String,
        width: Int,
        height: Int
    ): io.nekohasekai.libbox.ShellSession = throw UnsupportedOperationException("shell not supported on Android")

    override fun startNeighborMonitor(listener: io.nekohasekai.libbox.NeighborUpdateListener) {}

    override fun closeNeighborMonitor(listener: io.nekohasekai.libbox.NeighborUpdateListener) {}

    // ─── 1.14.0-lx.3 (rc.2): platform-bridge (upstream L3-forwarding) ────
    // Апстрим влил "bridge outbound" — платформенный L3-мост, где ОС отдаёт
    // ядру отдельный TUN-fd под egress. Android VPN-клиент его не использует
    // (весь трафик уже идёт через наш единственный VpnService-TUN). Контракт
    // §050/§151: `usePlatformBridge` БЕЗ `throws` → безопасный `false`, ядро
    // мост не строит; `createBridge` С `throws Exception` (как openShellSession)
    // — ядро его не позовёт при false, но контракт требует реализацию.

    /** Не используем platform-bridge — весь трафик через VpnService-TUN. */
    override fun usePlatformBridge(): Boolean = false

    /// `cancelNotification` — новый метод PlatformInterface в ядре lx.27-rc.2
    /// (пришёл из апстрима вместе с Taildrop). Дефолт — no-op: реализации без
    /// собственных уведомлений (ProbeSession) не обязаны его переопределять,
    /// а `BoxVpnService` форвардит в `BoxService.cancelNotification`.
    /// Сигнатура с `throws` (§151 F1: бросать отсюда безопасно), но нам нечего
    /// бросать — уведомлений мы не ставили.
    override fun cancelNotification(identifier: String, typeID: Int) {}

    override fun createBridge(
        options: io.nekohasekai.libbox.BridgeOptions
    ): io.nekohasekai.libbox.BridgeSession =
        throw UnsupportedOperationException("platform bridge not used on Android")

    private class StringArray(private val iter: Iterator<String>) : StringIterator {
        override fun hasNext() = iter.hasNext()
        // §151 F1 — JNI no-throw: `StringIterator.Next()` — Go-метод БЕЗ `error`,
        // throw отсюда = `Runtime::Abort`. За концом отдаём "", не бросаем.
        override fun next(): String = if (iter.hasNext()) iter.next() else ""
        override fun len(): Int = 0
    }
}

private fun InterfaceAddress.toPrefix(): String {
    return if (address is Inet6Address) {
        "${Inet6Address.getByAddress(address.address).hostAddress}/$networkPrefixLength"
    } else {
        "${address.hostAddress}/$networkPrefixLength"
    }
}

