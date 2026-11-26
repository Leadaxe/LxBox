package com.leadaxe.lxbox.vpn

import android.os.ParcelFileDescriptor
import android.util.Log
import io.flutter.plugin.common.EventChannel
import java.io.DataOutputStream
import java.util.ArrayDeque
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.locks.ReentrantLock

/// §747 — очереди канала событий: что ждёт записи в pipe. Чистая логика без
/// Android (JVM-тест): четыре класса кадров с разной судьбой при отставшем
/// читателе.
///
/// - **reliable** — ответы асинхронных вызовов и команды автоматизации: не
///   теряются; число ограничено числом идущих вызовов;
/// - **events** — потоки событий (DNS-запросы, шаги теста соединения):
///   ограниченная очередь, при переполнении новое отбрасывается;
/// - **latest** — снимки (статус, группы, соединения…): по одному на поток,
///   последний побеждает — отставший читатель получит только свежий;
/// - **log** — строки лога: ограниченная очередь, уходят пачками.
///
/// Значения хранятся как объекты и кодируются пишущим потоком прямо перед
/// записью: вытесненный снимок не кодируется вовсе, а поток ядра и главный
/// поток `:bg` не тратят время на кодирование.
internal class PipeQueues(
    private val eventsMax: Int = EVENTS_MAX,
    private val logMax: Int = LOG_MAX,
    private val logBatchMax: Int = LOG_BATCH_MAX,
) {
    private val reliable = ArrayDeque<Pair<String, Any?>>()
    private val events = ArrayDeque<Pair<String, Any?>>()
    private val latest = LinkedHashMap<String, Any?>()
    private val log = ArrayDeque<String>()

    var dropped = 0L
        private set

    val isEmpty: Boolean
        get() = reliable.isEmpty() && events.isEmpty() && latest.isEmpty() && log.isEmpty()

    /// Ответы вызовов (и команды автоматизации), ещё не взятые на запись.
    val hasReliable: Boolean get() = reliable.isNotEmpty()

    fun reliable(stream: String, value: Any?) {
        reliable.addLast(stream to value)
    }

    fun event(stream: String, value: Any?) {
        if (events.size >= eventsMax) {
            dropped++
            return
        }
        events.addLast(stream to value)
    }

    fun latest(stream: String, value: Any?) {
        // Замена на месте: поток сохраняет свою очередь на запись.
        latest[stream] = value
    }

    fun log(line: String) {
        if (log.size >= logMax) {
            dropped++
            return
        }
        log.addLast(line)
    }

    /// Снять всё, что ждёт у потока [stream] (окно отписалось).
    fun forget(stream: String) {
        latest.remove(stream)
        events.removeAll { it.first == stream }
        if (stream == BgEventPipe.STREAM_LOG) log.clear()
    }

    /// Следующий кадр на запись: `(поток, значение)`; null — очереди пусты.
    /// Порядок: ответы вызовов, события, снимки, лог (пачкой строк).
    fun next(): Pair<String, Any?>? {
        reliable.pollFirst()?.let { return it }
        events.pollFirst()?.let { return it }
        val it = latest.entries.iterator()
        if (it.hasNext()) {
            val e = it.next()
            it.remove()
            return e.key to e.value
        }
        if (log.isNotEmpty()) {
            val batch = ArrayList<String>(minOf(log.size, logBatchMax))
            while (batch.size < logBatchMax) batch.add(log.pollFirst() ?: break)
            return BgEventPipe.STREAM_LOG to batch
        }
        return null
    }

    companion object {
        const val EVENTS_MAX = 512
        const val LOG_MAX = 4096
        const val LOG_BATCH_MAX = 200
    }
}

/// §747 — сервисная сторона (`:bg`) канала событий `:bg` → `:ui`: один pipe,
/// по которому идут все потоки данных окна — статус, outbounds, группы,
/// соединения, DNS-запросы, Tailscale, тест соединения, входящие Taildrop,
/// openconnect, лог ядра, — а также ответы асинхронных вызовов и команды
/// автоматизации. Кадр — имя потока и значение ([EventFrames]).
///
/// Окно при подключении движка создаёт pipe и передаёт сюда пишущий конец
/// (`uiAttached`); отключение — `uiDetached` или гибель `:ui` (запись получает
/// `EPIPE`).
///
/// Пишет в pipe один поток (`lxbox-event-pipe`); источники только кладут
/// значение в очередь ([PipeQueues]) и не блокируются никогда. Окно в фоне
/// может быть заморожено системой и не читать: пишущий поток тогда стоит на
/// `write`, снимки вытесняют друг друга, очереди событий и лога ограничены —
/// `:bg` не виснет и память не растёт.
object BgEventPipe {
    private const val TAG = "BgEventPipe"

    /// Поток лога: значение кадра — список строк (форма события прежняя).
    const val STREAM_LOG = "lxbox/coreLog"

    private class Session(val out: DataOutputStream) {
        val lock = ReentrantLock()
        val ready = lock.newCondition()
        val queues = PipeQueues()
        var closed = false

        /// Пишущий поток взял кадр и ещё не дописал его; [writingKept] — кадр,
        /// который нельзя терять (ответ вызова, команда автоматизации).
        var writing = false
        var writingKept = false
    }

    @Volatile
    private var session: Session? = null

    /// Окно слушает лог (`lxbox/coreLog`).
    @Volatile
    private var logListening = false

    private val drops = AtomicLong(0)

    /// Канал открыт: окно подключено и читает (или заморожено).
    val connected: Boolean get() = session != null

    /// Ответ вызова окна ждёт записи или пишется: процессу рано завершаться
    /// (`BgLifecycle`) — окно осталось бы без ответа. Дописанное в pipe окно
    /// дочитает и после гибели `:bg`.
    val hasPendingReplies: Boolean
        get() {
            val s = session ?: return false
            s.lock.lock()
            try {
                return !s.closed && (s.queues.hasReliable || s.writingKept)
            } finally {
                s.lock.unlock()
            }
        }

    /// Дать пишущему потоку дописать то, что уже в очередях (последние строки
    /// журнала перед завершением процесса), не дольше [maxMs]. Замороженное
    /// окно не читает — тогда срок просто истекает.
    fun drain(maxMs: Long) {
        val deadline = System.nanoTime() + maxMs * 1_000_000L
        while (System.nanoTime() < deadline) {
            val s = session ?: return
            s.lock.lock()
            val idle = try {
                s.closed || (s.queues.isEmpty && !s.writing)
            } finally {
                s.lock.unlock()
            }
            if (idle) return
            runCatching { Thread.sleep(10L) }
        }
    }

    /// Гейт «никто не слушает — не форматировать»: первой строкой проверяется
    /// в `BoxService.writeDebugMessage`.
    val logActive: Boolean get() = logListening && session != null

    fun setLogListening(on: Boolean) {
        logListening = on
        if (!on) put("forget log") { queues.forget(STREAM_LOG) }
    }

    /// Подключить пишущий конец [writeEnd] (прежний канал закрывается).
    /// Дескриптор дублируется: полученный объект закрывает отправитель.
    @Synchronized
    fun attach(writeEnd: ParcelFileDescriptor?) {
        close()
        val pfd = writeEnd ?: return
        val own = runCatching { pfd.dup() }.getOrNull()
        runCatching { pfd.close() }
        if (own == null) return
        val s = Session(
            DataOutputStream(ParcelFileDescriptor.AutoCloseOutputStream(own).buffered(64 * 1024)),
        )
        session = s
        Thread({ pump(s) }, "lxbox-event-pipe").apply { isDaemon = true }.start()
    }

    @Synchronized
    fun close() {
        val s = session ?: return
        session = null
        logListening = false
        s.lock.lock()
        try {
            s.closed = true
            s.ready.signalAll()
        } finally {
            s.lock.unlock()
        }
        // Поток может стоять в write() на полном pipe; close() из другого
        // потока его не снимет — он закроет дескриптор сам, когда выйдет
        // (читающий конец к этому времени закрыт окном или его гибелью).
    }

    /// Строка лога; без слушателя — отбрасывается.
    fun logLine(line: String) {
        if (!logListening) return
        put("log") { queues.log(line) }
    }

    /// Снимок потока [stream]: последний побеждает.
    fun latest(stream: String, value: Any?) = put(stream) { queues.latest(stream, value) }

    /// Событие потока [stream]: ограниченная очередь.
    fun event(stream: String, value: Any?) = put(stream) { queues.event(stream, value) }

    /// Кадр, который нельзя терять (ответ вызова, команда автоматизации).
    /// `false` — канала нет.
    fun reliable(stream: String, value: Any?): Boolean =
        put(stream) { queues.reliable(stream, value) }

    /// Окно отписалось от потока — недоставленное ему больше не нужно.
    fun forget(stream: String) {
        put(stream) { queues.forget(stream) }
    }

    private inline fun put(what: String, block: Session.() -> Unit): Boolean {
        val s = session ?: return false
        s.lock.lock()
        try {
            if (s.closed) return false
            s.block()
            s.ready.signal()
        } catch (t: Throwable) {
            Log.w(TAG, "offer($what) failed: ${t.javaClass.simpleName}")
            return false
        } finally {
            s.lock.unlock()
        }
        return true
    }

    private fun pump(s: Session) {
        try {
            while (true) {
                val frame: Pair<String, Any?>
                s.lock.lock()
                try {
                    var next = s.queues.next()
                    while (next == null && !s.closed) {
                        s.ready.await()
                        next = s.queues.next()
                    }
                    if (s.closed) break
                    frame = next!!
                    s.writing = true
                    s.writingKept = frame.first.startsWith("!")
                } finally {
                    s.lock.unlock()
                }
                val (stream, value) = frame
                // Служебные кадры окно декодирует само; события Dart идут
                // готовым конвертом EventChannel — окно их не перекодирует.
                // Значение, которое кодек не принял (чужой тип в ответе метода),
                // роняет один кадр, а не весь канал: поток Dart теряет событие,
                // вызов получает ошибку вместо ответа.
                val payload = try {
                    if (stream.startsWith("!")) BgCodec.encode(value)
                    else BgCodec.encodeEventEnvelope(value)
                } catch (t: Throwable) {
                    Log.w(TAG, "frame($stream) cannot be encoded: ${t.message}")
                    unencodable(stream, value, t)
                }
                if (payload != null) {
                    EventFrames.write(s.out, stream, payload)
                    s.out.flush()
                }
                s.lock.lock()
                s.writing = false
                s.writingKept = false
                s.lock.unlock()
            }
        } catch (t: Throwable) {
            // EPIPE: окно закрыло читающий конец или процесс `:ui` умер.
            Log.d(TAG, "event pipe closed: ${t.javaClass.simpleName}")
        } finally {
            runCatching { s.out.close() }
            synchronized(this) {
                if (session === s) {
                    session = null
                    logListening = false
                }
            }
            drops.addAndGet(s.queues.dropped)
        }
    }

    /// Что отправить вместо кадра, который не удалось закодировать: ответу
    /// вызова — ошибку с тем же номером (иначе вызов окна остался бы без
    /// ответа), остальным — ничего.
    internal fun unencodable(stream: String, value: Any?, cause: Throwable): ByteArray? {
        if (stream != EventFrames.REPLY) return null
        val id = (value as? Map<*, *>)?.get("id") as? Number ?: return null
        return BgCodec.encode(
            mapOf(
                "id" to id.toLong(),
                "ec" to BgControlProvider.ERROR_CALL_FAILED,
                "em" to "reply cannot be encoded: ${cause.message}",
            ),
        )
    }

    /// Приёмник `EventChannel` для клиентов ядра в `:bg`: вместо движка
    /// Flutter (его в этом процессе нет) значение уходит кадром в канал
    /// событий. [coalesce] — поток снимков: последний побеждает.
    internal class Sink(private val stream: String, private val coalesce: Boolean) :
        EventChannel.EventSink {
        override fun success(event: Any?) {
            if (coalesce) BgEventPipe.latest(stream, event) else BgEventPipe.event(stream, event)
        }

        // Клиенты ядра этими двумя не пользуются.
        override fun error(errorCode: String?, errorMessage: String?, errorDetails: Any?) {}
        override fun endOfStream() {}
    }
}
