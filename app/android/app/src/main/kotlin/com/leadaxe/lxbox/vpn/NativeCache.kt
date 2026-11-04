package com.leadaxe.lxbox.vpn

import android.content.Context
import android.content.SharedPreferences

/// Внутренний кэш Kotlin: то, что Kotlin выбрал или запомнил сам и чего
/// пользователь не настраивал (последний получатель окна Send, предохранитель
/// sticky-рестартов, зеркало запушенной локали). Пишет и читает только Kotlin,
/// Dart о нём не знает, в бэкап не идёт; пустой или битый файл = пустой кэш.
/// Настройки сюда не кладутся — их место `lxbox_settings.json` и зеркало
/// `boxvpn_boot` (ARCHITECTURE.md → «Persistent storage»). §707 итер. 9.
object NativeCache {
    private const val PREF_NAME = "lxbox_native_cache"

    private const val KEY_CLIP_TAG = "clip_tag"
    private const val KEY_CLIP_PEER = "clip_peer"
    private const val KEY_CLIP_NAME = "clip_name"
    private const val KEY_VPN_DESIRED = "vpn_desired"
    private const val KEY_STICKY_RESTART_COUNT = "sticky_restart_count"
    private const val KEY_STICKY_RESTART_WINDOW_START = "sticky_restart_window_start"
    private const val KEY_LAST_PUSHED_LOCALE = "last_pushed_locale"
    private const val KEY_SHORTCUT_RELABEL_PENDING = "shortcut_relabel_pending"

    /// Ключи состояния, которые до итерации 9 лежали в зеркале `boxvpn_boot`.
    /// Состояние одного запуска: не переносятся, а удаляются оттуда один раз.
    private val LEGACY_BOOT_KEYS = listOf(
        KEY_VPN_DESIRED,
        KEY_STICKY_RESTART_COUNT,
        KEY_STICKY_RESTART_WINDOW_START,
        KEY_LAST_PUSHED_LOCALE,
        KEY_SHORTCUT_RELABEL_PENDING,
    )

    @Volatile private var legacyDropped = false

    private fun prefs(ctx: Context): SharedPreferences {
        val app = ctx.applicationContext ?: ctx
        if (!legacyDropped) dropLegacyBootKeys(app)
        return app.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
    }

    @Synchronized
    private fun dropLegacyBootKeys(app: Context) {
        if (legacyDropped) return
        val boot = BootReceiver.prefs(app)
        if (LEGACY_BOOT_KEYS.any { boot.contains(it) }) {
            val e = boot.edit()
            for (k in LEGACY_BOOT_KEYS) e.remove(k)
            e.apply()
        }
        legacyDropped = true
    }

    // ─────────────── последний получатель окна Send ───────────────

    /// (тег, ID, имя) или `null`.
    fun clipTarget(ctx: Context): Triple<String, String, String>? {
        val p = prefs(ctx)
        val tag = p.getString(KEY_CLIP_TAG, null) ?: return null
        val peer = p.getString(KEY_CLIP_PEER, null) ?: return null
        return Triple(tag, peer, p.getString(KEY_CLIP_NAME, "") ?: "")
    }

    fun setClipTarget(ctx: Context, tag: String, peerId: String, name: String) {
        prefs(ctx).edit()
            .putString(KEY_CLIP_TAG, tag)
            .putString(KEY_CLIP_PEER, peerId)
            .putString(KEY_CLIP_NAME, name)
            .apply()
    }

    // ─────────────── §428 «туннель желателен» и sticky-рестарты ───────────────

    fun isVpnDesired(ctx: Context): Boolean = prefs(ctx).getBoolean(KEY_VPN_DESIRED, false)

    fun setVpnDesired(ctx: Context, desired: Boolean) {
        prefs(ctx).edit().putBoolean(KEY_VPN_DESIRED, desired).apply()
    }

    fun stickyRestartCount(ctx: Context): Int = prefs(ctx).getInt(KEY_STICKY_RESTART_COUNT, 0)

    fun stickyRestartWindowStart(ctx: Context): Long =
        prefs(ctx).getLong(KEY_STICKY_RESTART_WINDOW_START, 0L)

    fun setStickyRestarts(ctx: Context, count: Int, windowStart: Long) {
        prefs(ctx).edit()
            .putInt(KEY_STICKY_RESTART_COUNT, count)
            .putLong(KEY_STICKY_RESTART_WINDOW_START, windowStart)
            .apply()
    }

    fun resetStickyRestarts(ctx: Context) {
        prefs(ctx).edit()
            .remove(KEY_STICKY_RESTART_COUNT)
            .remove(KEY_STICKY_RESTART_WINDOW_START)
            .apply()
    }

    // ─────────────── §279 локаль и ярлыки ───────────────

    /// `null` = ещё не пушили.
    fun lastPushedLocale(ctx: Context): String? = prefs(ctx).getString(KEY_LAST_PUSHED_LOCALE, null)

    fun setLastPushedLocale(ctx: Context, value: String) {
        prefs(ctx).edit().putString(KEY_LAST_PUSHED_LOCALE, value).apply()
    }

    fun isShortcutRelabelPending(ctx: Context): Boolean =
        prefs(ctx).getBoolean(KEY_SHORTCUT_RELABEL_PENDING, false)

    fun setShortcutRelabelPending(ctx: Context, pending: Boolean) {
        prefs(ctx).edit().putBoolean(KEY_SHORTCUT_RELABEL_PENDING, pending).apply()
    }
}
