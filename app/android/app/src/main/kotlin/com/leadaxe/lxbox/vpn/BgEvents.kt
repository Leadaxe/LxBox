package com.leadaxe.lxbox.vpn

import android.content.Context
import android.content.Intent

/// §747 — события `:bg` → `:ui`: broadcast'ы внутри пакета (`setPackage`).
/// Приёмники регистрирует `VpnPlugin`, пока подключён Flutter-движок; без
/// движка событие никто не принимает — как раньше вызов в пустой sink.
///
/// Данных, кроме перечисленных здесь, события не несут: снимок openconnect
/// (в нём форма входа) и секреты формы идут только вызовом `BgControlProvider`.
object BgEvents {
    /// Состояние openconnect изменилось — `:ui` забирает снимок вызовом
    /// `ccGetOpenConnectStatus`. Без extras.
    const val ACTION_OPENCONNECT_CHANGED = "com.leadaxe.lxbox.BG_OPENCONNECT_CHANGED"

    /// Команда автоматизации или «нативный Stop» для Dart
    /// (`AutomationRelay` → `AutomationBridge`). Extras: [EXTRA_NAME],
    /// [EXTRA_ARGS] (карта, [BgCodec]).
    const val ACTION_AUTOMATION = "com.leadaxe.lxbox.BG_AUTOMATION_ACTION"
    const val EXTRA_NAME = "name"
    const val EXTRA_ARGS = "args"

    /// `:bg` поднимает командный сервер, а в `:ui` идёт проба без туннеля на
    /// том же сокете: остановить пробу и ответить вызовом `probeEnd`.
    const val ACTION_STOP_PROBE = "com.leadaxe.lxbox.BG_STOP_PROBE"

    // Extras запуска `MainActivity` из уведомлений `:bg` (тап по «Sign-in
    // required» и по уведомлению Taildrop): тег узла.
    const val EXTRA_LAUNCH_OPENCONNECT_TAG = "openconnect_tag"
    const val EXTRA_LAUNCH_TAILDROP_TAG = "taildrop_tag"

    // Метка порядка и поля снимка туннеля в `BROADCAST_STATUS`.
    const val EXTRA_EPOCH = "ts_epoch"
    const val EXTRA_SEQ = "ts_seq"
    const val EXTRA_STARTED_ELAPSED_MS = "started_elapsed_ms"
    const val EXTRA_SESSION_ALLOW_BYPASS = "session_allow_bypass"

    fun send(ctx: Context, action: String, fill: Intent.() -> Unit = {}) {
        runCatching {
            ctx.sendBroadcast(Intent(action).setPackage(ctx.packageName).apply(fill))
        }
    }

    /// Положить в `BROADCAST_STATUS` метку и те поля снимка, которых нет среди
    /// прежних extras (`status`, `revoked` кладёт отправитель).
    fun putWire(intent: Intent, w: TunnelState.Wire): Intent = intent
        .putExtra(EXTRA_EPOCH, w.epoch)
        .putExtra(EXTRA_SEQ, w.seq)
        .putExtra(EXTRA_STARTED_ELAPSED_MS, w.snapshot.startedElapsedMs)
        .putExtra(EXTRA_SESSION_ALLOW_BYPASS, w.snapshot.sessionAllowBypass)

    /// Снимок из `BROADCAST_STATUS`; null — метки нет или статус не разобран.
    fun wireOf(intent: Intent): TunnelState.Wire? {
        if (!intent.hasExtra(EXTRA_SEQ)) return null
        val status = statusOf(intent.getStringExtra(BoxVpnService.EXTRA_STATUS)) ?: return null
        return TunnelState.Wire(
            epoch = intent.getLongExtra(EXTRA_EPOCH, 0L),
            seq = intent.getLongExtra(EXTRA_SEQ, 0L),
            snapshot = TunnelState.Snapshot(
                status = status,
                revoked = intent.getBooleanExtra(BoxVpnService.EXTRA_REVOKED, false),
                startedElapsedMs = intent.getLongExtra(EXTRA_STARTED_ELAPSED_MS, 0L),
                sessionAllowBypass = intent.getBooleanExtra(EXTRA_SESSION_ALLOW_BYPASS, false),
            ),
        )
    }

    /// Снимок для ответа вызова `tunnelSnapshot`.
    fun wireToMap(w: TunnelState.Wire): Map<String, Any> = mapOf(
        "status" to w.snapshot.status.name,
        BoxVpnService.EXTRA_REVOKED to w.snapshot.revoked,
        EXTRA_STARTED_ELAPSED_MS to w.snapshot.startedElapsedMs,
        EXTRA_SESSION_ALLOW_BYPASS to w.snapshot.sessionAllowBypass,
        EXTRA_EPOCH to w.epoch,
        EXTRA_SEQ to w.seq,
    )

    fun wireOf(m: Map<*, *>): TunnelState.Wire? {
        val status = statusOf(m["status"] as? String) ?: return null
        return TunnelState.Wire(
            epoch = (m[EXTRA_EPOCH] as? Number)?.toLong() ?: return null,
            seq = (m[EXTRA_SEQ] as? Number)?.toLong() ?: return null,
            snapshot = TunnelState.Snapshot(
                status = status,
                revoked = m[BoxVpnService.EXTRA_REVOKED] as? Boolean ?: false,
                startedElapsedMs = (m[EXTRA_STARTED_ELAPSED_MS] as? Number)?.toLong() ?: 0L,
                sessionAllowBypass = m[EXTRA_SESSION_ALLOW_BYPASS] as? Boolean ?: false,
            ),
        )
    }

    private fun statusOf(name: String?): VpnStatus? =
        VpnStatus.values().firstOrNull { it.name == name }
}
