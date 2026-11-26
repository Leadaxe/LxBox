package com.leadaxe.lxbox.vpn

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.util.Log
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/// §747 — канал `:ui` → `:bg`: вызов с ответом.
///
/// `ContentProvider` процесса `:bg`, не экспортируется; работает только
/// [call]. Вызов сам поднимает `:bg`, если процесса нет. Имя метода — имя
/// метода `MethodChannel` (или служебное), аргументы и результат — значения
/// `MethodChannel`, закодированные [BgCodec]. Тело каждого метода — в
/// [BgMethods].
///
/// Два вида вызова:
/// - **синхронный** — ответ в `Bundle` того же вызова. Для быстрых методов
///   (настройки, команды, подписки): [call] исполняется на потоке пула Binder
///   процесса `:bg` (15 потоков) и держит его до ответа;
/// - **асинхронный** ([METHOD_INVOKE_ASYNC]) — вызов возвращается сразу, метод
///   исполняется на своём потоке `:bg`, ответ приходит кадром
///   [EventFrames.REPLY] в канале событий. Для долгих методов (остановка
///   туннеля, замеры, проба, Taildrop, openconnect, профиль): сотня
///   параллельных замеров не занимает ни одного потока Binder.
///
/// Аргументы и синхронный ответ больше [BgCodec.XFER_INLINE_MAX] идут файлом в
/// `cacheDir/bg-xfer` (конфиг на проверку бывает больше предела Binder).
class BgControlProvider : ContentProvider() {

    companion object {
        private const val TAG = "BgControl"

        /// Authority = `<applicationId>.bgcontrol` (манифест).
        fun uri(ctx: Context): Uri = Uri.parse("content://${ctx.packageName}.bgcontrol")

        const val KEY_ARGS = "a"
        const val KEY_ARGS_FILE = "af"
        const val KEY_RESULT = "r"
        const val KEY_RESULT_FILE = "rf"
        const val KEY_ERROR_CODE = "ec"
        const val KEY_ERROR_MESSAGE = "em"
        /// Номер асинхронного вызова (`invokeAsync`).
        const val KEY_ID = "id"
        /// Пишущий конец pipe канала событий (`uiAttached`): pipe создаёт окно.
        const val KEY_PFD = "pfd"
        /// Binder-метка живого процесса окна (`uiAttached`).
        const val KEY_TOKEN = "token"

        /// Окно подключилось: метка процесса и канал событий.
        const val METHOD_UI_ATTACHED = "uiAttached"
        /// Асинхронный вызов: имя метода — в `arg`.
        const val METHOD_INVOKE_ASYNC = "invokeAsync"

        const val ERROR_CALL_FAILED = "BG_CALL_FAILED"
        /// Процесс `:bg` уже решил завершиться; вызов НЕ исполнен — повторить.
        const val ERROR_EXITING = "BG_EXITING"
        /// Канала событий нет — ответ асинхронного вызова некуда слать.
        const val ERROR_NO_PIPE = "BG_NO_PIPE"

        private val asyncSeq = AtomicInteger(0)
        private val asyncPool = Executors.newCachedThreadPool { r ->
            Thread(r, "lxbox-bg-async-${asyncSeq.incrementAndGet()}").apply { isDaemon = true }
        }

        private fun xferDir(ctx: Context) = File(ctx.cacheDir, BgCodec.XFER_DIR)

        /// Положить байты в `Bundle`: небольшие — как есть, крупные — файлом.
        fun putBytes(ctx: Context, out: Bundle, key: String, fileKey: String, bytes: ByteArray) {
            if (bytes.size <= BgCodec.XFER_INLINE_MAX) {
                out.putByteArray(key, bytes)
                return
            }
            val dir = xferDir(ctx).also { it.mkdirs() }
            val f = File.createTempFile("x-", ".bin", dir)
            f.writeBytes(bytes)
            out.putString(fileKey, f.path)
        }

        /// Достать байты, положенные [putBytes]. Путь принимается только из
        /// нашего каталога посылок. [delete] — удалить файл-посылку после
        /// чтения: ответ читает один раз окно; посылку с аргументами удаляет
        /// сам отправитель, когда вызов завершён, — при повторе вызова она
        /// нужна снова.
        fun takeBytes(
            ctx: Context, from: Bundle?, key: String, fileKey: String, delete: Boolean,
        ): ByteArray? {
            from ?: return null
            from.getByteArray(key)?.let { return it }
            val path = from.getString(fileKey) ?: return null
            val f = File(path)
            if (f.canonicalFile.parentFile != xferDir(ctx).canonicalFile) return null
            return try {
                f.readBytes()
            } finally {
                if (delete) f.delete()
            }
        }

        /// Удалить файл-посылку, если она была создана для [bundle].
        fun dropFile(ctx: Context, bundle: Bundle?, fileKey: String) {
            val path = bundle?.getString(fileKey) ?: return
            val f = File(path)
            if (f.canonicalFile.parentFile == xferDir(ctx).canonicalFile) f.delete()
        }

        /// Осиротевшие посылки (процесс умер между записью и чтением): внутри
        /// бывает конфиг с ключами. Удаляются при старте процесса — те, что
        /// старше [olderThanMs] (свежая может принадлежать вызову в пути).
        fun sweepXfer(ctx: Context, olderThanMs: Long = XFER_ORPHAN_MS) {
            val now = System.currentTimeMillis()
            for (f in xferDir(ctx).listFiles() ?: return) {
                if (xferOrphan(f.lastModified(), now, olderThanMs)) runCatching { f.delete() }
            }
        }

        const val XFER_ORPHAN_MS = 10 * 60 * 1000L

        /// Посылка осиротела: старше срока (или время изменения из будущего).
        fun xferOrphan(modifiedAt: Long, now: Long, olderThanMs: Long): Boolean =
            now - modifiedAt >= olderThanMs || modifiedAt > now + olderThanMs
    }

    override fun onCreate(): Boolean = true

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle {
        val ctx = context?.applicationContext ?: return error(ERROR_CALL_FAILED, "no context")
        val out = Bundle()
        if (!BgLifecycle.enter()) {
            // Процесс уже решил завершиться (§747 G): вызов не исполняется.
            // Окно по этому отказу повторит его — уже в новый процесс.
            Log.w(TAG, "call($method) not executed in pid ${android.os.Process.myPid()}: the process is exiting")
            return error(ERROR_EXITING, "service process is exiting")
        }
        try {
            when (method) {
                METHOD_UI_ATTACHED -> {
                    @Suppress("DEPRECATION")
                    BgEventPipe.attach(extras?.getParcelable(KEY_PFD))
                    UiPresence.attached(ctx, extras?.getBinder(KEY_TOKEN))
                }
                METHOD_INVOKE_ASYNC -> invokeAsync(ctx, arg ?: "", extras)
                else -> {
                    val result = BgMethods.handle(ctx, method, args(ctx, extras))
                    putBytes(ctx, out, KEY_RESULT, KEY_RESULT_FILE, BgCodec.encode(result))
                }
            }
        } catch (e: BgError) {
            return error(e.code, e.message)
        } catch (t: Throwable) {
            // Имя метода — в лог; аргументы не пишем (в них бывают секреты формы входа).
            Log.e(TAG, "call($method) failed", t)
            return error(ERROR_CALL_FAILED, t.message ?: t.javaClass.simpleName)
        } finally {
            BgLifecycle.callFinished(ctx)
        }
        return out
    }

    private fun args(ctx: Context, extras: Bundle?): Map<*, *>? =
        BgCodec.decode(takeBytes(ctx, extras, KEY_ARGS, KEY_ARGS_FILE, delete = false)) as? Map<*, *>

    /// Запустить метод на своём потоке и ответить кадром в канале событий.
    private fun invokeAsync(ctx: Context, method: String, extras: Bundle?) {
        if (!BgEventPipe.connected) throw BgError(ERROR_NO_PIPE, "no event pipe")
        val id = extras?.getLong(KEY_ID) ?: 0L
        val args = args(ctx, extras)
        BgLifecycle.callStarted()
        asyncPool.execute {
            val reply = HashMap<String, Any?>()
            reply["id"] = id
            try {
                reply["r"] = BgMethods.handle(ctx, method, args)
            } catch (e: BgError) {
                reply["ec"] = e.code
                reply["em"] = e.message
            } catch (t: Throwable) {
                Log.e(TAG, "async $method failed", t)
                reply["ec"] = ERROR_CALL_FAILED
                reply["em"] = t.message ?: t.javaClass.simpleName
            } finally {
                BgLifecycle.callFinished(ctx)
            }
            // Окна уже нет — ответ некому; вызов свою работу сделал.
            BgEventPipe.reliable(EventFrames.REPLY, reply)
        }
    }

    private fun error(code: String, message: String?): Bundle = Bundle().apply {
        putString(KEY_ERROR_CODE, code)
        putString(KEY_ERROR_MESSAGE, message)
    }

    // Табличного доступа нет: провайдер — только носитель `call()`.
    override fun query(
        uri: Uri, projection: Array<out String>?, selection: String?,
        selectionArgs: Array<out String>?, sortOrder: String?,
    ): Cursor? = null

    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(
        uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?,
    ): Int = 0
}
