package com.leadaxe.lxbox.vpn

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.core.app.NotificationCompat
import com.leadaxe.lxbox.R
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.TaildropDownloadHandler
import io.nekohasekai.libbox.TaildropSendHandler
import io.nekohasekai.libbox.TaildropSendSession
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLongArray
import java.util.concurrent.atomic.AtomicReference

/// §707 — Taildrop на стороне натива: отправка файлов пиру (потоком из
/// `content://` прямо в ядро, без копии на телефоне), уведомления отправки,
/// сохранение принятого файла в Downloads, уведомления приёма ядра, разовый
/// перенос старой общей папки ядра.
///
/// Отправка живёт в своём scope процесса, а не активности: экран
/// «Поделиться» закрывается сразу после выбора пира, передача идёт дальше.
/// Имена файлов и устройств в журнал не пишутся (правило фичи 030).
object Taildrop {
    private const val TAG = "Taildrop"

    const val CHANNEL_ID = "lxbox-taildrop"

    /// Экстра интента MainActivity: тег узла, чью вкладку Network открыть.
    const val EXTRA_TAG = "taildrop_tag"

    const val ACTION_CANCEL_SEND = "com.leadaxe.lxbox.taildrop.CANCEL_SEND"
    const val EXTRA_SEND_ID = "send_id"

    /// Старая общая папка ядра (дефолт `taildrop_directory` до §707).
    private const val LEGACY_DIR = "Taildrop"
    private const val PARTIAL_SUFFIX = ".partial"
    private const val DELETED_SUFFIX = ".deleted"

    private const val SEND_ID_BASE = 3000
    private const val PROGRESS_MIN_INTERVAL_MS = 500L

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val nextId = AtomicInteger(0)
    private val sends = ConcurrentHashMap<Int, SendJob>()

    /// Файл к отправке: поток уже открыт (права на `content://` из
    /// «Поделиться» живут, пока жива активность; открытый поток — дольше).
    /// [size] < 0 — размер неизвестен.
    class Item(val name: String, val size: Long, val stream: InputStream)

    private class SendJob {
        @Volatile var session: TaildropSendSession? = null
        @Volatile var cancelled = false
    }

    // ───────────────────────── источники ─────────────────────────

    /// Имя заметки из текста «Поделиться»: `note-YYYY-MM-DD-HHMM.txt`,
    /// местное время телефона.
    fun noteName(now: Date = Date()): String =
        "note-" + SimpleDateFormat("yyyy-MM-dd-HHmm", Locale.US).format(now) + ".txt"

    fun noteItem(text: String, now: Date = Date()): Item {
        val bytes = text.toByteArray(Charsets.UTF_8)
        return Item(noteName(now), bytes.size.toLong(), ByteArrayInputStream(bytes))
    }

    /// Открыть присланные `content://`: имя — `DISPLAY_NAME`, размер — `SIZE`
    /// или −1. Неоткрывшиеся пропускаются.
    fun openUris(ctx: Context, uris: List<Uri>): List<Item> {
        val out = ArrayList<Item>()
        for (uri in uris) {
            runCatching {
                var name: String? = null
                var size = -1L
                ctx.contentResolver.query(
                    uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                    null, null, null,
                )?.use { c ->
                    if (c.moveToFirst()) {
                        val ni = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        val si = c.getColumnIndex(OpenableColumns.SIZE)
                        if (ni >= 0 && !c.isNull(ni)) name = c.getString(ni)
                        if (si >= 0 && !c.isNull(si)) size = c.getLong(si)
                    }
                }
                val stream = ctx.contentResolver.openInputStream(uri)
                    ?: throw IOException("no stream")
                val fallback = uri.lastPathSegment?.substringAfterLast('/')
                val finalName = name?.takeIf { it.isNotBlank() }
                    ?: fallback?.takeIf { it.isNotBlank() } ?: "file"
                out.add(Item(finalName, size, stream))
            }.onFailure { Log.w(TAG, "open shared item failed: ${it.javaClass.simpleName}") }
        }
        return out
    }

    // ───────────────────────── отправка ─────────────────────────

    /// Запустить передачу [items] пиру [peerId] узла [tag]. `false` — VPN
    /// не поднят (потоки закрыты, ничего не откладывается).
    fun send(
        ctx: Context,
        tag: String,
        peerId: String,
        peerName: String,
        items: List<Item>,
    ): Boolean {
        val cc = BoxService.commandClient
        if (cc == null || items.isEmpty()) {
            closeAll(items)
            return false
        }
        val app = ctx.applicationContext
        val id = SEND_ID_BASE + (nextId.getAndIncrement() and 0xfff)
        val job = SendJob()
        sends[id] = job
        scope.launch { runSend(app, cc, id, job, tag, peerId, peerName, items) }
        return true
    }

    /// Cancel из уведомления: закрыть сессию; ядро рвёт передачу.
    fun cancelSend(ctx: Context, id: Int) {
        val job = sends[id] ?: run { notificationManager(ctx).cancel(id); return }
        job.cancelled = true
        scope.launch { job.session?.runCatching { close() } }
    }

    private fun runSend(
        ctx: Context,
        cc: BoxCommandClient,
        id: Int,
        job: SendJob,
        tag: String,
        peerId: String,
        peerName: String,
        items: List<Item>,
    ) {
        val total = if (items.all { it.size >= 0 }) items.sumOf { it.size } else -1L
        val notifier = SendNotifier(ctx, id, peerName, items.size, total)
        notifier.progress(0, 0L, force = true)
        val client = cc.newCallClient()
        if (client == null) {
            notifier.failed(L10n.str(ctx, R.string.taildrop_reason_vpn_off))
            closeAll(items)
            sends.remove(id)
            return
        }
        val finished = CountDownLatch(1)
        val finishError = AtomicReference("")
        val sent = AtomicLongArray(items.size)
        val handler = object : TaildropSendHandler {
            // Колбэки из Go-потока: исключения наружу не выходят (JNI abort).
            override fun onProgress(fileIndex: Int, sentBytes: Long) {
                runCatching {
                    if (fileIndex in 0 until sent.length()) sent.set(fileIndex, sentBytes)
                    notifier.progress(fileIndex, sum(sent))
                }
            }

            override fun onFileCompleted(fileIndex: Int, sentBytes: Long) {
                runCatching {
                    if (fileIndex in 0 until sent.length()) sent.set(fileIndex, sentBytes)
                    notifier.progress(fileIndex + 1, sum(sent))
                }
            }

            override fun onFinish(errorMessage: String?) {
                runCatching {
                    finishError.set(errorMessage ?: "")
                    finished.countDown()
                }
            }
        }
        var readError: String? = null
        try {
            val opts = Libbox.newTaildropSendOptions().apply {
                endpointTag = tag
                peerStableID = peerId
            }
            for (item in items) opts.addFile(item.name, item.size)
            val session = client.sendTaildropFiles(opts, handler)
            job.session = session
            if (job.cancelled) session.runCatching { close() }
            val buf = ByteArray(Libbox.TaildropChunkSize.toInt().coerceAtLeast(16 * 1024))
            outer@ for (item in items) {
                while (true) {
                    if (job.cancelled) break@outer
                    val n = try {
                        item.stream.read(buf)
                    } catch (e: IOException) {
                        readError = L10n.str(ctx, R.string.taildrop_reason_cant_read)
                        break@outer
                    }
                    if (n < 0) break
                    if (n == 0) continue
                    // Ошибка записи — сессия кончилась; причина придёт в onFinish.
                    try {
                        session.writeChunk(if (n == buf.size) buf else buf.copyOf(n))
                    } catch (_: Exception) {
                        break@outer
                    }
                }
                try {
                    session.finishFile()
                } catch (_: Exception) {
                    break@outer
                }
            }
            if (readError != null || job.cancelled) {
                session.runCatching { close() }
            } else {
                // Ждём итог ядра; Cancel посреди ожидания закрывает сессию,
                // и onFinish тогда не приходит.
                while (!finished.await(500, TimeUnit.MILLISECONDS)) {
                    if (job.cancelled) break
                }
            }
        } catch (e: Exception) {
            // Старт отвергнут (пир ушёл, узел не запущен…): текст ядра.
            if (finishError.get().isEmpty()) finishError.set(e.message ?: "failed")
            finished.countDown()
        } finally {
            closeAll(items)
            client.runCatching { disconnect() }
            sends.remove(id)
        }
        when {
            job.cancelled -> notifier.cancel()
            readError != null -> notifier.failed(readError!!)
            finished.count > 0L -> notifier.failed(L10n.str(ctx, R.string.taildrop_reason_interrupted))
            finishError.get().isNotEmpty() -> {
                Log.w(TAG, "taildrop send failed")
                notifier.failed(finishError.get())
            }
            else -> notifier.sent()
        }
    }

    private fun sum(a: AtomicLongArray): Long {
        var s = 0L
        for (i in 0 until a.length()) s += a.get(i)
        return s
    }

    private fun closeAll(items: List<Item>) {
        for (i in items) runCatching { i.stream.close() }
    }

    // ───────────────────────── уведомления ─────────────────────────

    private fun notificationManager(ctx: Context) =
        ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    fun ensureChannel(ctx: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        runCatching {
            val channel = NotificationChannel(
                CHANNEL_ID,
                L10n.str(ctx, R.string.taildrop_channel_name),
                NotificationManager.IMPORTANCE_DEFAULT,
            )
            notificationManager(ctx).createNotificationChannel(channel)
        }
    }

    /// Интент открытия вкладки Network узла [tag] (тап по уведомлению).
    fun openNodeIntent(ctx: Context, tag: String, requestCode: Int): PendingIntent? {
        val intent = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
            ?.apply {
                putExtra(EXTRA_TAG, tag)
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            } ?: return null
        return PendingIntent.getActivity(
            ctx, requestCode, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private class SendNotifier(
        private val ctx: Context,
        private val id: Int,
        private val peerName: String,
        private val count: Int,
        private val total: Long,
    ) {
        private var lastAt = 0L

        @Synchronized
        fun progress(filesDone: Int, sentBytes: Long, force: Boolean = false) {
            val now = SystemClock.elapsedRealtime()
            if (!force && now - lastAt < PROGRESS_MIN_INTERVAL_MS) return
            lastAt = now
            ensureChannel(ctx)
            val cancel = PendingIntent.getBroadcast(
                ctx, id,
                Intent(ctx, TaildropCancelReceiver::class.java)
                    .setAction(ACTION_CANCEL_SEND)
                    .putExtra(EXTRA_SEND_ID, id),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val b = NotificationCompat.Builder(ctx, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_upload)
                .setContentTitle(L10n.str(ctx, R.string.taildrop_sending_title, peerName))
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setCategory(NotificationCompat.CATEGORY_PROGRESS)
                .addAction(0, L10n.str(ctx, R.string.taildrop_cancel), cancel)
            if (count > 1) {
                b.setContentText(L10n.str(
                    ctx, R.string.taildrop_files_progress,
                    (filesDone.coerceAtMost(count - 1)) + 1, count,
                ))
            }
            if (total > 0) {
                val pct = ((sentBytes.coerceAtMost(total) * 100) / total).toInt()
                b.setProgress(100, pct, false)
                b.setSubText("$pct%")
            } else {
                b.setProgress(0, 0, true)
            }
            notify(b)
        }

        @Synchronized
        fun sent() {
            lastAt = Long.MAX_VALUE
            ensureChannel(ctx)
            notify(NotificationCompat.Builder(ctx, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_upload_done)
                .setContentTitle(L10n.str(ctx, R.string.taildrop_sent_title, peerName))
                .setAutoCancel(true))
        }

        @Synchronized
        fun failed(reason: String) {
            lastAt = Long.MAX_VALUE
            ensureChannel(ctx)
            notify(NotificationCompat.Builder(ctx, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_notify_error)
                .setContentTitle(L10n.str(ctx, R.string.taildrop_failed_title, peerName))
                .setContentText(reason)
                .setStyle(NotificationCompat.BigTextStyle().bigText(reason))
                .setAutoCancel(true))
        }

        @Synchronized
        fun cancel() {
            lastAt = Long.MAX_VALUE
            runCatching { notificationManager(ctx).cancel(id) }
        }

        private fun notify(b: NotificationCompat.Builder) {
            runCatching { notificationManager(ctx).notify(id, b.build()) }
                .onFailure { Log.w(TAG, "notify failed: ${it.javaClass.simpleName}") }
        }
    }

    // ───────────────────── уведомления приёма ядра ─────────────────────

    /// Уведомление ядра о приёме Taildrop (`identifier = taildrop/<tag>/…`).
    fun isCoreNotification(identifier: String?): Boolean =
        identifier?.startsWith("taildrop/") == true

    /// Своё id на каждый файл: ядро шлёт все уведомления Taildrop с одним
    /// typeID, и снятие «receiving» иначе снимало бы и «received».
    fun coreNotificationId(identifier: String): Int =
        5000 + (identifier.hashCode() and 0x3fff)

    /// Тег узла из `openURL` ядра `sing-box:taildrop?endpoint=<tag>`;
    /// `null` — ссылка не та.
    fun tagFromOpenUrl(url: String?): String? {
        if (url == null || !url.startsWith("sing-box:taildrop")) return null
        val q = url.substringAfter('?', "")
        for (part in q.split('&')) {
            if (part.startsWith("endpoint=")) {
                return Uri.decode(part.removePrefix("endpoint=")).takeIf { it.isNotEmpty() }
            }
        }
        return null
    }

    // ───────────────────────── сохранение ─────────────────────────

    fun mimeOf(name: String): String {
        val ext = name.substringAfterLast('.', "").lowercase(Locale.ROOT)
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
            ?: "application/octet-stream"
    }

    /// Сохранить принятый файл [name] узла [tag]: выгрузка ядром во
    /// временный файл кэша, копия в [target] (API 24–28, «Сохранить как») или
    /// в `MediaStore.Downloads` (API 29+, без разрешений), затем файл
    /// уходит из входящих. Блокирующий — звать с IO. `null` — успех, иначе
    /// причина.
    fun save(ctx: Context, tag: String, name: String, target: Uri?): String? {
        val cc = BoxService.commandClient ?: return L10n.str(ctx, R.string.taildrop_reason_vpn_off)
        val client = cc.newCallClient() ?: return L10n.str(ctx, R.string.taildrop_reason_vpn_off)
        val dir = File(ctx.cacheDir, "taildrop-save").apply { mkdirs() }
        val tmp = File(dir, UUID.randomUUID().toString())
        try {
            val done = CountDownLatch(1)
            val error = AtomicReference("")
            val session = client.downloadTaildropFile(tag, name, tmp.path,
                object : TaildropDownloadHandler {
                    override fun onProgress(downloaded: Long, total: Long) {}

                    override fun onFinish(errorMessage: String?) {
                        runCatching {
                            error.set(errorMessage ?: "")
                            done.countDown()
                        }
                    }
                })
            if (!done.await(30, TimeUnit.MINUTES)) {
                session.runCatching { close() }
                return L10n.str(ctx, R.string.taildrop_reason_interrupted)
            }
            if (error.get().isNotEmpty()) {
                Log.w(TAG, "taildrop download failed")
                return error.get()
            }
            if (target != null) {
                val out = ctx.contentResolver.openOutputStream(target)
                    ?: return L10n.str(ctx, R.string.taildrop_reason_cant_write)
                out.use { o -> tmp.inputStream().use { it.copyTo(o) } }
            } else {
                val err = writeToDownloads(ctx, name, tmp)
                if (err != null) return err
            }
            cc.taildropDelete(tag, name)
            return null
        } catch (e: Exception) {
            Log.w(TAG, "taildrop save failed: ${e.javaClass.simpleName}")
            return e.message ?: L10n.str(ctx, R.string.taildrop_reason_cant_write)
        } finally {
            tmp.delete()
            client.runCatching { disconnect() }
        }
    }

    private fun writeToDownloads(ctx: Context, name: String, src: File): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return L10n.str(ctx, R.string.taildrop_reason_cant_write)
        }
        val resolver = ctx.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeOf(name))
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: return L10n.str(ctx, R.string.taildrop_reason_cant_write)
        return try {
            val out = resolver.openOutputStream(uri)
                ?: throw IOException("no output stream")
            out.use { o -> src.inputStream().use { it.copyTo(o) } }
            resolver.update(uri, ContentValues().apply {
                put(MediaStore.MediaColumns.IS_PENDING, 0)
            }, null, null)
            null
        } catch (e: Exception) {
            runCatching { resolver.delete(uri, null, null) }
            L10n.str(ctx, R.string.taildrop_reason_cant_write)
        }
    }

    // ─────────────────── перенос старой общей папки ───────────────────

    /// До §707 ядро принимало файлы всех узлов в `<рабочий каталог>/Taildrop`.
    /// Теперь у каждого узла свой `taildrop_directory`; принятое раньше один
    /// раз уезжает во входящие первого по порядку узла Tailscale, старая
    /// папка удаляется. Признак «уже сделано» — её отсутствие. Недокачанные
    /// (`.partial`) и метки удаления (`.deleted`) не переносятся.
    fun migrateLegacyInbox(workingDir: File, configJson: String) {
        val legacy = File(workingDir, LEGACY_DIR)
        if (!legacy.isDirectory) return
        val target = firstTaildropDirectory(configJson) ?: return
        val dest = File(target)
        if (dest.canonicalPath == legacy.canonicalPath) return
        dest.mkdirs()
        var moved = 0
        legacy.listFiles()?.forEach { f ->
            if (!f.isFile) return@forEach
            if (f.name.endsWith(PARTIAL_SUFFIX) || f.name.endsWith(DELETED_SUFFIX)) return@forEach
            val to = freeName(dest, f.name)
            val ok = f.renameTo(to) || runCatching {
                f.copyTo(to)
                f.delete()
                true
            }.getOrDefault(false)
            if (ok) moved++
        }
        legacy.deleteRecursively()
        Log.i(TAG, "legacy taildrop folder migrated: $moved file(s)")
    }

    /// `taildrop_directory` первого endpoint'а `tailscale` конфига.
    internal fun firstTaildropDirectory(configJson: String): String? = runCatching {
        val eps = JSONObject(configJson).optJSONArray("endpoints") ?: return null
        for (i in 0 until eps.length()) {
            val ep = eps.optJSONObject(i) ?: continue
            if (ep.optString("type") != "tailscale") continue
            return ep.optString("taildrop_directory").takeIf { it.isNotEmpty() }
        }
        null
    }.getOrNull()

    private fun freeName(dir: File, name: String): File {
        var f = File(dir, name)
        if (!f.exists()) return f
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        var n = 1
        while (f.exists()) {
            f = File(dir, "$base ($n)$ext")
            n++
        }
        return f
    }
}

/// Cancel в уведомлении отправки.
class TaildropCancelReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Taildrop.ACTION_CANCEL_SEND) return
        val id = intent.getIntExtra(Taildrop.EXTRA_SEND_ID, -1)
        if (id >= 0) Taildrop.cancelSend(context, id)
    }
}
