package com.leadaxe.lxbox.vpn

import android.util.Log
import java.io.File

/**
 * File-based config storage (replaces SharedPreferences approach from the plugin).
 * Config is stored at: /data/data/<pkg>/files/singbox_config.json
 */
object ConfigManager {
    private const val TAG = "ConfigManager"
    private const val CONFIG_FILE = "singbox_config.json"

    var notificationTitle: String = "L×Box"
        private set

    // §123 — подтекст уведомления (тег активной ноды / route.final). Пустая
    // строка = native сам подставит статусный fallback ("Connected").
    var notificationText: String = ""
        private set

    private var cachedConfig: String? = null

    fun save(json: String): Boolean {
        return try {
            // §122 — гарантируем что в файл/кэш не попадёт clash_api (rc.2 без него).
            val clean = stripClashApi(json)
            val file = File(BoxApplication.application.filesDir, CONFIG_FILE)
            file.writeText(clean)
            cachedConfig = clean
            Log.d(TAG, "Config saved (${clean.length} bytes)")
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
                val content = stripClashApi(file.readText())
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

    /// §122 Фаза 1b / §6.2 — defensive: вырезать блок `experimental.clash_api`
    /// из ЛЮБОГО конфига перед стартом ядра. rc.2 собран без with_clash_api →
    /// наличие блока даёт фатальный отказ старта ("clash api is not included").
    /// Покрывает старые сохранённые конфиги и импорт (builder его уже не пишет).
    /// JSON-парсинг через org.json — надёжнее regex по вложенному объекту.
    private fun stripClashApi(json: String): String {
        return try {
            val root = org.json.JSONObject(json)
            val exp = root.optJSONObject("experimental") ?: return json
            if (!exp.has("clash_api")) return json
            exp.remove("clash_api")
            Log.d(TAG, "stripClashApi: removed experimental.clash_api (rc.2 has no with_clash_api)")
            root.toString()
        } catch (e: Exception) {
            // Не валидный JSON / что-то пошло не так — отдаём как есть, не ломаем старт.
            Log.w(TAG, "stripClashApi failed, passing through: ${e.message}")
            json
        }
    }

    fun setNotificationTitle(title: String) {
        notificationTitle = title
    }

    fun setNotificationText(text: String) {
        notificationText = text
    }
}

