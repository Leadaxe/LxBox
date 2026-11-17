package com.leadaxe.lxbox.vpn

import android.os.ParcelFileDescriptor
import android.util.Log
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicLong

/// §747 — кадр потока лога: длина UTF-8 (int) и байты. Строка лога ядра
/// бывает многострочной (стек), поэтому разделитель-перевод строки не годится.
internal object LogFrames {
    /// Строка длиннее — признак рассинхрона потока, а не лога.
    const val MAX_FRAME = 4 * 1024 * 1024

    fun write(out: DataOutputStream, line: String) {
        val bytes = line.toByteArray(Charsets.UTF_8)
        out.writeInt(bytes.size)
        out.write(bytes)
    }

    /// Следующая строка; конец потока — [EOFException].
    fun read(input: DataInputStream): String {
        val n = input.readInt()
        if (n < 0 || n > MAX_FRAME) throw EOFException("bad log frame length $n")
        val buf = ByteArray(n)
        input.readFully(buf)
        return String(buf, Charsets.UTF_8)
    }
}

/// §747 — сервисная сторона (`:bg`) потока лога в окно: строки ядра
/// (`BoxService.writeDebugMessage`) и журнала приложения (`appLogLine`).
///
/// Окно при подписке на лог создаёт pipe и передаёт сюда пишущий конец
/// вызовом `openLogPipe`; отписка — вызов `closeLogPipe` или закрытие
/// читающего конца (запись получает `EPIPE`, в том числе при гибели `:ui`).
///
/// [active] — гейт «никто не слушает — не форматировать»: первой строкой
/// проверяется в `BoxService`, как раньше `UiSinks.coreLogSink == null`.
/// Очередь ограничена ([QUEUE_MAX], лишнее отбрасывается со счётчиком): если
/// окно заморожено системой и не читает, пишущий поток стоит на `write`, а
/// поток ядра не блокируется.
object BgLogPipe {
    private const val TAG = "BgLogPipe"
    private const val QUEUE_MAX = 4096

    private class Session(val out: DataOutputStream) {
        val queue = LinkedBlockingQueue<String>()
        @Volatile var closed = false
    }

    @Volatile
    private var session: Session? = null

    private val drops = AtomicLong(0)

    val active: Boolean get() = session != null

    /// Подключить пишущий конец [writeEnd] (прежний поток закрывается).
    /// Дескриптор дублируется: при вызове внутри одного процесса `Bundle` не
    /// пакуется, и вызывающий закрывает тот же объект, что получили мы.
    @Synchronized
    fun attach(writeEnd: ParcelFileDescriptor?) {
        close()
        val pfd = writeEnd ?: return
        val own = runCatching { pfd.dup() }.getOrNull()
        runCatching { pfd.close() }
        if (own == null) return
        val s = Session(
            DataOutputStream(ParcelFileDescriptor.AutoCloseOutputStream(own).buffered(16 * 1024)),
        )
        session = s
        Thread({ pump(s) }, "lxbox-log-pipe").apply { isDaemon = true }.start()
    }

    @Synchronized
    fun close() {
        val s = session ?: return
        session = null
        finish(s)
    }

    /// Строка в поток; без слушателя или при полной очереди — отбрасывается.
    fun offer(line: String) {
        val s = session ?: return
        if (s.queue.size >= QUEUE_MAX) {
            drops.incrementAndGet()
            return
        }
        s.queue.offer(line)
    }

    private fun finish(s: Session) {
        s.closed = true
        s.queue.clear()
        // Пустая строка будит пишущий поток, стоящий на take().
        s.queue.offer("")
        // Закрытие — не под замком объекта и не здесь: поток может стоять в
        // write() на полном pipe, close() из другого потока его не снимет, а
        // сам он закроет поток, когда выйдет.
    }

    private fun pump(s: Session) {
        try {
            while (!s.closed) {
                val line = s.queue.take()
                if (s.closed) break
                LogFrames.write(s.out, line)
                if (s.queue.isEmpty()) s.out.flush()
            }
        } catch (t: Throwable) {
            // EPIPE: окно закрыло читающий конец или процесс `:ui` умер.
            Log.d(TAG, "log pipe closed: ${t.javaClass.simpleName}")
        } finally {
            runCatching { s.out.close() }
            synchronized(this) { if (session === s) session = null }
            s.queue.clear()
        }
    }
}

/// §747 — сторона окна (`:ui`) потока лога: читает кадры из pipe и отдаёт их
/// пачками в [deliver] на главном потоке (форма события `lxbox/coreLog`
/// прежняя — список строк, до [BATCH_MAX] за раз).
///
/// Следующая пачка читается только после доставки предыдущей: медленный
/// главный поток тормозит чтение, pipe заполняется, и лишнее отбрасывает
/// ограниченная очередь `:bg` — память окна не растёт.
class UiLogPipeReader(
    readEnd: ParcelFileDescriptor,
    private val post: (Runnable) -> Unit,
    private val deliver: (List<String>) -> Unit,
    private val onEnd: () -> Unit,
) {
    private val input = DataInputStream(
        ParcelFileDescriptor.AutoCloseInputStream(readEnd).buffered(16 * 1024),
    )

    @Volatile
    private var stopped = false

    fun start() {
        Thread({ run() }, "lxbox-log-read").apply { isDaemon = true }.start()
    }

    /// Закрыть читающий конец: пишущая сторона получит `EPIPE`.
    fun stop() {
        stopped = true
        runCatching { input.close() }
    }

    private fun run() {
        try {
            while (!stopped) {
                val batch = ArrayList<String>()
                batch.add(LogFrames.read(input))
                while (batch.size < BATCH_MAX && input.available() > 0) {
                    batch.add(LogFrames.read(input))
                }
                val done = CountDownLatch(1)
                post(Runnable {
                    try {
                        if (!stopped) deliver(batch)
                    } finally {
                        done.countDown()
                    }
                })
                done.await()
            }
        } catch (_: Throwable) {
            // Конец потока: `:bg` закрыл pipe или умер; либо stop().
        } finally {
            runCatching { input.close() }
            if (!stopped) onEnd()
        }
    }

    companion object {
        const val BATCH_MAX = 200
    }
}
