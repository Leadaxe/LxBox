package com.leadaxe.lxbox.vpn

import android.app.NotificationManager
import android.content.Context
import android.net.ConnectivityManager
import android.net.wifi.WifiManager
import android.os.PowerManager
import go.Seq
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.SetupOptions
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.launch
import java.io.File
import java.util.Locale

object BoxApplication {
    lateinit var application: Context
        private set

    val powerManager: PowerManager by lazy {
        application.getSystemService(Context.POWER_SERVICE) as PowerManager
    }

    val connectivity: ConnectivityManager by lazy {
        application.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    }

    val packageManager by lazy { application.packageManager }

    val notificationManager: NotificationManager by lazy {
        application.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    }

    /// §049 F12.3 fix: WifiManager для readWIFIState. Использует Application
    /// context (а не Activity) — иначе на API >= R может выкидывать
    /// `IllegalStateException` при getSystemService с non-Activity context'ом
    /// (см. https://developer.android.com/reference/android/net/wifi/WifiManager).
    /// applicationContext безопасен.
    val wifiManager: WifiManager by lazy {
        application.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    }

    private var initialized = false

    /// Сигналит готовность `Libbox.setup` + `Libbox.redirectStderr`.
    /// `BoxVpnService.startSingbox` обязан `await` этого до любого
    /// обращения к libbox-классам — иначе на медленных Android'ах
    /// нативный crash в JNI без stderr-записи.
    val libboxReady: CompletableDeferred<Unit> = CompletableDeferred()

    fun initialize(context: Context) {
        if (initialized) return
        initialized = true
        application = context.applicationContext
        Seq.setContext(application)

        // §049 F9 fix: Libbox.setLocale обязательно ПЕРЕД setup'ом — иначе
        // sing-box error messages не локализованы. Reference
        // (`Application.kt:42`) делает то же. Формат `xx_YY` (с подчёркиванием),
        // а не BCP-47 `xx-YY`.
        runCatching {
            Libbox.setLocale(Locale.getDefault().toLanguageTag().replace("-", "_"))
        }.onFailure { android.util.Log.w("BoxApplication", "Libbox.setLocale failed: ${it.message}") }

        // Quick Connect-побочка опциональна — из BoxVpnService.onCreate
        // тоже сюда заходим, любой сбой здесь не должен валить сервис.
        runCatching { QuickShortcuts.refresh(application) }
            .onFailure { android.util.Log.w("BoxApplication", "QuickShortcuts.refresh failed: ${it.message}") }

        @Suppress("OPT_IN_USAGE")
        GlobalScope.launch(Dispatchers.IO) {
            try {
                initializeLibbox(application)
                libboxReady.complete(Unit)
            } catch (t: Throwable) {
                android.util.Log.e("BoxApplication", "initializeLibbox failed", t)
                libboxReady.completeExceptionally(t)
            }
        }
    }

    private fun initializeLibbox(context: Context) {
        // libbox пишет cache.db / stderr.log / transient state в internal
        // `filesDir` — там же где SettingsStorage, ConfigManager и SRS-кэш.
        // Не external (Scoped Storage / Knox-SELinux могут его блокировать).
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
            // §043: forwarding sing-box логов в наш PlatformInterface
            // callback writeDebugMessage. `daemon/started_service.go:1048-1050`
            // gates `s.handler.WriteDebugMessage(message)` за `if s.debug` —
            // без флага наш callback никогда не зовётся, AppLog не получает
            // core логи. Default false (volume reduction). Юзер opt-in'ит
            // через UI toggle (App Settings или DebugScreen) — изменение
            // применяется только после restart Service'а (Libbox.setup
            // вызывается один раз).
            debug = BootReceiver.isCoreLogsEnabled(context)
        }
        Libbox.setup(opts)
        // redirectStderr может отсутствовать в старых сборках libbox или
        // упасть на ограничениях SELinux отдельных OEM-устройств. Терпимо.
        runCatching { Libbox.redirectStderr(File(workingDir, "stderr.log").path) }
            .onFailure { android.util.Log.w("BoxApplication", "redirectStderr failed: ${it.message}") }
    }
}
