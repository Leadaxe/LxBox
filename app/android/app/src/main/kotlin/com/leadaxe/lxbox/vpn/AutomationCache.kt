package com.leadaxe.lxbox.vpn

import android.content.Context
import android.content.SharedPreferences

/// §740 — единая точка доступа к файлу `lxbox_automation` (§047 Шаг 2):
/// native-кеш активной ноды/группы и списков нод/групп. Пишет Dart через
/// `setAutomationActiveState` (`VpnPlugin`), читают `LocaleConditionReceiver`
/// (синхронный ответ на QUERY_CONDITION) и `LocaleApi` (Spinner'ы
/// edit-Activity). Flutter-engine при чтении может спать, потому prefs.
/// Имя файла и ключи — только здесь.
object AutomationCache {
    const val PREF_NAME = "lxbox_automation"

    const val KEY_ACTIVE_NODE = "active_node"
    const val KEY_ACTIVE_GROUP = "active_group"
    /// JSON-массив строк.
    const val KEY_ALL_NODES = "all_nodes"
    /// JSON-массив строк.
    const val KEY_ALL_GROUPS = "all_groups"

    /// Файл открывается на переданном контексте, как раньше в каждом месте.
    fun prefs(ctx: Context): SharedPreferences =
        ctx.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)

    /// §750 — файл `lxbox_assistant`: индекс ассистента (производное зеркало
    /// от Dart, `setAssistantIndex`). Здесь только открытие файла — правило
    /// boundary_check `kt-sharedprefs` держит `getSharedPreferences` в трёх
    /// файлах; ключи и разбор — в `appfunctions/AssistantIndex.kt`.
    const val ASSISTANT_PREF_NAME = "lxbox_assistant"

    fun assistantPrefs(ctx: Context): SharedPreferences =
        ctx.applicationContext.getSharedPreferences(ASSISTANT_PREF_NAME, Context.MODE_PRIVATE)
}
