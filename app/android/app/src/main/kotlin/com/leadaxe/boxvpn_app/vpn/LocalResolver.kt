package com.leadaxe.boxvpn_app.vpn

import io.nekohasekai.libbox.ExchangeContext
import io.nekohasekai.libbox.LocalDNSTransport
import java.net.InetAddress

object LocalResolver : LocalDNSTransport {
    override fun raw(): Boolean = false

    override fun lookup(ctx: ExchangeContext, network: String, domain: String) {
        val addresses = InetAddress.getAllByName(domain)
        ctx.success(addresses.joinToString("\n") { it.hostAddress ?: "" })
    }

    override fun exchange(ctx: ExchangeContext, message: ByteArray?) {
        ctx.errorCode(1)
    }
}
