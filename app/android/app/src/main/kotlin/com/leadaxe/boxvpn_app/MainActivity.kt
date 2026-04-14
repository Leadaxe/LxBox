package com.leadaxe.boxvpn_app

import android.util.Log
import com.leadaxe.boxvpn_app.vpn.VpnPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        Log.d("MainActivity", "configureFlutterEngine — registering VpnPlugin")
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(VpnPlugin())
    }
}
