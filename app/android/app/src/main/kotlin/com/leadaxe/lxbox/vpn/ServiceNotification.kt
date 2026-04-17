package com.leadaxe.lxbox.vpn

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
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
        service.startForeground(NOTIFICATION_ID, notification)
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
