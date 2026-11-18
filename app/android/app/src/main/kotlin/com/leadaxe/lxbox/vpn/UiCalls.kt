package com.leadaxe.lxbox.vpn

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull

/// §747 — вызовы с ответом, ждущие другую сторону: сопоставление по номеру.
/// Чистая логика без Android (JVM-тест).
///
/// У вызова два события: [ack] — другая сторона получила запрос (она жива и
/// не заморожена) и [complete] — она ответила. Вызывающий ждёт их с разными
/// сроками. [close] снимает запись: событие с её номером, пришедшее позже
/// (ответ после таймаута), никому не достаётся.
internal class PendingCalls<T> {
    class Entry<T> {
        val acked = CompletableDeferred<Unit>()
        val result = CompletableDeferred<T>()
    }

    private val next = AtomicLong(0)
    private val entries = ConcurrentHashMap<Long, Entry<T>>()

    val size: Int get() = entries.size

    fun open(): Pair<Long, Entry<T>> {
        val id = next.incrementAndGet()
        val e = Entry<T>()
        entries[id] = e
        return id to e
    }

    /// Запрос [id] получен. `false` — такого вызова уже нет.
    fun ack(id: Long): Boolean {
        val e = entries[id] ?: return false
        e.acked.complete(Unit)
        return true
    }

    /// Ответ на вызов [id]. `false` — вызова нет (срок вышел) или уже отвечен.
    fun complete(id: Long, value: T): Boolean {
        val e = entries.remove(id) ?: return false
        e.acked.complete(Unit)
        return e.result.complete(value)
    }

    fun close(id: Long) {
        entries.remove(id)
    }
}

/// §747 — обратный вызов `:bg` → Dart окна **с ответом**: метод
/// `MethodChannel` плагина, который исполняет Dart (§750 — шлюз ассистента
/// `assistantCall`).
///
/// Запрос уходит окну кадром [EventFrames.CALL] `{id, method, args}`; окно
/// сразу подтверждает получение (`uiCallAck`), исполняет `invokeMethod` в Dart
/// и возвращает итог вызовом `uiCallReply` по номеру. Ответ и подтверждение
/// приходят обычными вызовами окна (`BgMethods`).
///
/// Подтверждение отделяет «окна нет или оно заморожено системой» (кадр лежит
/// в pipe, никто его не читает) от «Dart долго исполняет запрос»: первого
/// ждём недолго, второго — сколько положено вызову.
object UiCalls {
    /// Сколько ждать, что окно получило запрос.
    const val ACK_TIMEOUT_MS = 2_000L

    sealed class Reply {
        data class Ok(val value: Any?) : Reply()
        data class Error(val code: String, val message: String?) : Reply()
        object NotImplemented : Reply()
    }

    sealed class Outcome {
        /// Окна нет, канала событий нет или окно не подтвердило получение.
        object NotDelivered : Outcome()
        /// Окно получило запрос, но Dart не ответил в срок.
        object TimedOut : Outcome()
        data class Answered(val reply: Reply) : Outcome()
    }

    private val pending = PendingCalls<Reply>()

    /// Окно подключено и канал событий открыт.
    val available: Boolean get() = UiPresence.isAttached && BgEventPipe.connected

    suspend fun invoke(
        method: String,
        args: Map<String, Any?>,
        timeoutMs: Long,
        ackTimeoutMs: Long = ACK_TIMEOUT_MS,
    ): Outcome {
        if (!available) return Outcome.NotDelivered
        val (id, entry) = pending.open()
        try {
            val sent = BgEventPipe.reliable(
                EventFrames.CALL, mapOf("id" to id, "method" to method, "args" to args),
            )
            if (!sent) return Outcome.NotDelivered
            withTimeoutOrNull(ackTimeoutMs) { entry.acked.await() } ?: return Outcome.NotDelivered
            val reply = withTimeoutOrNull(timeoutMs) { entry.result.await() }
            return if (reply == null) Outcome.TimedOut else Outcome.Answered(reply)
        } finally {
            pending.close(id)
        }
    }

    /// `uiCallAck` — окно получило запрос [id].
    fun onAck(id: Long) {
        pending.ack(id)
    }

    /// `uiCallReply` — итог `invokeMethod`: `{id, kind: ok|error|missing, …}`.
    fun onReply(id: Long, kind: String, value: Any?, code: String?, message: String?) {
        pending.complete(
            id,
            when (kind) {
                "ok" -> Reply.Ok(value)
                "error" -> Reply.Error(code ?: "error", message)
                else -> Reply.NotImplemented
            },
        )
    }
}
