package com.leadaxe.lxbox.appfunctions

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.leadaxe.lxbox.MainActivity
import com.leadaxe.lxbox.R
import com.leadaxe.lxbox.vpn.AutomationBridge
import com.leadaxe.lxbox.vpn.L10n
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume

/// §750 — мост шлюза ассистента (`getApiHelp` / `callApi`) в Dart.
///
/// Вызов уходит методом `assistantCall` `{method, path, body}` по тому же
/// MethodChannel, что и у [AutomationBridge] (канал ставит плагин при attach
/// движка и снимает при detach) — отдельной ссылки на канал не заводим.
/// Dart отвечает `{status, body}`; политику (белый список, тумблер «Let
/// assistants change settings») проверяет Dart, натив их не знает.
///
/// Лежит в `appfunctions/` (сервисная сторона): Flutter-канал берёт только
/// через [AutomationBridge], `VpnPlugin`/`UiSinks`/клиента UI не знает.
/// После §747 этот шов станет межпроцессным (`:bg` → `:ui`).
///
/// Движка нет или Dart ответил `503 not_ready`: один раз пробуем открыть окно
/// L×Box и ждём до [AssistantLogic.BRIDGE_WAIT_MS]; не дождались — уведомление
/// «Open L×Box…» и [AssistantError.APP_NOT_OPEN].
object AssistantBridge {
    private const val TAG = "AssistantBridge"
    private const val METHOD = "assistantCall"
    private const val CHANNEL_ID = "lxbox_assistant"
    private const val NOTIFICATION_ID = 7501

    private val mainHandler = Handler(Looper.getMainLooper())

    suspend fun call(ctx: Context, method: String, path: String, body: String?): AssistantLogic.ApiResult {
        val appCtx = ctx.applicationContext
        var launchedAt = -1L
        while (true) {
            val channel = AutomationBridge.bridgeChannel
            if (channel != null) {
                val reply = invoke(channel, method, path, body)
                if (!AssistantLogic.isNotReady(reply)) return reply
            }
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
    }

    /// Один вызов `assistantCall` на главном потоке; ответ — через колбэк
    /// `MethodChannel.Result`. Нет ответа за [AssistantLogic.BRIDGE_CALL_TIMEOUT_MS]
    /// (например, движок отцепился посреди вызова) — ошибка.
    private suspend fun invoke(
        channel: MethodChannel,
        method: String,
        path: String,
        body: String?,
    ): AssistantLogic.ApiResult {
        val outcome: Result<AssistantLogic.ApiResult> =
            withTimeoutOrNull(AssistantLogic.BRIDGE_CALL_TIMEOUT_MS) {
                suspendCancellableCoroutine<Result<AssistantLogic.ApiResult>> { cont ->
                    fun finish(r: Result<AssistantLogic.ApiResult>) {
                        if (cont.isActive) cont.resume(r)
                    }
                    mainHandler.post {
                        runCatching {
                            channel.invokeMethod(
                                METHOD,
                                mapOf("method" to method, "path" to path, "body" to body),
                                object : MethodChannel.Result {
                                    override fun success(result: Any?) {
                                        val parsed = AssistantLogic.parseBridgeReply(result)
                                        finish(
                                            if (parsed != null) Result.success(parsed)
                                            else Result.failure(AssistantError(
                                                AssistantError.CORE_ERROR, AssistantLogic.MSG_BRIDGE_BAD_REPLY,
                                            )),
                                        )
                                    }

                                    override fun error(code: String, message: String?, details: Any?) {
                                        Log.w(TAG, "assistantCall error: $code")
                                        finish(Result.failure(AssistantError(
                                            AssistantError.CORE_ERROR, AssistantLogic.MSG_BRIDGE_BAD_REPLY,
                                        )))
                                    }

                                    override fun notImplemented() {
                                        // Dart-обработчика нет — считаем «не готов», ждём как старта.
                                        finish(Result.success(AssistantLogic.ApiResult(503, "{\"error\":\"not_ready\"}")))
                                    }
                                },
                            )
                        }.onFailure {
                            Log.w(TAG, "invokeMethod($METHOD) failed: ${it.javaClass.simpleName}")
                            finish(Result.success(AssistantLogic.ApiResult(503, "{\"error\":\"not_ready\"}")))
                        }
                    }
                }
            } ?: Result.failure(AssistantError(AssistantError.CORE_ERROR, AssistantLogic.MSG_BRIDGE_TIMEOUT))
        return outcome.getOrThrow()
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
