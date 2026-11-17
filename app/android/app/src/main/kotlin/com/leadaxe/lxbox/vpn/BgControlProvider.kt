package com.leadaxe.lxbox.vpn

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.util.Log

/// §747 — канал `:ui` → `:bg`: вызов с ответом.
///
/// `ContentProvider` процесса `:bg`, не экспортируется; работает только
/// [call]. Вызов синхронный, с ответом, и сам поднимает `:bg`, если процесса
/// нет. Имя метода — имя метода `MethodChannel` (или служебное), аргументы и
/// результат — значения `MethodChannel`, закодированные [BgCodec] в
/// `ByteArray` внутри `Bundle`. Тело каждого метода — в [BgMethods].
///
/// [call] исполняется на потоке пула Binder процесса `:bg` (15 потоков):
/// долгие методы (остановка туннеля, профиль, отправка Taildrop) занимают
/// поток на всё время, поэтому `:ui` зовёт их со своих отдельных потоков и
/// никогда — с главного (`BgClient`).
class BgControlProvider : ContentProvider() {

    companion object {
        private const val TAG = "BgControl"

        /// Authority = `<applicationId>.bgcontrol` (манифест).
        fun uri(ctx: Context): Uri = Uri.parse("content://${ctx.packageName}.bgcontrol")

        const val KEY_ARGS = "a"
        const val KEY_RESULT = "r"
        const val KEY_ERROR_CODE = "ec"
        const val KEY_ERROR_MESSAGE = "em"
        /// Пишущий конец pipe лога (`openLogPipe`): pipe создаёт окно.
        const val KEY_PFD = "pfd"
        /// Binder-метка живого процесса окна (`uiAttached`).
        const val KEY_TOKEN = "token"

        /// Служебные методы, которым нужен сам `Bundle` (дескриптор, Binder).
        const val METHOD_OPEN_LOG_PIPE = "openLogPipe"
        const val METHOD_UI_ATTACHED = "uiAttached"

        const val ERROR_CALL_FAILED = "BG_CALL_FAILED"
    }

    override fun onCreate(): Boolean = true

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle {
        val ctx = context?.applicationContext ?: return error(ERROR_CALL_FAILED, "no context")
        val out = Bundle()
        BgLifecycle.callStarted()
        try {
            when (method) {
                METHOD_OPEN_LOG_PIPE -> {
                    @Suppress("DEPRECATION")
                    BgLogPipe.attach(extras?.getParcelable(KEY_PFD))
                }
                METHOD_UI_ATTACHED -> UiPresence.attached(ctx, extras?.getBinder(KEY_TOKEN))
                else -> {
                    val args = BgCodec.decode(extras?.getByteArray(KEY_ARGS)) as? Map<*, *>
                    out.putByteArray(KEY_RESULT, BgCodec.encode(BgMethods.handle(ctx, method, args)))
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
