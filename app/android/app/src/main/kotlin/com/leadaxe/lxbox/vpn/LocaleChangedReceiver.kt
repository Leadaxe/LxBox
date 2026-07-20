package com.leadaxe.lxbox.vpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/// §279 Phase 6 (спека §6.3) — manifest-receiver на ACTION_LOCALE_CHANGED.
///
/// При `app_language == "system"` смена языка устройства (или per-app смена в
/// системных Settings на 33+) обязана перештамповать нативные поверхности,
/// даже когда Flutter-движок мёртв (сервис живёт без UI): канал, шторка,
/// shortcuts, тайл, локаль ядра — те же шаги 1–5, что у setAppLanguage-handler.
/// Dart-сторона той же смены — LocaleController.didChangeLocales (§7.2).
///
/// При явном выборе ("en"/"ru") — no-op: поверхности уже рендерятся через
/// L10n.ctx с явной локалью, смена системного языка их не касается.
class LocaleChangedReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "LocaleChangedReceiver"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_LOCALE_CHANGED) return
        if (L10n.setting(context) != L10n.SETTING_SYSTEM) return
        Log.d(TAG, "system locale changed → refresh native surfaces")
        runCatching { L10n.refreshSurfaces(context.applicationContext) }
            .onFailure { Log.w(TAG, "refreshSurfaces failed: ${it.message}") }
    }
}
