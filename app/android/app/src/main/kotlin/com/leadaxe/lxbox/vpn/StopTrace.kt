package com.leadaxe.lxbox.vpn

import android.os.SystemClock
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.util.Collections
import java.util.concurrent.atomic.AtomicBoolean

/// §668 — трасса одной остановки службы (`doStop` / `doForceStop`).
///
/// Зачем: §663 довёл force-stop до службы, но какой Go-вызов teardown'а не
/// возвращается, по логу пользователя не видно — logcat без adb ему
/// недоступен. Трасса пишет каждый шаг в журнал приложения ([emit]), а при
/// зависании шага снимает дамп горутин.
///
/// Каждый шаг крутится в своём потоке-демоне, корутина ждёт его через
/// `withTimeoutOrNull`. Обычный `withTimeout` вокруг блокирующего JNI-вызова
/// ничего не ограничивает: таймаут кооперативный, и он вернётся только когда
/// вызов вернётся сам. Здесь зависший вызов остаётся в своём потоке, а
/// остановка идёт дальше.
internal class StopTrace(
    private val path: String,
    private val filesDir: File,
    /// (строка, warn). warn=false — штатная трасса (INFO, в `corelog.txt` не
    /// сохраняется); warn=true — зависание/ошибка (WARN, сохраняется).
    private val emit: (String, Boolean) -> Unit,
) {
    private val t0 = SystemClock.elapsedRealtime()
    private val lines = Collections.synchronizedList(ArrayList<String>())
    private val stuckFired = AtomicBoolean(false)

    fun mark(text: String, warn: Boolean = false) {
        val now = SystemClock.elapsedRealtime()
        val line = "[stop] $path +${now - t0}ms at=${now}ms $text"
        lines.add(line)
        emit(line, warn)
    }

    /// Выполнить [block] с потолком [timeoutMs]. Возвращает true, если шаг
    /// завершился без исключения в срок. Не бросает.
    suspend fun step(name: String, timeoutMs: Long, block: () -> Unit): Boolean {
        mark("$name begin")
        val started = SystemClock.elapsedRealtime()
        val done = CompletableDeferred<Result<Unit>>()
        Thread({ done.complete(runCatching(block)) }, "lxbox-stop-$name")
            .apply { isDaemon = true }
            .start()

        val stuckAfter = minOf(STUCK_AFTER_MS, timeoutMs)
        var r = withTimeoutOrNull(stuckAfter) { done.await() }
        if (r == null) {
            onStuck(name, SystemClock.elapsedRealtime() - started)
            r = withTimeoutOrNull(timeoutMs - stuckAfter) { done.await() }
        }
        val took = SystemClock.elapsedRealtime() - started
        return when {
            r == null -> {
                mark("$name TIMEOUT after ${took}ms, abandoned (thread still blocked)", warn = true)
                // Поздний возврат брошенного шага — тоже улика: сколько он
                // висел на самом деле.
                done.invokeOnCompletion {
                    mark("$name returned late after ${SystemClock.elapsedRealtime() - started}ms", warn = true)
                }
                false
            }
            r.isFailure -> {
                mark("$name failed in ${took}ms: ${r.exceptionOrNull()}", warn = true)
                false
            }
            else -> {
                mark("$name done in ${took}ms")
                true
            }
        }
    }

    /// Один раз на остановку: WARN со всей трассой (она переживает
    /// перезапуск приложения в `corelog.txt`) и дамп горутин в отдельном
    /// потоке — `PProfClient` поднимает свой `PProfServer`, от
    /// `CommandServer` не зависит, но на дедлоке рантайма может сам ждать
    /// до своих таймаутов, поэтому остановку он не держит.
    private fun onStuck(step: String, elapsedMs: Long) {
        if (!stuckFired.compareAndSet(false, true)) return
        mark("stuck at $step after ${elapsedMs}ms", warn = true)
        val traceSoFar = synchronized(lines) { lines.joinToString("\n") }
        emit("[stop] $path trace so far:\n$traceSoFar", true)
        Thread({
            runCatching { PProfClient.goroutineDump() }
                .onSuccess { dump ->
                    runCatching { writeDumpFile(traceSoFar, dump) }
                        .onFailure { emit("[stop] $path goroutine dump file write failed: $it", true) }
                    emit(summarizeGoroutines(dump), true)
                }
                .onFailure { emit("[stop] $path goroutine dump failed: $it", true) }
        }, "lxbox-stop-dump").apply { isDaemon = true }.start()
    }

    private fun writeDumpFile(trace: String, dump: String) {
        val body = "$trace\n\n$dump"
        val capped = if (body.length > DUMP_FILE_MAX_CHARS) {
            body.substring(0, DUMP_FILE_MAX_CHARS) + "\n…(truncated)"
        } else body
        File(filesDir, DUMP_FILE_NAME).writeText(capped)
    }

    companion object {
        /// Сторож: шаг дольше этого — дамп (или раньше, если потолок шага меньше).
        const val STUCK_AFTER_MS = 5_000L

        /// Полный дамп последнего зависания; `DumpBuilder` кладёт его в пак
        /// поддержки полем `stop_stuck_goroutines`.
        const val DUMP_FILE_NAME = "stop_stuck_goroutines.txt"
        private const val DUMP_FILE_MAX_CHARS = 1 shl 20

        private const val SUMMARY_MAX_GOROUTINES = 8
        private const val SUMMARY_MAX_LINES = 30
        private const val SUMMARY_MAX_CHARS = 24 * 1024

        /// Заголовок горутины вида `goroutine 7 [sync.Mutex.Lock, 3 minutes]:`.
        private val BLOCKED_HEADER_RE =
            Regex("^goroutine \\d+ \\[(semacquire|sync\\.(Mutex|RWMutex|WaitGroup|Cond))")
        private val TEARDOWN_MARKERS = listOf("CloseService", "Endpoint).Close", "closeBindLocked")

        /// Сводка для журнала: всего горутин и до [SUMMARY_MAX_GOROUTINES]
        /// горутин, стоящих на примитивах синхронизации или в цепочке
        /// закрытия. Полный дамп — в файле.
        internal fun summarizeGoroutines(dump: String): String {
            val blocks = dump.split(Regex("\n\\s*\n"))
                .map { it.trim() }
                .filter { it.startsWith("goroutine ") }
            val picked = blocks.filter { b ->
                BLOCKED_HEADER_RE.containsMatchIn(b.lineSequence().first()) ||
                    TEARDOWN_MARKERS.any { b.contains(it) }
            }
            val sb = StringBuilder("[stop] goroutines: total=${blocks.size} blocked_or_teardown=${picked.size}")
            for (b in picked.take(SUMMARY_MAX_GOROUTINES)) {
                val ls = b.lines()
                sb.append("\n\n").append(ls.take(SUMMARY_MAX_LINES).joinToString("\n"))
                if (ls.size > SUMMARY_MAX_LINES) sb.append("\n…(+${ls.size - SUMMARY_MAX_LINES} lines)")
                if (sb.length > SUMMARY_MAX_CHARS) break
            }
            if (picked.size > SUMMARY_MAX_GOROUTINES) {
                sb.append("\n\n…(+${picked.size - SUMMARY_MAX_GOROUTINES} more)")
            }
            sb.append("\n\nfull dump: $DUMP_FILE_NAME")
            return if (sb.length > SUMMARY_MAX_CHARS + 4096) {
                sb.substring(0, SUMMARY_MAX_CHARS) + "\n…(truncated)"
            } else sb.toString()
        }
    }
}
