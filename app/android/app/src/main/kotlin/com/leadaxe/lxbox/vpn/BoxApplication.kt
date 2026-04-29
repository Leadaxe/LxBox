package com.leadaxe.lxbox.vpn

import android.app.NotificationManager
import android.content.Context
import android.net.ConnectivityManager
import android.os.PowerManager
import go.Seq
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.SetupOptions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.launch
import java.io.File

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

    private var initialized = false

    fun initialize(context: Context) {
        if (initialized) return
        initialized = true
        application = context.applicationContext
        Seq.setContext(application)

        // Quick Connect-побочка: dynamic launcher shortcuts. Полностью
        // опционально, любой сбой не должен валить старт приложения /
        // сервиса — из VpnService.onCreate тоже сюда заходим.
        runCatching { QuickShortcuts.refresh(application) }
            .onFailure { android.util.Log.w("BoxApplication", "QuickShortcuts.refresh failed: ${it.message}") }

        @Suppress("OPT_IN_USAGE")
        GlobalScope.launch(Dispatchers.IO) {
            try {
                initializeLibbox(application)
            } catch (t: Throwable) {
                // Defensive: если libbox setup упал — лучше залогировать и
                // продолжить без него, чем убить весь процесс с unhandled
                // в фоне. startSingbox всё равно увидит проблему отдельно.
                android.util.Log.e("BoxApplication", "initializeLibbox failed", t)
            }
        }
    }

    private fun initializeLibbox(context: Context) {
        val baseDir = context.filesDir.also { it.mkdirs() }
        val workingDir = context.getExternalFilesDir(null) ?: return
        workingDir.mkdirs()
        val tempDir = context.cacheDir.also { it.mkdirs() }

        val fixAndroidStack =
            android.os.Build.VERSION.SDK_INT in android.os.Build.VERSION_CODES.N..android.os.Build.VERSION_CODES.N_MR1 ||
                    android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P

        val opts = SetupOptions().apply {
            basePath = baseDir.path
            workingPath = workingDir.path
            tempPath = tempDir.path
            this.fixAndroidStack = fixAndroidStack
        }
        Libbox.setup(opts)
        // redirectStderr может отсутствовать в старых сборках libbox или
        // упасть на ограничениях SELinux отдельных OEM-устройств. Терпимо.
        runCatching { Libbox.redirectStderr(File(workingDir, "stderr.log").path) }
            .onFailure { android.util.Log.w("BoxApplication", "redirectStderr failed: ${it.message}") }
    }
}
