package com.leadaxe.lxbox.vpn

import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit

/// §732 — одна фоновая нить для блокирующих вызовов ядра, которым нужен
/// порядок (connect/disconnect клиентов CommandClient, pause/wake ядра).
///
/// Зачем: `CommandClient.connect()` ждёт ответа командного сервера до 3,25 с
/// (десять попыток с растущей паузой), `pause()`/`wake()` синхронно обходят
/// все WG-устройства. С главного потока Android такой вызов останавливает
/// MethodChannel и приём broadcast-ов: интерфейс получает таймауты, Stop не
/// доходит до службы. На полосе вызов блокирует только её.
///
/// Задачи исполняются строго по очереди, в порядке постановки. Задача,
/// работающая дольше [slowMs], называется через [onSlow] дважды: когда порог
/// пройден (вызов ещё висит) и когда она вернулась (с длительностью) — так в
/// журнале остаётся имя зависшего вызова. Без `android.util.Log`: класс
/// проверяется JVM-тестом.
internal class SerialLane(
    private val name: String,
    private val slowMs: Long = 3_000L,
    private val onSlow: (String) -> Unit = {},
    private val onError: (String, Throwable) -> Unit = { _, _ -> },
) {
    private val exec = ScheduledThreadPoolExecutor(1) { r ->
        Thread(r, name).apply { isDaemon = true }
    }
    private val watch = ScheduledThreadPoolExecutor(1) { r ->
        Thread(r, "$name-watch").apply { isDaemon = true }
    }

    fun post(label: String, block: () -> Unit) {
        exec.execute(wrap(label, block))
    }

    fun postDelayed(label: String, delayMs: Long, block: () -> Unit) {
        exec.schedule(wrap(label, block), delayMs, TimeUnit.MILLISECONDS)
    }

    private fun wrap(label: String, block: () -> Unit) = Runnable {
        val t0 = System.nanoTime()
        val alarm = watch.schedule(
            { runCatching { onSlow("$name: $label still running after ${slowMs}ms") } },
            slowMs,
            TimeUnit.MILLISECONDS,
        )
        try {
            block()
        } catch (t: Throwable) {
            runCatching { onError(label, t) }
        } finally {
            alarm.cancel(false)
            val ms = (System.nanoTime() - t0) / 1_000_000
            if (ms >= slowMs) runCatching { onSlow("$name: $label returned after ${ms}ms") }
        }
    }
}

/// §732 — пауза между попытками переподключения: растёт вдвое от [startMs] до
/// [maxMs], после успеха сбрасывается. Раньше пауза была постоянной (500 мс),
/// и при молчащем командном сервере попытки шли вплотную одна за другой.
internal class ReconnectBackoff(private val startMs: Long, private val maxMs: Long) {
    private var nextMs = startMs
    private var failureReported = false

    @Synchronized
    fun next(): Long {
        val d = nextMs
        nextMs = (nextMs * 2).coerceAtMost(maxMs)
        return d
    }

    /// `true` — первый сбой подключения с последнего [reset]: о нём пишут в
    /// журнал один раз за серию. Отдельный флаг, а не «пауза равна стартовой»:
    /// паузу забирает и обрыв потока (`disconnected`), который при потере
    /// сокета приходит раньше сбоя подключения, — признак по паузе не
    /// срабатывал никогда.
    @Synchronized
    fun firstFailure(): Boolean {
        if (failureReported) return false
        failureReported = true
        return true
    }

    @Synchronized
    fun reset() {
        nextMs = startMs
        failureReported = false
    }
}
