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
                if (call.method == "openUrl") {
                    val url = call.argument<String>("url")
                    if (url != null) {
                        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                        result.success(null)
                    } else {
                        result.error("INVALID_URL", "URL is null", null)
                    }
                } else {
                    result.notImplemented()
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
