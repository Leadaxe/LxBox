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
        //
        // libbox 1.14: setLocale стал СТРОГИМ — golang.org/x/text/language
        // бросает `unsupported locale` на нераспознанной комбинации язык+регион
        // (напр. `ru_IL` = русский на устройстве с регионом Израиль). В 1.13.13
        // это глоталось. Без catch → краш в onCreate ДО старта ядра, приложение
        // не запускается вовсе. Локаль влияет лишь на язык error-строк ядра —
        // fail-safe: при отказе пробуем голый язык (`ru`), затем молча
        // пропускаем (ядро возьмёт дефолтную локаль).
        runCatching {
            Libbox.setLocale(Locale.getDefault().toLanguageTag().replace("-", "_"))
        }.recoverCatching {
            Libbox.setLocale(Locale.getDefault().language)
        }.onFailure {
            android.util.Log.w(TAG, "setLocale failed, using core default: ${it.message}")
        }

        runCatching { QuickShortcuts.refresh(this) }
            .onFailure { android.util.Log.w(TAG, "QuickShortcuts.refresh failed: ${it.message}") }

        // §051 Phase 3 — singleton observer. start()/stop() driven by
        // `auto_record_wifi_history` storage flag. Dart запускает на
        // app init если flag true; toggle в Diagnostics дёргает на лету.
        wifiObserver = WifiNetworkObserver(this)

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
            // §173/§271 — OOM-killer: замена удалённому в 1.14 `Libbox.setMemoryLimit`.
            // libbox 1.14 конфигурит память декларативно через SetupOptions.
            // Лимит настраиваемый (§271, prefs `memory_limit`): хардкод 200MB
            // (§173) душил GC на конфигах с большой кучей (WG-пулы) → GC-шторм
            // и перегрев CPU. Семантика ядра (setup.go:85-94): limit>0 →
            // Go soft-limit = limit*3/4; limit=0 на Android = БЕЗ лимита
            // (`SetMemoryLimit(MaxInt64)`), oom-killer при этом остаётся в
            // Available-режиме (следит за системной свободной памятью) —
            // анти-LMK-страховка сохраняется при любом значении.
            oomKillerEnabled = true
            oomMemoryLimit = resolveMemoryLimitBytes(context)
            // §038/§173 — crash/stderr-канал: замена удалённому `redirectStderr`.
            // Непустой source → ядро редиректит stderr в
            // `workingPath/CrashReport-lxbox.log` (setup.go:102) — восстанавливает
            // stderr-диагностику §038, потерянную с удалением redirectStderr в 1.14.
            crashReportSource = "lxbox"
        }
        // §334 — событие «прошлый запуск упал»: непустой CrashReport-lxbox.log.
        // СТРОГО до Libbox.setup — тот архивирует репорт и затирает файл
        // (`redirectStderr`, log.go:69-77), а cache.db здесь ещё никем не
        // открыт, поэтому удаление безопасно. Затирание же даёт дедуп даром:
        // на следующем запуске файл пуст, второй раз не сработает.
        if (CrashRecovery.crashedOnPreviousLaunch(workingDir)) {
            CrashRecovery.resetKernelCaches(tempDir)
        }
        Libbox.setup(opts)
    }

    companion object {
        private const val TAG = "BoxApplication"

        /** §271 — пресеты МБ, зеркало MemoryLimitSetting.values (Dart). */
        private val MEMORY_LIMIT_PRESETS_MB = setOf(200L, 384L, 512L, 768L)

        /**
         * §271 — prefs-значение memory limit → байты для SetupOptions.oomMemoryLimit.
         * "off" → 0 (на Android ядро трактует 0 как «без лимита», setup.go:90-91);
         * "auto" → лесенка по физическому RAM устройства (totalMem у «4GB»-класса
         * ≈3.7GiB, у «8GB» ≈7.5GiB — пороги ниже маркетинговых);
         * пресетное число → мегабайты. Всё прочее (включая непресетные числа,
         * например из prefs будущей/чужой версии) ведёт себя как "auto" — тот же
         * fallback, что у MemoryLimitSetting.normalize на Dart-стороне, иначе
         * значение, невидимое для §189-sync, стало бы действующим лимитом.
         */
        fun resolveMemoryLimitBytes(context: Context): Long {
            val value = BootReceiver.getMemoryLimit(context)
            value.toLongOrNull()?.let { mb ->
                if (mb in MEMORY_LIMIT_PRESETS_MB) return mb * 1024 * 1024
            }
            if (value == BootReceiver.MEMORY_LIMIT_OFF) return 0L
            // "auto" (и любой неизвестный wire) — по общему RAM устройства.
            val am = context.getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
            val mi = android.app.ActivityManager.MemoryInfo()
            am.getMemoryInfo(mi)
            val gib = 1024L * 1024 * 1024
            val autoMb = when {
                mi.totalMem < 7L * gib / 2 -> 200L // < 3.5 GiB — прежний §173-лимит
                mi.totalMem < 7L * gib -> 384L
                else -> 512L
            }
            return autoMb * 1024 * 1024
        }

        // `lateinit var ... private set` не работает в Kotlin companion —
        // setter недоступен из enclosing class. internal видимости хватает.
        @Volatile
        internal lateinit var instance: BoxApplication

        /** Готовность `Libbox.setup` (libbox 1.14: redirectStderr убран из API). */
        val libboxReady: CompletableDeferred<Unit> = CompletableDeferred()

        /** §051 Phase 3 — singleton WifiNetworkObserver. Toggled через
         *  Dart side (`MainActivity` MethodChannel `setAutoRecordWifi`).
         *  Init в onCreate (lifecycle = process). */
        @Volatile
        internal lateinit var wifiObserver: WifiNetworkObserver

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
