package com.leadaxe.lxbox.automation

import android.os.Bundle
import org.json.JSONObject

/// §047 Шаг 2 — Locale / Tasker plugin-стандарт (twofortyfouram).
///
/// Константы протокола + (de)serialize нашего bundle. L×Box выступает и как
/// **setting**-плагин (FIRE_SETTING исполняет команду), и как **condition**-
/// плагин (QUERY_CONDITION отвечает result code'ом).
///
/// Bundle-конвенция стандарта: host хранит `EXTRA_BUNDLE` (<25 KB) и шлёт его
/// обратно при fire/query. Внутри кладём один String-ключ [KEY_CONFIG] с JSON
/// нашего формата (версионируемый через `v`).
object LocaleApi {
    // ─── Standard action constants ──────────────────────────────────────────────
    const val ACTION_EDIT_SETTING = "com.twofortyfouram.locale.intent.action.EDIT_SETTING"
    const val ACTION_FIRE_SETTING = "com.twofortyfouram.locale.intent.action.FIRE_SETTING"
    const val ACTION_EDIT_CONDITION = "com.twofortyfouram.locale.intent.action.EDIT_CONDITION"
    const val ACTION_QUERY_CONDITION = "com.twofortyfouram.locale.intent.action.QUERY_CONDITION"

    const val EXTRA_BUNDLE = "com.twofortyfouram.locale.intent.extra.BUNDLE"
    const val EXTRA_STRING_BLURB = "com.twofortyfouram.locale.intent.extra.BLURB"

    // Ordered-broadcast result codes для condition-плагина.
    const val RESULT_CONDITION_SATISFIED = 16
    const val RESULT_CONDITION_UNSATISFIED = 17
    const val RESULT_CONDITION_UNKNOWN = 18

    /// Лимит сериализованного bundle (base-10) по стандарту.
    const val BUNDLE_MAX_BYTES = 25_000

    /// Наш единственный ключ внутри EXTRA_BUNDLE — String с JSON.
    const val KEY_CONFIG = "com.leadaxe.lxbox.plugin.CONFIG"

    /// Текущая версия формата bundle (миграции при будущих изменениях).
    const val BUNDLE_VERSION = 1

    // ─── Setting bundle ───────────────────────────────────────────────────────────

    /// Сериализует setting-конфиг (команда + args) в bundle.
    /// `{ "v":1, "cmd":"switch-node", "args":{ "tag":"…" } }`
    fun buildSettingBundle(cmd: String, args: Map<String, Any?>): Bundle {
        val json = JSONObject()
            .put("v", BUNDLE_VERSION)
            .put("cmd", cmd)
            .put("args", JSONObject(args.filterValues { it != null }))
        return Bundle().apply { putString(KEY_CONFIG, json.toString()) }
    }

    /// Парсит setting-bundle. Возвращает (cmd, args) или null если невалиден.
    fun parseSetting(bundle: Bundle?): Pair<String, Map<String, Any?>>? {
        val raw = bundle?.getString(KEY_CONFIG) ?: return null
        return runCatching {
            val obj = JSONObject(raw)
            val cmd = obj.optString("cmd").ifEmpty { return@runCatching null }
            val argsObj = obj.optJSONObject("args") ?: JSONObject()
            val args = mutableMapOf<String, Any?>()
            for (key in argsObj.keys()) args[key] = argsObj.get(key)
            cmd to args
        }.getOrNull()
    }

    // ─── Condition bundle ─────────────────────────────────────────────────────────

    /// Сериализует condition-конфиг. `check` ∈ {vpn-up, active-node, active-group};
    /// для node/group — `equals` со значением.
    fun buildConditionBundle(check: String, equals: String?): Bundle {
        val json = JSONObject()
            .put("v", BUNDLE_VERSION)
            .put("check", check)
        if (equals != null) json.put("equals", equals)
        return Bundle().apply { putString(KEY_CONFIG, json.toString()) }
    }

    /// Парсит condition-bundle. Возвращает (check, equals?) или null.
    fun parseCondition(bundle: Bundle?): Pair<String, String?>? {
        val raw = bundle?.getString(KEY_CONFIG) ?: return null
        return runCatching {
            val obj = JSONObject(raw)
            val check = obj.optString("check").ifEmpty { return@runCatching null }
            val equals = if (obj.has("equals")) obj.optString("equals") else null
            check to equals
        }.getOrNull()
    }
}
