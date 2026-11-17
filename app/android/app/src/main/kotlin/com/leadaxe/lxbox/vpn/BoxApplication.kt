package com.leadaxe.lxbox.vpn

import android.app.Application
import android.app.NotificationManager
import android.content.Context
import android.net.ConnectivityManager
import android.net.wifi.WifiManager
import android.os.PowerManager
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.SetupOptions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.launch

/**
 * §049 — Application class зарегистрирован в AndroidManifest как
 * `android:name=".vpn.BoxApplication"`. Mirror reference SagerNet
 * (commit 3b3883e libbox 1.13.11).
 *
 * §747 — процессов два (`:ui` — окно, `:bg` — сервисная сторона), и
 * `onCreate` исполняется в каждом. Шаги выполняются только на своей стороне
 * ([ProcessRole]): чужой шаг здесь вреден, а не лишний — `TaildropClip` в
 * окне выключил бы «Поделиться» при живом туннеле, а ядро (`libbox.so`) в
 * окне не нужно вовсе и стоит десятков мегабайт.
 *
 * `Seq.setContext(this)` намеренно не вызываем (см. reference
 * `Application.kt:41` — закомментирован). Native libbox init сам
 * устанавливает context при загрузке `.so`; явный вызов делает
 * двойной-set ломающий `Seq$RefTracker` state.
 */
class BoxApplication : Application() {

    override fun onCreate() {
        super.onCreate()
        initCommon()
        when (ProcessRole.role) {
            ProcessRole.Role.Bg -> initServiceSide()
            ProcessRole.Role.Ui -> initUiSide()
            // Каждый компонент манифеста помечен `:ui` или `:bg`; процесс без
            // имени — признак компонента без пометки (сборка такое не
            // пропускает) или постороннего запуска. Шаги сторон не выполняются.
            ProcessRole.Role.Unnamed -> android.util.Log.e(
                TAG, "started in an unnamed process '${ProcessRole.name}' — neither :ui nor :bg",
            )
        }
    }

    /**
     * Общее: нужно обеим сторонам. `instance` — опора компаньон-прокси
     * (`BoxApplication.application`, системные сервисы); кэш Wi-Fi читает
     * `WifiInfoReader` — и окно, и сервис.
     */
    private fun initCommon() {
        instance = this

        // Reference 1.13.11 (Application.kt:41) закомментировал:
//        Seq.setContext(this)

        // §569 — кэш Wi-Fi для API 31+ (NetworkCallback с
        // FLAG_INCLUDE_LOCATION_INFO). Колбэк регистрируется лениво, при
        // первом WifiInfoReader.read с пройденным preflight.
        wifiStateCache = WifiStateCache(this)
    }

    /**
     * Сервисная сторона (`:bg`): ярлыки лаунчера (их действия — старт/стоп
     * VPN без UI), Taildrop (входящие узлов, «Поделиться» / «Send to device»
     * после падения), счёт причин процессу жить.
     *
     * Ядро здесь НЕ загружается: `Libbox.setup` — лениво, [ensureLibbox] при
     * первом старте сервиса или другой потребности в ядре. Процесс `:bg`,
     * поднятый ради записи настройки или плитки, библиотеку ядра не грузит.
     */
    private fun initServiceSide() {
        // §747/§276 — метка «туннель отобрало другое VPN-приложение» от
        // прежнего процесса `:bg`: окно спросит её через `getVpnStatus`.
        runCatching { if (NativeCache.isTunnelRevoked(this)) TunnelState.restoreRevoked() }

        runCatching { QuickShortcuts.refresh(this) }
            .onFailure { android.util.Log.w(TAG, "QuickShortcuts.refresh failed: ${it.message}") }

        // §747 — посылки вызовов, осиротевшие при гибели процесса.
        sweepXferAsync()

        // §707 итер. 3 — принятое во входящие узлов с автосохранением (без
        // галки, до её включения, неудачи прошлых попыток) уходит в Downloads.
        // В фоне, одной очередью с другими разборами.
        Taildrop.sweepInboxesAsync(this)

        // §707 итер. 7 — VPN этого процесса ещё не поднят: «Поделиться» и
        // «Send to device», оставшиеся включёнными после падения, скрываются.
        runCatching { TaildropClip.syncOnProcessStart(this) }

        // §334/§316 — прошлый запуск ядра упал (непустой crash-файл): ядро
        // загружается сразу, не дожидаясь старта туннеля. `Libbox.setup`
        // архивирует репорт (его показывает баннер Dart при открытии окна), а
        // `CrashRecovery` перед ним чистит кэши ядра — как раньше, при первом
        // же запуске процесса после падения. В остальных случаях ядро здесь не
        // грузится.
        if (runCatching { CrashRecovery.crashedOnPreviousLaunch(filesDir) }.getOrDefault(false)) {
            @Suppress("OPT_IN_USAGE")
            GlobalScope.launch(Dispatchers.IO) {
                runCatching { ensureLibbox() }
                    .onFailure { android.util.Log.e(TAG, "initializeLibbox failed", it) }
            }
        }

        // §747 G — завершение процесса, когда он никому не нужен.
        BgLifecycle.install(this)
    }

    /**
     * Сторона окна (`:ui`): наблюдатель Wi-Fi для истории сетей (включает и
     * выключает его Dart, `setAutoRecordWifi`). Ядро здесь не грузится.
     */
    private fun initUiSide() {
        // §051 Phase 3 — singleton observer. start()/stop() driven by
        // `auto_record_wifi_history` storage flag. Dart запускает на
        // app init если flag true; toggle в Diagnostics дёргает на лету.
        wifiObserver = WifiNetworkObserver(this)

        // §747 — посылки вызовов, осиротевшие при гибели процесса.
        sweepXferAsync()

        // §747 — ядро в этот процесс не загружается никогда: клиент экрана,
        // проба, проверка конфига живут в `:bg`. Первый вызов заранее
        // поднимает процесс `:bg` — к подключению движка он уже отвечает.
        @Suppress("OPT_IN_USAGE")
        GlobalScope.launch(Dispatchers.IO) {
            runCatching { BgClient.call(this@BoxApplication, "tunnelSnapshot") }
        }
    }

    private fun sweepXferAsync() {
        @Suppress("OPT_IN_USAGE")
        GlobalScope.launch(Dispatchers.IO) { runCatching { BgControlProvider.sweepXfer(this@BoxApplication) } }
    }

    private fun baseSetupOptions(): SetupOptions {
        val baseDir = filesDir.also { it.mkdirs() }
        val tempDir = coreTempDir(this)
        return SetupOptions().apply {
            basePath = baseDir.path
            workingPath = baseDir.path
            tempPath = tempDir.path
            fixAndroidStack =
                android.os.Build.VERSION.SDK_INT in android.os.Build.VERSION_CODES.N..android.os.Build.VERSION_CODES.N_MR1 ||
                    android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P
            // Match reference: limit sing-box log buffer (без него unbounded
            // accumulation → memory pressure → потенциально refnum race).
            logMaxLines = 3000
        }
    }

    /** `Libbox.setup` процесса с ядром (`:bg`). */
    private fun initializeLibboxForCore(context: Context) {
        // setLocale обязательно ДО Libbox.setup'а — иначе sing-box error
        // messages не локализованы. Формат `xx_YY` (с подчёркиванием).
        //
        // libbox 1.14: setLocale стал СТРОГИМ — golang.org/x/text/language
        // бросает `unsupported locale` на нераспознанной комбинации язык+регион
        // (напр. `ru_IL` = русский на устройстве с регионом Израиль). В 1.13.13
        // это глоталось. Локаль влияет лишь на язык error-строк ядра —
        // fail-safe: при отказе пробуем голый язык (`ru`), затем молча
        // пропускаем (ядро возьмёт дефолтную локаль).
        //
        // §607 — язык из сохранённой настройки приложения, а не устройства:
        // headless-старт (загрузка, QS-плитка, Intent API) Dart не поднимает,
        // и пере-пуша языка из Dart там нет. "system" → локаль устройства.
        L10n.setLibboxLocale(L10n.setting(context))

        val workingDir = context.filesDir
        val tempDir = coreTempDir(context)
        val opts = baseSetupOptions().apply {
            // §043: forwarding sing-box логов в `writeDebugMessage`.
            // `daemon/started_service.go:1048-1050` gates за `if s.debug`.
            debug = BootReceiver.isCoreLogsEnabled(context)
            // §173/§271/§705 — OOM-killer: замена удалённому в 1.14 `Libbox.setMemoryLimit`.
            // libbox 1.14 конфигурит память декларативно через SetupOptions.
            // Лимит настраиваемый (§271, prefs `memory_limit`): хардкод 200MB
            // (§173) душил GC на конфигах с большой кучей (WG-пулы) → GC-шторм
            // и перегрев CPU. Семантика ядра (setup.go:105-108, service/oomkiller):
            // limit>0 → Go soft-limit = limit*4/5 И порог oom-killer; limit=0
            // на Android = без GC-потолка (`SetMemoryLimit(MaxInt64)`),
            // oom-killer в Available-режиме (следит за свободной памятью
            // системы) — анти-LMK-страховка сохраняется при любом значении.
            oomKillerEnabled = true
            oomMemoryLimit = resolveMemoryLimitBytes(context)
            // §705 часть 2 (ядро lx.29, SPEC 148): порог oom-killer сравнивается
            // с памятью Go-рантайма ядра (`StatusMessage.MemoryRuntime`), а не
            // с RSS всего процесса. Слежение за MemAvailable при этом остаётся.
            oomMemoryLimitHeap = true
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
        // §341/§747 — ручки quic-go: Go-side os.Setenv действует на процесс,
        // а процесс с ядром каждый раз новый — применяем запомненное.
        for (knob in listOf("gso", "ecn")) {
            if (NativeCache.quicKnobDisabled(context, knob)) {
                runCatching { applyQuicKnob(knob, true) }
            }
        }
    }

    companion object {
        private const val TAG = "BoxApplication"

        /** §271 — пресеты МБ, зеркало MemoryLimitSetting.values (Dart). */
        private val MEMORY_LIMIT_PRESETS_MB = setOf(200L, 384L, 512L, 768L)

        /**
         * §271/§705 — prefs-значение memory limit → байты для SetupOptions.oomMemoryLimit.
         * Пресетное число → мегабайты. Всё прочее — "auto", legacy "off" и любой
         * неизвестный wire (например из prefs будущей/чужой версии) — `0`: ядро
         * снимает GC-потолок и переводит oom-killer в Available-режим
         * (setup.go:108, policy.go:58). Непресетные числа тоже дают 0 — тот же
         * fallback, что у MemoryLimitSetting.normalize на Dart-стороне, иначе
         * значение, невидимое для §189-sync, стало бы действующим лимитом.
         *
         * До §705 "auto" выбирал 200/384/512 MB по RAM устройства. Снято: порог
         * oom-killer сравнивается с RSS всего процесса, а процесс делят ядро и
         * Flutter — ≈140 MB одного кода (`libbox.so`, libflutter) плюс графика.
         * 200 MB пробивались через 100 мс после старта, а число чуть выше
         * рабочего RSS давало бы сбросы сети в работе. Порог по RSS — только
         * по явному выбору пользователя.
         */
        fun resolveMemoryLimitBytes(context: Context): Long {
            val value = BootReceiver.getMemoryLimit(context)
            value.toLongOrNull()?.let { mb ->
                if (mb in MEMORY_LIMIT_PRESETS_MB) return mb * 1024 * 1024
            }
            return 0L
        }

        // `lateinit var ... private set` не работает в Kotlin companion —
        // setter недоступен из enclosing class. internal видимости хватает.
        @Volatile
        internal lateinit var instance: BoxApplication

        private val libboxLock = Any()

        /**
         * §747 — временный каталог ядра (`SetupOptions.tempPath`): свой
         * подкаталог `cacheDir`. Раньше ядру отдавался весь `cacheDir`, и
         * `CrashRecovery` после падения чистил его целиком; теперь эта чистка
         * идёт в `:bg` под живым окном и не должна задевать чужое —
         * временные файлы Flutter и плагинов, посылки вызовов `bg-xfer`.
         */
        fun coreTempDir(context: Context): java.io.File =
            java.io.File(context.cacheDir, CORE_TEMP_DIR).also { it.mkdirs() }

        private const val CORE_TEMP_DIR = "core-tmp"

        @Volatile
        private var lastCoreUseAt = 0L

        /**
         * §747 G — ядром пользуются без туннеля (проба, проверка и
         * форматирование конфига): `BgLifecycle` не перезапускает процесс ради
         * сброса ядра, пока оно не простоит без дела.
         */
        fun noteCoreUse() {
            lastCoreUseAt = android.os.SystemClock.elapsedRealtime()
        }

        /** Сколько миллисекунд ядром не пользовались без туннеля. */
        fun coreIdleMs(): Long = android.os.SystemClock.elapsedRealtime() - lastCoreUseAt

        /** §747 — `Libbox.setup` этого процесса отработал. */
        @Volatile
        var libboxLoaded: Boolean = false
            private set

        /**
         * §747 — загрузить ядро в процесс `:bg`, если ещё не загружено
         * (`Libbox.setup` — один раз на процесс): локаль, лог, порог памяти,
         * crash-файл, `CrashRecovery`, ручки quic-go. Блокирует на время
         * загрузки библиотеки; звать вне главного потока. Отказ — исключение,
         * следующий вызов попробует снова.
         *
         * Только сервисная сторона: в процессе окна ядра нет вовсе (итерация 2
         * спеки 747) — вызов оттуда бросает исключение, сторож границ такие
         * вызовы не пропускает.
         */
        fun ensureLibbox() {
            noteCoreUse()
            if (libboxLoaded) return
            synchronized(libboxLock) {
                if (libboxLoaded) return
                val app = instance
                check(ProcessRole.role != ProcessRole.Role.Ui) { "the core is never loaded in :ui" }
                app.initializeLibboxForCore(app)
                libboxLoaded = true
            }
        }

        /** §341 — ручка quic-go: Go-side `os.Setenv`, действует в своём процессе. */
        fun applyQuicKnob(knob: String, disabled: Boolean) {
            when (knob) {
                "gso" -> Libbox.setQuicGSODisabled(disabled)
                "ecn" -> Libbox.setQuicECNDisabled(disabled)
            }
        }

        /**
         * §271 — применить `memory_limit` из настроек к загруженному ядру:
         * `reloadSetupOptions` читает только OOM-поля и сразу зовёт
         * `debug.SetMemoryLimit`. Ядро не загружено — ничего не делает
         * (значение прочтёт `Libbox.setup`). Не блокирует вызывающего.
         */
        fun reloadMemoryLimit(context: Context) {
            val app = context.applicationContext
            @Suppress("OPT_IN_USAGE")
            GlobalScope.launch(Dispatchers.IO) {
                // Ядро как раз загружается (`ensureLibbox` держит замок и мог
                // прочесть прежнее значение) — дождаться и применить новое.
                synchronized(libboxLock) { }
                if (!libboxLoaded) return@launch
                runCatching {
                    val opts = SetupOptions().apply {
                        oomKillerEnabled = true
                        oomMemoryLimit = resolveMemoryLimitBytes(app)
                        // §705 (SPEC 148): порог по памяти рантайма ядра, не по RSS.
                        oomMemoryLimitHeap = true
                    }
                    Libbox.reloadSetupOptions(opts)
                }.onFailure { android.util.Log.w(TAG, "reloadSetupOptions failed: ${it.message}") }
            }
        }

        /** §051 Phase 3 — singleton WifiNetworkObserver. Toggled через
         *  Dart side (`MainActivity` MethodChannel `setAutoRecordWifi`).
         *  Init в onCreate (lifecycle = process). */
        @Volatile
        internal lateinit var wifiObserver: WifiNetworkObserver

        /** §569 — singleton WifiStateCache (API 31+; ниже — no-op).
         *  Init в onCreate, колбэк регистрирует WifiInfoReader.read. */
        @Volatile
        internal lateinit var wifiStateCache: WifiStateCache

        /** §569 — null, если onCreate ещё не отработал (read без кэша). */
        internal val wifiStateCacheOrNull: WifiStateCache?
            get() = if (::wifiStateCache.isInitialized) wifiStateCache else null

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
