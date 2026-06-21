package com.leadaxe.lxbox.vpn

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.util.Log
import com.leadaxe.lxbox.MainActivity

/// §047 Public Intent API — приём automation-команд через broadcast intents
/// (Tasker / Macrodroid / `am broadcast`). Объявлен в манифесте
/// `enabled="false"`; включается рантаймом ([setEnabled]) когда юзер поднимает
/// мастер-toggle «Принимать команды автоматизации».
///
/// **Опциональный пропуск.** Галка «Требовать пропуск» (default OFF) зеркалится
/// из Flutter в native-кеш (`lxbox_automation` SharedPreferences). Если ON —
/// [onReceive] проверяет, что отправитель держит [PERMISSION_AUTOMATION], иначе
/// тихо игнорит. Если OFF — принимаем от любого caller'а (gate здесь — сам
/// мастер-toggle: без него receiver disabled).
///
/// **Маршрутизация.** Прямые lifecycle-команды (START/STOP/TOGGLE) идут на
/// [BoxVpnService] напрямую (быстро, без Flutter-engine). Остальные
/// (switch-node / set-group / rebuild / refresh / reset / urltest) форвардятся
/// в Dart через [VpnPlugin.handleAutomationAction] → MethodChannel → shared
/// action-handlers (та же бизнес-логика, что у Debug API).
class LxBoxIntentReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "LxBoxIntent"

        const val ACTION_START_VPN = "com.leadaxe.lxbox.START_VPN"
        const val ACTION_STOP_VPN = "com.leadaxe.lxbox.STOP_VPN"
        const val ACTION_TOGGLE_VPN = "com.leadaxe.lxbox.TOGGLE_VPN"
        const val ACTION_SWITCH_NODE = "com.leadaxe.lxbox.SWITCH_NODE"
        const val ACTION_SET_GROUP = "com.leadaxe.lxbox.SET_GROUP"
        const val ACTION_REBUILD_CONFIG = "com.leadaxe.lxbox.REBUILD_CONFIG"
        const val ACTION_REFRESH_SUBS = "com.leadaxe.lxbox.REFRESH_SUBS"
        const val ACTION_RESET_NETWORK = "com.leadaxe.lxbox.RESET_NETWORK"
        const val ACTION_URLTEST_GROUP = "com.leadaxe.lxbox.URLTEST_GROUP"

        const val EXTRA_TAG = "tag"
        const val EXTRA_GROUP = "group"
        const val EXTRA_FORCE = "force"

        const val PERMISSION_AUTOMATION = "com.leadaxe.lxbox.permission.AUTOMATION"

        /// Native-кеш галки «Требовать пропуск». Зеркало storage-key
        /// `automation_require_permission`, синкается из Flutter
        /// ([setRequirePermission]). Читаем из prefs, а не через MethodChannel:
        /// onReceive обязан решить про permission синхронно, Flutter-engine
        /// может быть не запущен.
        private const val PREFS = "lxbox_automation"
        private const val KEY_REQUIRE_PERMISSION = "require_permission"

        fun requirePermission(ctx: Context): Boolean =
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getBoolean(KEY_REQUIRE_PERMISSION, false)

        /// Вызывается из Flutter (`setAutomationRequirePermission`) при смене
        /// галки — пишет в native-кеш, который синхронно читают receiver и
        /// emitter (`VpnPlugin.sendAutomationBroadcast`).
        fun setRequirePermission(ctx: Context, value: Boolean) {
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putBoolean(KEY_REQUIRE_PERMISSION, value).apply()
            Log.d(TAG, "require-permission set to $value")
        }

        /// Включает/выключает все automation-receiver'ы (raw Шаг 1 +
        /// Locale-плагины Шаг 2) одной транзакцией. Мастер-toggle «Принимать
        /// команды автоматизации» (Flutter `setAutomationEnabled`).
        ///
        /// Edit-Activity Locale-плагинов НЕ гейтятся (всегда exported) — без
        /// receiver'а они безвредны (юзер настроит плагин, но fire/query не
        /// дойдёт пока компонент disabled).
        fun setEnabled(ctx: Context, enabled: Boolean) {
            val pm = ctx.packageManager
            val state = if (enabled) PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            else PackageManager.COMPONENT_ENABLED_STATE_DISABLED
            // §047 Шаг 2 — Locale-receiver'ы по FQN (другой пакет `automation`).
            val components = listOf(
                ComponentName(ctx, LxBoxIntentReceiver::class.java),
                ComponentName(ctx, "com.leadaxe.lxbox.automation.LocaleSettingReceiver"),
                ComponentName(ctx, "com.leadaxe.lxbox.automation.LocaleConditionReceiver"),
            )
            for (c in components) {
                pm.setComponentEnabledSetting(c, state, PackageManager.DONT_KILL_APP)
            }
            Log.d(TAG, "automation receivers ${if (enabled) "enabled" else "disabled"} (raw + Locale)")
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        // Defensive: receiver exported=true — любой intent может прилететь.
        // Никогда не даём упасть (краш FGS-процесса при работающем VPN — хуже
        // любого пропущенного intent'а).
        try {
            dispatch(context, intent)
        } catch (t: Throwable) {
            Log.e(TAG, "onReceive failed for ${intent.action}", t)
        }
    }

    private fun dispatch(context: Context, intent: Intent) {
        val action = intent.action ?: return
        val callerPkg = intent.`package` ?: "<unknown>"
        Log.d(TAG, "received $action from $callerPkg")

        // Опциональный пропуск (галка «Требовать пропуск», default OFF).
        // checkCallingPermission в receiver-контексте возвращает гранты
        // отправителя broadcast'а; legacy-send без permission → DENIED.
        if (requirePermission(context)) {
            val granted = context.checkCallingPermission(PERMISSION_AUTOMATION) ==
                PackageManager.PERMISSION_GRANTED
            if (!granted) {
                Log.w(TAG, "rejected $action from $callerPkg — permission required but not granted")
                return
            }
        }

        when (action) {
            ACTION_START_VPN -> BoxVpnService.start(context)
            ACTION_STOP_VPN -> BoxVpnService.stop(context)
            ACTION_TOGGLE_VPN -> handleToggle(context)
            ACTION_SWITCH_NODE -> {
                val tag = intent.getStringExtra(EXTRA_TAG)
                if (tag.isNullOrEmpty()) {
                    Log.w(TAG, "SWITCH_NODE missing extra '$EXTRA_TAG'")
                    return
                }
                forward(context, "switch-node", mapOf("tag" to tag))
            }
            ACTION_SET_GROUP -> {
                val group = intent.getStringExtra(EXTRA_GROUP)
                if (group.isNullOrEmpty()) {
                    Log.w(TAG, "SET_GROUP missing extra '$EXTRA_GROUP'")
                    return
                }
                forward(context, "set-group", mapOf("group" to group))
            }
            ACTION_REBUILD_CONFIG -> forward(context, "rebuild-config", emptyMap())
            ACTION_REFRESH_SUBS -> {
                val force = intent.getBooleanExtra(EXTRA_FORCE, false)
                forward(context, "refresh-subs", mapOf("force" to force))
            }
            ACTION_RESET_NETWORK -> forward(context, "reset-network", emptyMap())
            ACTION_URLTEST_GROUP -> {
                val group = intent.getStringExtra(EXTRA_GROUP)
                if (group.isNullOrEmpty()) {
                    Log.w(TAG, "URLTEST_GROUP missing extra '$EXTRA_GROUP'")
                    return
                }
                forward(context, "urltest-group", mapOf("group" to group))
            }
            else -> Log.w(TAG, "unknown action $action")
        }
    }

    /// TOGGLE_VPN — toggle относительно текущего статуса. Старт требует VPN-
    /// consent: если он уже дан — стартуем напрямую; иначе открываем
    /// MainActivity с extra (тот же путь, что Quick Settings tile §032).
    private fun handleToggle(context: Context) {
        if (BoxVpnService.currentStatus == VpnStatus.Started) {
            BoxVpnService.stop(context)
            return
        }
        if (VpnService.prepare(context.applicationContext) == null) {
            BoxVpnService.start(context)
        } else {
            val launch = Intent(context, MainActivity::class.java).apply {
                putExtra(MainActivity.EXTRA_ACTION, MainActivity.ACTION_TOGGLE)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(launch)
        }
    }

    /// Форвард в Dart через VpnPlugin companion (cached MethodChannel). Если
    /// Flutter-engine не запущен — silently skip (action не выполнится, Tasker
    /// узнает из отсутствия outgoing-события / по таймауту).
    private fun forward(context: Context, name: String, args: Map<String, Any?>) {
        VpnPlugin.handleAutomationAction(name, args)
    }
}
