package com.leadaxe.lxbox

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.net.VpnService
import android.os.Bundle
import android.util.Log
import android.widget.Toast
import com.leadaxe.lxbox.vpn.BoxApplication
import com.leadaxe.lxbox.vpn.BoxVpnService
import com.leadaxe.lxbox.vpn.PermissionUtils
import com.leadaxe.lxbox.vpn.VpnPlugin
import com.leadaxe.lxbox.vpn.VpnStatus
import com.leadaxe.lxbox.vpn.WifiHistoryBridge
import com.leadaxe.lxbox.vpn.WifiInfoReader
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "MainActivity"
        private const val VPN_REQUEST_CODE_QUICK = 7032
        private const val NOTIFICATION_PERMISSION_REQUEST = 7033
        private const val NEARBY_WIFI_PERMISSION_REQUEST = 7034

        const val EXTRA_ACTION = "action"

        const val ACTION_CONNECT = "connect"
        const val ACTION_DISCONNECT = "disconnect"
        const val ACTION_TOGGLE = "toggle"
    }

    /// Если activity была открыта именно из tile/shortcut (через extras),
    /// после успешного consent'а закрываемся, чтобы юзер вернулся на хоум —
    /// он не просил открывать app, он просил подключить VPN.
    private var finishAfterConsent = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        Log.d(TAG, "configureFlutterEngine — registering VpnPlugin")
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(VpnPlugin())

        // §051 Phase 3 — channel для auto-record wifi history. Native side
        // вызывает invokeMethod("onWifiSeen", ...) когда юзер пробыл на
        // сети ≥ 60 сек. Dart-side handler пишет в SettingsStorage.
        // Attach сразу в configureFlutterEngine — поскольку Dart будет
        // регистрировать handler через тот же channel name.
        val wifiHistoryChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.leadaxe.lxbox/wifi_history",
        )
        WifiHistoryBridge.attach(wifiHistoryChannel)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.leadaxe.lxbox/utils")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openUrl" -> {
                        val url = call.argument<String>("url")
                        if (url != null) {
                            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                            result.success(null)
                        } else {
                            result.error("INVALID_URL", "URL is null", null)
                        }
                    }
                    "openAppSettings" -> {
                        // §050 — open Android Settings directly to App permissions.
                        val opened = openAppPermissions()
                        result.success(opened)
                    }
                    "checkNotificationPermission" -> {
                        // POST_NOTIFICATIONS — runtime permission на API 33+.
                        // На pre-33 концепта не было → implicit grant.
                        result.success(PermissionUtils.has(
                            this, "android.permission.POST_NOTIFICATIONS",
                            minSdk = 33,
                        ))
                    }
                    "requestNotificationPermission" -> {
                        // Trigger system permission dialog for POST_NOTIFICATIONS on API 33+.
                        // result.success(null) immediately — the user will see the dialog
                        // asynchronously. Re-check permission status afterward.
                        if (android.os.Build.VERSION.SDK_INT >= 33) {
                            requestPermissions(
                                arrayOf("android.permission.POST_NOTIFICATIONS"),
                                NOTIFICATION_PERMISSION_REQUEST,
                            )
                        }
                        result.success(null)
                    }
                    "checkNearbyWifiPermission" -> {
                        // API 33+ canonical permission для `WifiInfo.ssid`.
                        // Pre-33 → implicit grant (covered by location-perms).
                        result.success(PermissionUtils.has(
                            this, "android.permission.NEARBY_WIFI_DEVICES",
                            minSdk = 33,
                        ))
                    }
                    "checkBackgroundLocationPermission" -> {
                        // API 29+ требуется BACKGROUND_LOCATION для wifi info
                        // из background. Pre-Q → fallback на FINE_LOCATION
                        // (implicit чтение из foreground).
                        val name = if (android.os.Build.VERSION.SDK_INT >= 29) {
                            "android.permission.ACCESS_BACKGROUND_LOCATION"
                        } else {
                            "android.permission.ACCESS_FINE_LOCATION"
                        }
                        result.success(PermissionUtils.has(this, name))
                    }
                    "requestNearbyWifiPermission" -> {
                        // Trigger system runtime prompt for NEARBY_WIFI_DEVICES.
                        // Async — Flutter must re-check via `checkNearbyWifiPermission`.
                        if (android.os.Build.VERSION.SDK_INT >= 33) {
                            requestPermissions(
                                arrayOf("android.permission.NEARBY_WIFI_DEVICES"),
                                NEARBY_WIFI_PERMISSION_REQUEST,
                            )
                        }
                        result.success(null)
                    }
                    "getCurrentWifiInfo" -> {
                        // §051 Phase 2 — return current Wi-Fi SSID/BSSID для UI
                        // editor'а. Reuses `WifiManager.connectionInfo` (та же
                        // path что sing-box использует для match'а).
                        // Returns Map: {ssid?, bssid?, error?}.
                        // Errors: "permission_missing", "no_wifi", "unknown_ssid".
                        result.success(getCurrentWifiInfoMap())
                    }
                    "setAutoRecordWifi" -> {
                        // §051 Phase 3 — start/stop WifiNetworkObserver
                        // (auto-record history). Toggle гейтится storage
                        // var `auto_record_wifi_history`; Dart-side читает
                        // его на init и при tap toggle, синкает сюда.
                        val enable = call.argument<Boolean>("enable") ?: false
                        if (enable) {
                            BoxApplication.wifiObserver.start()
                        } else {
                            BoxApplication.wifiObserver.stop()
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleQuickAction(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleQuickAction(intent)
    }

    private fun handleQuickAction(intent: Intent?) {
        val action = intent?.getStringExtra(EXTRA_ACTION) ?: return
        Log.d(TAG, "handleQuickAction action=$action currentStatus=${BoxVpnService.currentStatus.name}")
        // `extras.action` ставится только из tile или shortcut'а — поэтому
        // если мы здесь, мы пришли не через обычный launcher-tap. Закрываемся
        // после обработки, чтобы юзер вернулся на хоум.
        finishAfterConsent = true
        // Один раз обработали — счищаем extras, иначе любая ротация / возврат
        // на activity дёргает снова.
        intent.removeExtra(EXTRA_ACTION)

        when (action) {
            ACTION_CONNECT -> startVpnWithConsent()
            ACTION_DISCONNECT -> {
                BoxVpnService.stop(applicationContext)
                if (finishAfterConsent) finish()
            }
            ACTION_TOGGLE -> {
                val s = BoxVpnService.currentStatus
                if (s == VpnStatus.Started) {
                    BoxVpnService.stop(applicationContext)
                    if (finishAfterConsent) finish()
                } else if (s == VpnStatus.Stopped) {
                    startVpnWithConsent()
                } else {
                    Log.d(TAG, "toggle ignored in transient state ${s.name}")
                    if (finishAfterConsent) finish()
                }
            }
            else -> Log.w(TAG, "Unknown quick action: $action")
        }
    }

    private fun startVpnWithConsent() {
        val prep = VpnService.prepare(applicationContext)
        if (prep == null) {
            BoxVpnService.start(applicationContext)
            if (finishAfterConsent) finish()
            return
        }
        // Покажем тост ровно если activity «просто открылась» под consent —
        // обычный запуск через UI и так показывает диалог как часть flow.
        if (finishAfterConsent) {
            Toast.makeText(applicationContext, R.string.qc_first_open, Toast.LENGTH_SHORT).show()
        }
        try {
            startActivityForResult(prep, VPN_REQUEST_CODE_QUICK)
        } catch (e: Exception) {
            Log.e(TAG, "VPN consent prepare failed: ${e.message}", e)
            if (finishAfterConsent) finish()
        }
    }

    /// §050 — open Settings directly на App permissions screen.
    /// Try `MANAGE_APP_PERMISSIONS` first — this is the action used by
    /// PermissionController to show the permissions UI for a specific app.
    /// If that fails (very old OEMs without PermissionController), fall back
    /// to the generic App info page.
    private fun openAppPermissions(): Boolean {
        // Strategy 1: direct permissions UI
        val direct = Intent("android.intent.action.MANAGE_APP_PERMISSIONS")
            .putExtra("android.intent.extra.PACKAGE_NAME", packageName)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (direct.resolveActivity(packageManager) != null) {
            runCatching { startActivity(direct); return true }
                .onFailure { Log.w(TAG, "MANAGE_APP_PERMISSIONS failed: ${it.message}") }
        }
        // Strategy 2: APP_PERMISSION (singular) — alternate action на некоторых OEM
        val singular = Intent("android.intent.action.MANAGE_PERMISSION_APPS")
            .putExtra("android.intent.extra.PACKAGE_NAME", packageName)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (singular.resolveActivity(packageManager) != null) {
            runCatching { startActivity(singular); return true }
                .onFailure { Log.w(TAG, "MANAGE_PERMISSION_APPS failed: ${it.message}") }
        }
        // Strategy 3: generic App info (юзеру нужно tap на Permissions)
        val fallback = Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
            .setData(Uri.fromParts("package", packageName, null))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { startActivity(fallback); return true }
            .onFailure { Log.e(TAG, "openAppSettings (all strategies) failed: ${it.message}") }
        return false
    }

    /// §051 Phase 2 — return current Wi-Fi info как Map для Flutter
    /// MethodChannel. Тонкая обёртка над `WifiInfoReader.read()` — same
    /// defensive логика что у sing-box callback и auto-record observer.
    private fun getCurrentWifiInfoMap(): Map<String, String> {
        return when (val r = WifiInfoReader.read(this)) {
            is WifiInfoReader.Result.Success ->
                mapOf("ssid" to r.ssid, "bssid" to r.bssid)
            is WifiInfoReader.Result.PermissionMissing ->
                mapOf("error" to "permission_missing")
            is WifiInfoReader.Result.NoWifi ->
                mapOf("error" to "no_wifi")
            is WifiInfoReader.Result.UnknownSsid ->
                mapOf("error" to "unknown_ssid")
            is WifiInfoReader.Result.RuntimeError ->
                mapOf("error" to "runtime_error")
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != VPN_REQUEST_CODE_QUICK) return
        if (resultCode == Activity.RESULT_OK) {
            BoxVpnService.start(applicationContext)
            if (finishAfterConsent) finish()
        } else {
            Toast.makeText(applicationContext, R.string.qc_consent_denied, Toast.LENGTH_SHORT).show()
            if (finishAfterConsent) finish()
        }
    }
}
