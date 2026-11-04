package com.leadaxe.lxbox.vpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class BootReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "BootReceiver"
        private const val PREF_NAME = "boxvpn_boot"
        private const val KEY_AUTO_START = "auto_start_vpn"
        private const val KEY_KEEP_ON_EXIT = "keep_vpn_on_exit"
        private const val KEY_BACKGROUND_MODE = "background_mode"
        /// §043: forwarding sing-box логов в Flutter EventChannel (см.
        /// `BoxApplication.initialize` где `SetupOptions.debug = ...`
        /// читается из этой prefs). Default false — opt-in для диагностики.
        /// Изменение применяется только после restart Service'а
        /// (Libbox.setup вызывается один раз).
        private const val KEY_CORE_LOGS = "core_logs_enabled"
        // §345 — live-переключаемый verbose (снятие TRACE/DEBUG-фильтра)
        private const val KEY_CORE_LOGS_VERBOSE = "core_logs_verbose"

        /// §049 F15 fix: разрешать app'ам обходить tun (Android `Builder.allowBypass()`).
        /// Default false — без bypass'а весь трафик уходит в tun (наша цель —
        /// strict tunnel). С bypass = true — app может явно через
        /// `ConnectivityManager.bindProcessToNetwork(network)` обойти VPN.
        /// Для большинства юзеров не нужно; opt-in для разработчиков.
        private const val KEY_ALLOW_BYPASS = "allow_bypass"

        /// §124 — root-only tproxy через nftables/iptables (`auto_redirect` в
        /// sing-tun). Работает ТОЛЬКО на рутированном Android (`redirect_linux.go`
        /// требует `su` + `/system/bin/iptables`); на не-root ядро вернёт ошибку.
        /// Default false. Проброс заведён (helper `BoxService.buildOverrideOptions`
        /// читает getter), UI-тоггла пока НЕТ — выставить можно через prefs/adb;
        /// полноценный UI + `auto_route` — отдельная таска.
        private const val KEY_AUTO_REDIRECT = "auto_redirect"

        /// §192 — есть ли TUN-inbound в текущем конфиге (производное от §119
        /// vpn_mode: vpn/vpn_proxy → true, proxy → false). Зеркало из Dart
        /// (§189 native_prefs). Гейтит `VpnService.prepare()`: в proxy-режиме
        /// (port-only, без TUN) prepare НЕ нужен и его вызов ЗРЯ забирает
        /// системный VPN-слот → отзывает чужой активный VPN (onRevoke).
        /// Default TRUE — безопасно: если ключа ещё нет (старый юзер / до
        /// первого sync), ведём себя как раньше (prepare вызывается, vpn-режим
        /// не ломается). proxy-фикс активируется только при явном has_tun=false.
        private const val KEY_HAS_TUN = "has_tun"

        /// §271/§705 — memory limit ядра (SetupOptions.oomMemoryLimit). Wire-значения:
        /// "auto" (без порога, oom-killer в Available-режиме), legacy "off" (то же,
        /// принимается на чтении), либо число мегабайт строкой ("200"/"384"/"512"/"768")
        /// — порог по RSS всего процесса. Default "auto".
        /// Разрешение в байты — BoxApplication.resolveMemoryLimitBytes.
        private const val KEY_MEMORY_LIMIT = "memory_limit"

        const val MEMORY_LIMIT_AUTO = "auto"
        const val MEMORY_LIMIT_OFF = "off"

        /// §279 — язык приложения ("system" | "en" | "ru"). Derived cache от
        /// var `app_language` в lxbox_settings.json (истина — Dart-сторадж,
        /// спека 279 §6.5): пишется MethodChannel-handler'ом setAppLanguage и
        /// пере-пушится bootstrapAndSyncNativePrefs на каждом старте. Читается
        /// L10n.ctx в момент рендера нативных поверхностей (без Flutter).
        private const val KEY_APP_LANGUAGE = "app_language"

        /// §707 итер. 9 — производные множества итоговых тегов узлов с галками
        /// Taildrop (`taildrop_commands` / `taildrop_autosave` записи узла).
        /// Зеркало из Dart (§189), заменяется целиком каналом setTaildropTags.
        private const val KEY_TAILDROP_COMMANDS_TAGS = "taildrop_commands_tags"
        private const val KEY_TAILDROP_AUTOSAVE_TAGS = "taildrop_autosave_tags"

        /// §707 итер. 9 — кнопки уведомления VPN (native_prefs), дефолт true.
        private const val KEY_NOTIFICATION_STOP = "notification_stop"
        private const val KEY_NOTIFICATION_RESTART = "notification_restart"
        private const val KEY_NOTIFICATION_SEND = "notification_send"

        /// §428 — окно предохранителя от шторма `START_STICKY`-рестартов.
        /// Счётчик, начало окна и «туннель желателен» — в [NativeCache].
        const val STICKY_RESTART_WINDOW_MS = 5 * 60 * 1000L
        const val STICKY_RESTART_LIMIT = 3

        /// Три режима фоновой работы tunnel'а. По умолчанию "never" — максимум
        /// стабильности, минимум экономии батареи. VPN-пользователи обычно
        /// выбирают надёжность (пуши, длинные TCP-сокеты), поэтому default
        /// именно такой.
        /// - "never": pause/wake не вызывается никогда, tunnel всегда активен
        /// - "lazy": pause при deep Doze (текущее поведение sing-box-android)
        /// - "always": pause при screen off (максимум экономии)
        const val BG_MODE_NEVER = "never"
        const val BG_MODE_LAZY = "lazy"
        const val BG_MODE_ALWAYS = "always"

        /// §279 — см. KEY_APP_LANGUAGE. Писать только через L10n.applySetting
        /// (pref + LocaleManager + relabel поверхностей одним путём).
        fun setAppLanguage(context: Context, value: String) {
            context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .edit().putString(KEY_APP_LANGUAGE, value).apply()
        }

        fun getAppLanguage(context: Context): String {
            return context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .getString(KEY_APP_LANGUAGE, "system") ?: "system"
        }

        /// Зеркало `boxvpn_boot` — для NativeCache (одноразовая чистка ключей
        /// состояния, переехавших в кэш).
        internal fun prefs(context: Context) =
            context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)

        /// §279 — последнее значение, которое МЫ запушили в LocaleManager (33+):
        /// "" = пустой список (system), "en"/"ru" — явный выбор; null = ещё не
        /// пушили. Нужен трёхстороннему reconciliation на Dart-старте (спека 279
        /// §6.4). Хранится в [NativeCache].
        fun setLastPushedLocale(context: Context, value: String) {
            NativeCache.setLastPushedLocale(context, value)
        }

        fun getLastPushedLocale(context: Context): String? = NativeCache.lastPushedLocale(context)

        /// §279 — updateShortcuts отработал под rate-limit (locale-change в
        /// background) → гарантированный retry из MainActivity.onResume.
        /// Хранится в [NativeCache].
        fun setShortcutRelabelPending(context: Context, pending: Boolean) {
            NativeCache.setShortcutRelabelPending(context, pending)
        }

        /// §428 — зафиксировать sticky-рестарт; возвращает номер рестарта в
        /// текущем окне (1 = первый). Окно старше STICKY_RESTART_WINDOW_MS
        /// открывается заново. Сбрасывается успешным `Started`.
        fun noteStickyRestart(context: Context, now: Long = System.currentTimeMillis()): Int {
            val windowStart = NativeCache.stickyRestartWindowStart(context)
            val inWindow = windowStart > 0L && now - windowStart < STICKY_RESTART_WINDOW_MS
            val count = if (inWindow) NativeCache.stickyRestartCount(context) + 1 else 1
            NativeCache.setStickyRestarts(context, count, if (inWindow) windowStart else now)
            return count
        }

        /// §428 — «туннель желателен»: true с момента Started до явного
        /// setStatus(Stopped). Читает VpnWatchdogReceiver в свежем процессе.
        fun setVpnDesired(context: Context, desired: Boolean) {
            NativeCache.setVpnDesired(context, desired)
        }

        fun isVpnDesired(context: Context): Boolean = NativeCache.isVpnDesired(context)

        fun resetStickyRestarts(context: Context) {
            NativeCache.resetStickyRestarts(context)
        }

        fun isShortcutRelabelPending(context: Context): Boolean =
            NativeCache.isShortcutRelabelPending(context)

        /// §707 итер. 9 — заменить оба множества целиком. Возвращает `true`,
        /// если в autosave-множестве появился тег, которого не было.
        fun setTaildropTags(context: Context, commands: Collection<String>, autosave: Collection<String>): Boolean {
            val before = taildropAutosaveTags(context)
            val newAutosave = autosave.toSet()
            context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE).edit()
                .putStringSet(KEY_TAILDROP_COMMANDS_TAGS, commands.toSet())
                .putStringSet(KEY_TAILDROP_AUTOSAVE_TAGS, newAutosave)
                .apply()
            return !before.containsAll(newAutosave)
        }

        /// Копия: множество из getStringSet менять нельзя.
        fun taildropCommandsTags(context: Context): Set<String> =
            context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .getStringSet(KEY_TAILDROP_COMMANDS_TAGS, null)?.toSet() ?: emptySet()

        fun taildropAutosaveTags(context: Context): Set<String> =
            context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .getStringSet(KEY_TAILDROP_AUTOSAVE_TAGS, null)?.toSet() ?: emptySet()

        /// §707 итер. 9 — кнопки уведомления VPN, зеркало native_prefs.
        /// Default true. После записи уведомление обновляет вызывающий.
        fun setNotificationStop(context: Context, enabled: Boolean) {
            context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .edit().putBoolean(KEY_NOTIFICATION_STOP, enabled).apply()
        }

        fun isNotificationStop(context: Context): Boolean {
            return context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .getBoolean(KEY_NOTIFICATION_STOP, true)
        }

        fun setNotificationRestart(context: Context, enabled: Boolean) {
            context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .edit().putBoolean(KEY_NOTIFICATION_RESTART, enabled).apply()
        }

        fun isNotificationRestart(context: Context): Boolean {
            return context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .getBoolean(KEY_NOTIFICATION_RESTART, true)
        }

        fun setNotificationSend(context: Context, enabled: Boolean) {
            context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .edit().putBoolean(KEY_NOTIFICATION_SEND, enabled).apply()
        }

        fun isNotificationSend(context: Context): Boolean {
            return context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .getBoolean(KEY_NOTIFICATION_SEND, true)
        }

        fun setMemoryLimit(context: Context, value: String) {
            context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .edit().putString(KEY_MEMORY_LIMIT, value).apply()
        }

        fun getMemoryLimit(context: Context): String {
            return context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .getString(KEY_MEMORY_LIMIT, MEMORY_LIMIT_AUTO) ?: MEMORY_LIMIT_AUTO
        }

        fun setBackgroundMode(context: Context, mode: String) {
            context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .edit().putString(KEY_BACKGROUND_MODE, mode).apply()
        }

        fun getBackgroundMode(context: Context): String {
            return context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .getString(KEY_BACKGROUND_MODE, BG_MODE_NEVER) ?: BG_MODE_NEVER
        }

        fun setEnabled(context: Context, enabled: Boolean) {
            context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .edit().putBoolean(KEY_AUTO_START, enabled).apply()
        }

        fun isEnabled(context: Context): Boolean {
            return context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .getBoolean(KEY_AUTO_START, false)
        }

        fun setKeepOnExit(context: Context, enabled: Boolean) {
            context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .edit().putBoolean(KEY_KEEP_ON_EXIT, enabled).apply()
        }

        fun isKeepOnExit(context: Context): Boolean {
            // §188 — дефолт ON (было false). keep-alive ожидаем пользователями
            // (VPN живёт при закрытии). Затрагивает существующих без явного ключа.
            return context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .getBoolean(KEY_KEEP_ON_EXIT, true)
        }

        /// §043: forwarding sing-box логов в наш PlatformInterface.writeDebugMessage
        /// callback. Read by `BoxApplication.initialize` для `SetupOptions.debug`.
        /// Default false — opt-in для диагностики (сотни строк/мин на busy traffic).
        fun setCoreLogsEnabled(context: Context, enabled: Boolean) {
            context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .edit().putBoolean(KEY_CORE_LOGS, enabled).apply()
        }

        fun isCoreLogsEnabled(context: Context): Boolean {
            return context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .getBoolean(KEY_CORE_LOGS, false)
        }

        /// §345: verbose-режим core-логов — снимает TRACE/DEBUG-фильтр в
        /// `BoxService.writeDebugMessage`. Применяется на лету (volatile в
        /// BoxService), здесь — только persist для переживания рестарта.
        fun setCoreLogsVerbose(context: Context, enabled: Boolean) {
            context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .edit().putBoolean(KEY_CORE_LOGS_VERBOSE, enabled).apply()
        }

        fun isCoreLogsVerbose(context: Context): Boolean {
            return context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .getBoolean(KEY_CORE_LOGS_VERBOSE, false)
        }

        /// §049 F15 fix: opt-in toggle для VPN bypass. Reference (`Settings.allowBypass`).
        /// Default false — strict tunnel.
        fun setAllowBypass(context: Context, enabled: Boolean) {
            context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .edit().putBoolean(KEY_ALLOW_BYPASS, enabled).apply()
        }

        fun isAllowBypass(context: Context): Boolean {
            return context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .getBoolean(KEY_ALLOW_BYPASS, false)
        }

        /// §124 — см. KEY_AUTO_REDIRECT. Default false (strict / не-root безопасно).
        fun setAutoRedirect(context: Context, enabled: Boolean) {
            context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .edit().putBoolean(KEY_AUTO_REDIRECT, enabled).apply()
        }

        fun isAutoRedirect(context: Context): Boolean {
            return context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .getBoolean(KEY_AUTO_REDIRECT, false)
        }

        /// §192 — зеркало has_tun из Dart (§189). Default true (см. KEY_HAS_TUN).
        fun setHasTun(context: Context, enabled: Boolean) {
            context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .edit().putBoolean(KEY_HAS_TUN, enabled).apply()
        }

        fun hasTun(context: Context): Boolean {
            return context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .getBoolean(KEY_HAS_TUN, true)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        if (!isEnabled(context)) return

        Log.d(TAG, "Boot completed — auto-starting VPN")
        BoxApplication.initialize(context)
        BoxVpnService.start(context)
    }
}
