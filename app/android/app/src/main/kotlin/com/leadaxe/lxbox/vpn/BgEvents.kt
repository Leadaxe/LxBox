package com.leadaxe.lxbox.vpn

import android.content.Intent

/// §747 — то, что едет между процессами в Intent'ах: снимок состояния туннеля
/// в `BROADCAST_STATUS` (и в ответе вызова `tunnelSnapshot`) и extras запуска
/// окна из уведомлений `:bg`. Остальные события `:bg` → `:ui` (потоки данных,
/// ответы вызовов, команды автоматизации) идут каналом событий ([BgEventPipe]).
object BgEvents {
    // Extras запуска `MainActivity` из уведомлений `:bg` (тап по «Sign-in
    // required» и по уведомлению Taildrop): тег узла.
    const val EXTRA_LAUNCH_OPENCONNECT_TAG = "openconnect_tag"
    const val EXTRA_LAUNCH_TAILDROP_TAG = "taildrop_tag"

    // Метка порядка и поля снимка туннеля в `BROADCAST_STATUS`.
    const val EXTRA_EPOCH = "ts_epoch"
    const val EXTRA_SEQ = "ts_seq"
    const val EXTRA_STARTED_ELAPSED_MS = "started_elapsed_ms"
    const val EXTRA_SESSION_ALLOW_BYPASS = "session_allow_bypass"

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
