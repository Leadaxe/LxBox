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

/// §747 D — согласование пробы без туннеля (`ProbeSession`, живёт в `:ui`) со
/// стартом туннеля в `:bg`: сокет ядра `command.sock` один на оба процесса.
///
/// - окно перед стартом пробы зовёт [begin]: отказ, если туннель не `Stopped`;
/// - `BoxService` перед запуском своего командного сервера, если проба идёт,
///   шлёт окну событие «остановить пробу» и ждёт [end] не дольше заданного
///   времени ([awaitIdle]); не дождался — считает пробу снятой и идёт дальше.
///
/// Чистая логика без Android — проверяется JVM-тестом.
object ProbeGate {
    private val lock = java.util.concurrent.locks.ReentrantLock()
    private val idle = lock.newCondition()
    private var active = false

    val isActive: Boolean get() = locked { active }

    /// Проба начинается. `false` — туннель не остановлен, пробе нельзя.
    fun begin(tunnelStopped: Boolean): Boolean = locked {
        if (tunnelStopped) active = true
        tunnelStopped
    }

    /// Проба закончена (или окно умерло).
    fun end() = locked {
        active = false
        idle.signalAll()
    }

    /// Ждать конца пробы не дольше [timeoutMs]. `true` — проба не шла или
    /// закончилась; `false` — время вышло, отметка «проба идёт» снята силой.
    fun awaitIdle(timeoutMs: Long, now: () -> Long = System::nanoTime): Boolean = locked {
        val deadline = now() + timeoutMs * 1_000_000L
        var ok = true
        while (active) {
            val leftNs = deadline - now()
            if (leftNs <= 0L) {
                active = false
                ok = false
                break
            }
            idle.awaitNanos(leftNs)
        }
        ok
    }

    private inline fun <T> locked(block: () -> T): T {
        lock.lock()
        try {
            return block()
        } finally {
            lock.unlock()
        }
    }
}

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
                isAttached = false
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
        // Слушать лог и держать сокет ядра под пробу больше некому.
        BgLogPipe.close()
        ProbeGate.end()
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
    /// В окне идёт проба без туннеля.
    val probeActive: Boolean,
)

/// §747 G — можно ли процессу `:bg` завершиться: туннель остановлен, сервис
/// уничтожен и ни одной причины жить не осталось.
fun bgMayExit(s: BgExitState): Boolean =
    s.tunnelStopped && !s.serviceAlive && !s.uiAttached && s.nativeWindows == 0 &&
        s.holds == 0 && s.activeCalls == 0 && !s.taildropBusy && !s.watchdogPending &&
        !s.probeActive

/// §747 G — завершение ненужного процесса `:bg`.
///
/// Библиотеку ядра из живого процесса выгрузить нельзя: память возвращает
/// только завершение процесса. Поэтому после остановки туннеля, закрытия окна
/// или любого другого события, снявшего причину жить, `:bg` с задержкой
/// проверяет [bgMayExit] и, если жить незачем, завершается сам. Плитку,
/// автозапуск, сторожа, команды автоматизации и вызовы окна система поднимает
/// в новом процессе.
///
/// Работает только в процессе с ролью `:bg` ([ProcessRole]).
object BgLifecycle {
    private const val TAG = "BgLifecycle"

    /// Задержка после остановки туннеля, закрытия нативного окна, конца вызова.
    const val DELAY_IDLE_MS = 5_000L
    /// Задержка после закрытия окна приложения.
    const val DELAY_UI_GONE_MS = 1_500L
    /// Процесс поднят (плиткой, приёмником, вызовом), а дела не нашлось.
    const val DELAY_START_MS = 15_000L
    /// Задержка самозавершения после `quitApp`: ответ вызова успевает уйти.
    private const val DELAY_QUIT_MS = 150L

    private val main = Handler(Looper.getMainLooper())
    private val activeCalls = AtomicInteger(0)
    private val nativeWindows = AtomicInteger(0)
    private val holds = AtomicInteger(0)

    @Volatile
    private var quitting = false

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

    fun callStarted() {
        activeCalls.incrementAndGet()
    }

    fun callFinished(ctx: Context) {
        activeCalls.decrementAndGet()
        // Окно подключено — оно и держит процесс; проверять нечего.
        if (!UiPresence.isAttached) check(ctx, DELAY_IDLE_MS)
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
    fun check(ctx: Context, delayMs: Long) {
        if (!enabled || quitting) return
        val app = ctx.applicationContext ?: ctx
        synchronized(this) {
            pending?.let { main.removeCallbacks(it) }
            val r = Runnable { exitIfIdle(app) }
            pending = r
            main.postDelayed(r, delayMs)
        }
    }

    /// `quitApp`: завершиться после ответа вызова, не глядя на причины жить
    /// (туннель уже остановлен штатно или не ответил за отведённое время).
    fun quit(ctx: Context) {
        if (!enabled) return
        quitting = true
        val app = ctx.applicationContext ?: ctx
        main.postDelayed({ exit(app, "quitApp") }, DELAY_QUIT_MS)
    }

    private fun state(app: Context) = BgExitState(
        tunnelStopped = TunnelState.status == VpnStatus.Stopped,
        serviceAlive = BoxVpnService.live != null,
        uiAttached = UiPresence.isAttached,
        nativeWindows = nativeWindows.get(),
        holds = holds.get(),
        activeCalls = activeCalls.get(),
        taildropBusy = Taildrop.isBusy(),
        watchdogPending = runCatching { BootReceiver.isVpnDesired(app) }.getOrDefault(true),
        probeActive = ProbeGate.isActive,
    )

    private fun exitIfIdle(app: Context) {
        val s = state(app)
        if (!bgMayExit(s)) {
            Log.d(TAG, "stay: $s")
            return
        }
        exit(app, "idle")
    }

    private fun exit(app: Context, reason: String) {
        Log.i(TAG, "bg process exits ($reason)")
        // `apply()` пишет файл настроек в фоне; завершение процесса его не
        // ждёт. Пустой `commit()` дожидается записи всего, что уже применено.
        runCatching { BootReceiver.flushPrefs(app) }
        android.os.Process.killProcess(android.os.Process.myPid())
    }
}
