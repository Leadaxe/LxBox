package com.leadaxe.lxbox.vpn

import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodChannel

/**
 * §051 Phase 3 — наблюдает за актуально подключённой Wi-Fi сетью и
 * пишет в `wifi_history` (Dart side через `MethodChannel`) ровно те
 * сети **на которых юзер пробыл ≥ [STICKINESS_THRESHOLD_MS] миллисекунд**.
 *
 * Зачем debounce: без него история засоряется случайными drive-by
 * сетями (магазин на 30 сек, кафе на 5 минут с забытым выходом).
 * 60 сек — отсекает мимохожих, не теряет рабочие/домашние.
 *
 * Фича **opt-in** — гейтится `auto_record_wifi_history` в storage. Без
 * флага observer не регистрируется → нулевая стоимость когда выключено.
 *
 * Lifecycle = process-scope (BoxApplication). При toggle ON/OFF из UI
 * вызываются [start]/[stop] через `WifiHistoryBridge`.
 */
class WifiNetworkObserver(private val ctx: Context) {

    private val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE)
            as ConnectivityManager
    private val handler = Handler(Looper.getMainLooper())

    /// `(ssid, bssid)` сеть на которой юзер сейчас «висит». null когда
    /// нет активной wifi-сети или мы только что переключились (старый
    /// pending был cancelled, новый ещё не дождался threshold).
    private var pendingSsid: String? = null
    private var pendingBssid: String = ""
    private var pendingTimer: Runnable? = null
    private var registered = false

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onCapabilitiesChanged(
            net: Network,
            caps: NetworkCapabilities,
        ) {
            if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) return
            // Capabilities update fires при first connect, roaming, SSID
            // change и т.д. — каждый раз дёргаем readWifi и evaluate'им
            // pending timer.
            val state = readWifi() ?: return
            if (state.first.isEmpty()) return
            handlePending(state.first, state.second)
        }

        override fun onLost(net: Network) {
            // Wi-Fi пропал (off, отвалилась сеть). Pending timer
            // отменяем — текущая сеть «не достояла».
            cancelPending()
        }
    }

    @Synchronized
    fun start() {
        if (registered) return
        // На API 33+ проверяем NEARBY_WIFI_DEVICES, на 29-32 BACKGROUND_LOCATION.
        // Без них readWifi всё равно вернёт null, observer бесполезен — но
        // регистрируем callback чтобы как только permission'ы появятся,
        // дальше работало без re-toggle.
        try {
            val req = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .build()
            cm.registerNetworkCallback(req, callback)
            registered = true
            Log.d(TAG, "started")
        } catch (e: SecurityException) {
            Log.w(TAG, "registerNetworkCallback denied: ${e.message}")
        } catch (e: RuntimeException) {
            Log.w(TAG, "registerNetworkCallback failed: ${e.message}")
        }
    }

    @Synchronized
    fun stop() {
        cancelPending()
        if (!registered) return
        runCatching { cm.unregisterNetworkCallback(callback) }
            .onFailure { Log.w(TAG, "unregister failed: ${it.message}") }
        registered = false
        Log.d(TAG, "stopped")
    }

    /// Mirror `PlatformInterfaceWrapper.readWIFIState` (defensive try/catch).
    /// Возвращает `(ssid, bssid)` где bssid — lower-case или empty.
    /// Empty ssid → unknown / no permission / no wifi.
    @Suppress("DEPRECATION")
    private fun readWifi(): Pair<String, String>? {
        // Permission preflight — на API 33+ NEARBY_WIFI_DEVICES обязателен,
        // на 29+ BACKGROUND_LOCATION для connection_info из background.
        if (Build.VERSION.SDK_INT >= 33 &&
            ctx.checkSelfPermission(
                "android.permission.NEARBY_WIFI_DEVICES",
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            return null
        }
        if (Build.VERSION.SDK_INT >= 29 &&
            ctx.checkSelfPermission(
                "android.permission.ACCESS_BACKGROUND_LOCATION",
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            return null
        }
        val info = try {
            BoxApplication.wifiManager.connectionInfo
        } catch (_: SecurityException) {
            return null
        } catch (_: RuntimeException) {
            return null
        } ?: return null

        var ssid = info.ssid
        if (ssid == null || ssid == "<unknown ssid>") return "" to ""
        if (ssid.startsWith("\"") && ssid.endsWith("\"")) {
            ssid = ssid.substring(1, ssid.length - 1)
        }
        val bssid = info.bssid?.lowercase() ?: ""
        // Android placeholder для no-real-access — не пара которую стоит
        // записывать в history.
        if (bssid == "02:00:00:00:00:00") return "" to ""
        return ssid to bssid
    }

    /// Если та же сеть что pending — оставляем таймер. Иначе cancel + new.
    private fun handlePending(ssid: String, bssid: String) {
        if (pendingSsid == ssid && pendingBssid == bssid) return
        cancelPending()
        pendingSsid = ssid
        pendingBssid = bssid
        val task = Runnable {
            // Threshold met. Promote через MethodChannel в Dart →
            // SettingsStorage.addToWifiHistory.
            val s = pendingSsid
            val b = pendingBssid
            pendingSsid = null
            pendingTimer = null
            if (s != null && s.isNotEmpty()) {
                WifiHistoryBridge.notifySeen(s, b)
            }
        }
        pendingTimer = task
        handler.postDelayed(task, STICKINESS_THRESHOLD_MS)
    }

    private fun cancelPending() {
        pendingTimer?.let(handler::removeCallbacks)
        pendingTimer = null
        pendingSsid = null
        pendingBssid = ""
    }

    companion object {
        private const val TAG = "WifiNetObserver"

        /// 60 сек — middle ground. Дом / офис / постоянное кафе легко
        /// больше минуты. Drive-by сети — меньше. Не вытаскиваем константу
        /// в settings — overengineering, default work for everyone.
        const val STICKINESS_THRESHOLD_MS = 60_000L
    }
}

/**
 * Native ↔ Flutter bridge для §051 Phase 3 auto-history. Singleton
 * channel attached в `MainActivity.configureFlutterEngine`. Native
 * side вызывает `notifySeen(ssid, bssid)` → `MethodChannel.invokeMethod`
 * в main looper → Dart handler → `SettingsStorage.addToWifiHistory`.
 */
object WifiHistoryBridge {
    private const val TAG = "WifiHistoryBridge"
    private const val METHOD_ON_WIFI_SEEN = "onWifiSeen"

    @Volatile
    private var channel: MethodChannel? = null
    private val handler = Handler(Looper.getMainLooper())

    fun attach(ch: MethodChannel) {
        channel = ch
    }

    fun detach() {
        channel = null
    }

    fun notifySeen(ssid: String, bssid: String) {
        val ch = channel ?: run {
            Log.w(TAG, "notifySeen but channel not attached, dropped")
            return
        }
        handler.post {
            ch.invokeMethod(
                METHOD_ON_WIFI_SEEN,
                mapOf("ssid" to ssid, "bssid" to bssid),
            )
        }
    }
}
