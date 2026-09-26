package com.leadaxe.lxbox.vpn

import android.content.Context
import android.location.LocationManager
import android.os.Build
import android.provider.Settings
import android.util.Log
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

    private const val TAG = "WifiInfoReader"
    const val PERM_NEARBY = "android.permission.NEARBY_WIFI_DEVICES"
    const val PERM_FINE = "android.permission.ACCESS_FINE_LOCATION"
    const val PERM_BACKGROUND = "android.permission.ACCESS_BACKGROUND_LOCATION"

    /// Полный read — для каллеров которым нужен Map с error reason
    /// (`MainActivity.getCurrentWifiInfoMap` для Flutter MethodChannel).
    /// Returns:
    /// - `Result.Success(ssid, bssid)` — valid pair (bssid lower-case,
    ///   может быть empty если Android не отдал)
    /// - `Result.PermissionMissing(missing)` — нет нужных permissions
    ///   (полные имена, порядок = приоритет: NEARBY, FINE, BACKGROUND)
    /// - `Result.LocationDisabled` — системный тумблер геолокации выключен
    ///   (§567: Android тогда молча отдаёт `<unknown ssid>`)
    /// - `Result.NoWifi` — `connectionInfo` вернул null
    /// - `Result.UnknownSsid` — `<unknown ssid>` или placeholder bssid
    /// - `Result.RuntimeError(msg)` — неожиданное исключение
    ///
    /// §567: каждая нештатная ветка — одна строка `Log.w` с тегом [TAG]
    /// (только logcat, в диагностический экспорт не идёт).
    fun read(ctx: Context): Result {
        val missing = missingPermissions(ctx)
        if (missing.isNotEmpty()) {
            Log.w(TAG, "permission missing: ${missing.joinToString(",")}")
            return Result.PermissionMissing(missing)
        }
        if (!isLocationEnabled(ctx)) {
            Log.w(TAG, "location disabled: system location toggle is off")
            return Result.LocationDisabled
        }
        @Suppress("DEPRECATION")
        val info = try {
            BoxApplication.wifiManager.connectionInfo
        } catch (e: SecurityException) {
            Log.w(TAG, "permission missing: SecurityException from connectionInfo: ${e.message}")
            return Result.PermissionMissing(emptyList())
        } catch (e: RuntimeException) {
            val msg = e.message ?: e.javaClass.simpleName
            Log.w(TAG, "runtime error from connectionInfo: $msg")
            return Result.RuntimeError(msg)
        }
        if (info == null) {
            Log.w(TAG, "no wifi: connectionInfo is null")
            return Result.NoWifi
        }

        val rawSsid = info.ssid
        val rawBssid = info.bssid
        var ssid = rawSsid
        if (ssid == null || ssid == "<unknown ssid>") {
            Log.w(TAG, "unknown ssid: android returned ssid=$rawSsid bssid=$rawBssid")
            return Result.UnknownSsid
        }
        if (ssid.startsWith("\"") && ssid.endsWith("\"")) {
            ssid = ssid.substring(1, ssid.length - 1)
        }
        val bssid = rawBssid?.lowercase() ?: ""
        if (bssid == PLACEHOLDER_BSSID) {
            Log.w(TAG, "unknown ssid: android returned ssid=$rawSsid bssid=$rawBssid")
            return Result.UnknownSsid
        }
        Log.d(TAG, "ok: ssid='$ssid' bssid='$bssid'")
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

    /// §567 — permission preflight, возвращает список отсутствующих
    /// разрешений (полные имена) в порядке приоритета:
    /// 1. NEARBY_WIFI_DEVICES (API 33+);
    /// 2. ACCESS_FINE_LOCATION (любой API) — без «точного местоположения»
    ///    Android молча отдаёт `<unknown ssid>`, даже при выданном BACKGROUND;
    /// 3. ACCESS_BACKGROUND_LOCATION (API 29+).
    private fun missingPermissions(ctx: Context): List<String> {
        val missing = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= 33 && !PermissionUtils.has(ctx, PERM_NEARBY)) {
            missing += PERM_NEARBY
        }
        if (!PermissionUtils.has(ctx, PERM_FINE)) {
            missing += PERM_FINE
        }
        if (Build.VERSION.SDK_INT >= 29 && !PermissionUtils.has(ctx, PERM_BACKGROUND)) {
            missing += PERM_BACKGROUND
        }
        return missing
    }

    /// §567 — системный тумблер геолокации. API 28+ — `LocationManager`,
    /// ниже — `Settings.Secure.LOCATION_MODE`. При любом исключении считаем
    /// включённой: проверка не должна блокировать чтение сама по себе.
    private fun isLocationEnabled(ctx: Context): Boolean = try {
        if (Build.VERSION.SDK_INT >= 28) {
            val lm = ctx.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
            lm?.isLocationEnabled ?: true
        } else {
            @Suppress("DEPRECATION")
            Settings.Secure.getInt(ctx.contentResolver, Settings.Secure.LOCATION_MODE) !=
                Settings.Secure.LOCATION_MODE_OFF
        }
    } catch (_: Exception) {
        true
    }

    sealed interface Result {
        data class Success(val ssid: String, val bssid: String) : Result
        data class PermissionMissing(val missing: List<String>) : Result
        object LocationDisabled : Result
        object NoWifi : Result
        object UnknownSsid : Result
        data class RuntimeError(val message: String) : Result
    }
}
