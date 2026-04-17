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

        @Suppress("OPT_IN_USAGE")
        GlobalScope.launch(Dispatchers.IO) {
            initializeLibbox(application)
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
        Libbox.redirectStderr(File(workingDir, "stderr.log").path)
    }
}
