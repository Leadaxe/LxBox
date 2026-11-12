package com.leadaxe.lxbox.appfunctions

import android.content.Context
import android.os.Build
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.appfunctions.AppFunctionManager
import com.leadaxe.lxbox.vpn.BootReceiver
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/// §721 — тумблер «AI assistant control» (Dart `setAppFunctionsEnabled`).
///
/// Две линии:
/// 1. Зеркало `boxvpn_boot.appfunctions_enabled` — его проверяет каждая
///    функция ([LxBoxAppFunctions]); при `false` вызов отказывает
///    `AppFunctionDisabledException`. Это и есть гарантия «тумблер выключен —
///    функция не исполняется».
/// 2. `AppFunctionManager.setAppFunctionEnabled` для каждой функции — чтобы
///    выключенные функции не предлагались агентам (в схеме они
///    `isEnabled = false`). Ошибка здесь не фатальна: линия 1 держит.
object AppFunctionsGate {
    private const val TAG = "AppFunctionsGate"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    fun setEnabled(ctx: Context, enabled: Boolean) {
        val appCtx = ctx.applicationContext
        BootReceiver.setAppFunctionsEnabled(appCtx, enabled)
        if (Build.VERSION.SDK_INT < 36) return
        scope.launch { applySystemState(appCtx, enabled) }
    }

    @RequiresApi(36)
    private suspend fun applySystemState(ctx: Context, enabled: Boolean) {
        val state = if (enabled) AppFunctionManager.APP_FUNCTION_STATE_ENABLED
        else AppFunctionManager.APP_FUNCTION_STATE_DISABLED
        val manager: AppFunctionManager? = try {
            AppFunctionManager.getInstance(ctx)
        } catch (t: Throwable) {
            Log.w(TAG, "AppFunctionManager unavailable: ${t.message}")
            null
        }
        if (manager == null) return
        for (id in AppFunctionsLogic.FUNCTION_IDS) {
            try {
                manager.setAppFunctionEnabled(id, state)
            } catch (t: Throwable) {
                Log.w(TAG, "setAppFunctionEnabled($id, $state) failed: ${t.message}")
            }
        }
        Log.d(TAG, "app functions ${if (enabled) "enabled" else "disabled"}")
    }
}
