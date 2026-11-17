package com.leadaxe.lxbox.appfunctions

import androidx.appfunctions.AppFunctionSerializable

// §750 — типы ответов функций ассистента (AppFunctions). KDoc — английский,
// описывает только смысл полей; KSP кладёт его в схему.

/** A routing direction of L×Box: a named group of exits that traffic can go through. */
@AppFunctionSerializable(isDescribedByKDoc = true)
data class DirectionInfo(
    /** The direction identifier, such as "vpn-1". */
    val tag: String,
    /** The direction name set by the user. */
    val name: String,
    /** The number of exits in the direction. */
    val exitCount: Int,
    /** The name of the exit selected now, as set by the subscription provider or the user; empty when the VPN is off. */
    val currentExit: String,
)

/** A private network connection configured in L×Box (WireGuard, AmneziaWG, OpenVPN, OpenConnect or Tailscale). */
@AppFunctionSerializable(isDescribedByKDoc = true)
data class ConnectionInfo(
    /** The connection identifier. */
    val id: String,
    /** The connection name set by the user or the provider. */
    val name: String,
    /** The connection type: "wireguard", "amneziawg", "openvpn", "openconnect" or "tailscale". */
    val type: String,
    /** Whether the connection is turned on in L×Box. */
    val enabled: Boolean,
    /** The connection state: "up", "connecting", "idle", "needs_login", "down", "disabled" or "unknown". */
    val state: String,
)

/** An overview of the L×Box network setup. */
@AppFunctionSerializable(isDescribedByKDoc = true)
data class NetworkOverview(
    /** The tunnel state: "stopped", "starting", "started" or "stopping". */
    val vpnStatus: String,
    /** Where traffic without a matching rule goes: a direction identifier, "direct" or "block". */
    val defaultRoute: String,
    /** The routing directions. */
    val directions: List<DirectionInfo>,
    /** The private network connections. */
    val connections: List<ConnectionInfo>,
)

/** Exits of a routing direction. */
@AppFunctionSerializable(isDescribedByKDoc = true)
data class ExitList(
    /** The direction identifier. */
    val direction: String,
    /** Exit names as set by the subscription provider or the user; a name often carries a country flag or a country name. */
    val exits: List<String>,
    /** The number of matching exits. */
    val total: Int,
    /** Whether the list was cut short. */
    val truncated: Boolean,
)

/** The route a checked request took. */
@AppFunctionSerializable(isDescribedByKDoc = true)
data class RouteInfo(
    /** The direction identifier the request went through; empty for a direct or blocked route. */
    val direction: String,
    /** The name of the exit the request went through, as set by the subscription provider or the user; empty when unknown. */
    val exit: String,
    /** Whether the request went directly, without the VPN. */
    val direct: Boolean,
    /** Whether a routing rule blocked the request. */
    val blocked: Boolean,
)

/** The result of a check whether an address opens. */
@AppFunctionSerializable(isDescribedByKDoc = true)
data class UrlCheckReport(
    /** The outcome: "ok", "failed", "vpn_off", "busy" or "timeout". */
    val outcome: String,
    /** The step that failed: "dns", "route", "tunnel", "connect", "tls", "http"; empty when nothing failed. */
    val failedStage: String,
    /** The error text of the failed step; empty when nothing failed. */
    val error: String,
    /** The HTTP status of the answer; 0 when there was no answer. */
    val httpStatus: Int,
    /** How long the check took, in milliseconds. */
    val elapsedMs: Int,
    /** The route the request took. */
    val route: RouteInfo,
    /** Diagnostic codes found during the check. */
    val findings: List<String>,
    /** What to do next, in one or two sentences. */
    val advice: String,
)

/** The actual exit of a routing direction as seen from the internet. */
@AppFunctionSerializable(isDescribedByKDoc = true)
data class ExitCheck(
    /** The outcome: "ok", "failed" or "vpn_off". */
    val outcome: String,
    /** The two-letter country code of the exit address; empty when unknown. */
    val country: String,
    /** The public IP address of the exit; empty when unknown. */
    val ip: String,
    /** The name of the selected exit, as set by the subscription provider or the user. */
    val exit: String,
    /** The error text; empty on success. */
    val error: String,
)

/** An installed app. */
@AppFunctionSerializable(isDescribedByKDoc = true)
data class AppMatch(
    /** The app package name, such as "org.telegram.messenger". */
    val packageName: String,
    /** The app name shown on the device. */
    val label: String,
)

/** How the saved routing rules route an app. */
@AppFunctionSerializable(isDescribedByKDoc = true)
data class AppRoute(
    /** The app package name. */
    val app: String,
    /** Where the app traffic goes: a direction identifier, "direct" or "block". */
    val target: String,
    /** The name of the target: the direction name set by the user, "Direct" or "Block". */
    val targetName: String,
    /** The name of the rule that routes the app, set by the user; empty when no rule matches and the default route applies. */
    val ruleName: String,
    /** Whether the rule also has other conditions (domain, network, Wi-Fi), so the route depends on them. */
    val conditional: Boolean,
)

/** The result of selecting an exit in a routing direction. */
@AppFunctionSerializable(isDescribedByKDoc = true)
data class ExitSelection(
    /** The direction identifier. */
    val direction: String,
    /** The name of the selected exit. */
    val exit: String,
    /** Whether the selection changed. */
    val changed: Boolean,
)
