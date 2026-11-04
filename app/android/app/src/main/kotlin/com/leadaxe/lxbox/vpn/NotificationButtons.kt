package com.leadaxe.lxbox.vpn

import android.content.Context

/// §707 итер. 8–9 — какие кнопки показывать в уведомлении VPN: настройка
/// `native_prefs` (`notification_stop` / `notification_restart` /
/// `notification_send`, в бэкапе), Kotlin читает зеркало `boxvpn_boot`
/// ([BootReceiver]), по умолчанию все. «Send» сверх этого появляется только
/// при [TaildropClip.available].
object NotificationButtons {
    const val STOP = "stop"
    const val RESTART = "restart"
    const val SEND = "send"

    fun enabled(ctx: Context, button: String): Boolean = when (button) {
        STOP -> BootReceiver.isNotificationStop(ctx)
        RESTART -> BootReceiver.isNotificationRestart(ctx)
        SEND -> BootReceiver.isNotificationSend(ctx)
        else -> true
    }
}
