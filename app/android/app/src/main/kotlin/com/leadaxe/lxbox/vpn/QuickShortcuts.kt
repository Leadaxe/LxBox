package com.leadaxe.lxbox.vpn

import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.os.Build
import android.util.Log
import com.leadaxe.lxbox.MainActivity
import com.leadaxe.lxbox.R

/// Long-press menu shortcuts on the launcher icon.
///
/// Не статические в `res/xml/shortcuts.xml`, а динамические через
/// `ShortcutManager.dynamicShortcuts` — обновляются каждый раз когда
/// `BoxVpnService.setStatus` отдаёт новое состояние:
///
///   Stopped       → 1 пункт «Connect»
///   Started       → 1 пункт «Disconnect»
///   Starting/Stopping → оба пункта (даём юзеру и cancel-старт, и форс-стоп)
///
/// Init-точка — `BoxApplication.initialize` (любой запуск процесса) +
/// каждый `setStatus`. Quick Connect — фича primary-tier (Android 11+,
/// API 30+); на best-effort устройствах 8-10 это no-op чтобы не рисковать
/// API/OEM-несовместимостями.
object QuickShortcuts {
    private const val TAG = "QuickShortcuts"

    private const val ID_CONNECT = "qc_connect"
    private const val ID_DISCONNECT = "qc_disconnect"

    fun refresh(ctx: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        try {
            doRefresh(ctx)
        } catch (t: Throwable) {
            // Throwable — ловим и Error (NoClassDefFoundError, VerifyError).
            Log.w(TAG, "refresh failed: ${t.message}")
        }
    }

    private fun doRefresh(ctx: Context) {
        val sm = ctx.getSystemService(ShortcutManager::class.java) ?: return

        val list = mutableListOf<ShortcutInfo>()
        when (BoxVpnService.currentStatus) {
            VpnStatus.Stopped -> list += build(ctx, ID_CONNECT, "Connect", MainActivity.ACTION_CONNECT)
            VpnStatus.Started -> list += build(ctx, ID_DISCONNECT, "Disconnect", MainActivity.ACTION_DISCONNECT)
            VpnStatus.Starting, VpnStatus.Stopping -> {
                list += build(ctx, ID_CONNECT, "Connect", MainActivity.ACTION_CONNECT)
                list += build(ctx, ID_DISCONNECT, "Disconnect", MainActivity.ACTION_DISCONNECT)
            }
        }
        try {
            sm.dynamicShortcuts = list
        } catch (e: IllegalStateException) {
            // Rate-limited (system reset on launcher start). На следующий
            // setStatus всё равно повторим — некритично.
            Log.w(TAG, "dynamicShortcuts rate-limited: ${e.message}")
        }
    }

    private fun build(ctx: Context, id: String, label: String, action: String): ShortcutInfo {
        val intent = Intent(ctx, MainActivity::class.java).apply {
            this.action = Intent.ACTION_MAIN
            putExtra(MainActivity.EXTRA_ACTION, action)
            // Каждый shortcut — самостоятельный launch. SINGLE_TOP +
            // CLEAR_TOP избегают наложения старого taskState'а.
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        return ShortcutInfo.Builder(ctx, id)
            .setShortLabel(label)
            .setLongLabel(label)
            .setIcon(Icon.createWithResource(ctx, R.drawable.ic_lxbox_tile))
            .setIntent(intent)
            .build()
    }
}
