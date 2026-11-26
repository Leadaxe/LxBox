package com.leadaxe.lxbox.vpn

import android.util.Log

/**
 * §747 — сервисная сторона моста автоматизации (§047): нативные входы
 * (`LxBoxIntentReceiver`, `LocaleSettingReceiver`, воронка нативных Stop
 * `BoxVpnService.stop()`) живут в `:bg`, а обработчики — в Dart процесса
 * `:ui`. Команда уходит окну кадром канала событий
 * ([EventFrames.AUTOMATION]); окно отдаёт её в `AutomationBridge` (канал
 * Dart). Окна нет — команда пропускается с записью в лог, как раньше.
 */
object AutomationRelay {
    /// Тег лога оставлен прежним (`VpnPlugin`), чтобы фильтры logcat не поменялись.
    private const val TAG = "VpnPlugin"

    /// §047 incoming bridge: intent-action + extras → Dart (`box_vpn_client`
    /// `automationAction` handler) → shared action-handlers.
    fun handleAutomationAction(name: String, args: Map<String, Any?>) {
        val sent = UiPresence.isAttached &&
            BgEventPipe.reliable(EventFrames.AUTOMATION, mapOf("name" to name, "args" to args))
        if (!sent) {
            Log.w(TAG, "[automation] handleAutomationAction($name) — no Flutter engine, skip")
        } else if (!uiHoldWanted(TunnelState.status, true)) {
            // Туннель остановлен — процесс окна не удерживается (`UiHold`) и,
            // если окно свёрнуто, может быть заморожен системой: команда
            // лежит в канале событий и исполнится, когда окно вернётся (или
            // когда туннель стартует и удержание разбудит окно). При
            // работающем туннеле окно живо и команда исполняется сразу.
            Log.w(TAG, "[automation] $name sent while the tunnel is stopped — it runs when the window is awake")
        }
    }

    /// Фича 478, ревью после v2.25.1 (M2) — сообщить Dart о нативном Stop
    /// (`BoxVpnService.stop`): Dart гасит идущий прогон страховки. Имя —
    /// `kVpnStopRequestedAction` в `automation_dispatcher.dart`. Нет
    /// движка — нет и прогона, пропуск молча.
    fun notifyStopRequested() = handleAutomationAction("vpn-stop-requested", emptyMap())
}
