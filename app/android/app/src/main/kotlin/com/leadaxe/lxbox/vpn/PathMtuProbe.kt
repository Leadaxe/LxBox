package com.leadaxe.lxbox.vpn

import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.system.StructPollfd
import io.flutter.plugin.common.MethodChannel
import java.io.FileDescriptor
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.net.NetworkInterface
import java.util.concurrent.Executors

/// §725 — примитив замера Path MTU: ОДНА эхо-проба заданного размера мимо
/// туннеля. Поиск, повторы и отмена — в Dart (`lib/services/diagnostics/
/// path_mtu.dart`), здесь только «отправить пакет N байт с DF и дождаться
/// ответа».
///
/// Ядро не участвует (решение владельца): непривилегированный ICMP-сокет
/// (`SOCK_DGRAM` + `IPPROTO_ICMP`, «ping socket» Linux — приложениям
/// доступен без прав), привязанный к ФИЗИЧЕСКОЙ сети через
/// `Network.bindSocket`; при живом VpnService ещё и `protect(fd)`, как ядро
/// защищает свои сокеты. Системный `/system/bin/ping` не годится: при
/// включённом VPN он уходит в tun, а `-I` требует `CAP_NET_RAW`.
///
/// Канал `com.leadaxe.lxbox/path_mtu`, методы `network` / `resolve` /
/// `probe`; всё тело — вне main-потока.
object PathMtuProbe {
    const val CHANNEL = "com.leadaxe.lxbox/path_mtu"

    // Констант PMTU-сокопций в OsConstants нет — числа из linux/in.h,
    // linux/in6.h.
    private const val IP_MTU_DISCOVER = 10
    private const val IP_PMTUDISC_DO = 2
    /// DF выставлен, а кэш PMTU ядра Linux не подменяет размер отправки.
    private const val IP_PMTUDISC_PROBE = 3
    private const val IPV6_MTU_DISCOVER = 23
    private const val IPV6_PMTUDISC_DO = 2
    private const val IPV6_PMTUDISC_PROBE = 3
    private const val IPV6_DONTFRAG = 62

    private const val ICMP_ECHO_REQUEST = 8
    private const val ICMP_ECHO_REPLY = 0
    private const val ICMPV6_ECHO_REQUEST = 128
    private const val ICMPV6_ECHO_REPLY = 129

    /// Заголовки IP + ICMP: нагрузка эха = size − это число.
    private const val HDR_V4 = 28
    private const val HDR_V6 = 48

    private val executor = Executors.newCachedThreadPool()
    private val main = Handler(Looper.getMainLooper())

    fun attach(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            fun ok(v: Any?) = main.post { result.success(v) }
            fun fail(code: String, msg: String?) = main.post { result.error(code, msg, null) }
            when (call.method) {
                "network" -> executor.execute {
                    try {
                        val net = physicalNetwork()
                        if (net == null) fail("no_network", "no physical network") else ok(describe(net))
                    } catch (e: Throwable) {
                        fail("error", e.message ?: e.toString())
                    }
                }
                "resolve" -> executor.execute {
                    try {
                        val host = call.argument<String>("host").orEmpty().trim()
                        val net = physicalNetwork()
                        if (net == null) {
                            fail("no_network", "no physical network")
                        } else {
                            val all = net.getAllByName(host)
                            val pick = all.firstOrNull { it is Inet4Address } ?: all.firstOrNull()
                            if (pick == null) fail("resolve", "no address for $host")
                            else ok(pick.hostAddress)
                        }
                    } catch (e: Throwable) {
                        fail("resolve", e.message ?: e.toString())
                    }
                }
                "probe" -> executor.execute {
                    try {
                        val ip = call.argument<String>("ip").orEmpty()
                        val size = call.argument<Int>("size") ?: 0
                        val timeoutMs = call.argument<Int>("timeoutMs") ?: 1000
                        val seq = call.argument<Int>("seq") ?: 0
                        val net = physicalNetwork()
                        if (net == null) fail("no_network", "no physical network")
                        else ok(probe(net, ip, size, timeoutMs, seq))
                    } catch (e: Throwable) {
                        ok(mapOf("status" to "error", "rtt_ms" to 0, "error" to (e.message ?: e.toString())))
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private val connectivity: ConnectivityManager get() = BoxApplication.connectivity

    private fun isPhysical(net: Network): Boolean {
        val caps = connectivity.getNetworkCapabilities(net) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
    }

    /// Физическая сеть: при поднятом туннеле — та, что держит
    /// DefaultNetworkMonitor; иначе activeNetwork, если не VPN; иначе первая
    /// подходящая из allNetworks.
    private fun physicalNetwork(): Network? {
        if (BoxVpnService.live != null) {
            DefaultNetworkMonitor.defaultNetwork?.let { if (isPhysical(it)) return it }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            connectivity.activeNetwork?.let { if (isPhysical(it)) return it }
        }
        @Suppress("DEPRECATION")
        val all = connectivity.allNetworks
        return all.firstOrNull { isPhysical(it) }
    }

    private fun describe(net: Network): Map<String, Any> {
        val lp = connectivity.getLinkProperties(net)
        val iface = lp?.interfaceName.orEmpty()
        val caps = connectivity.getNetworkCapabilities(net)
        val transport = when {
            caps == null -> "other"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            else -> "other"
        }
        // LinkProperties.getMtu() есть с API 29 и часто 0 (сеть не сообщила);
        // тогда — MTU самого интерфейса: именно о него упирается отправка
        // (EMSGSIZE). 0 — неизвестен.
        var mtu = 0
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && lp != null) mtu = lp.mtu
        if (mtu <= 0 && iface.isNotEmpty()) {
            mtu = runCatching { NetworkInterface.getByName(iface)?.mtu ?: 0 }.getOrDefault(0)
        }
        return mapOf("iface" to iface, "transport" to transport, "mtu" to maxOf(mtu, 0))
    }

    private fun outcome(status: String, rttMs: Long = 0, error: String = "") =
        mapOf("status" to status, "rtt_ms" to rttMs.toInt(), "error" to error)

    private fun probe(net: Network, ip: String, size: Int, timeoutMs: Int, seq: Int): Map<String, Any> {
        val addr = InetAddress.getByName(ip) // литерал — без DNS
        val v6 = addr is Inet6Address
        val payload = size - if (v6) HDR_V6 else HDR_V4
        if (payload < 8) return outcome("error", error = "size too small")
        val fd: FileDescriptor = if (v6) {
            Os.socket(OsConstants.AF_INET6, OsConstants.SOCK_DGRAM, OsConstants.IPPROTO_ICMPV6)
        } else {
            Os.socket(OsConstants.AF_INET, OsConstants.SOCK_DGRAM, OsConstants.IPPROTO_ICMP)
        }
        try {
            // protect — на дубликате дескриптора: метка ставится самому сокету,
            // дубликат делит его с fd.
            val vpn = BoxVpnService.live
            if (vpn != null) {
                runCatching {
                    ParcelFileDescriptor.dup(fd).use { vpn.protect(it.fd) }
                }
            }
            net.bindSocket(fd)
            if (v6) {
                try {
                    Os.setsockoptInt(fd, OsConstants.IPPROTO_IPV6, IPV6_MTU_DISCOVER, IPV6_PMTUDISC_PROBE)
                } catch (_: ErrnoException) {
                    Os.setsockoptInt(fd, OsConstants.IPPROTO_IPV6, IPV6_MTU_DISCOVER, IPV6_PMTUDISC_DO)
                }
                runCatching { Os.setsockoptInt(fd, OsConstants.IPPROTO_IPV6, IPV6_DONTFRAG, 1) }
            } else {
                try {
                    Os.setsockoptInt(fd, OsConstants.IPPROTO_IP, IP_MTU_DISCOVER, IP_PMTUDISC_PROBE)
                } catch (_: ErrnoException) {
                    Os.setsockoptInt(fd, OsConstants.IPPROTO_IP, IP_MTU_DISCOVER, IP_PMTUDISC_DO)
                }
            }

            // Эхо-запрос: type, code, checksum (ping-сокет считает сам),
            // identifier (ядро подставит порт сокета), sequence, нагрузка.
            val packet = ByteArray(payload)
            packet[0] = (if (v6) ICMPV6_ECHO_REQUEST else ICMP_ECHO_REQUEST).toByte()
            val seq16 = seq and 0xffff
            packet[6] = (seq16 shr 8).toByte()
            packet[7] = (seq16 and 0xff).toByte()
            for (i in 8 until payload) packet[i] = (i and 0xff).toByte()

            val started = SystemClock.elapsedRealtime()
            try {
                Os.sendto(fd, packet, 0, packet.size, 0, addr, 0)
            } catch (e: ErrnoException) {
                if (e.errno == OsConstants.EMSGSIZE) return outcome("too_big")
                return outcome("error", error = e.message ?: "sendto")
            }

            val buf = ByteArray(maxOf(payload, 2048))
            val deadline = started + timeoutMs
            while (true) {
                val left = deadline - SystemClock.elapsedRealtime()
                if (left <= 0) return outcome("timeout")
                val pfd = StructPollfd()
                pfd.fd = fd
                pfd.events = OsConstants.POLLIN.toShort()
                val n = try {
                    Os.poll(arrayOf(pfd), left.toInt())
                } catch (e: ErrnoException) {
                    if (e.errno == OsConstants.EINTR) continue
                    return outcome("error", error = e.message ?: "poll")
                }
                if (n <= 0) return outcome("timeout")
                val got = try {
                    Os.recvfrom(fd, buf, 0, buf.size, 0, null)
                } catch (e: ErrnoException) {
                    // ICMP-ошибка пути (например «нужна фрагментация») приходит
                    // ошибкой сокета — пакет не дошёл.
                    if (e.errno == OsConstants.EAGAIN || e.errno == OsConstants.EINTR) continue
                    return outcome("timeout", error = e.message ?: "recv")
                }
                if (got < 8) continue
                val type = buf[0].toInt() and 0xff
                val replySeq = ((buf[6].toInt() and 0xff) shl 8) or (buf[7].toInt() and 0xff)
                val want = if (v6) ICMPV6_ECHO_REPLY else ICMP_ECHO_REPLY
                // Ответ любой длины: часть серверов обрезает эхо.
                if (type == want && replySeq == seq16) {
                    return outcome("ok", SystemClock.elapsedRealtime() - started)
                }
            }
        } finally {
            runCatching { Os.close(fd) }
        }
    }
}
