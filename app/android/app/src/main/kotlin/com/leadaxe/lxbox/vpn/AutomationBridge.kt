package com.leadaxe.lxbox.vpn

import android.content.Context
import android.content.Intent
import android.util.Log
import io.flutter.plugin.common.MethodChannel

/**
 * §740 — мост автоматизации (§047) между нативными входами и Dart. Звать его
 * может кто угодно (`LxBoxIntentReceiver`, `LocaleSettingReceiver`,
 * `BoxVpnService.stop()`), а живёт он на стороне UI: ссылки на канал и
 * контекст ставит `VpnPlugin` при attach и снимает при detach. Нет движка —
 * вызовы тихо пропускаются.
 *
 * После разделения на процессы этот шов станет межпроцессным — см.
 * docs/ARCHITECTURE.md, раздел о границе процессов.
 *
 * До §740 код лежал в `VpnPlugin.companion`; перенесён без изменений
 * (тег лога прежний — `VpnPlugin`).
 */
object AutomationBridge {
    /// Тег лога оставлен прежним (`VpnPlugin`), чтобы фильтры logcat не поменялись.
    private const val TAG = "VpnPlugin"

    // §047 — статические ссылки для bridge'а из LxBoxIntentReceiver (он
    // живёт вне Flutter-плагина). Заполняются в onAttachedToEngine,
    // обнуляются в onDetachedFromEngine. null = Flutter-engine не активен.
    @Volatile
    internal var bridgeChannel: MethodChannel? = null
    @Volatile
    internal var appContext: Context? = null
    private val bridgeHandler =
        android.os.Handler(android.os.Looper.getMainLooper())

    /// §047 incoming bridge: LxBoxIntentReceiver форвардит intent-action +
    /// extras → Dart (`box_vpn_client` `automationAction` handler) → shared
    /// action-handlers. Если engine не запущен — silently skip.
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

    /// Фича 478, ревью после v2.25.1 (M2) — сообщить Dart о нативном Stop
    /// (`BoxVpnService.stop`): Dart гасит идущий прогон страховки. Имя —
    /// `kVpnStopRequestedAction` в `automation_dispatcher.dart`. Нет
    /// движка — нет и прогона, пропуск молча.
    fun notifyStopRequested() = handleAutomationAction("vpn-stop-requested", emptyMap())

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
