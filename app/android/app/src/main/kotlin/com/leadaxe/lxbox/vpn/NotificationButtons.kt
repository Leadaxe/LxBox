package com.leadaxe.lxbox.vpn

import android.content.Context

/// §707 итер. 8 — какие кнопки показывать в уведомлении VPN: настройка
/// устройства (SharedPreferences, не бэкап L×Box), по умолчанию все.
/// «Send» сверх этого появляется только при [TaildropClip.available].
object NotificationButtons {
    const val STOP = "stop"
    const val RESTART = "restart"
    const val SEND = "send"

    private const val PREFS = "lxbox_notification_buttons"
    private val ALL = listOf(STOP, RESTART, SEND)

    private fun prefs(ctx: Context) =
        ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun enabled(ctx: Context, button: String): Boolean = prefs(ctx).getBoolean(button, true)

    fun all(ctx: Context): Map<String, Boolean> = ALL.associateWith { enabled(ctx, it) }

    /// `false` — неизвестная кнопка, ничего не записано.
    fun set(ctx: Context, button: String, value: Boolean): Boolean {
        if (button !in ALL) return false
        prefs(ctx).edit().putBoolean(button, value).apply()
        return true
    }
}
