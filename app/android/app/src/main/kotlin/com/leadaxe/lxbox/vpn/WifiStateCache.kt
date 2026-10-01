package com.leadaxe.lxbox.vpn

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiInfo
import android.os.Build
import android.os.SystemClock
import android.util.Log

/**
 * §569 — кэш текущей Wi-Fi сети для Android 12+ (API 31+).
 *
 * `WifiManager.getConnectionInfo()` deprecated с API 31. Замена —
 * `NetworkCallback(FLAG_INCLUDE_LOCATION_INFO)`: только такому колбэку
 * `NetworkCapabilities.transportInfo` приходит с SSID/BSSID (синхронный
 * `cm.getNetworkCapabilities(net)` отдаёт `WifiInfo` с вырезанным SSID).
 * Поэтому данные читаются из кэша, который наполняет колбэк.
 *
 * - Регистрация ленивая: из [ensureCurrent] при первом успешном preflight
 *   в `WifiInfoReader.read` (пользователь без Wi-Fi-правил и Add current
 *   колбэк с location-флагом не получает).
 * - Редактирование SSID фиксируется на момент регистрации, поэтому при смене
 *   снимка разрешений/геолокации колбэк перерегистрируется; при провале
 *   preflight — снимается ([stop]).
 * - Колбэк живёт весь процесс (как `WifiNetworkObserver`), намеренно.
 * - Отдельный объект от `WifiNetworkObserver`: свой колбэк, свой lifecycle.
 *
 * На API < 31 объект существует, но [start]/[ensureCurrent] — no-op,
 * [latest] всегда null.
 */
class WifiStateCache(private val ctx: Context) {

    data class WifiSnapshot(
        /// Нормализованный SSID (без кавычек); пустой = Android не отдал.
        val ssid: String,
        /// BSSID lower-case; пустой = не отдан или placeholder.
        val bssid: String,
        val network: Network,
        val atMillis: Long,
    )

    @Volatile
    var latest: WifiSnapshot? = null
        private set

    private var callback: ConnectivityManager.NetworkCallback? = null

    /// Снимок разрешений и геолокации, при котором зарегистрирован колбэк.
    private var registeredWith: String? = null

    private val cm: ConnectivityManager
        get() = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    val isRegistered: Boolean
        @Synchronized get() = callback != null

    /// Вызывается из `WifiInfoReader.read` после успешного preflight.
    /// Не зарегистрирован — регистрирует; снимок разрешений сменился —
    /// перерегистрирует. Иначе ничего не делает (лимит 100 колбэков на процесс).
    @Synchronized
    fun ensureCurrent() {
        if (Build.VERSION.SDK_INT < 31) return
        val snap = WifiInfoReader.permissionSnapshot(ctx)
        if (callback != null) {
            if (registeredWith == snap) return
            Log.d(TAG, "permissions changed ($registeredWith -> $snap), re-registering")
            stop()
        }
        start()
    }

    /// Регистрирует колбэк, если preflight 567 проходит. Ошибки регистрации
    /// (SecurityException, TooManyRequestsException — RuntimeException) пишутся
    /// в лог, кэш считается не запущенным: `read` уходит в fallback.
    @Synchronized
    fun start() {
        if (Build.VERSION.SDK_INT < 31) return
        if (callback != null) return
        val reason = WifiInfoReader.preflight(ctx)
        if (reason != null) {
            Log.d(TAG, "not started: preflight failed ($reason)")
            return
        }
        val cb = newCallback()
        try {
            val req = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .build()
            cm.registerNetworkCallback(req, cb)
        } catch (e: SecurityException) {
            Log.w(TAG, "registerNetworkCallback denied: ${e.message}")
            return
        } catch (e: RuntimeException) {
            Log.w(TAG, "registerNetworkCallback failed: ${e.javaClass.simpleName}: ${e.message}")
            return
        }
        callback = cb
        registeredWith = WifiInfoReader.permissionSnapshot(ctx)
        Log.d(TAG, "started (perms=$registeredWith)")
    }

    /// Снимает колбэк и очищает кэш. Вызывается при перерегистрации и при
    /// провале preflight (разрешение отозвано, геолокация выключена).
    @Synchronized
    fun stop() {
        latest = null
        val cb = callback ?: return
        callback = null
        registeredWith = null
        runCatching { cm.unregisterNetworkCallback(cb) }
            .onFailure { Log.w(TAG, "unregister failed: ${it.message}") }
        Log.d(TAG, "stopped")
    }

    private fun newCallback(): ConnectivityManager.NetworkCallback =
        object : ConnectivityManager.NetworkCallback(
            ConnectivityManager.NetworkCallback.FLAG_INCLUDE_LOCATION_INFO,
        ) {
            override fun onCapabilitiesChanged(net: Network, caps: NetworkCapabilities) {
                // На некоторых OEM transportInfo может быть не WifiInfo
                // (или VPN-сеть с underlying Wi-Fi) — не трогаем кэш.
                val info = caps.transportInfo as? WifiInfo ?: return
                val snap = WifiSnapshot(
                    ssid = WifiInfoReader.normalizeSsid(info.ssid),
                    bssid = WifiInfoReader.normalizeBssid(info.bssid),
                    network = net,
                    atMillis = SystemClock.elapsedRealtime(),
                )
                val prev = latest
                latest = snap
                if (prev == null || prev.ssid != snap.ssid || prev.bssid != snap.bssid ||
                    prev.network != snap.network) {
                    Log.d(TAG, "update: ssid='${snap.ssid}' bssid='${snap.bssid}' net=$net")
                }
            }

            override fun onLost(net: Network) {
                if (latest?.network == net) {
                    latest = null
                    Log.d(TAG, "lost: net=$net")
                }
            }
        }

    private companion object {
        const val TAG = "WifiStateCache"
    }
}
