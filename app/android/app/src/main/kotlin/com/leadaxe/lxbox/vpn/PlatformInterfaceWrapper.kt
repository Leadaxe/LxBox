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
        val uid = BoxApplication.connectivity.getConnectionOwnerUid(
            ipProtocol,
            InetSocketAddress(sourceAddress, sourcePort),
            InetSocketAddress(destinationAddress, destinationPort)
        )
        if (uid == Process.INVALID_UID) error("android: connection owner not found")
        // Sing-box 1.13 ушёл от двухступенчатого callback'а
        // (`packageNameByUid`/`uidByPackageName`) к одной структуре `ConnectionOwner`,
        // которую мы заполняем сразу: UID + список пакетов под ним. Process path и
        // username на Android неприменимы (нет /proc-доступа без root) — оставляем пустыми.
        val packages = BoxApplication.packageManager.getPackagesForUid(uid)?.toList() ?: emptyList()
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

    override fun underNetworkExtension(): Boolean = false
    override fun includeAllNetworks(): Boolean = false
    override fun clearDNSCache() {}

    /// §049 F12.3: возвращаем null — deferred окончательно, blocked on
    /// libbox debug symbols / upgrade.
    ///
    /// **Полный лог attempt'ов на нашем env (Android 15 OnePlus + libbox 1.13.11)**:
    ///
    /// Pre-Phase H (старый BoxApplication object, был активный `Seq.setContext`):
    /// 1. Pre-split + `WIFIState(s,b)` constructor → crash refnum 42
    /// 2. F1 split + ctor → crash 8s
    /// 3. F1 split + ctor + Java strong-ref pin → crash 10s
    /// 4. F1 split + `Libbox.newWIFIState(s,b)` factory + pin → crash 8s
    /// 5. F1 split + ctor + drop `Seq.setContext` (на object) → crash 12s
    ///
    /// Phase H baseline (registered Application class + закомментированный
    /// `Seq.setContext` + `logMaxLines=3000` + `Libbox.setMemoryLimit(true)`
    /// removed):
    /// 6. v11400 (Phase H + F12.3 ctor) → cold-start crash refnum 42 за 1-3s,
    ///    auto-restart picks up stable. Stop-vpn + start-vpn cycle = снова
    ///    cold-start crash. Process-Runtime tombstones consistently <3s на
    ///    cold launch. Auto-restart прозрачен для UX но system-side это 2-3
    ///    SIGABRT каждый VPN start.
    /// 7. v11500 (Phase H + drop `Libbox.setMemoryLimit(true)` + F12.3 ctor)
    ///    → тот же cold-start crash refnum 42 за 1s. Setting setMemoryLimit
    ///    (которое reference НЕ зовёт) НЕ был root cause.
    ///
    /// Crash signature: `cproxylibbox_CommandServerHandler_WriteDebugMessage+68
    /// → go_seq_from_refnum+228 → 'Unknown reference: N'` (где N = handler
    /// refnum после cold start, обычно 42 на baseline). Corruption происходит
    /// внутри Go runtime libbox.so при cold-start sequence — Java-side
    /// `Seq.Ref` wrapper держится strongly, Go-side не находит ref.
    ///
    /// Reference SagerNet (1.13.11 commit 3b3883e) имеет **identical Java code**
    /// для readWIFIState (port 1:1 verified). Reference на 1.13.x **не падает**
    /// в production — у людей работает stably. Что-то в нашем environment'е
    /// (Android 15 OnePlus + наш Flutter wrapper + наша build chain) отличается
    /// на native level, но без libbox.so debug symbols мы не можем resolve
    /// PC → Go file:line чтобы найти где destroyRef triggered.
    ///
    /// **Tracking**: `docs/spec/tasks/050-libbox-debug-build/spec.md` —
    /// собрать `libbox.aar` с debug symbols через `gomobile bind` из
    /// `SagerNet/sing-box` v1.13.11 source, repro crash, `addr2line` resolve
    /// каждый PC frame в backtrace. Estimate: 2-5 часов отдельной session.
    /// Альтернатива — upgrade libbox 1.14-alpha (reference's current).
    ///
    /// **Practical impact**: F12.3 deferred = sing-box rules с условиями
    /// `wifi_ssid:` / `wifi_bssid:` не работают. У нас в wizard config
    /// generation таких rules нет, юзеры тоже не используют — feature
    /// без реального usage сейчас.
    override fun readWIFIState(): WIFIState? = null

    @OptIn(kotlin.io.encoding.ExperimentalEncodingApi::class)
    override fun systemCertificates(): StringIterator {
        val certs = mutableListOf<String>()
        val ks = java.security.KeyStore.getInstance("AndroidCAStore")
        if (ks != null) {
            ks.load(null, null)
            val aliases = ks.aliases()
            while (aliases.hasMoreElements()) {
                val cert = ks.getCertificate(aliases.nextElement())
                certs.add("-----BEGIN CERTIFICATE-----\n${kotlin.io.encoding.Base64.encode(cert.encoded)}\n-----END CERTIFICATE-----")
            }
        }
        return StringArray(certs.iterator())
    }

    private class StringArray(private val iter: Iterator<String>) : StringIterator {
        override fun hasNext() = iter.hasNext()
        override fun next() = iter.next()
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

