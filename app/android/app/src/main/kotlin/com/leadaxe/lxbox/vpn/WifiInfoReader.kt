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

    private const val UNKNOWN_SSID = "<unknown ssid>"

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
    ///
    /// §569: на API 31+ сначала кэш [WifiStateCache] (колбэк с
    /// `FLAG_INCLUDE_LOCATION_INFO`, `NetworkCapabilities.transportInfo`),
    /// при пустом кэше или SSID, который кэш не получил, — fallback на
    /// `getConnectionInfo()`. Успешное чтение пишет `Log.d` с `source=cache`
    /// или `source=legacy`. API < 31 — только `getConnectionInfo()`.
    fun read(ctx: Context): Result {
        val blocked = preflight(ctx)
        if (blocked != null) {
            when (blocked) {
                is Result.PermissionMissing ->
                    Log.w(TAG, "permission missing: ${blocked.missing.joinToString(",")}")
                else -> Log.w(TAG, "location disabled: system location toggle is off")
            }
            // §569: колбэк зарегистрирован при другом наборе разрешений —
            // снимаем, после восстановления ensureCurrent зарегистрирует заново.
            if (Build.VERSION.SDK_INT >= 31) BoxApplication.wifiStateCacheOrNull?.stop()
            return blocked
        }

        var cacheUnknown = false
        if (Build.VERSION.SDK_INT >= 31) {
            val cache = BoxApplication.wifiStateCacheOrNull
            if (cache != null) {
                cache.ensureCurrent()
                val snap = cache.latest
                if (snap != null && snap.ssid.isNotEmpty()) {
                    Log.d(TAG, "ok: source=cache ssid='${snap.ssid}' bssid='${snap.bssid}'")
                    return Result.Success(snap.ssid, snap.bssid)
                }
                if (snap != null) {
                    // Кэш есть, но Android отдал его с вырезанным SSID.
                    // Сверяемся со старым путём: результат не хуже, чем до §569.
                    cacheUnknown = true
                    Log.d(TAG, "cache has unknown ssid, falling back: source=legacy")
                } else {
                    Log.d(TAG, "cache empty (registered=${cache.isRegistered}), falling back: source=legacy")
                }
            }
        }
        return readLegacy(cacheUnknown)
    }

    /// `WifiManager.getConnectionInfo()` — единственный путь на API < 31 и
    /// fallback на 31+. [cacheUnknown] — только для строки лога.
    private fun readLegacy(cacheUnknown: Boolean): Result {
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
        val ssid = normalizeSsid(rawSsid)
        val bssid = normalizeBssid(rawBssid)
        if (ssid.isEmpty() || rawBssid?.lowercase() == PLACEHOLDER_BSSID) {
            val suffix = if (cacheUnknown) " (cache also unknown)" else ""
            Log.w(TAG, "unknown ssid: android returned ssid=$rawSsid bssid=$rawBssid$suffix")
            return Result.UnknownSsid
        }
        Log.d(TAG, "ok: source=legacy ssid='$ssid' bssid='$bssid'")
        return Result.Success(ssid, bssid)
    }

    /// §569 — нормализация SSID из `WifiInfo`: `null` и `<unknown ssid>` →
    /// пустая строка, кавычки вокруг UTF-8 SSID снимаются.
    fun normalizeSsid(raw: String?): String {
        if (raw == null || raw == UNKNOWN_SSID) return ""
        if (raw.length >= 2 && raw.startsWith("\"") && raw.endsWith("\"")) {
            return raw.substring(1, raw.length - 1)
        }
        return raw
    }

    /// §569 — нормализация BSSID: lower-case; `null` и placeholder
    /// `02:00:00:00:00:00` → пустая строка.
    fun normalizeBssid(raw: String?): String {
        val b = raw?.lowercase() ?: return ""
        return if (b == PLACEHOLDER_BSSID) "" else b
    }

    /// Convenience для callers которым нужен WIFIState? (sing-box callback
    /// + auto-record). null на любую ошибку — sing-box обрабатывает gracefully
    /// (existing F12.3 fix flow).
    fun readAsState(ctx: Context): WIFIState? = when (val r = read(ctx)) {
        is Result.Success -> WIFIState(r.ssid, r.bssid)
        is Result.UnknownSsid -> WIFIState("", "")
        else -> null
    }

    /// §567/§569 — preflight разрешений и геолокации. `null` — чтение
    /// возможно; иначе причина: [Result.PermissionMissing] или
    /// [Result.LocationDisabled]. Без логирования — пишет вызывающий.
    fun preflight(ctx: Context): Result? {
        val missing = missingPermissions(ctx)
        if (missing.isNotEmpty()) return Result.PermissionMissing(missing)
        if (!isLocationEnabled(ctx)) return Result.LocationDisabled
        return null
    }

    /// §569 — снимок разрешений и геолокации для [WifiStateCache]: при его
    /// смене колбэк с `FLAG_INCLUDE_LOCATION_INFO` перерегистрируется
    /// (редактирование SSID фиксируется на момент регистрации).
    fun permissionSnapshot(ctx: Context): String {
        fun bit(v: Boolean) = if (v) '1' else '0'
        val nearby = Build.VERSION.SDK_INT < 33 || PermissionUtils.has(ctx, PERM_NEARBY)
        val fine = PermissionUtils.has(ctx, PERM_FINE)
        val bg = Build.VERSION.SDK_INT < 29 || PermissionUtils.has(ctx, PERM_BACKGROUND)
        return "nearby=${bit(nearby)} fine=${bit(fine)} bg=${bit(bg)} loc=${bit(isLocationEnabled(ctx))}"
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
