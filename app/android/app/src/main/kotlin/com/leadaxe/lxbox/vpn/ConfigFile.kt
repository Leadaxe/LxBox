package com.leadaxe.lxbox.vpn

import android.content.Context
import android.util.Log
import java.io.File

/// §747 — файл конфига ядра `files/singbox_config.json`: чтение и атомарная
/// запись. Общий для обеих сторон: пишет `:ui` (`saveConfig`), читает `:bg`
/// (`ConfigManager` с кэшем) и `:ui` (`getConfig`). Конфиг бывает больше
/// предела Binder, поэтому между процессами идёт файлом, а не вызовом.
///
/// Запись — во временный файл рядом и `rename`: читатель другого процесса
/// видит либо прежний файл, либо новый целиком.
object ConfigFile {
    private const val TAG = "ConfigManager"
    private const val CONFIG_FILE = "singbox_config.json"
    private val writeLock = Any()

    private fun file(ctx: Context) = File(ctx.filesDir, CONFIG_FILE)

    /// Очищенный текст, если запись удалась; иначе null.
    fun write(ctx: Context, json: String): String? {
        return try {
            // §122 — гарантируем что в файл/кэш не попадёт clash_api (rc.2 без него).
            val clean = stripClashApi(json)
            synchronized(writeLock) {
                val target = file(ctx)
                val tmp = File(target.parentFile, "$CONFIG_FILE.tmp")
                tmp.writeText(clean)
                if (!tmp.renameTo(target)) {
                    // rename поверх существующего файла атомарен; отказ — редкость
                    // (нет места, чужой владелец). Запасной путь — прямая запись.
                    target.writeText(clean)
                    tmp.delete()
                }
            }
            Log.d(TAG, "Config saved (${clean.length} bytes)")
            clean
        } catch (e: Exception) {
            Log.e(TAG, "Failed to save config", e)
            null
        }
    }

    /// Текст конфига; файла нет или чтение не удалось (запись в лог) — null.
    fun read(ctx: Context): String? {
        return try {
            val f = file(ctx)
            if (f.exists()) stripClashApi(f.readText()) else null
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load config", e)
            null
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
}
