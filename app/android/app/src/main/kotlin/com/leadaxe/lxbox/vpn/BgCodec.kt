package com.leadaxe.lxbox.vpn

import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.common.StandardMethodCodec
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.nio.ByteBuffer

/// §747 — отказ вызова `:ui` → `:bg`, который Dart должен увидеть как
/// `PlatformException(code, message)` — то же, что раньше давал
/// `result.error(code, message, null)` в обработчике `VpnPlugin`.
class BgError(val code: String, message: String?) : Exception(message)

/// §747 — кодек значений между процессами: аргументы и ответ вызова
/// `BgControlProvider.call()` и кадры канала событий `:bg` → `:ui`.
///
/// Значения — те же, что ходят по `MethodChannel` (null, Boolean, Int, Long,
/// Double, String, ByteArray, List, Map), и кодируются тем же
/// `StandardMessageCodec`: типы Dart-контракта переживают границу процессов
/// без ручной сериализации. Через Binder идут только небольшие значения
/// (предел транзакции ~1 МБ) — крупное передаётся файлом ([XFER_INLINE_MAX]);
/// кадры канала событий идут через pipe и размером не ограничены.
object BgCodec {
    /// Байты крупнее этого порога идут файлом в `cacheDir/bg-xfer`, не в Bundle.
    const val XFER_INLINE_MAX = 256 * 1024

    /// Каталог файлов-посылок между процессами (аргументы и ответы вызова
    /// больше предела Binder: конфиг на проверку, профиль pprof).
    const val XFER_DIR = "bg-xfer"

    /// Значение → байты. null кодируется одним байтом (как внутри списка).
    fun encode(value: Any?): ByteArray {
        val buf = StandardMessageCodec.INSTANCE.encodeMessage(value) ?: return byteArrayOf(0)
        buf.flip()
        return ByteArray(buf.remaining()).also { buf.get(it) }
    }

    fun decode(bytes: ByteArray?): Any? {
        if (bytes == null || bytes.isEmpty()) return null
        return StandardMessageCodec.INSTANCE.decodeMessage(ByteBuffer.wrap(bytes))
    }

    /// Событие `EventChannel` в готовом для Dart виде — «конверт успеха»
    /// `StandardMethodCodec`. Окно отдаёт эти байты в свой канал как есть, без
    /// декодирования и повторного кодирования (снимок групп на тысячу узлов
    /// кодируется один раз, в `:bg`). Конверт, а не голое значение: кодек
    /// выравнивает double и типизированные массивы от начала сообщения, и
    /// приписанный позже байт-префикс сдвинул бы выравнивание.
    fun encodeEventEnvelope(value: Any?): ByteArray {
        val buf = StandardMethodCodec.INSTANCE.encodeSuccessEnvelope(value)
        buf.flip()
        return ByteArray(buf.remaining()).also { buf.get(it) }
    }

    /// Обратное к [encodeEventEnvelope] — для теста.
    fun decodeEventEnvelope(bytes: ByteArray): Any? =
        StandardMethodCodec.INSTANCE.decodeEnvelope(
            ByteBuffer.allocateDirect(bytes.size).apply { put(bytes); flip() },
        )
}

/// §747 — кадр канала событий `:bg` → `:ui`: общая длина (int), длина имени
/// потока (byte), имя (UTF-8), полезная нагрузка. Имя потока событий Dart —
/// имя его `EventChannel` (`lxbox/cc/groups`, `lxbox/coreLog`); служебные
/// потоки начинаются с `!`.
internal object EventFrames {
    /// Кадр длиннее — признак рассинхрона потока.
    const val MAX_FRAME = 64 * 1024 * 1024

    /// Ответ асинхронного вызова: `{id, r}` или `{id, ec, em}` ([BgCodec.encode]).
    const val REPLY = "!reply"

    /// Обратный вызов метода Dart с ответом: `{id, method, args}` (`UiCalls`).
    const val CALL = "!call"

    /// Команда автоматизации для Dart: `{name, args}` ([BgCodec.encode]).
    const val AUTOMATION = "!automation"

    fun write(out: DataOutputStream, stream: String, payload: ByteArray) {
        val name = stream.toByteArray(Charsets.UTF_8)
        require(name.size in 1..127) { "bad stream name" }
        out.writeInt(1 + name.size + payload.size)
        out.writeByte(name.size)
        out.write(name)
        out.write(payload)
    }

    /// Следующий кадр; конец потока — [EOFException].
    fun read(input: DataInputStream): Pair<String, ByteArray> {
        val total = input.readInt()
        if (total < 2 || total > MAX_FRAME) throw EOFException("bad frame length $total")
        val nameLen = input.readByte().toInt()
        if (nameLen < 1 || nameLen > total - 1) throw EOFException("bad stream name length $nameLen")
        val name = ByteArray(nameLen).also { input.readFully(it) }
        val payload = ByteArray(total - 1 - nameLen).also { input.readFully(it) }
        return String(name, Charsets.UTF_8) to payload
    }
}
