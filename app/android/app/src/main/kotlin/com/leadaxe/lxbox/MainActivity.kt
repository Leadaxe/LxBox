package com.leadaxe.lxbox

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.net.VpnService
import android.os.Bundle
import android.util.Log
import android.widget.Toast
import com.leadaxe.lxbox.vpn.BoxVpnService
import com.leadaxe.lxbox.vpn.VpnPlugin
import com.leadaxe.lxbox.vpn.VpnStatus
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
                        // Returns true if POST_NOTIFICATIONS granted (or API < 33 — implicit grant).
                        val granted = if (android.os.Build.VERSION.SDK_INT >= 33) {
                            checkSelfPermission("android.permission.POST_NOTIFICATIONS") ==
                                android.content.pm.PackageManager.PERMISSION_GRANTED
                        } else true
                        result.success(granted)
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
                        // API 33+: NEARBY_WIFI_DEVICES is the canonical permission
                        // for `WifiInfo.ssid`. Pre-33 → implicit grant (covered by
                        // ACCESS_FINE_LOCATION / ACCESS_BACKGROUND_LOCATION).
                        val granted = if (android.os.Build.VERSION.SDK_INT >= 33) {
                            checkSelfPermission("android.permission.NEARBY_WIFI_DEVICES") ==
                                android.content.pm.PackageManager.PERMISSION_GRANTED
                        } else true
                        result.success(granted)
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
