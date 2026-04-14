package com.leadaxe.boxvpn_app.vpn

enum class VpnStatus {
    Stopped,
    Starting,
    Started,
    Stopping;

    val nativeName: String get() = name
}
