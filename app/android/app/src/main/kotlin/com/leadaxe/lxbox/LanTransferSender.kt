package com.leadaxe.lxbox

import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.leadaxe.lxbox.vpn.BoxApplication
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.ConnectException
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.SocketTimeoutException

/// §622 — отправка настроек на TV мимо собственного туннеля (фича 031, P7).
///
/// В allow-mode LxBox кладёт себя в tun («+self», `BoxService.buildOverrideOptions`),
/// и обычный сокет на 192.168.x.x мог бы уйти в sing-box. Здесь сокет создаётся
/// фабрикой физической сети (Wi-Fi/Ethernet без TRANSPORT_VPN): `Network.socketFactory`
/// привязывает его к netId этой сети. netd разрешает такую привязку UID, который
/// вправе защищать сокеты от VPN, — владелец VPN среди них, allowBypass не нужен.
///
/// HTTP пишется руками поверх сокета: `HttpURLConnection` подчиняется
/// network_security_config, а cleartext там разрешён только для loopback.
object LanTransferSender {
    private const val TAG = "LanTransfer"
    private const val MAX_RESPONSE = 64 * 1024

    private val main = Handler(Looper.getMainLooper())

    fun post(
        host: String,
        port: Int,
        path: String,
        body: ByteArray,
        connectTimeoutMs: Int,
        readTimeoutMs: Int,
        userAgent: String,
        result: MethodChannel.Result,
    ) {
        val target = runCatching { InetAddress.getByName(host) }.getOrNull()
        val network = target?.let { pickNetwork(it) }
        if (network == null) {
            result.success(mapOf("outcome" to "no_network"))
            return
        }
        Thread({
            val out = runCatching {
                send(network, host, port, path, body, connectTimeoutMs, readTimeoutMs, userAgent)
            }.getOrElse { e -> failure(e) }
            main.post { result.success(out) }
        }, "lan-transfer").start()
    }

    /// Wi-Fi или Ethernet без VPN; при нескольких — та, в чьей подсети адрес.
    private fun pickNetwork(target: InetAddress): Network? {
        val cm = BoxApplication.connectivity
        @Suppress("DEPRECATION")
        val candidates = cm.allNetworks.filter { n ->
            val caps = cm.getNetworkCapabilities(n) ?: return@filter false
            !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
                (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET))
        }
        if (candidates.isEmpty()) return null
        return candidates.firstOrNull { n ->
            cm.getLinkProperties(n)?.linkAddresses?.any { la ->
                la.address is Inet4Address && sameSubnet(la.address, target, la.prefixLength)
            } == true
        } ?: candidates.first()
    }

    private fun sameSubnet(a: InetAddress, b: InetAddress, prefix: Int): Boolean {
        val x = a.address
        val y = b.address
        if (x.size != y.size) return false
        var bits = prefix
        for (i in x.indices) {
            if (bits <= 0) return true
            val mask = if (bits >= 8) 0xFF else (0xFF shl (8 - bits)) and 0xFF
            if ((x[i].toInt() and mask) != (y[i].toInt() and mask)) return false
            bits -= 8
        }
        return true
    }

    private fun send(
        network: Network,
        host: String,
        port: Int,
        path: String,
        body: ByteArray,
        connectTimeoutMs: Int,
        readTimeoutMs: Int,
        userAgent: String,
    ): Map<String, Any> {
        network.socketFactory.createSocket().use { socket ->
            socket.connect(InetSocketAddress(host, port), connectTimeoutMs)
            socket.soTimeout = readTimeoutMs
            val head = "POST $path HTTP/1.1\r\n" +
                "Host: $host:$port\r\n" +
                "Content-Type: application/json\r\n" +
                (if (userAgent.isBlank()) "" else "User-Agent: $userAgent\r\n") +
                "Content-Length: ${body.size}\r\n" +
                "Connection: close\r\n\r\n"
            val os = socket.getOutputStream()
            os.write(head.toByteArray(Charsets.US_ASCII))
            os.write(body)
            os.flush()

            val buf = ByteArrayOutputStream()
            val chunk = ByteArray(8192)
            val input = socket.getInputStream()
            while (buf.size() < MAX_RESPONSE) {
                val n = input.read(chunk)
                if (n < 0) break
                buf.write(chunk, 0, n)
            }
            return parseResponse(buf.toByteArray())
        }
    }

    private fun parseResponse(raw: ByteArray): Map<String, Any> {
        val text = String(raw, Charsets.UTF_8)
        val statusLine = text.substringBefore("\r\n")
        val status = statusLine.split(' ').getOrNull(1)?.toIntOrNull()
            ?: return mapOf("outcome" to "unreachable", "detail" to "bad response")
        val body = text.substringAfter("\r\n\r\n", "")
        return mapOf("outcome" to "response", "status" to status, "body" to body)
    }

    private fun failure(e: Throwable): Map<String, Any> {
        Log.i(TAG, "send failed: ${e.javaClass.simpleName}: ${e.message}")
        return when {
            e is ConnectException && e.message?.contains("ECONNREFUSED") == true ->
                mapOf("outcome" to "refused")
            e is SocketTimeoutException ->
                mapOf("outcome" to "unreachable", "detail" to "timeout")
            e is IOException ->
                mapOf("outcome" to "unreachable", "detail" to (e.message ?: e.javaClass.simpleName))
            else ->
                mapOf("outcome" to "unreachable", "detail" to e.javaClass.simpleName)
        }
    }
}
