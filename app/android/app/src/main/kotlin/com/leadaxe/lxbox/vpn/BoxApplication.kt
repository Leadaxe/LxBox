package com.leadaxe.lxbox.vpn

import android.app.Application
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

/**
 * §049 Phase H — Application class registered в AndroidManifest.xml
 * (`android:name=".vpn.BoxApplication"`). Mirror reference SagerNet
 * `io.nekohasekai.sfa.Application` (commit 3b3883e libbox 1.13.11).
 *
 * Был `object BoxApplication` инициализирующийся лениво из
 * `BoxVpnService.onCreate()` / `MainActivity.onCreate()`. Теперь — Android
 * Application class который Android создаёт **до любого Service** или
 * Activity. Это:
 *   - Устраняет timing race window'ы между Application init и Service start
 *   - Гарантирует что `Libbox.setup()` всегда завершён ДО первого
 *     `CommandServer(...)` ctor'а
 *   - Убирает необходимость в `BoxApplication.initialize()` defensive вызовах
 *     из BoxVpnService.onCreate / MainActivity.onCreate
 *
 * **Reference deltas (важно!)**:
 *   - `Seq.setContext(this)` — закомментирован (reference Application.kt:41).
 *     В libbox 1.13.x native init сам устанавливает контекст при загрузке
 *     `.so`. Наш дополнительный явный вызов мог двойным-set'ом ломать
 *     `Seq$RefTracker` state — главный suspect для `refnum 42` crash race.
 *   - `logMaxLines = 3000` (reference Application.kt: SetupOptions). Без
 *     лимита sing-box копит логи unbounded → memory pressure → GC pressure
 *     → может trigger refnum 42 race.
 *   - `Libbox.setLocale(...)` без `runCatching` — fail loud, как reference.
 *
 * Companion object сохраняет публичный API через `instance` для backward
 * compatibility со всеми callsite'ами `BoxApplication.X` в codebase.
 */
class BoxApplication : Application() {

    override fun onCreate() {
        super.onCreate()
        instance = this

        // §049 Phase H — закомментировано 1:1 как reference
        // (`SagerNet/sing-box-for-android/Application.kt:41` для libbox 1.13.11).
        // Native libbox init сам устанавливает context при загрузке `.so`.
        // Наш дополнительный явный вызов делал двойной-set который ломал
        // `Seq$RefTracker` state → главный suspect для refnum 42 race.
        // Эмпирически verified: v11270 (split only с этим вызовом активным)
        // — crash 2s; v11300 (split + закомментированный setContext) — stable.
//        Seq.setContext(this)

        // §049 F9 — Libbox.setLocale обязательно ПЕРЕД setup'ом.
        // Reference вызывает синхронно без runCatching — fail loud.
        Libbox.setLocale(Locale.getDefault().toLanguageTag().replace("-", "_"))

        // Quick Connect refresh — best-effort, опциональный.
        runCatching { QuickShortcuts.refresh(this) }
            .onFailure { android.util.Log.w(TAG, "QuickShortcuts.refresh failed: ${it.message}") }

        // libbox setup — async в IO scope. К моменту когда юзер запускает
        // VPN, setup уже точно завершён. Через `libboxReady` CompletableDeferred
        // предоставляем sync-барьер для случая когда auto-start или
        // QS-tile сразу триггерят VPN после boot — там race возможна.
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
            // §049 Phase H — match reference `logMaxLines = 3000`.
            // Без лимита sing-box копит logs unbounded → memory pressure
            // на JVM heap (через writeDebugMessage callbacks с large strings)
            // → GC pressure → refnum 42 race.
            logMaxLines = 3000
            // §043: forwarding sing-box логов в наш PlatformInterface
            // callback writeDebugMessage. `daemon/started_service.go:1048-1050`
            // gates `s.handler.WriteDebugMessage(message)` за `if s.debug`.
            debug = BootReceiver.isCoreLogsEnabled(context)
        }
        Libbox.setup(opts)
        // redirectStderr — best-effort (старые libbox / SELinux OEM могут
        // блокировать). Reference вызывает без runCatching, но у нас
        // production'е runCatching стабильнее на разнообразии устройств.
        runCatching { Libbox.redirectStderr(File(workingDir, "stderr.log").path) }
            .onFailure { android.util.Log.w(TAG, "redirectStderr failed: ${it.message}") }
    }

    companion object {
        private const val TAG = "BoxApplication"

        // Set из BoxApplication.onCreate(). Kotlin не позволяет
        // `lateinit var ... private set` потому что setter становится
        // недоступен из enclosing class — оставляем internal-видимый.
        @Volatile
        internal lateinit var instance: BoxApplication

        /**
         * Сигналит готовность `Libbox.setup` + `Libbox.redirectStderr`.
         * `BoxService.startSingbox` опционально может `await` для
         * сценариев где VPN стартует немедленно после boot.
         */
        val libboxReady: CompletableDeferred<Unit> = CompletableDeferred()

        // -------------------------------------------------------------------
        // Backward-compat API — все callsite'ы `BoxApplication.X` продолжают
        // работать через companion proxy на `instance`.
        // -------------------------------------------------------------------

        val application: Context get() = instance

        val powerManager: PowerManager
            get() = instance.getSystemService(Context.POWER_SERVICE) as PowerManager

        val connectivity: ConnectivityManager
            get() = instance.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

        val packageManager get() = instance.packageManager

        val notificationManager: NotificationManager
            get() = instance.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        /// §049 F12.3: WifiManager для readWIFIState. Использует Application
        /// context (а не Activity) — иначе на API >= R может выкидывать
        /// `IllegalStateException` при getSystemService с non-Activity context'ом.
        val wifiManager: WifiManager
            get() = instance.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager

        /**
         * No-op после миграции на Android Application class. Оставлено
         * для backward compat — все callsite'ы (BoxService.onCreate,
         * MainActivity.onCreate) продолжают компилироваться.
         *
         * Application class инициализируется Android runtime'ом до любого
         * Service / Activity, так что libbox setup гарантированно отработает.
         */
        @Suppress("UNUSED_PARAMETER")
        fun initialize(context: Context) {
            // No-op: Application.onCreate() уже был вызван Android runtime'ом.
        }
    }
}
