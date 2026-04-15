package com.leadaxe.boxvpn_app.vpn

import android.util.Log
import java.io.File

/**
 * File-based config storage (replaces SharedPreferences approach from the plugin).
 * Config is stored at: /data/data/<pkg>/files/singbox_config.json
 */
object ConfigManager {
    private const val TAG = "ConfigManager"
    private const val CONFIG_FILE = "singbox_config.json"

    var notificationTitle: String = "BoxVPN"
        private set

    private var cachedConfig: String? = null

    fun save(json: String): Boolean {
        return try {
            val file = File(BoxApplication.application.filesDir, CONFIG_FILE)
            file.writeText(json)
            cachedConfig = json
            Log.d(TAG, "Config saved (${json.length} bytes)")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to save config", e)
            false
        }
    }

    fun load(): String {
        cachedConfig?.let { return it }
        return try {
            val file = File(BoxApplication.application.filesDir, CONFIG_FILE)
            if (file.exists()) {
                val content = file.readText()
                cachedConfig = content
                content
            } else {
                "{}"
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load config", e)
            "{}"
        }
    }

    fun setNotificationTitle(title: String) {
        notificationTitle = title
    }

    // --- Per-app proxy ---

    var perAppMode: String = "off"
        private set
    var perAppList: List<String> = emptyList()
        private set

    fun setPerApp(mode: String, list: List<String>) {
        perAppMode = mode
        perAppList = list
    }
}

