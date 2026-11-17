package com.leadaxe.lxbox.vpn

import android.content.Context
import android.content.Intent
import android.util.Log
import io.flutter.plugin.common.MethodChannel

/**
 * §747 — сервисная сторона моста автоматизации (§047): нативные входы
 * (`LxBoxIntentReceiver`, `LocaleSettingReceiver`, воронка нативных Stop
 * `BoxVpnService.stop()`) живут в `:bg`, а обработчики — в Dart процесса
 * `:ui`. Команда уходит broadcast'ом внутри пакета ([BgEvents.ACTION_AUTOMATION]);
 * приёмник в `:ui` зарегистрирован, пока подключён Flutter-движок, и отдаёт её
 * в [AutomationBridge]. Нет движка — команда пропускается с записью в лог,
 * как раньше.
 */
object AutomationRelay {
    /// Тег лога оставлен прежним (`VpnPlugin`), чтобы фильтры logcat не поменялись.
    private const val TAG = "VpnPlugin"

    /// §047 incoming bridge: intent-action + extras → Dart (`box_vpn_client`
    /// `automationAction` handler) → shared action-handlers.
    fun handleAutomationAction(ctx: Context, name: String, args: Map<String, Any?>) {
        // Жив ли процесс окна — знает `:bg` (`UiPresence`); из самого окна
        // (ярлык в `MainActivity`) событие шлётся всегда.
        if (ProcessRole.role == ProcessRole.Role.Bg && !UiPresence.isAttached) {
            Log.w(TAG, "[automation] handleAutomationAction($name) — no Flutter engine, skip")
            return
        }
        BgEvents.send(ctx, BgEvents.ACTION_AUTOMATION) {
            putExtra(BgEvents.EXTRA_NAME, name)
            putExtra(BgEvents.EXTRA_ARGS, BgCodec.encode(args))
        }
    }

    /// Фича 478, ревью после v2.25.1 (M2) — сообщить Dart о нативном Stop
    /// (`BoxVpnService.stop`): Dart гасит идущий прогон страховки. Имя —
    /// `kVpnStopRequestedAction` в `automation_dispatcher.dart`. Нет
    /// движка — нет и прогона, пропуск молча.
    fun notifyStopRequested(ctx: Context) =
        handleAutomationAction(ctx, "vpn-stop-requested", emptyMap())
}

/**
 * §740 — мост автоматизации (§047), сторона окна: ссылки на канал и контекст
 * ставит `VpnPlugin` при attach и снимает при detach. §747 — команды
 * приходят событием из `:bg` ([AutomationRelay]); приёмник события — в
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
