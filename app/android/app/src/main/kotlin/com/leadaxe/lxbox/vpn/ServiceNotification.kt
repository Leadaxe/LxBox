package com.leadaxe.lxbox.vpn

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.core.app.NotificationCompat

class ServiceNotification(private val service: Service) {
    companion object {
        private const val CHANNEL_ID = "boxvpn_vpn_channel"
        private const val NOTIFICATION_ID = 1
    }

    private val builder: NotificationCompat.Builder

    init {
        createChannel()
        val openIntent = service.packageManager.getLaunchIntentForPackage(service.packageName)
        val pendingIntent = if (openIntent != null) {
            PendingIntent.getActivity(
                service, 0, openIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        } else null

        builder = NotificationCompat.Builder(service, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentTitle(ConfigManager.notificationTitle)
            .setContentText("Connecting...")
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setOngoing(true)

        if (pendingIntent != null) builder.setContentIntent(pendingIntent)

        // §182 — кнопки Stop / Reconnect прямо в шторке (фидбэк #180/#261).
        // ВАЖНО: addAction НЕ идемпотентен — навешиваем СТРОГО здесь, в init
        // (builder переиспользуется между show()), иначе кнопки стекаются на
        // каждый апдейт title/text. icon=0: на Android 7+ action-иконки в
        // развёрнутом уведомлении compat-стиль скрывает, текст-лейбла достаточно.
        builder
            .addAction(0, "Stop", broadcastPI(BoxVpnService.ACTION_STOP, 1))
            .addAction(0, "Reconnect", broadcastPI(BoxVpnService.ACTION_RECONNECT, 2))
    }

    /// §182 — PendingIntent на explicit-broadcast (только своему пакету →
    /// receiver RECEIVER_NOT_EXPORTED извне не дёрнуть). FLAG_IMMUTABLE —
    /// требование API 31+.
    private fun broadcastPI(action: String, requestCode: Int): PendingIntent {
        val intent = Intent(action).setPackage(service.packageName)
        return PendingIntent.getBroadcast(
            service, requestCode, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "VPN Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows when VPN is active"
                setShowBadge(false)
            }
            BoxApplication.notificationManager.createNotificationChannel(channel)
        }
    }

    fun show(title: String, text: String) {
        val notification = builder
            .setContentTitle(title)
            .setContentText(text)
            .build()
        // На Android 14+ (API 34) Google требует typed startForeground —
        // иначе MissingForegroundServiceTypeException на строгих OEM
        // (One UI 6, MIUI 14). На младших API typed-перегрузка отсутствует
        // в SDK или ничего не даёт — используем legacy 2-arg API.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            service.startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            service.startForeground(NOTIFICATION_ID, notification)
        }
    }

    fun stop() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            service.stopForeground(Service.STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            service.stopForeground(true)
        }
    }
}
