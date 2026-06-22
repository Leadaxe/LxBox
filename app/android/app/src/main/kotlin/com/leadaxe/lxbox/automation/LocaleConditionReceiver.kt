package com.leadaxe.lxbox.automation

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.leadaxe.lxbox.vpn.BoxVpnService
import com.leadaxe.lxbox.vpn.VpnStatus

/// §047 Шаг 2 — condition-плагин (Locale/Tasker «State → Plugin → L×Box»).
///
/// Host (Tasker) шлёт `QUERY_CONDITION` + `EXTRA_BUNDLE` периодически и читает
/// **ordered-broadcast result code**: SATISFIED / UNSATISFIED / UNKNOWN.
///
/// Отвечать обязаны **синхронно** — Flutter-engine может спать. VPN up/down
/// читаем из [BoxVpnService.currentStatus] (companion @Volatile, всегда жив).
/// Активную ноду/группу — из native-кеша `lxbox_automation` prefs (Dart
/// зеркалит туда при смене через `setAutomationActiveState`).
class LocaleConditionReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "LocaleCondition"
        private const val PREFS = "lxbox_automation"
        private const val KEY_ACTIVE_NODE = "active_node"
        private const val KEY_ACTIVE_GROUP = "active_group"
    }

    override fun onReceive(context: Context, intent: Intent) {
        try {
            if (intent.action != LocaleApi.ACTION_QUERY_CONDITION) {
                setResultCode(LocaleApi.RESULT_CONDITION_UNKNOWN)
                return
            }
            val parsed = LocaleApi.parseCondition(
                intent.getBundleExtra(LocaleApi.EXTRA_BUNDLE),
            )
            if (parsed == null) {
                Log.w(TAG, "QUERY — invalid/missing bundle → UNKNOWN")
                setResultCode(LocaleApi.RESULT_CONDITION_UNKNOWN)
                return
            }
            val (check, equals) = parsed
            val result = evaluate(context, check, equals)
            Log.d(TAG, "query check=$check equals=$equals → $result")
            setResultCode(result)
        } catch (t: Throwable) {
            Log.e(TAG, "onReceive failed → UNKNOWN", t)
            // setResultCode мог не успеть — выставляем UNKNOWN best-effort.
            runCatching { setResultCode(LocaleApi.RESULT_CONDITION_UNKNOWN) }
        }
    }

    private fun evaluate(context: Context, check: String, equals: String?): Int {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return when (check) {
            "vpn-up" -> satisfied(BoxVpnService.currentStatus == VpnStatus.Started)
            "active-node" -> matchCached(prefs.getString(KEY_ACTIVE_NODE, null), equals)
            "active-group" -> matchCached(prefs.getString(KEY_ACTIVE_GROUP, null), equals)
            else -> LocaleApi.RESULT_CONDITION_UNKNOWN
        }
    }

    /// Сравнение кешированного значения с ожидаемым. Нет кеша / нет ожидаемого
    /// значения → UNKNOWN (Tasker не активирует profile на неизвестном).
    private fun matchCached(cached: String?, equals: String?): Int {
        if (equals.isNullOrEmpty() || cached == null) {
            return LocaleApi.RESULT_CONDITION_UNKNOWN
        }
        return satisfied(cached == equals)
    }

    private fun satisfied(value: Boolean): Int =
        if (value) LocaleApi.RESULT_CONDITION_SATISFIED
        else LocaleApi.RESULT_CONDITION_UNSATISFIED
}
