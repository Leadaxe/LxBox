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
            VpnStatus.Stopped -> list += buildConnect(ctx)
            VpnStatus.Started -> list += buildDisconnect(ctx)
            VpnStatus.Starting, VpnStatus.Stopping -> {
                list += buildConnect(ctx)
                list += buildDisconnect(ctx)
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

    private fun buildConnect(ctx: Context): ShortcutInfo = build(
        ctx, ID_CONNECT,
        L10n.str(ctx, R.string.qc_connect_label),
        MainActivity.ACTION_CONNECT,
    )

    private fun buildDisconnect(ctx: Context): ShortcutInfo = build(
        ctx, ID_DISCONNECT,
        L10n.str(ctx, R.string.qc_disconnect_label),
        MainActivity.ACTION_DISCONNECT,
    )

    /// §279 (спека §6.3, шаг 3) — relabel при смене языка. НЕ doRefresh:
    /// status-зависимый набор публикует только часть ярлыков (Stopped — один
    /// Connect), а pinned-копия второго осталась бы на старом языке навсегда.
    /// `updateShortcuts` — документированный API label-refresh'а: обновляет
    /// существующие dynamic И pinned по id, несуществующие id игнорирует
    /// (состав не меняется). Rate-limit (locale-change исполняется в
    /// background) → флаг pending, гарантированный retry из
    /// MainActivity.onResume (foreground — rate-limit не применяется).
    fun relabel(ctx: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        try {
            val sm = ctx.getSystemService(ShortcutManager::class.java) ?: return
            val both = listOf(buildConnect(ctx), buildDisconnect(ctx))
            val ok = try {
                sm.updateShortcuts(both)
            } catch (e: IllegalStateException) {
                Log.w(TAG, "updateShortcuts rate-limited: ${e.message}")
                false
            }
            BootReceiver.setShortcutRelabelPending(ctx, !ok)
        } catch (t: Throwable) {
            Log.w(TAG, "relabel failed: ${t.message}")
            BootReceiver.setShortcutRelabelPending(ctx, true)
        }
    }

    /// §279 — retry отложенного relabel'а (см. [relabel]) из foreground.
    fun retryPendingRelabel(ctx: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        try {
            if (!BootReceiver.isShortcutRelabelPending(ctx)) return
            relabel(ctx)
        } catch (t: Throwable) {
            Log.w(TAG, "retryPendingRelabel failed: ${t.message}")
        }
    }

    private fun build(ctx: Context, id: String, label: String, action: String): ShortcutInfo {
        // §032 polish: разные цветные adaptive-иконки на Connect / Disconnect
        // (зелёный ▶ / красный ■). Launcher не тонирует bitmap-фронт adaptive-
        // icon'а в свою тему — цвета остаются. Fallback drawable
        // ic_lxbox_tile (monochrome shield) — на случай неизвестного action,
        // не должно реально срабатывать.
        val iconRes = when (action) {
            MainActivity.ACTION_CONNECT -> R.mipmap.ic_qc_connect
            MainActivity.ACTION_DISCONNECT -> R.mipmap.ic_qc_disconnect
            else -> R.drawable.ic_lxbox_tile
        }
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
            .setIcon(Icon.createWithResource(ctx, iconRes))
            .setIntent(intent)
            .build()
    }
}
