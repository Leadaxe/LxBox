package com.leadaxe.lxbox.vpn

import android.app.Application
import android.app.NotificationManager
import android.content.Context
import android.net.ConnectivityManager
import android.net.wifi.WifiManager
import android.os.PowerManager
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.SetupOptions
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.launch
import java.io.File
import java.util.Locale

/**
 * §049 — Application class зарегистрирован в AndroidManifest как
 * `android:name=".vpn.BoxApplication"`. Mirror reference SagerNet
 * (commit 3b3883e libbox 1.13.11). Android создаёт Application до
 * любого Service / Activity → `Libbox.setup` гарантированно отрабатывает
 * до первого `CommandServer(...)` ctor'а.
 *
 * `Seq.setContext(this)` намеренно не вызываем (см. reference
 * `Application.kt:41` — закомментирован). Native libbox init сам
 * устанавливает context при загрузке `.so`; явный вызов делает
 * двойной-set ломающий `Seq$RefTracker` state.
 */
class BoxApplication : Application() {

    override fun onCreate() {
        super.onCreate()
        instance = this

        // Reference 1.13.11 (Application.kt:41) закомментировал:
//        Seq.setContext(this)

        // setLocale обязательно ДО Libbox.setup'а — иначе sing-box error
        // messages не локализованы. Формат `xx_YY` (с подчёркиванием).
        Libbox.setLocale(Locale.getDefault().toLanguageTag().replace("-", "_"))

        runCatching { QuickShortcuts.refresh(this) }
            .onFailure { android.util.Log.w(TAG, "QuickShortcuts.refresh failed: ${it.message}") }

        // libbox setup async в IO. К моменту start VPN setup завершён.
        // `libboxReady` — sync-барьер для VPN auto-start / QS-tile сразу
        // после boot (там race возможна).
        @Suppress("OPT_IN_USAGE")
        GlobalScope.launch(Dispatchers.IO) {
            try {
                initializeLibbox(this@BoxApplication)
                libboxReady.complete(Unit)
            } catch (t: Throwable) {
                android.util.Log.e(TAG, "initializeLibbox failed", t)
                libboxReady.completeExceptionally(t)
            }
        }
    }

    private fun initializeLibbox(context: Context) {
        val baseDir = context.filesDir.also { it.mkdirs() }
        val workingDir = baseDir
        val tempDir = context.cacheDir.also { it.mkdirs() }

        val fixAndroidStack =
            android.os.Build.VERSION.SDK_INT in android.os.Build.VERSION_CODES.N..android.os.Build.VERSION_CODES.N_MR1 ||
                    android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P

        val opts = SetupOptions().apply {
            basePath = baseDir.path
            workingPath = workingDir.path
            tempPath = tempDir.path
            this.fixAndroidStack = fixAndroidStack
            // Match reference: limit sing-box log buffer (без него unbounded
            // accumulation → memory pressure → потенциально refnum race).
            logMaxLines = 3000
            // §043: forwarding sing-box логов в `writeDebugMessage`.
            // `daemon/started_service.go:1048-1050` gates за `if s.debug`.
            debug = BootReceiver.isCoreLogsEnabled(context)
        }
        Libbox.setup(opts)
        // redirectStderr — best-effort: старые libbox или SELinux OEM могут
        // блокировать.
        runCatching { Libbox.redirectStderr(File(workingDir, "stderr.log").path) }
            .onFailure { android.util.Log.w(TAG, "redirectStderr failed: ${it.message}") }
    }

    companion object {
        private const val TAG = "BoxApplication"

        // `lateinit var ... private set` не работает в Kotlin companion —
        // setter недоступен из enclosing class. internal видимости хватает.
        @Volatile
        internal lateinit var instance: BoxApplication

        /** Готовность `Libbox.setup` + `Libbox.redirectStderr`. */
        val libboxReady: CompletableDeferred<Unit> = CompletableDeferred()

        // -------------------------------------------------------------------
        // Backward-compat API — callsite'ы `BoxApplication.X` работают через
        // companion proxy на `instance`.
        // -------------------------------------------------------------------

        val application: Context get() = instance

        val powerManager: PowerManager
            get() = instance.getSystemService(Context.POWER_SERVICE) as PowerManager

        val connectivity: ConnectivityManager
            get() = instance.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

        val packageManager get() = instance.packageManager

        val notificationManager: NotificationManager
            get() = instance.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        /**
         * §049 F12.3: WifiManager через application context — на API >= R
         * Activity context может выкидывать `IllegalStateException`.
         */
        val wifiManager: WifiManager
            get() = instance.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager

        /**
         * No-op — оставлено для backward compat. Application class
         * инициализируется Android runtime'ом до Service/Activity, так что
         * вызовы `BoxApplication.initialize(...)` из BoxService.onCreate /
         * MainActivity / BootReceiver безопасно компилируются и ничего
         * не делают.
         */
        @Suppress("UNUSED_PARAMETER")
        fun initialize(context: Context) {
            // No-op
        }
    }
}
