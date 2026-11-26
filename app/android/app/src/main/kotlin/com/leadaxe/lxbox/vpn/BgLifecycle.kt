package com.leadaxe.lxbox.vpn

import android.app.Activity
import android.app.Application
import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import java.util.concurrent.atomic.AtomicInteger

/// §747 — жив ли процесс окна с подключённым Flutter-движком, глазами `:bg`.
///
/// Окно при подключении движка передаёт вызовом `uiAttached` Binder-метку;
/// `:bg` вешает на неё `linkToDeath` и узнаёт о гибели `:ui` без опроса.
/// Штатное отключение движка — вызов `uiDetached` («окно закрыто»).
object UiPresence {
    private const val TAG = "UiPresence"

    @Volatile
    var isAttached: Boolean = false
        private set

    private var token: IBinder? = null
    private var recipient: IBinder.DeathRecipient? = null

    @Synchronized
    fun attached(ctx: Context, newToken: IBinder?) {
        unlink()
        isAttached = true
        // Туннель уже поднят (окно открыли позже старта) — клиент экрана
        // создаётся сейчас; без Started `ensure()` ничего не делает.
        ScreenCoreSession.ensure()
        // …и процесс окна с этого момента удерживается живым.
        UiHold.sync(ctx)
        if (newToken == null) return
        val r = IBinder.DeathRecipient {
            Log.w(TAG, "ui process died")
            gone(ctx, newToken)
        }
        // Метка своего процесса (вызов без границы процессов) — локальный
        // Binder, linkToDeath для него ничего не делает.
        runCatching { newToken.linkToDeath(r, 0) }
            .onFailure {
                // Процесс умер раньше, чем мы подписались.
                left(ctx)
                return
            }
        token = newToken
        recipient = r
    }

    /// Окно закрыто (движок отключён).
    @Synchronized
    fun detached(ctx: Context) {
        unlink()
        left(ctx)
    }

    @Synchronized
    private fun gone(ctx: Context, dead: IBinder) {
        if (token !== dead) return // метка прежнего окна, новое уже подключено
        token = null
        recipient = null
        left(ctx)
    }

    private fun unlink() {
        val t = token
        val r = recipient
        if (t != null && r != null) runCatching { t.unlinkToDeath(r, 0) }
        token = null
        recipient = null
    }

    private fun left(ctx: Context) {
        isAttached = false
        // Удержание процесса окна снимается первым — внутри этого же вызова,
        // раньше, чем окно завершит свой процесс: привязка не должна ни
        // пережить окно, ни воскресить его процесс.
        UiHold.sync(ctx)
        // Показывать некому: потоки данных окна снимаются, канал событий и
        // клиент экрана закрываются (ядро перестаёт слать то, что никто не
        // читает), проба без туннеля останавливается.
        StreamSinks.cancelAll()
        BgMethods.cancelWindowJobs()
        BgEventPipe.close()
        ScreenCoreSession.closeOffThread()
        if (ProbeSession.active) {
            Thread({ runCatching { ProbeSession.stop() } }, "lxbox-probe-stop")
                .apply { isDaemon = true }.start()
        }
        BgLifecycle.check(ctx, BgLifecycle.DELAY_UI_GONE_MS)
    }
}

/// §747 G — причины процессу `:bg` жить. Чистые данные — для JVM-теста.
data class BgExitState(
    /// Статус туннеля `Stopped`.
    val tunnelStopped: Boolean,
    /// Экземпляр `BoxVpnService` существует (onCreate…onDestroy).
    val serviceAlive: Boolean,
    /// Процесс окна жив и движок подключён.
    val uiAttached: Boolean,
    /// Открытые нативные окна `:bg` (Taildrop, автоматизация).
    val nativeWindows: Int,
    /// Удержания: слушающая плитка и т. п.
    val holds: Int,
    /// Идущие вызовы `BgControlProvider`.
    val activeCalls: Int,
    /// Идёт передача или разбор входящих Taildrop.
    val taildropBusy: Boolean,
    /// Признак «VPN желателен» при остановленном туннеле: сторож (§428)
    /// собирается поднять его снова.
    val watchdogPending: Boolean,
    /// Идёт проба без туннеля (`ProbeSession`).
    val probeActive: Boolean,
    /// Сервису только что отправлена команда старта, а его экземпляр ещё не
    /// создан: завершиться сейчас — значит потерять старт.
    val startPending: Boolean,
    /// В канале событий ждут записи ответы вызовов окна: завершиться сейчас —
    /// значит оставить вызов без ответа.
    val pendingReplies: Boolean,
)

/// §747 G — можно ли процессу `:bg` завершиться: туннель остановлен, сервис
/// уничтожен и ни одной причины жить не осталось.
fun bgMayExit(s: BgExitState): Boolean =
    s.tunnelStopped && !s.serviceAlive && !s.uiAttached && s.nativeWindows == 0 &&
        s.holds == 0 && s.activeCalls == 0 && !s.taildropBusy && !s.watchdogPending &&
        !s.probeActive && !s.startPending && !s.pendingReplies

/// §747 G — что держит процесс `:bg` (кроме окна — см. [bgMayRecycle]): имена
/// причин для журнала. Пусто — ни одной причины, кроме, возможно, окна.
fun bgExitVeto(s: BgExitState): List<String> = buildList {
    if (!s.tunnelStopped) add("tunnel-not-stopped")
    if (s.serviceAlive) add("service-alive")
    if (s.startPending) add("start-pending")
    if (s.activeCalls > 0) add("calls=${s.activeCalls}")
    if (s.pendingReplies) add("replies-unwritten")
    if (s.probeActive) add("probe")
    if (s.taildropBusy) add("taildrop")
    if (s.nativeWindows > 0) add("native-windows=${s.nativeWindows}")
    if (s.holds > 0) add("holds=${s.holds}")
    if (s.watchdogPending) add("vpn-desired")
}

/// §747 G — можно ли процессу `:bg` перезапуститься под открытым окном, чтобы
/// сбросить загруженное ядро: туннель остановлен, а `libbox.so` из живого
/// процесса не выгрузить. Те же причины жить, что в [bgMayExit], кроме самого
/// окна; перезапуск нужен, только если ядро загружено ([coreLoaded]) и им не
/// пользовались без туннеля (проба, проверка конфига) последние
/// [BgLifecycle.CORE_IDLE_MS] — иначе редактор конфига грузил бы ядро заново
/// на каждую проверку.
fun bgMayRecycle(s: BgExitState, coreLoaded: Boolean, coreIdleMs: Long): Boolean =
    coreLoaded && s.uiAttached && coreIdleMs >= BgLifecycle.CORE_IDLE_MS &&
        bgMayExit(s.copy(uiAttached = false))

/// §747 G — завершение ненужного процесса `:bg`.
///
/// Библиотеку ядра из живого процесса выгрузить нельзя: память возвращает
/// только завершение процесса. Поэтому после остановки туннеля, закрытия окна
/// или любого другого события, снявшего причину жить, `:bg` с задержкой
/// проверяет [bgMayExit] и, если жить незачем, завершается сам. Плитку,
/// автозапуск, сторожа, команды автоматизации и вызовы окна система поднимает
/// в новом процессе.
///
/// **Перезапуск под открытым окном.** Подключённое окно — причина жить, но не
/// причина держать ядро: после остановки туннеля (или пробы, проверки
/// конфига) процесс с загруженным ядром завершается так же ([bgMayRecycle]),
/// а окно, увидев конец канала событий, тут же поднимает новый `:bg` — лёгкий,
/// без `libbox.so`, — и заново называет себя, открывает канал и подписки.
///
/// **Граница завершения** ([enter] / [dying]). Решение «завершаемся» и вход
/// вызова окна сериализованы одним замком: либо вызов вошёл раньше и отменил
/// завершение, либо решение принято — и тогда вызов не исполняется вовсе:
/// окно получает отказ `BG_EXITING` и повторяет вызов, пока не попадёт в новый
/// процесс (`BgClient`). Наполовину исполненных вызовов при этом не бывает.
/// Команда старта, пришедшая Intent'ом (плитка, приёмник), процесс поднимет
/// сама система.
///
/// Работает только в процессе с ролью `:bg` ([ProcessRole]).
object BgLifecycle {
    private const val TAG = "BgLifecycle"

    /// Задержка после остановки туннеля, закрытия нативного окна, снятия удержания.
    const val DELAY_IDLE_MS = 5_000L
    /// Задержка после закрытия окна приложения.
    const val DELAY_UI_GONE_MS = 1_500L
    /// Процесс поднят (плиткой, приёмником, вызовом без окна), а дела не нашлось.
    const val DELAY_START_MS = 15_000L
    /// Сколько процесс ждёт создания сервиса после команды старта.
    private const val START_GRACE_MS = 20_000L
    /// Сколько ядро должно простоять без дела без туннеля (проба, проверка и
    /// форматирование конфига), прежде чем процесс перезапустится ради него.
    const val CORE_IDLE_MS = 30_000L
    /// Задержка самозавершения после `quitApp`: ответ вызова успевает уйти.
    private const val DELAY_QUIT_MS = 150L

    private val main = Handler(Looper.getMainLooper())

    /// Замок границы завершения: счёт идущих вызовов, пометка «старт в пути»
    /// и решение завершиться меняются и читаются под ним.
    private val gate = Any()
    private var activeCalls = 0

    /// Решение завершиться принято: новые вызовы не исполняются.
    @Volatile
    var dying = false
        private set

    private val nativeWindows = AtomicInteger(0)
    private val holds = AtomicInteger(0)

    @Volatile
    private var quitting = false

    /// До какого момента (`elapsedRealtime`) процесс ждёт создания сервиса по
    /// только что отправленной команде старта.
    @Volatile
    private var startPendingUntil = 0L

    /// Сервису отправлена команда старта (`BoxVpnService.start`): между
    /// `startForegroundService` и `onCreate` сервиса проходит время, и в этом
    /// окне туннель ещё `Stopped`, а экземпляра сервиса нет. Завершение
    /// процесса здесь оставило бы систему с обещанным, но не начатым
    /// foreground-сервисом — на [START_GRACE_MS] процесс удерживается.
    fun startRequested() {
        synchronized(gate) {
            startPendingUntil = android.os.SystemClock.elapsedRealtime() + START_GRACE_MS
        }
    }

    /// Команда старта дошла: сервис создан (дальше процесс держит сам сервис —
    /// `serviceAlive`) или туннель дошёл до `Stopped`. Таймер [START_GRACE_MS]
    /// остаётся страховкой только на случай «команда ушла, сервис так и не
    /// создан».
    fun startSettled() {
        startPendingUntil = 0L
    }

    private val enabled: Boolean get() = ProcessRole.role == ProcessRole.Role.Bg

    private var pending: Runnable? = null

    /// Старт процесса `:bg`: счёт нативных окон и первая проверка.
    fun install(app: Application) {
        if (!enabled) return
        app.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityCreated(a: Activity, b: Bundle?) {
                nativeWindows.incrementAndGet()
            }
            override fun onActivityDestroyed(a: Activity) {
                nativeWindows.decrementAndGet()
                check(app, DELAY_IDLE_MS)
            }
            override fun onActivityStarted(a: Activity) {}
            override fun onActivityResumed(a: Activity) {}
            override fun onActivityPaused(a: Activity) {}
            override fun onActivityStopped(a: Activity) {}
            override fun onActivitySaveInstanceState(a: Activity, b: Bundle) {}
        })
        check(app, DELAY_START_MS)
    }

    /// Вызов окна входит в процесс. `false` — процесс уже решил завершиться:
    /// исполнять вызов нельзя — провайдер отвечает отказом `BG_EXITING`.
    fun enter(): Boolean = synchronized(gate) {
        if (dying) return false
        activeCalls++
        true
    }

    /// Долгий вызов продолжает исполняться на своём потоке после возврата
    /// запустившего его быстрого.
    fun callStarted() {
        synchronized(gate) { activeCalls++ }
    }

    fun callFinished(ctx: Context) {
        synchronized(gate) { activeCalls-- }
        if (!UiPresence.isAttached) {
            // С запасом на холодный старт окна: его первые вызовы приходят
            // раньше, чем движок подключится и окно назовёт себя (`uiAttached`).
            // Уже ждущую проверку не отодвигаем: иначе конец самого вызова
            // `uiDetached` заменял бы короткую задержку «окно закрыто» на эту.
            check(ctx, DELAY_START_MS, keepPending = true)
        } else if (BoxApplication.libboxLoaded && TunnelState.status == VpnStatus.Stopped) {
            // Окно подключено, туннеля нет, а ядро загружено (проба, проверка
            // конфига): проверить позже, не пора ли перезапуститься без него.
            // Уже ждущую проверку не отодвигаем — вызовы окна идут часто.
            check(ctx, CORE_IDLE_MS + 1_000L, keepPending = true)
        }
    }

    /// Удержание процесса (слушающая плитка). Парный вызов — [release].
    fun hold() {
        holds.incrementAndGet()
    }

    fun release(ctx: Context) {
        holds.decrementAndGet()
        check(ctx, DELAY_IDLE_MS)
    }

    /// Запланировать проверку «можно ли завершиться» через [delayMs]. Новая
    /// проверка заменяет ожидающую; любое событие, вернувшее причину жить
    /// (старт туннеля, вызов, окно), проверка увидит сама.
    fun check(ctx: Context, delayMs: Long, keepPending: Boolean = false) {
        if (!enabled || quitting) return
        val app = ctx.applicationContext ?: ctx
        synchronized(this) {
            if (keepPending && pending != null) return
            pending?.let { main.removeCallbacks(it) }
            val r = Runnable {
                synchronized(this) { pending = null }
                exitIfIdle(app)
            }
            pending = r
            main.postDelayed(r, delayMs)
        }
    }

    /// `quitApp`: завершиться после ответа вызова, не глядя на причины жить
    /// (туннель уже остановлен штатно или не ответил за отведённое время).
    fun quit(ctx: Context) {
        if (!enabled) return
        quitting = true
        // Новые вызовы больше не исполняются: запоздалый вызов окна не должен
        // ни выполниться наполовину, ни пережить процесс.
        synchronized(gate) { dying = true }
        val app = ctx.applicationContext ?: ctx
        main.postDelayed({ exit(app, "quitApp") }, DELAY_QUIT_MS)
    }

    private fun state(app: Context) = BgExitState(
        tunnelStopped = TunnelState.status == VpnStatus.Stopped,
        serviceAlive = BoxVpnService.live != null,
        uiAttached = UiPresence.isAttached,
        nativeWindows = nativeWindows.get(),
        holds = holds.get(),
        activeCalls = activeCalls,
        taildropBusy = Taildrop.isBusy(),
        watchdogPending = runCatching { BootReceiver.isVpnDesired(app) }.getOrDefault(true),
        probeActive = ProbeSession.active,
        startPending = android.os.SystemClock.elapsedRealtime() < startPendingUntil,
        pendingReplies = BgEventPipe.hasPendingReplies,
    )

    private fun exitIfIdle(app: Context) {
        val coreLoaded = BoxApplication.libboxLoaded
        val coreIdleMs = BoxApplication.coreIdleMs()
        var reason: String? = null
        // Решение — под замком границы: вызов окна либо уже вошёл (и тогда
        // причина жить видна в состоянии), либо войдёт после и будет ждать
        // гибели процесса, не исполняясь.
        val s = synchronized(gate) {
            val st = state(app)
            reason = when {
                bgMayExit(st) -> "idle"
                bgMayRecycle(st, coreLoaded, coreIdleMs) -> "drop the core under the open window"
                else -> null
            }
            if (reason != null) dying = true
            st
        }
        val why = reason
        if (why != null) {
            exit(app, why)
            return
        }
        Log.d(TAG, "stay: $s coreLoaded=$coreLoaded coreIdleMs=$coreIdleMs")
        // В журнал — только когда завершение (или перезапуск ради ядра) было
        // на подходе и его остановила не простая «ещё рано»: по этой строке
        // видно, что удержало процесс в момент старта.
        val veto = bgExitVeto(s)
        if (veto.isNotEmpty() && (!s.uiAttached || coreLoaded)) {
            journal("bg exit vetoed in pid ${android.os.Process.myPid()}: ${veto.joinToString(",")}")
        }
        // Причина, у которой нет своего события об окончании (передача
        // Taildrop, идущий вызов, проба, недописанный ответ, ядро ещё не
        // простояло своё): перепроверить позже.
        // Причины с собственным событием (плитка, нативное окно, окно
        // приложения, сервис) и «VPN желателен» опросом не ждём — иначе процесс
        // под открытым окном просыпался бы каждые 5 с без конца.
        val coreNotIdleYet = coreLoaded && s.uiAttached && s.tunnelStopped && !s.serviceAlive &&
            coreIdleMs < CORE_IDLE_MS
        if (s.taildropBusy || s.activeCalls > 0 || s.probeActive || s.startPending ||
            s.pendingReplies
        ) {
            check(app, DELAY_IDLE_MS)
        } else if (coreNotIdleYet) {
            check(app, (CORE_IDLE_MS - coreIdleMs + 1_000L).coerceAtLeast(DELAY_IDLE_MS))
        }
    }

    /// Строка о развилке жизненного цикла `:bg`: в logcat и в журнал
    /// приложения (канал событий, если окно слушает лог) — чтобы случай
    /// «старт принят, туннель не поднялся» разбирался по дампу.
    fun journal(text: String) {
        Log.w(TAG, text)
        BgEventPipe.logLine("WARN [bg] $text")
    }

    private fun exit(app: Context, reason: String) {
        journal("bg exit allowed in pid ${android.os.Process.myPid()}: $reason")
        // Строка журнала успевает уйти окну; вызовы в это время не исполняются.
        BgEventPipe.drain(200L)
        // `apply()` пишет файл настроек в фоне; завершение процесса его не
        // ждёт. Пустой `commit()` дожидается записи всего, что уже применено.
        runCatching { BootReceiver.flushPrefs(app) }
        android.os.Process.killProcess(android.os.Process.myPid())
    }
}
