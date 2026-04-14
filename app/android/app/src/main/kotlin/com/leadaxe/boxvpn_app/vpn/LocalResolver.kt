package com.leadaxe.boxvpn_app.vpn

import io.nekohasekai.libbox.LocalDNSTransport
import java.net.InetAddress

object LocalResolver : LocalDNSTransport {
    override fun raw(): Boolean = false

    override fun lookup(network: String, domain: String): String {
        val addresses = InetAddress.getAllByName(domain)
        return addresses.joinToString("\n") { it.hostAddress ?: "" }
    }

    override fun exchange(message: ByteArray?): ByteArray {
        error("raw mode disabled")
    }
}
