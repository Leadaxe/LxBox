package com.leadaxe.lxbox.appfunctions

import android.content.Context
import com.leadaxe.lxbox.vpn.AutomationCache

/// §750 — индекс ассистента: сводка подписей Направлений, подключений и
/// правил по приложениям, которую Dart присылает методом канала
/// `setAssistantIndex` после каждой записи конфига и на старте. Производное
/// зеркало, не настройка: Kotlin `lxbox_settings.json` не открывает
/// (ARCHITECTURE § 5). Файл `lxbox_assistant` (открывает `AutomationCache`),
/// ключ `index` — строка JSON. Читается обоими процессами после §747.
object AssistantIndex {
    const val KEY_INDEX = "index"

    fun save(ctx: Context, json: String) {
        AutomationCache.assistantPrefs(ctx).edit().putString(KEY_INDEX, json).apply()
    }

    /// null — индекса нет или он не разбирается.
    fun load(ctx: Context): ParsedIndex? =
        AssistantLogic.parseIndex(AutomationCache.assistantPrefs(ctx).getString(KEY_INDEX, null))
}
