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
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        if (!isEnabled(context)) return

        Log.d(TAG, "Boot completed — auto-starting VPN")
        BoxApplication.initialize(context)
        BoxVpnService.start(context)
    }
}
