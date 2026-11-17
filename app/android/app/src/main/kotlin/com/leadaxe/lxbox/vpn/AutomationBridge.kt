package com.leadaxe.lxbox.vpn

import android.content.Context
import android.content.Intent
import android.util.Log
import io.flutter.plugin.common.MethodChannel

/**
 * §740 — мост автоматизации (§047), сторона окна: ссылки на канал и контекст
 * ставит `VpnPlugin` при attach и снимает при detach. §747 — команды
 * приходят из `:bg` кадром канала событий (`AutomationRelay`); кадр принимает
 * `VpnPlugin`.
 *
 * До §740 код лежал в `VpnPlugin.companion`; перенесён без изменений
 * (тег лога прежний — `VpnPlugin`).
 */
object AutomationBridge {
    /// Тег лога оставлен прежним (`VpnPlugin`), чтобы фильтры logcat не поменялись.
    private const val TAG = "VpnPlugin"

    // §047 — ссылки заполняются в onAttachedToEngine, обнуляются в
    // onDetachedFromEngine. null = Flutter-engine не активен.
    @Volatile
    internal var bridgeChannel: MethodChannel? = null

    @Volatile
    internal var appContext: Context? = null

    private val bridgeHandler =
        android.os.Handler(android.os.Looper.getMainLooper())

    /// Отдать команду в Dart (`automationAction`). Если engine не запущен —
    /// пропуск с записью в лог.
    fun handleAutomationAction(name: String, args: Map<String, Any?>) {
        val channel = bridgeChannel
        if (channel == null) {
            Log.w(TAG, "[automation] handleAutomationAction($name) — no Flutter engine, skip")
            return
        }
        bridgeHandler.post {
            runCatching {
                channel.invokeMethod(
                    "automationAction",
                    mapOf("name" to name, "args" to args),
                )
            }.onFailure {
                Log.e(TAG, "[automation] invokeMethod(automationAction) failed", it)
            }
        }
    }

    /// §047 outgoing emit: Dart (`AutomationEventEmitter`) шлёт событие
    /// наружу. action — короткое имя (`VPN_CONNECTED`), namespace'ится в
    /// `com.leadaxe.lxbox.event.<action>`. Открыт всем подписчикам — события
    /// не содержат секретов (только лейблы: теги нод, группы, статус); см.
    /// §157 (permission-фильтр удалён вместе с нерабочей галкой).
    fun sendAutomationBroadcast(action: String, extras: Map<String, Any?>) {
        val ctx = appContext ?: return
        val intent = Intent("com.leadaxe.lxbox.event.$action")
        for ((k, v) in extras) {
            when (v) {
                null -> {}
                is String -> intent.putExtra(k, v)
                is Boolean -> intent.putExtra(k, v)
                is Int -> intent.putExtra(k, v)
                is Long -> intent.putExtra(k, v)
                is Double -> intent.putExtra(k, v)
                else -> intent.putExtra(k, v.toString())
            }
        }
        // setPackage намеренно не выставляем — broadcast открыт всем
        // подписчикам (события без секретов, только лейблы).
        ctx.sendBroadcast(intent)
        Log.d(TAG, "[automation] emit $action (${extras.size} extras)")
    }
}
