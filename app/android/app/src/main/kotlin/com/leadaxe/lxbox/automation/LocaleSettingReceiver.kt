package com.leadaxe.lxbox.automation

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.util.Log
import com.leadaxe.lxbox.MainActivity
import com.leadaxe.lxbox.vpn.BoxVpnService
import com.leadaxe.lxbox.vpn.VpnPlugin
import com.leadaxe.lxbox.vpn.VpnStatus

/// §047 Шаг 2 — setting-плагин (Locale/Tasker «Action → Plugin → L×Box»).
///
/// Host (Tasker) шлёт `FIRE_SETTING` + `EXTRA_BUNDLE` (наш JSON-конфиг,
/// собранный в [LocaleSettingEditActivity]). Парсим → исполняем команду через
/// **те же** shared handlers, что raw-actions Шага 1 и Debug API.
///
/// Lifecycle-команды (start/stop/toggle) идут напрямую в [BoxVpnService] —
/// быстро, без Flutter-engine. Остальные форвардятся в Dart через
/// [VpnPlugin.handleAutomationAction].
///
/// Receiver `enabled=false` в манифесте; включается мастер-toggle'ом «Принимать
/// команды автоматизации» вместе с raw-receiver Шага 1. По стандарту
/// `android:permission` НЕ задаётся — хост проверяет права сам.
class LocaleSettingReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "LocaleSetting"
    }

    override fun onReceive(context: Context, intent: Intent) {
        // Defensive: exported receiver, исполняем в try/catch — краш FGS-
        // процесса при работающем VPN хуже пропущенной команды.
        try {
            if (intent.action != LocaleApi.ACTION_FIRE_SETTING) return
            val parsed = LocaleApi.parseSetting(
                intent.getBundleExtra(LocaleApi.EXTRA_BUNDLE),
            )
            if (parsed == null) {
                Log.w(TAG, "FIRE_SETTING — invalid/missing bundle, ignored")
                return
            }
            val (cmd, args) = parsed
            Log.d(TAG, "fire cmd=$cmd args=$args")
            when (cmd) {
                "start-vpn" -> BoxVpnService.start(context)
                "stop-vpn" -> BoxVpnService.stop(context)
                "toggle-vpn" -> handleToggle(context)
                else -> VpnPlugin.handleAutomationAction(cmd, args)
            }
        } catch (t: Throwable) {
            Log.e(TAG, "onReceive failed", t)
        }
    }

    /// Тот же toggle-путь, что у raw-receiver Шага 1 (§032 consent-flow).
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
}
