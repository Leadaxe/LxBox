package com.leadaxe.lxbox.vpn

import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.io.DataInputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/// §747 — сторона окна (`:ui`) связи с сервисной стороной (`:bg`).
///
/// **Вызовы** (`BgControlProvider.call()`) с главного потока не делаются
/// никогда. Все уходят с одной упорядоченной полосы ([onLane]) — порядок
/// вызовов Dart сохраняется (`setHasTun` → `startVPN`, `saveConfig` →
/// `reloadVPN`):
/// - быстрый ([forward]) — синхронный, ответ тем же вызовом;
/// - долгий ([forward] с `long`, [callAsync]) — вызов только запускает метод
///   в `:bg` и сразу возвращается; ответ приходит кадром канала событий.
///   Полосу и пул Binder долгий метод не занимает.
///
/// **Канал событий** `:bg` → `:ui` ([connect]): pipe, по которому приходят
/// потоки данных окна и ответы долгих вызовов. Кадр потока Dart — готовый
/// конверт `EventChannel`: окно отдаёт его в канал как есть.
object BgClient {
    private const val TAG = "BgClient"

    /// Сколько раз повторить вызов, попавший на смену процесса `:bg`, и паузы
    /// между попытками (растут до [DEAD_RETRY_PAUSE_MAX_MS]; всего ~3 с). Под
    /// нагрузкой система узнаёт о гибели процесса не сразу и какое-то время
    /// отдаёт мёртвого провайдера — короткой серии повторов на это не хватает.
    private const val DEAD_RETRIES = 10
    private const val DEAD_RETRY_PAUSE_MS = 50L
    private const val DEAD_RETRY_PAUSE_MAX_MS = 500L

    /// Методы, которые после `DeadObjectException` не повторяются: их двойное
    /// исполнение видно пользователю (два файла в Downloads, две отправки).
    private val NO_REPLAY = setOf("taildropSave", "taildropSendUris", "ccTaildropSendBytes")

    /// `quitApp` отработал: `:bg` завершается, окно — следом. Вызовы после
    /// этого не делаются — запоздалый `uiDetached` поднял бы новый `:bg`.
    @Volatile
    private var closed = false

    fun shutDown() {
        closed = true
    }

    /// Номер жизни канала событий: растёт, когда канал кончается.
    @Volatile
    private var channelGen = 0L

    /// Приёмник строк журнала приложения от стороны окна (повтор вызова после
    /// гибели `:bg`); ставит `VpnPlugin`, пока подключён движок.
    @Volatile
    var journal: ((String) -> Unit)? = null

    private fun note(text: String) {
        Log.w(TAG, text)
        runCatching { journal?.invoke("WARN [ui] $text") }
    }

    private val lane = Executors.newSingleThreadExecutor { r ->
        Thread(r, "lxbox-bg-lane").apply { isDaemon = true }
    }
    private val longSeq = AtomicInteger(0)
    private val longPool = Executors.newCachedThreadPool { r ->
        Thread(r, "lxbox-bg-long-${longSeq.incrementAndGet()}").apply { isDaemon = true }
    }
    private val main = Handler(Looper.getMainLooper())

    fun onLane(block: () -> Unit) {
        lane.execute { runCatching(block).onFailure { Log.w(TAG, "lane task failed: $it") } }
    }

    fun onMain(block: () -> Unit) {
        main.post(block)
    }

    // ───────────────────────── вызовы ─────────────────────────

    /// Блокирующий вызов метода [BgMethods]. Отказ метода — [BgError] (то, что
    /// Dart видел как `PlatformException`); сбой самого вызова (процесс `:bg`
    /// не поднялся, исключение в обработчике) — тоже [BgError] с кодом
    /// `BG_CALL_FAILED`. Не звать с главного потока.
    fun call(ctx: Context, method: String, args: Map<String, Any?>? = null): Any? {
        val extras = argsBundle(ctx, args)
        val reply = try {
            raw(ctx, method, null, extras)
        } finally {
            // Посылку с аргументами удаляет отправитель: при повторе вызова
            // она нужна снова, а при сбое не должна осиротеть.
            BgControlProvider.dropFile(ctx, extras, BgControlProvider.KEY_ARGS_FILE)
        }
        return BgCodec.decode(
            BgControlProvider.takeBytes(
                ctx, reply, BgControlProvider.KEY_RESULT, BgControlProvider.KEY_RESULT_FILE,
                delete = true,
            ),
        )
    }

    private fun argsBundle(ctx: Context, args: Map<String, Any?>?): Bundle {
        val extras = Bundle()
        if (args != null) {
            BgControlProvider.putBytes(
                ctx, extras, BgControlProvider.KEY_ARGS, BgControlProvider.KEY_ARGS_FILE,
                BgCodec.encode(args),
            )
        }
        return extras
    }

    /// Один вызов провайдера. Соединение с провайдером — «нестабильное»
    /// (`acquireUnstableContentProviderClient`): процесс `:bg` завершается сам
    /// (§747 G), а при обычном, «стабильном» соединении система вместе с
    /// умершим провайдером убивает и его клиента — окно.
    ///
    /// Вызов, попавший на смену процесса, повторяется:
    /// - отказ `BG_EXITING` — `:bg` уже решил завершиться и вызов **не
    ///   исполнял** (`BgLifecycle.enter`); повтор безопасен всегда;
    /// - `DeadObjectException` — транзакция ушла в процесс, которого уже нет
    ///   (система ещё не узнала о его гибели), либо процесс **упал посреди
    ///   вызова**. Второй случай от первого отсюда не отличить, и при нём
    ///   повтор исполнит метод второй раз. Для почти всех методов это
    ///   безвредно (запись настройки, команда сервису под защитой статуса,
    ///   чтение); методы из [NO_REPLAY], чьё двойное исполнение видно
    ///   пользователю, после `DeadObjectException` не повторяются — вызов
    ///   завершается ошибкой.
    ///
    /// Наружу ошибка выходит, только если и повторы не удались.
    private fun raw(ctx: Context, method: String, arg: String?, extras: Bundle?): Bundle {
        val what = if (method == BgControlProvider.METHOD_INVOKE_ASYNC) "$method:$arg" else method
        val name = if (method == BgControlProvider.METHOD_INVOKE_ASYNC) arg else method
        var attempt = 0
        while (true) {
            if (closed) throw BgError(BgControlProvider.ERROR_CALL_FAILED, "the app is quitting")
            var retry: String? = null
            val reply = try {
                val client = ctx.contentResolver
                    .acquireUnstableContentProviderClient(BgControlProvider.uri(ctx))
                    ?: throw BgError(BgControlProvider.ERROR_CALL_FAILED, "no provider")
                try {
                    client.call(method, arg, extras)
                } finally {
                    runCatching { client.close() }
                }
            } catch (e: android.os.DeadObjectException) {
                if (name in NO_REPLAY) {
                    note("call $what failed: the service process died and the call is not replayable")
                    throw BgError(BgControlProvider.ERROR_CALL_FAILED, "service process died during the call")
                }
                retry = "DeadObject"
                null
            } catch (e: BgError) {
                throw e
            } catch (t: Throwable) {
                throw BgError(BgControlProvider.ERROR_CALL_FAILED, t.message ?: t.javaClass.simpleName)
            }
            if (retry == null) {
                reply ?: throw BgError(BgControlProvider.ERROR_CALL_FAILED, "no reply")
                val code = reply.getString(BgControlProvider.KEY_ERROR_CODE) ?: return reply
                if (code != BgControlProvider.ERROR_EXITING) {
                    throw BgError(code, reply.getString(BgControlProvider.KEY_ERROR_MESSAGE))
                }
                retry = "BG_EXITING"
            }
            if (++attempt > DEAD_RETRIES) {
                note("call $what failed: the service process is gone ($DEAD_RETRIES replays)")
                throw BgError(BgControlProvider.ERROR_CALL_FAILED, "service process is gone")
            }
            note("call $what replayed after $retry (attempt $attempt)")
            runCatching {
                Thread.sleep(
                    (DEAD_RETRY_PAUSE_MS shl (attempt - 1).coerceAtMost(4))
                        .coerceAtMost(DEAD_RETRY_PAUSE_MAX_MS),
                )
            }
        }
    }

    /// [call], который не бросает: сбой — в лог и [fallback].
    fun <T> callOr(ctx: Context, method: String, args: Map<String, Any?>?, fallback: T): T =
        try {
            @Suppress("UNCHECKED_CAST")
            call(ctx, method, args) as T
        } catch (t: Throwable) {
            Log.w(TAG, "call($method) failed: ${t.message}")
            fallback
        }

    private val nextId = AtomicLong(0)

    /// Ждущий ответа долгий вызов. [dispatched] — `:bg` принял его к
    /// исполнению (вызов-запуск вернулся): только такой вызов пропадает вместе
    /// с процессом. Пока запуск в пути (в том числе повторяется в новый
    /// процесс), конец канала событий его не касается.
    private class Pending(val done: (Result<Any?>) -> Unit) {
        @Volatile
        var dispatched = false
    }

    /// Ждущие ответа долгие вызовы: номер → приёмник (зовётся на главном потоке).
    private val pending = ConcurrentHashMap<Long, Pending>()

    /// Долгий вызов: запустить метод в `:bg` и получить ответ кадром канала
    /// событий. [done] зовётся на главном потоке ровно один раз. Запуск идёт
    /// полосой (после всех ранее отправленных вызовов). Канала событий нет —
    /// запасной путь: синхронный вызов на отдельном потоке.
    fun callAsync(
        ctx: Context,
        method: String,
        args: Map<String, Any?>?,
        done: (Result<Any?>) -> Unit,
    ) {
        onLane {
            val id = nextId.incrementAndGet()
            val entry = Pending(done)
            pending[id] = entry
            val extras = argsBundle(ctx, args).apply { putLong(BgControlProvider.KEY_ID, id) }
            try {
                val gen = channelGen
                raw(ctx, BgControlProvider.METHOD_INVOKE_ASYNC, method, extras)
                entry.dispatched = true
                // Канал кончился, пока запуск возвращался: принявший вызов
                // процесс умер, а конец канала эту запись ещё не видел
                // принятой — ответа не будет, ответить нужно здесь.
                if (channelGen != gen && pending.remove(id) != null) {
                    main.post {
                        done(Result.failure(BgError(BgControlProvider.ERROR_CALL_FAILED, "service process is gone")))
                    }
                }
            } catch (e: BgError) {
                // Ответить должен ровно один: кто снял запись, тот и отвечает.
                if (pending.remove(id) == null) return@onLane
                if (e.code == BgControlProvider.ERROR_NO_PIPE) {
                    // Новый `:bg` ещё не получил канал событий (окно заново
                    // подключается после его перезапуска) — синхронным вызовом.
                    longPool.execute {
                        val reply = runCatching { call(ctx, method, args) }
                        main.post { done(reply) }
                    }
                } else {
                    main.post { done(Result.failure(e)) }
                }
            } finally {
                // `:bg` читает аргументы до возврата запуска — посылка больше
                // не нужна (запасной синхронный путь создаёт свою).
                BgControlProvider.dropFile(ctx, extras, BgControlProvider.KEY_ARGS_FILE)
            }
        }
    }

    /// Переслать вызов Dart в `:bg` под тем же именем и ответить Dart на
    /// главном потоке тем же значением (или той же ошибкой). [long] — долгим
    /// вызовом ([callAsync]), иначе — синхронно на полосе.
    fun forward(
        ctx: Context,
        method: String,
        arguments: Any?,
        result: MethodChannel.Result,
        long: Boolean = false,
    ) {
        @Suppress("UNCHECKED_CAST")
        val args = arguments as? Map<String, Any?>
        if (long) {
            callAsync(ctx, method, args) { answer(result, it) }
        } else {
            onLane {
                val reply = runCatching { call(ctx, method, args) }
                main.post { answer(result, reply) }
            }
        }
    }

    fun answer(result: MethodChannel.Result, reply: Result<Any?>) {
        reply.fold(
            onSuccess = { runCatching { result.success(it) } },
            onFailure = { e ->
                val code = (e as? BgError)?.code ?: BgControlProvider.ERROR_CALL_FAILED
                runCatching { result.error(code, e.message, null) }
            },
        )
    }

    // ───────────────────────── канал событий ─────────────────────────

    private class Reader(
        readEnd: ParcelFileDescriptor,
        val onFrame: (String, ByteArray) -> Unit,
        val onLost: () -> Unit,
    ) {
        val input = DataInputStream(
            ParcelFileDescriptor.AutoCloseInputStream(readEnd).buffered(64 * 1024),
        )

        @Volatile
        var stopped = false

        fun stop() {
            stopped = true
            runCatching { input.close() }
        }
    }

    @Volatile
    private var reader: Reader? = null

    /// Открыть канал событий и назвать себя `:bg` (`uiAttached`): создаётся
    /// pipe, читающий конец остаётся здесь, пишущий уходит в `:bg` вместе с
    /// Binder-меткой [token] живого процесса окна. Прежний канал закрывается.
    /// [onFrame] — кадр потока Dart (имя канала, готовый конверт события) или
    /// служебный кадр — зовётся на главном потоке; следующий кадр читается
    /// только после доставки предыдущего, так что медленный главный поток
    /// тормозит чтение, а не копит кадры в памяти окна.
    ///
    /// [onLost] — канал оборвался не по [disconnect]: процесс `:bg` ушёл
    /// (перезапустился, чтобы сбросить ядро, или умер); зовётся на главном
    /// потоке, окно в ответ подключается заново.
    ///
    /// Блокирует (вызов `:bg`); звать с полосы. `false` — `:bg` не ответил.
    fun connect(
        ctx: Context,
        token: IBinder,
        onFrame: (String, ByteArray) -> Unit,
        onLost: () -> Unit,
    ): Boolean {
        disconnect()
        val pipe = runCatching { ParcelFileDescriptor.createPipe() }.getOrNull() ?: return false
        val r = Reader(pipe[0], onFrame, onLost)
        reader = r
        Thread({ read(r) }, "lxbox-event-read").apply { isDaemon = true }.start()
        val ok = runCatching {
            raw(
                ctx, BgControlProvider.METHOD_UI_ATTACHED, null,
                Bundle().apply {
                    putBinder(BgControlProvider.KEY_TOKEN, token)
                    putParcelable(BgControlProvider.KEY_PFD, pipe[1])
                },
            )
        }.onFailure { Log.w(TAG, "uiAttached failed: ${it.message}") }.isSuccess
        // Свой экземпляр пишущего конца закрываем: у `:bg` — дубликат. Если
        // вызов не удался, читатель увидит конец потока и завершится.
        runCatching { pipe[1].close() }
        return ok
    }

    /// Закрыть канал событий (движок отключён): `:bg` на записи получит `EPIPE`.
    fun disconnect() {
        reader?.stop()
        reader = null
        channelGen++
        failDispatched("window detached")
    }

    private fun read(r: Reader) {
        try {
            while (!r.stopped) {
                val (stream, payload) = EventFrames.read(r.input)
                if (stream == EventFrames.REPLY) {
                    reply(payload)
                    continue
                }
                val done = CountDownLatch(1)
                main.post {
                    try {
                        if (!r.stopped) r.onFrame(stream, payload)
                    } catch (t: Throwable) {
                        Log.w(TAG, "frame($stream) failed: ${t.message}")
                    } finally {
                        done.countDown()
                    }
                }
                done.await()
            }
        } catch (_: Throwable) {
            // Конец потока: `:bg` закрыл канал или умер; либо disconnect().
        } finally {
            runCatching { r.input.close() }
            if (reader === r) {
                reader = null
                channelGen++
                // Процесс `:bg` ушёл. Принятые им вызовы пропали вместе с ним
                // (при перезапуске ради ядра таких нет: `:bg` дожидается
                // ответов); вызовы, чей запуск ещё в пути, повторятся сами.
                failDispatched("service process is gone")
                if (!r.stopped) main.post { if (!r.stopped) r.onLost() }
            }
        }
    }

    private fun reply(payload: ByteArray) {
        val m = runCatching { BgCodec.decode(payload) as? Map<*, *> }.getOrNull() ?: return
        val id = (m["id"] as? Number)?.toLong() ?: return
        val done = pending.remove(id)?.done ?: return
        val code = m["ec"] as? String
        val result: Result<Any?> =
            if (code != null) Result.failure(BgError(code, m["em"] as? String))
            else Result.success(m["r"])
        main.post { done(result) }
    }

    private fun failDispatched(why: String) {
        for ((id, entry) in pending.entries.toList()) {
            if (!entry.dispatched) continue
            if (pending.remove(id) == null) continue
            main.post {
                entry.done(Result.failure(BgError(BgControlProvider.ERROR_CALL_FAILED, why)))
            }
        }
    }
}
