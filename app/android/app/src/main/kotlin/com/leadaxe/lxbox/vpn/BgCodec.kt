package com.leadaxe.lxbox.vpn

import io.flutter.plugin.common.StandardMessageCodec
import java.nio.ByteBuffer

/// §747 — отказ вызова `:ui` → `:bg`, который Dart должен увидеть как
/// `PlatformException(code, message)` — то же, что раньше давал
/// `result.error(code, message, null)` в обработчике `VpnPlugin`.
class BgError(val code: String, message: String?) : Exception(message)

/// §747 — кодек значений между процессами: аргументы и ответ вызова
/// `BgControlProvider.call()` и полезная нагрузка событий `:bg` → `:ui`.
///
/// Значения — те же, что ходят по `MethodChannel` (null, Boolean, Int, Long,
/// Double, String, ByteArray, List, Map), и кодируются тем же
/// `StandardMessageCodec`: типы Dart-контракта переживают границу процессов
/// без ручной сериализации. Через Binder идут только небольшие значения
/// (предел транзакции ~1 МБ) — крупное передаётся файлом ([XFER_INLINE_MAX]).
object BgCodec {
    /// Байты крупнее этого порога идут файлом в `cacheDir/bg-xfer`, не в Bundle.
    const val XFER_INLINE_MAX = 256 * 1024

    /// Каталог файлов-посылок между процессами (профили pprof, байты Taildrop).
    const val XFER_DIR = "bg-xfer"

    fun encode(value: Any?): ByteArray {
        val buf = StandardMessageCodec.INSTANCE.encodeMessage(value) ?: return ByteArray(0)
        buf.flip()
        return ByteArray(buf.remaining()).also { buf.get(it) }
    }

    fun decode(bytes: ByteArray?): Any? {
        if (bytes == null || bytes.isEmpty()) return null
        return StandardMessageCodec.INSTANCE.decodeMessage(ByteBuffer.wrap(bytes))
    }
}
