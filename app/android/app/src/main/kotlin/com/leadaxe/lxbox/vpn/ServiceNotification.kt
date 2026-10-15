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
import com.leadaxe.lxbox.R

class ServiceNotification(private val service: Service) {
    companion object {
        // Wire: id канала стабилен между релизами и локалями — НЕ в ресурсы.
        private const val CHANNEL_ID = "boxvpn_vpn_channel"
        private const val NOTIFICATION_ID = 1
        /// §428 — отдельное (не foreground) уведомление: сервис уже остановлен,
        /// а сказать юзеру надо — UI-процесса при sticky-рестарте нет.
        private const val ALERT_NOTIFICATION_ID = 2

        /// §279 — идемпотентный (пере)сабмит канала. createNotificationChannel
        /// с тем же id обновляет имя/описание (документированный rename-путь) —
        /// зовётся из init и из L10n.refreshSurfaces при смене языка.
        fun createChannel(ctx: Context) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    L10n.str(ctx, R.string.notification_channel_name),
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description =
                        L10n.str(ctx, R.string.notification_channel_description)
                    setShowBadge(false)
                }
                BoxApplication.notificationManager.createNotificationChannel(channel)
            }
        }

        /// §430 — в шторке висит уведомление id=1, хотя сервис в Stopped:
        /// утечка от УМЕРШЕГО процесса.
        ///
        /// Гонка в AMS (см. §428/§430): если tun-интерфейс исчезает раньше
        /// binder-death, `serviceProcessGoneLocked` стирает запись сервиса без
        /// `cancelForegroundNotificationLocked`, и уведомление с
        /// FLAG_FOREGROUND_SERVICE остаётся в шторке навсегда — «работает в
        /// фоне», а приложение честно показывает Start (4PDA, Redmi 12s).
        ///
        /// Снять его из приложения нельзя: NMS отбрасывает cancel() на
        /// уведомление с этим флагом, а при подмене под тем же id переносит
        /// флаг на новое (проверено на AVD: flags 0x62 → 0x48, бит 0x40
        /// остаётся). Единственный путь — bounce сервиса
        /// (`BoxVpnService.clearStaleNotification`): AMS снимает уведомление
        /// сам при штатной остановке foreground-сервиса.
        fun isStalePresent(): Boolean = runCatching {
            BoxApplication.notificationManager.activeNotifications.any { it.id == NOTIFICATION_ID }
        }.getOrDefault(false)

        /// §639 — страховочное снятие уведомления id=1 перед убийством
        /// процесса в Quit. После штатного `stopForeground` это no-op; если
        /// сервис ещё foreground, NMS cancel отбросит (см. §430) — вреда нет.
        fun cancelServiceNotification() {
            runCatching { BoxApplication.notificationManager.cancel(NOTIFICATION_ID) }
        }

        /// §428 — обычное уведомление на том же канале, живёт после stopSelf()
        /// и без сервиса (зовётся и из VpnWatchdogReceiver). Без
        /// POST_NOTIFICATIONS (API 33+) система молча его не покажет — это
        /// допустимо: сервис в любом случае остановлен, шторм прерван.
        fun showAlert(ctx: Context, title: String, text: String) {
            createChannel(ctx)
            val openIntent = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
            val builder = NotificationCompat.Builder(ctx, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_lock_lock)
                .setContentTitle(title)
                .setContentText(text)
                .setStyle(NotificationCompat.BigTextStyle().bigText(text))
                .setAutoCancel(true)
            if (openIntent != null) {
                builder.setContentIntent(
                    PendingIntent.getActivity(
                        ctx, 0, openIntent,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                    )
                )
            }
            runCatching {
                (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                    .notify(ALERT_NOTIFICATION_ID, builder.build())
            }
        }

        /// §637 — снять уведомление об ошибке (id=2) при новом явном старте и
        /// при успешном переходе в Started: после отказа старта страховка
        /// «core rejected node» отключает узел и повторяет старт, и без снятия
        /// «Error: Failed to start service …» висело бы рядом с живым VPN.
        /// Трогает только id=2; постоянное уведомление id=1 не пересобирается.
        fun cancelAlert(ctx: Context) {
            runCatching {
                (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                    .cancel(ALERT_NOTIFICATION_ID)
            }
        }

        /// §654 C — экстра интента MainActivity: тег узла openconnect, чей
        /// челлендж показать после тапа по уведомлению.
        const val EXTRA_OPENCONNECT_TAG = "openconnect_tag"

        /// §654 C — id уведомления «Sign-in required» на узел: своё на каждый
        /// тег, вне id 1/2.
        private fun signInId(tag: String): Int = 1000 + (tag.hashCode() and 0x7fff)

        /// §654 C — шлюз openconnect ждёт второй фактор или вход через
        /// браузер. Тап открывает приложение с диалогом этого узла. Канал
        /// тот же, что у уведомления VPN.
        fun showSignIn(ctx: Context, tag: String) {
            runCatching {
                createChannel(ctx)
                val openIntent = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
                    ?.apply {
                        putExtra(EXTRA_OPENCONNECT_TAG, tag)
                        addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    }
                val text = L10n.str(ctx, R.string.openconnect_sign_in_text)
                val builder = NotificationCompat.Builder(ctx, CHANNEL_ID)
                    .setSmallIcon(android.R.drawable.ic_lock_lock)
                    .setContentTitle(L10n.str(ctx, R.string.openconnect_sign_in_title, tag))
                    .setContentText(text)
                    .setStyle(NotificationCompat.BigTextStyle().bigText(text))
                    .setCategory(NotificationCompat.CATEGORY_STATUS)
                    .setAutoCancel(true)
                if (openIntent != null) {
                    builder.setContentIntent(
                        PendingIntent.getActivity(
                            ctx, signInId(tag), openIntent,
                            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                        )
                    )
                }
                (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                    .notify(signInId(tag), builder.build())
            }
        }

        /// §654 C — челлендж узла закрыт (ответ, отмена, остановка VPN).
        fun cancelSignIn(ctx: Context, tag: String) {
            runCatching {
                (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                    .cancel(signInId(tag))
            }
        }
    }

    init {
        createChannel(service)
    }

    /// §182/§279 — builder реконструируется ЦЕЛИКОМ на каждый show():
    /// `addAction` НЕ идемпотентен (на переиспользуемом builder'е кнопки
    /// Stop/Reconnect стекались бы на каждый апдейт), а лейблы обязаны
    /// перечитываться из ресурсов на активной локали в момент рендера
    /// (§279: relabel при смене языка = обычный show()-путь через
    /// ACTION_UPDATE_NOTIFICATION). show() зовётся редко (connect / смена
    /// лейбла) — цена реконструкции незначима.
    private fun buildNotification(title: String, text: String)
        : android.app.Notification {
        val openIntent = service.packageManager
            .getLaunchIntentForPackage(service.packageName)
        val pendingIntent = if (openIntent != null) {
            PendingIntent.getActivity(
                service, 0, openIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        } else null

        val builder = NotificationCompat.Builder(service, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentTitle(title)
            .setContentText(text)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setOngoing(true)

        if (pendingIntent != null) builder.setContentIntent(pendingIntent)

        // §182 — кнопки Stop / Reconnect прямо в шторке (фидбэк #180/#261).
        // icon=0: на Android 7+ action-иконки в развёрнутом уведомлении
        // compat-стиль скрывает, текст-лейбла достаточно.
        builder
            .addAction(
                0,
                L10n.str(service, R.string.notification_action_stop),
                broadcastPI(BoxVpnService.ACTION_STOP, 1),
            )
            .addAction(
                0,
                L10n.str(service, R.string.notification_action_reconnect),
                broadcastPI(BoxVpnService.ACTION_RECONNECT, 2),
            )
        return builder.build()
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

    fun show(title: String, text: String) {
        val notification = buildNotification(title, text)
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

    fun showAlert(title: String, text: String) = showAlert(service, title, text)

    fun cancelAlert() = cancelAlert(service)

    fun stop() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            service.stopForeground(Service.STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            service.stopForeground(true)
        }
    }
}
