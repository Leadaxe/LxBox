package com.leadaxe.lxbox.vpn

import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/// §747 — сторона окна (`:ui`) канала `:ui` → `:bg`: вызов
/// `BgControlProvider.call()` с ответом.
///
/// Вызов синхронный и может поднимать процесс `:bg`, поэтому с главного
/// потока не делается никогда — только с двух мест:
/// - [onLane] — одна упорядоченная полоса для быстрых вызовов (настройки,
///   команды сервису, снимок туннеля). Порядок вызовов Dart сохраняется:
///   `setHasTun` → `startVPN`, `saveConfig` → `reloadVPN`;
/// - [onLong] — свой поток на каждый долгий вызов (остановка туннеля, профиль,
///   Taildrop, openconnect, Path MTU), чтобы он не держал полосу.
object BgClient {
    private const val TAG = "BgClient"

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

    fun onLong(block: () -> Unit) {
        longPool.execute { runCatching(block).onFailure { Log.w(TAG, "long task failed: $it") } }
    }

    fun onMain(block: () -> Unit) {
        main.post(block)
    }

    /// Блокирующий вызов метода [BgMethods]. Отказ метода — [BgError] (то, что
    /// Dart видел как `PlatformException`); сбой самого вызова (процесс `:bg`
    /// не поднялся, исключение в обработчике) — тоже [BgError] с кодом
    /// `BG_CALL_FAILED`. Не звать с главного потока.
    fun call(ctx: Context, method: String, args: Map<String, Any?>? = null): Any? {
        val extras = Bundle()
        if (args != null) extras.putByteArray(BgControlProvider.KEY_ARGS, BgCodec.encode(args))
        val reply = raw(ctx, method, extras)
        return BgCodec.decode(reply.getByteArray(BgControlProvider.KEY_RESULT))
    }

    /// То же для служебных методов с `Bundle` (дескриптор, Binder).
    fun raw(ctx: Context, method: String, extras: Bundle?): Bundle {
        val reply = try {
            ctx.contentResolver.call(BgControlProvider.uri(ctx), method, null, extras)
        } catch (t: Throwable) {
            throw BgError(BgControlProvider.ERROR_CALL_FAILED, t.message ?: t.javaClass.simpleName)
        } ?: throw BgError(BgControlProvider.ERROR_CALL_FAILED, "no reply")
        reply.getString(BgControlProvider.KEY_ERROR_CODE)?.let { code ->
            throw BgError(code, reply.getString(BgControlProvider.KEY_ERROR_MESSAGE))
        }
        return reply
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

    /// Переслать вызов Dart в `:bg` под тем же именем и ответить Dart на
    /// главном потоке тем же значением (или той же ошибкой). [long] — на своём
    /// потоке, иначе — полосой.
    fun forward(
        ctx: Context,
        method: String,
        arguments: Any?,
        result: MethodChannel.Result,
        long: Boolean = false,
    ) {
        @Suppress("UNCHECKED_CAST")
        val args = arguments as? Map<String, Any?>
        val task = {
            val reply = runCatching { call(ctx, method, args) }
            main.post { answer(result, reply) }
            Unit
        }
        if (long) onLong(task) else onLane(task)
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

    /// Файл-посылка в `cacheDir/bg-xfer` для байтов больше предела Binder.
    fun xferFile(ctx: Context, prefix: String): File {
        val dir = File(ctx.cacheDir, BgCodec.XFER_DIR).also { it.mkdirs() }
        return File.createTempFile(prefix, ".bin", dir)
    }
}
