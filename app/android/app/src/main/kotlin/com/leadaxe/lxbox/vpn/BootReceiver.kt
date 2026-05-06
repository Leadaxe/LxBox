package com.leadaxe.lxbox.vpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class BootReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "BootReceiver"
        private const val PREF_NAME = "boxvpn_boot"
        private const val KEY_AUTO_START = "auto_start_vpn"
        private const val KEY_KEEP_ON_EXIT = "keep_vpn_on_exit"
        private const val KEY_BACKGROUND_MODE = "background_mode"
        /// §043: forwarding sing-box логов в Flutter EventChannel (см.
        /// `BoxApplication.initialize` где `SetupOptions.debug = ...`
        /// читается из этой prefs). Default false — opt-in для диагностики.
        /// Изменение применяется только после restart Service'а
        /// (Libbox.setup вызывается один раз).
        private const val KEY_CORE_LOGS = "core_logs_enabled"

        /// Три режима фоновой работы tunnel'а. По умолчанию "never" — максимум
        /// стабильности, минимум экономии батареи. VPN-пользователи обычно
        /// выбирают надёжность (пуши, длинные TCP-сокеты), поэтому default
        /// именно такой.
        /// - "never": pause/wake не вызывается никогда, tunnel всегда активен
        /// - "lazy": pause при deep Doze (текущее поведение sing-box-android)
        /// - "always": pause при screen off (максимум экономии)
        const val BG_MODE_NEVER = "never"
        const val BG_MODE_LAZY = "lazy"
        const val BG_MODE_ALWAYS = "always"

        fun setBackgroundMode(context: Context, mode: String) {
            context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .edit().putString(KEY_BACKGROUND_MODE, mode).apply()
        }

        fun getBackgroundMode(context: Context): String {
            return context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .getString(KEY_BACKGROUND_MODE, BG_MODE_NEVER) ?: BG_MODE_NEVER
        }

        fun setEnabled(context: Context, enabled: Boolean) {
            context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .edit().putBoolean(KEY_AUTO_START, enabled).apply()
        }

        fun isEnabled(context: Context): Boolean {
            return context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .getBoolean(KEY_AUTO_START, false)
        }

        fun setKeepOnExit(context: Context, enabled: Boolean) {
            context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .edit().putBoolean(KEY_KEEP_ON_EXIT, enabled).apply()
        }

        fun isKeepOnExit(context: Context): Boolean {
            return context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .getBoolean(KEY_KEEP_ON_EXIT, false)
        }

        /// §043: forwarding sing-box логов в наш PlatformInterface.writeDebugMessage
        /// callback. Read by `BoxApplication.initialize` для `SetupOptions.debug`.
        /// Default false — opt-in для диагностики (сотни строк/мин на busy traffic).
        fun setCoreLogsEnabled(context: Context, enabled: Boolean) {
            context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .edit().putBoolean(KEY_CORE_LOGS, enabled).apply()
        }

        fun isCoreLogsEnabled(context: Context): Boolean {
            return context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .getBoolean(KEY_CORE_LOGS, false)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        if (!isEnabled(context)) return

        Log.d(TAG, "Boot completed — auto-starting VPN")
        BoxApplication.initialize(context)
        BoxVpnService.start(context)
    }
}
