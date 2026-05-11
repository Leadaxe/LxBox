package com.leadaxe.lxbox.vpn

import android.content.Context
import android.os.Build
import io.nekohasekai.libbox.WIFIState

/**
 * §051 — single source of truth для чтения текущей Wi-Fi сети.
 *
 * До рефактора одна и та же defensive-логика жила в 3 местах:
 * - `PlatformInterfaceWrapper.readWIFIState()` — sing-box hot callback
 * - `MainActivity.getCurrentWifiInfoMap()` — Flutter Add current
 * - `WifiNetworkObserver.readWifi()` — Phase 3 auto-record
 *
 * Drift risk: фикс одного места без других → silent inconsistencies.
 * Все три теперь делегируют сюда. Один permission preflight, один
 * try/catch SecurityException, одна нормализация `<unknown ssid>` и
 * `02:00:00:00:00:00` placeholder.
 */
object WifiInfoReader {

    /// `02:00:00:00:00:00` — Android placeholder когда нет реального
    /// доступа к connection info (e.g., other-app's network на API 30+).
    /// Не валидная пара, трактуем как unknown.
    private const val PLACEHOLDER_BSSID = "02:00:00:00:00:00"

    /// Полный read — для каллеров которым нужен Map с error reason
    /// (`MainActivity.getCurrentWifiInfoMap` для Flutter MethodChannel).
    /// Returns:
    /// - `Result.Success(ssid, bssid)` — valid pair (bssid lower-case,
    ///   может быть empty если Android не отдал)
    /// - `Result.PermissionMissing` — нет нужных permissions
    /// - `Result.NoWifi` — `connectionInfo` вернул null
    /// - `Result.UnknownSsid` — `<unknown ssid>` или placeholder bssid
    /// - `Result.RuntimeError(msg)` — неожиданное исключение
    fun read(ctx: Context): Result {
        if (!hasWifiInfoPermissions(ctx)) {
            return Result.PermissionMissing
        }
        @Suppress("DEPRECATION")
        val info = try {
            BoxApplication.wifiManager.connectionInfo
        } catch (_: SecurityException) {
            return Result.PermissionMissing
        } catch (e: RuntimeException) {
            return Result.RuntimeError(e.message ?: e.javaClass.simpleName)
        } ?: return Result.NoWifi

        var ssid = info.ssid
        if (ssid == null || ssid == "<unknown ssid>") {
            return Result.UnknownSsid
        }
        if (ssid.startsWith("\"") && ssid.endsWith("\"")) {
            ssid = ssid.substring(1, ssid.length - 1)
        }
        val bssid = info.bssid?.lowercase() ?: ""
        if (bssid == PLACEHOLDER_BSSID) {
            return Result.UnknownSsid
        }
        return Result.Success(ssid, bssid)
    }

    /// Convenience для callers которым нужен WIFIState? (sing-box callback
    /// + auto-record). null на любую ошибку — sing-box обрабатывает gracefully
    /// (existing F12.3 fix flow).
    fun readAsState(ctx: Context): WIFIState? = when (val r = read(ctx)) {
        is Result.Success -> WIFIState(r.ssid, r.bssid)
        is Result.UnknownSsid -> WIFIState("", "")
        else -> null
    }

    /// Permission preflight — combined check для BACKGROUND_LOCATION
    /// (API 29+) + NEARBY_WIFI_DEVICES (API 33+). Без них `connectionInfo`
    /// либо бросает SecurityException либо возвращает redacted ssid.
    private fun hasWifiInfoPermissions(ctx: Context): Boolean {
        if (Build.VERSION.SDK_INT >= 33 &&
            !PermissionUtils.has(ctx, "android.permission.NEARBY_WIFI_DEVICES")) {
            return false
        }
        if (Build.VERSION.SDK_INT >= 29) {
            return PermissionUtils.has(
                ctx, "android.permission.ACCESS_BACKGROUND_LOCATION",
            )
        }
        return PermissionUtils.has(ctx, "android.permission.ACCESS_FINE_LOCATION")
    }

    sealed interface Result {
        data class Success(val ssid: String, val bssid: String) : Result
        object PermissionMissing : Result
        object NoWifi : Result
        object UnknownSsid : Result
        data class RuntimeError(val message: String) : Result
    }
}
