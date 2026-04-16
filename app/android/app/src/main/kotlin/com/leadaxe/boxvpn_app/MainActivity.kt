package com.leadaxe.boxvpn_app

import android.content.Intent
import android.net.Uri
import android.util.Log
import com.leadaxe.boxvpn_app.vpn.VpnPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        Log.d("MainActivity", "configureFlutterEngine — registering VpnPlugin")
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(VpnPlugin())

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.leadaxe.boxvpn/utils")
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
}
