package com.leadaxe.lxbox.appfunctions

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.leadaxe.lxbox.MainActivity
import com.leadaxe.lxbox.R
import com.leadaxe.lxbox.vpn.L10n
import com.leadaxe.lxbox.vpn.UiCalls
import com.leadaxe.lxbox.vpn.UiHold
import kotlinx.coroutines.delay

/// §750 — мост шлюза ассистента (`getApiHelp` / `callApi`) в Dart.
///
/// Dart отвечает `{status, body}`; политику (белый список, тумблер «Let
/// assistants change settings») проверяет Dart, натив их не знает.
///
/// §747 — шов межпроцессный: AppFunctions исполняются в `:bg`, Dart живёт в
/// процессе окна. Вызов `assistantCall` `{method, path, body}` идёт обратным
/// вызовом [UiCalls]: запрос кадром канала событий, окно исполняет
/// `invokeMethod` на канале плагина и возвращает итог по номеру. «Мост есть» —
/// окно назвалось `:bg` (`UiPresence`) и подтвердило получение запроса. На
/// время вызова процесс окна удерживается ([UiHold]): свёрнутое окно при
/// остановленном туннеле иначе могло бы быть заморожено.
///
/// Моста нет (окно закрыто, движка нет, окно заморожено и не подтвердило
/// получение) или Dart ответил `503 not_ready`: один раз пробуем открыть окно
/// L×Box и ждём до [AssistantLogic.BRIDGE_WAIT_MS]; не дождались — уведомление
/// «Open L×Box…» и [AssistantError.APP_NOT_OPEN].
object AssistantBridge {
    private const val TAG = "AssistantBridge"
    private const val METHOD = "assistantCall"
    private const val CHANNEL_ID = "lxbox_assistant"
    private const val NOTIFICATION_ID = 7501

    suspend fun call(ctx: Context, method: String, path: String, body: String?): AssistantLogic.ApiResult {
        val appCtx = ctx.applicationContext
        UiHold.callStarted(appCtx)
        try {
            var launchedAt = -1L
            while (true) {
                val reply = invoke(method, path, body)
                if (reply != null && !AssistantLogic.isNotReady(reply)) return reply
                val since = if (launchedAt < 0) 0L else SystemClock.elapsedRealtime() - launchedAt
                when (AssistantLogic.bridgeStep(launched = launchedAt >= 0, sinceLaunchMs = since)) {
                    AssistantLogic.BridgeStep.LAUNCH -> {
                        launchedAt = SystemClock.elapsedRealtime()
                        openApp(appCtx)
                    }
                    AssistantLogic.BridgeStep.WAIT -> delay(AssistantLogic.BRIDGE_POLL_MS)
                    AssistantLogic.BridgeStep.GIVE_UP -> {
                        Log.d(TAG, "Dart side not ready after ${since}ms, giving up")
                        notifyOpenApp(appCtx)
                        throw AssistantError(AssistantError.APP_NOT_OPEN, AssistantLogic.MSG_APP_NOT_OPEN)
                    }
                }
            }
        } finally {
            UiHold.callFinished(appCtx)
        }
    }

    /// Один вызов `assistantCall` в Dart окна. null — моста нет (окно не
    /// подключено или не подтвердило получение запроса): ждём как старта.
    /// Окно получило запрос, но Dart не ответил за
    /// [AssistantLogic.BRIDGE_CALL_TIMEOUT_MS] — ошибка.
    private suspend fun invoke(method: String, path: String, body: String?): AssistantLogic.ApiResult? {
        val outcome = UiCalls.invoke(
            METHOD,
            mapOf("method" to method, "path" to path, "body" to body),
            timeoutMs = AssistantLogic.BRIDGE_CALL_TIMEOUT_MS,
        )
        return when (outcome) {
            UiCalls.Outcome.NotDelivered -> null
            UiCalls.Outcome.TimedOut ->
                throw AssistantError(AssistantError.CORE_ERROR, AssistantLogic.MSG_BRIDGE_TIMEOUT)
            is UiCalls.Outcome.Answered -> when (val r = outcome.reply) {
                is UiCalls.Reply.Ok -> AssistantLogic.parseBridgeReply(r.value)
                    ?: throw AssistantError(AssistantError.CORE_ERROR, AssistantLogic.MSG_BRIDGE_BAD_REPLY)
                is UiCalls.Reply.Error -> {
                    Log.w(TAG, "assistantCall error: ${r.code}")
                    throw AssistantError(AssistantError.CORE_ERROR, AssistantLogic.MSG_BRIDGE_BAD_REPLY)
                }
                // Dart-обработчика нет — считаем «не готов», ждём как старта.
                UiCalls.Reply.NotImplemented -> null
            }
        }
    }

    /// Открыть окно L×Box. Android может запретить запуск из фона (иногда
    /// молча) — тогда просто ждём и сдаёмся по таймауту.
    private fun openApp(ctx: Context) {
        runCatching {
            ctx.startActivity(launchIntent(ctx))
        }.onFailure { Log.w(TAG, "startActivity failed: ${it.javaClass.simpleName}") }
    }

    private fun launchIntent(ctx: Context): Intent =
        Intent(ctx, MainActivity::class.java)
            .setAction(Intent.ACTION_MAIN)
            .addCategory(Intent.CATEGORY_LAUNCHER)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    /// Уведомление «Open L×Box to let the assistant continue»; тап открывает
    /// окно. Нет разрешения на уведомления — молча пропускаем.
    private fun notifyOpenApp(ctx: Context) {
        runCatching {
            val nm = NotificationManagerCompat.from(ctx)
            if (!nm.areNotificationsEnabled()) return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    L10n.str(ctx, R.string.assistant_channel_name),
                    NotificationManager.IMPORTANCE_DEFAULT,
                )
                (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                    .createNotificationChannel(channel)
            }
            val tap = PendingIntent.getActivity(
                ctx, NOTIFICATION_ID, launchIntent(ctx),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val n = NotificationCompat.Builder(ctx, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_lock_lock)
                .setContentTitle(L10n.str(ctx, R.string.assistant_open_app_title))
                .setContentIntent(tap)
                .setAutoCancel(true)
                .build()
            nm.notify(NOTIFICATION_ID, n)
        }.onFailure { Log.w(TAG, "notify failed: ${it.javaClass.simpleName}") }
    }
}
