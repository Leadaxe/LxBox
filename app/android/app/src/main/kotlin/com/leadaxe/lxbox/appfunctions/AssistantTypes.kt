package com.leadaxe.lxbox.appfunctions

import androidx.appfunctions.AppFunctionSerializable

// §750 — типы ответов функций ассистента (AppFunctions). KDoc — английский,
// описывает только смысл полей; KSP кладёт его в схему.

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

/** The answer of an L×Box API route. */
@AppFunctionSerializable(isDescribedByKDoc = true)
data class ApiResponse(
    /** The status code of the route, as in HTTP: 200 is success, 4xx is a rejected request. */
    val status: Int,
    /** The answer body as a JSON string. */
    val body: String,
)
