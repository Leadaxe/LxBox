package com.leadaxe.lxbox.vpn

import android.app.DownloadManager
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
import java.util.concurrent.atomic.AtomicBoolean
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

    /// Работа кнопки уведомления — вне главного потока; исключения не наружу.
    fun runInBackground(block: () -> Unit) {
        scope.launch {
            runCatching(block).onFailure {
                Log.w(TAG, "taildrop notification action failed: ${it.javaClass.simpleName}")
            }
        }
    }

    /// Файл ушёл из входящих не из уведомления (Save / Delete на вкладке
    /// узла) — его уведомление «принят» больше не нужно.
    fun dismissReceived(ctx: Context, tag: String, name: String) {
        runCatching { notificationManager(ctx).cancel(coreNotificationId("taildrop/$tag/$name")) }
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
                notifier.failed(failureText(finishError.get()))
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
    /// Текст отказа ядра для уведомления: без обёртки gomobile/gRPC
    /// (`taildrop send: rpc error: code = Unknown desc = <текст>` → `<текст>`).
    internal fun failureText(raw: String): String =
        raw.substringAfterLast("desc = ").removePrefix("taildrop send: ").trim().ifEmpty { raw }

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

    /// Разобранное уведомление приёма ядра.
    sealed class CoreNote {
        abstract val tag: String

        /// Идёт приём: `taildrop/<tag>/receiving/<senderID>/<baseName>`.
        data class Receiving(override val tag: String, val senderId: String, val name: String) : CoreNote()

        /// Принят: `taildrop/<tag>/<finalName>` (имя во входящих).
        data class Received(override val tag: String, val name: String) : CoreNote()
    }

    /// Разбор `identifier` ядра. Тег — из [openUrl] (в теге может быть `/`,
    /// по `identifier` его границу не найти); остаток после `taildrop/<tag>/`
    /// — форма приёма или имя файла (имена файлов и `senderID` без `/`).
    /// `null` — форма не та (кнопок у такого уведомления нет).
    fun parseCoreNotification(identifier: String?, openUrl: String?): CoreNote? {
        val tag = tagFromOpenUrl(openUrl) ?: return null
        val prefix = "taildrop/$tag/"
        if (identifier == null || !identifier.startsWith(prefix)) return null
        val rest = identifier.substring(prefix.length)
        if (rest.startsWith("receiving/")) {
            val r = rest.substring("receiving/".length)
            val slash = r.indexOf('/')
            if (slash <= 0 || slash == r.length - 1) return null
            val name = r.substring(slash + 1)
            if (name.contains('/')) return null
            return CoreNote.Receiving(tag, r.substring(0, slash), name)
        }
        if (rest.isEmpty() || rest.contains('/')) return null
        return CoreNote.Received(tag, rest)
    }

    // ─────────────── автосохранение (настройка устройства) ───────────────

    /// Настройки Taildrop этого устройства: не в `lxbox_settings.json`,
    /// значит не в бэкапе L×Box; сервис читает их без Flutter.
    private const val PREFS = "lxbox_taildrop"
    private const val AUTOSAVE_PREFIX = "autosave."

    /// Автосохранение в Downloads — только API 29+ (MediaStore без разрешений).
    fun autoSaveSupported(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    private fun prefs(ctx: Context) =
        ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun isAutoSave(ctx: Context, tag: String): Boolean =
        autoSaveSupported() && prefs(ctx).getBoolean(AUTOSAVE_PREFIX + tag, false)

    /// Хранится только включённое значение; выключение убирает запись.
    fun setAutoSave(ctx: Context, tag: String, enabled: Boolean) {
        val e = prefs(ctx).edit()
        if (enabled) e.putBoolean(AUTOSAVE_PREFIX + tag, true) else e.remove(AUTOSAVE_PREFIX + tag)
        e.apply()
    }

    /// Узлы удалены или переименованы — их записи убираются.
    fun forgetAutoSave(ctx: Context, tags: Collection<String>) {
        if (tags.isEmpty()) return
        val e = prefs(ctx).edit()
        for (t in tags) e.remove(AUTOSAVE_PREFIX + t)
        e.apply()
        // §707 итер. 4 — и разрешения служебных файлов узлов.
        TaildropServiceFiles.forgetTags(ctx, tags)
    }

    // ─────────────── уведомления приёма: кнопки и сохранение ───────────────

    const val ACTION_CANCEL_RECEIVING = "com.leadaxe.lxbox.taildrop.CANCEL_RECEIVING"
    const val ACTION_SAVE = "com.leadaxe.lxbox.taildrop.SAVE"
    const val ACTION_DELETE = "com.leadaxe.lxbox.taildrop.DELETE"
    const val EXTRA_NOTE_ID = "note_id"
    const val EXTRA_NOTE_TAG = "note_tag"
    const val EXTRA_NOTE_NAME = "note_name"
    const val EXTRA_NOTE_SENDER = "note_sender"
    const val EXTRA_NOTE_TITLE = "note_title"
    const val EXTRA_NOTE_BODY = "note_body"
    const val EXTRA_NOTE_SUBTITLE = "note_subtitle"

    /// Тексты уведомления ядра — чтобы кнопка могла поставить его заново
    /// (неудачный Save / Delete) без самого ядра.
    class NoteText(val title: String, val body: String, val subtitle: String)

    /// Уведомление ядра о приёме: кнопки Cancel (идёт приём) или Save /
    /// Delete (принят; Save — только API 29+), тап открывает вкладку узла.
    /// [reason] — причина неудачного Save / Delete, дописывается к тексту.
    /// [withActions] = false — без кнопок (идёт автосохранение).
    fun showCoreNotification(
        ctx: Context,
        id: Int,
        note: CoreNote?,
        text: NoteText,
        openTag: String?,
        reason: String? = null,
        withActions: Boolean = true,
    ) {
        ensureChannel(ctx)
        val body = if (reason.isNullOrEmpty()) text.body else text.body + "\n" + reason
        val b = NotificationCompat.Builder(ctx, CHANNEL_ID)
            .setSmallIcon(
                if (note is CoreNote.Receiving) android.R.drawable.stat_sys_download
                else android.R.drawable.stat_sys_download_done,
            )
            .setContentTitle(text.title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setAutoCancel(true)
        if (text.subtitle.isNotBlank()) b.setSubText(text.subtitle)
        (note?.tag ?: openTag)?.let { tag ->
            openNodeIntent(ctx, tag, id)?.let { b.setContentIntent(it) }
        }
        if (withActions) {
            when (note) {
                is CoreNote.Receiving -> b.addAction(0, L10n.str(ctx, R.string.taildrop_cancel),
                    noteAction(ctx, ACTION_CANCEL_RECEIVING, id, 0, note, text))
                is CoreNote.Received -> {
                    if (autoSaveSupported()) {
                        b.addAction(0, L10n.str(ctx, R.string.taildrop_save),
                            noteAction(ctx, ACTION_SAVE, id, 1, note, text))
                    }
                    b.addAction(0, L10n.str(ctx, R.string.taildrop_delete),
                        noteAction(ctx, ACTION_DELETE, id, 2, note, text))
                }
                null -> {}
            }
        }
        runCatching { notificationManager(ctx).notify(id, b.build()) }
            .onFailure { Log.w(TAG, "taildrop notify failed: ${it.javaClass.simpleName}") }
    }

    private fun noteAction(
        ctx: Context,
        action: String,
        id: Int,
        slot: Int,
        note: CoreNote,
        text: NoteText,
    ): PendingIntent {
        val i = Intent(ctx, TaildropNoteReceiver::class.java)
            .setAction(action)
            .putExtra(EXTRA_NOTE_ID, id)
            .putExtra(EXTRA_NOTE_TAG, note.tag)
            .putExtra(EXTRA_NOTE_TITLE, text.title)
            .putExtra(EXTRA_NOTE_BODY, text.body)
            .putExtra(EXTRA_NOTE_SUBTITLE, text.subtitle)
        when (note) {
            is CoreNote.Receiving -> i.putExtra(EXTRA_NOTE_NAME, note.name)
                .putExtra(EXTRA_NOTE_SENDER, note.senderId)
            is CoreNote.Received -> i.putExtra(EXTRA_NOTE_NAME, note.name)
        }
        return PendingIntent.getBroadcast(
            ctx, id * 4 + slot, i,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /// Уведомление ядра о приёме пришло в сервис: принятый файл узла с
    /// включённым автосохранением уходит в Downloads, остальное — с кнопками.
    fun onCoreNotification(ctx: Context, identifier: String, openUrl: String?, text: NoteText) {
        val app = ctx.applicationContext
        val id = coreNotificationId(identifier)
        val note = parseCoreNotification(identifier, openUrl)
        val openTag = tagFromOpenUrl(openUrl)
        // §707 итер. 4 — кандидат в служебные файлы разбирается раньше
        // автосохранения и уведомления «принят»; обычный — дальше как всегда.
        val spec = TaildropServiceFiles.spec(app)
        if (note is CoreNote.Received && spec != null && TaildropServiceFiles.isCandidate(spec, note.name)) {
            runInBackground {
                if (!processServiceCandidate(app, note.tag, note.name)) {
                    deliverReceived(app, id, note, text, openTag)
                }
            }
            return
        }
        deliverReceived(app, id, note, text, openTag)
    }

    /// Служебный ли файл [name] узла [tag] (тогда он разобран и удалён).
    /// Каталог входящих — из последнего собранного конфига.
    private fun processServiceCandidate(ctx: Context, tag: String, name: String): Boolean {
        val dir = taildropDirectories(ConfigManager.load()).firstOrNull { it.first == tag }?.second
            ?: return false
        val key = inFlightKey(tag, name)
        if (!inFlight.add(key)) return true // уже разбирает прогон входящих
        return try {
            name in TaildropServiceFiles.process(
                ctx, tag, listOf(TaildropServiceFiles.Incoming(name, File(dir, name))),
                viaCore = BoxService.commandClient != null,
            )
        } finally {
            inFlight.remove(key)
        }
    }

    private fun deliverReceived(app: Context, id: Int, note: CoreNote?, text: NoteText, openTag: String?) {
        if (note is CoreNote.Received && isAutoSave(app, note.tag)) {
            showCoreNotification(app, id, note, text, openTag, withActions = false)
            runInBackground { saveFromNotification(app, id, note, text) }
            return
        }
        showCoreNotification(app, id, note, text, openTag)
    }

    /// Save из уведомления или автосохранение: успех — «Saved to Downloads»
    /// с открытием файла; неудача — уведомление «принят» с кнопками и
    /// причиной, файл остаётся во входящих. Блокирующий — звать с IO.
    internal fun saveFromNotification(ctx: Context, id: Int, note: CoreNote.Received, text: NoteText) {
        if (BoxService.commandClient == null) {
            runCatching { notificationManager(ctx).cancel(id) }
            return
        }
        // Файл уже уносит разбор входящих — он и снимет это уведомление.
        val key = inFlightKey(note.tag, note.name)
        if (!inFlight.add(key)) return
        val saved = AtomicReference<Uri?>(null)
        val err = try {
            runCatching { saveInternal(ctx, note.tag, note.name, null, saved) }
                .getOrElse { it.message ?: L10n.str(ctx, R.string.taildrop_reason_cant_write) }
        } finally {
            inFlight.remove(key)
        }
        val uri = saved.get()
        if (err == null && uri != null) {
            showSaved(ctx, id, note.tag, uri, displayName(ctx, uri) ?: note.name)
        } else {
            showCoreNotification(ctx, id, note, text, note.tag,
                reason = L10n.str(ctx, R.string.taildrop_save_failed, err ?: ""))
        }
    }

    /// Delete / Cancel из уведомления. Без работающего ядра уведомление
    /// просто снимается.
    internal fun deleteFromNotification(ctx: Context, id: Int, note: CoreNote.Received, text: NoteText) {
        val cc = BoxService.commandClient
        val err = cc?.taildropDelete(note.tag, note.name)
        if (cc == null || err == null) {
            runCatching { notificationManager(ctx).cancel(id) }
            return
        }
        showCoreNotification(ctx, id, note, text, note.tag,
            reason = L10n.str(ctx, R.string.taildrop_delete_failed, err))
    }

    internal fun cancelReceivingFromNotification(ctx: Context, id: Int, note: CoreNote.Receiving) {
        BoxService.commandClient?.taildropCancelReceiving(note.tag, note.senderId, note.name)
        // Ядро само снимает «идёт приём» по концу приёма; снимаем и здесь —
        // без ядра снимать больше некому.
        runCatching { notificationManager(ctx).cancel(id) }
    }

    /// «Saved to Downloads: <name>»; тап открывает файл, нет обработчика —
    /// вкладку узла.
    private fun showSaved(ctx: Context, id: Int, tag: String, uri: Uri, name: String) {
        showDone(ctx, id, L10n.str(ctx, R.string.taildrop_saved_title, name), null,
            viewFileIntent(ctx, id, uri, name) ?: openNodeIntent(ctx, tag, id))
    }

    /// Итоговое уведомление сохранения (без кнопок, снимается по тапу).
    private fun showDone(ctx: Context, id: Int, title: String, text: String?, content: PendingIntent?) {
        ensureChannel(ctx)
        val b = NotificationCompat.Builder(ctx, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle(title)
            .setAutoCancel(true)
        if (!text.isNullOrEmpty()) b.setContentText(text)
        content?.let { b.setContentIntent(it) }
        runCatching { notificationManager(ctx).notify(id, b.build()) }
            .onFailure { Log.w(TAG, "taildrop notify failed: ${it.javaClass.simpleName}") }
    }

    /// Открыть сохранённый файл; `null` — обработчика нет.
    private fun viewFileIntent(ctx: Context, id: Int, uri: Uri, name: String): PendingIntent? {
        val view = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, mimeOf(name))
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        if (view.resolveActivity(ctx.packageManager) == null) return null
        return PendingIntent.getActivity(
            ctx, id, view,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /// Системные «Загрузки»; `null` — обработчика нет.
    private fun viewDownloadsIntent(ctx: Context, id: Int): PendingIntent? {
        val view = Intent(DownloadManager.ACTION_VIEW_DOWNLOADS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (view.resolveActivity(ctx.packageManager) == null) return null
        return PendingIntent.getActivity(
            ctx, id, view,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun displayName(ctx: Context, uri: Uri): String? = runCatching {
        ctx.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { c ->
                if (c.moveToFirst() && !c.isNull(0)) c.getString(0) else null
            }
    }.getOrNull()?.takeIf { it.isNotBlank() }

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
    fun save(ctx: Context, tag: String, name: String, target: Uri?): String? =
        saveInternal(ctx, tag, name, target, null)

    /// [saved] — куда положить uri записи `MediaStore` (только Downloads).
    private fun saveInternal(
        ctx: Context,
        tag: String,
        name: String,
        target: Uri?,
        saved: AtomicReference<Uri?>?,
    ): String? {
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
                val uri = writeToDownloads(ctx, name, tmp)
                    ?: return L10n.str(ctx, R.string.taildrop_reason_cant_write)
                saved?.set(uri)
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

    /// Копия [src] в `MediaStore.Downloads`; uri записи или `null` (не вышло).
    private fun writeToDownloads(ctx: Context, name: String, src: File): Uri? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        val resolver = ctx.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeOf(name))
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: return null
        return try {
            val out = resolver.openOutputStream(uri)
                ?: throw IOException("no output stream")
            out.use { o -> src.inputStream().use { it.copyTo(o) } }
            resolver.update(uri, ContentValues().apply {
                put(MediaStore.MediaColumns.IS_PENDING, 0)
            }, null, null)
            uri
        } catch (e: Exception) {
            runCatching { resolver.delete(uri, null, null) }
            null
        }
    }

    // ─────────────── разбор входящих узлов с автосохранением ───────────────

    /// Уведомление итога разбора — одно на прогон, следующий его заменяет.
    private const val SWEEP_NOTE_ID = 4999

    /// Файлы, которые сейчас уносит в Downloads разбор или автосохранение
    /// по уведомлению: второй путь их пропускает.
    private val inFlight: MutableSet<String> = ConcurrentHashMap.newKeySet()
    private fun inFlightKey(tag: String, name: String) = "$tag/$name"

    /// Одна очередь на процесс: прогоны идут по одному.
    private val sweepLock = Any()

    /// Фоновый прогон уже ждёт очереди — новый запрос он и покроет.
    private val sweepQueued = AtomicBoolean(false)

    /// Разобрать входящие в фоне (старт процесса, включение переключателя).
    fun sweepInboxesAsync(ctx: Context) {
        if (!sweepQueued.compareAndSet(false, true)) return
        val app = ctx.applicationContext
        scope.launch {
            runCatching {
                synchronized(sweepLock) {
                    sweepQueued.set(false)
                    sweepLocked(app, beforeCoreStart = false)
                }
            }.onFailure {
                sweepQueued.set(false)
                Log.w(TAG, "taildrop inbox sweep failed: ${it.javaClass.simpleName}")
            }
        }
    }

    /// Разобрать входящие из старта VPN — до старта ядра, после переноса
    /// старой общей папки. Блокирующий — звать с IO.
    fun sweepInboxesBeforeCoreStart(ctx: Context) {
        synchronized(sweepLock) { sweepLocked(ctx.applicationContext, beforeCoreStart = true) }
    }

    /// У каждого узла Tailscale последнего собранного конфига с включённым
    /// переключателем готовые файлы входящих уходят в Downloads. VPN работает —
    /// через ядро (выгрузка + удаление: входящие ядра не расходятся с
    /// диском); ядра нет — прямо с диска. Ядро поднимается или гаснет, а
    /// прогон не из старта VPN, — ничего: старт VPN разберёт сам.
    private fun sweepLocked(ctx: Context, beforeCoreStart: Boolean) {
        val all = taildropDirectories(ConfigManager.load())
        if (all.isEmpty()) return
        val viaCore = BoxService.commandClient != null
        if (!viaCore && !beforeCoreStart && BoxVpnService.currentStatus != VpnStatus.Stopped) return
        // §707 итер. 4 — служебные файлы раньше автосохранения, у всех узлов
        // с включённым Taildrop. Ядра нет — отправителя нет, разрешение не
        // находится (§5): команды не выполняются, файл удаляется.
        val service = HashSet<String>()
        for ((tag, dir) in all) {
            val items = readyFiles(File(dir)).mapNotNull { f ->
                if (inFlight.add(inFlightKey(tag, f.name))) TaildropServiceFiles.Incoming(f.name, f) else null
            }
            try {
                runCatching { TaildropServiceFiles.process(ctx, tag, items, viaCore) }
                    .onSuccess { names -> names.forEach { service.add(inFlightKey(tag, it)) } }
                    .onFailure { Log.w(TAG, "taildrop service files failed: ${it.javaClass.simpleName}") }
            } finally {
                for (i in items) inFlight.remove(inFlightKey(tag, i.name))
            }
        }
        if (!autoSaveSupported()) return
        val inboxes = all.filter { isAutoSave(ctx, it.first) }
        if (inboxes.isEmpty()) return
        var saved = 0
        var failed = 0
        var lastSaved: Triple<String, Uri, String>? = null
        var failedTag: String? = null
        for ((tag, dir) in inboxes) {
            for (f in readyFiles(File(dir))) {
                val key = inFlightKey(tag, f.name)
                if (key in service) continue
                if (!inFlight.add(key)) continue
                try {
                    // Ушёл, пока ждали очереди (Save на вкладке, автосохранение).
                    if (!f.isFile) continue
                    val uri = AtomicReference<Uri?>(null)
                    val err = runCatching {
                        if (viaCore) saveInternal(ctx, tag, f.name, null, uri)
                        else saveFromDisk(ctx, f, uri)
                    }.getOrElse { it.message ?: "failed" }
                    val u = uri.get()
                    if (err == null && u != null) {
                        saved++
                        lastSaved = Triple(tag, u, displayName(ctx, u) ?: f.name)
                        dismissReceived(ctx, tag, f.name)
                    } else {
                        failed++
                        if (failedTag == null) failedTag = tag
                    }
                } finally {
                    inFlight.remove(key)
                }
            }
        }
        if (saved > 0 || failed > 0) {
            Log.i(TAG, "taildrop inbox sweep: saved=$saved failed=$failed core=$viaCore")
        }
        showSweepResult(ctx, saved, failed, lastSaved, failedTag)
    }

    /// Ядра нет: копия в `MediaStore.Downloads`, затем файл удаляется. Не
    /// удалился — копия снимается (иначе следующий прогон её повторит).
    private fun saveFromDisk(ctx: Context, f: File, saved: AtomicReference<Uri?>): String? {
        val uri = writeToDownloads(ctx, f.name, f)
            ?: return L10n.str(ctx, R.string.taildrop_reason_cant_write)
        if (!f.delete()) {
            runCatching { ctx.contentResolver.delete(uri, null, null) }
            return L10n.str(ctx, R.string.taildrop_reason_cant_write)
        }
        saved.set(uri)
        return null
    }

    /// Готовые файлы каталога входящих: без недокачанных (`.partial`), меток
    /// удаления ядра (`.deleted`) и файлов с такой меткой рядом.
    private fun readyFiles(dir: File): List<File> {
        val all = dir.listFiles() ?: return emptyList()
        return all.filter { f ->
            f.isFile &&
                !f.name.endsWith(PARTIAL_SUFFIX) &&
                !f.name.endsWith(DELETED_SUFFIX) &&
                !File(dir, f.name + DELETED_SUFFIX).exists()
        }.sortedBy { it.lastModified() }
    }

    /// Один файл — «Saved to Downloads: <имя>», тап открывает файл; больше —
    /// «Saved N files to Downloads», тап открывает системные Загрузки (нет
    /// обработчика — вкладку узла). Неудачи — строкой «Couldn't save N files»;
    /// одни неудачи — заголовком, тап открывает вкладку узла (файлы там).
    private fun showSweepResult(
        ctx: Context,
        saved: Int,
        failed: Int,
        last: Triple<String, Uri, String>?,
        failedTag: String?,
    ) {
        val failText = if (failed > 0) {
            L10n.plural(ctx, R.plurals.taildrop_couldnt_save_files, failed, failed)
        } else {
            null
        }
        when {
            saved == 1 && last != null -> showDone(ctx, SWEEP_NOTE_ID,
                L10n.str(ctx, R.string.taildrop_saved_title, last.third), failText,
                viewFileIntent(ctx, SWEEP_NOTE_ID, last.second, last.third)
                    ?: openNodeIntent(ctx, last.first, SWEEP_NOTE_ID))
            saved > 1 && last != null -> showDone(ctx, SWEEP_NOTE_ID,
                L10n.plural(ctx, R.plurals.taildrop_saved_files, saved, saved), failText,
                viewDownloadsIntent(ctx, SWEEP_NOTE_ID)
                    ?: openNodeIntent(ctx, last.first, SWEEP_NOTE_ID))
            failText != null && failedTag != null -> showDone(ctx, SWEEP_NOTE_ID, failText, null,
                openNodeIntent(ctx, failedTag, SWEEP_NOTE_ID))
        }
    }

    /// §707 итер. 4 — теги узлов `tailscale` конфига с `disable_taildrop: true`.
    internal fun taildropOffTags(configJson: String): Set<String> = runCatching {
        val eps = JSONObject(configJson).optJSONArray("endpoints") ?: return emptySet()
        val out = HashSet<String>()
        for (i in 0 until eps.length()) {
            val ep = eps.optJSONObject(i) ?: continue
            if (ep.optString("type") != "tailscale") continue
            if (ep.optBoolean("disable_taildrop", false)) out.add(ep.optString("tag"))
        }
        out
    }.getOrDefault(emptySet())

    /// Пары (тег, `taildrop_directory`) endpoint'ов `tailscale` конфига.
    /// §707 итер. 4 — узлы с `disable_taildrop: true` не входят: разбор
    /// входящих и автосохранение их не трогают.
    internal fun taildropDirectories(configJson: String): List<Pair<String, String>> = runCatching {
        val eps = JSONObject(configJson).optJSONArray("endpoints") ?: return emptyList()
        val out = ArrayList<Pair<String, String>>()
        for (i in 0 until eps.length()) {
            val ep = eps.optJSONObject(i) ?: continue
            if (ep.optString("type") != "tailscale") continue
            if (ep.optBoolean("disable_taildrop", false)) continue
            val tag = ep.optString("tag")
            val dir = ep.optString("taildrop_directory")
            if (tag.isNotEmpty() && dir.isNotEmpty()) out.add(tag to dir)
        }
        out
    }.getOrDefault(emptyList())

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

/// Кнопки уведомлений приёма ядра: Cancel (идёт приём), Save и Delete
/// (принят). Работа — в scope Taildrop на IO, не на главном потоке.
class TaildropNoteReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val app = context.applicationContext
        val id = intent.getIntExtra(Taildrop.EXTRA_NOTE_ID, -1)
        val tag = intent.getStringExtra(Taildrop.EXTRA_NOTE_TAG)
        val name = intent.getStringExtra(Taildrop.EXTRA_NOTE_NAME)
        if (id < 0 || tag.isNullOrEmpty() || name.isNullOrEmpty()) return
        val text = Taildrop.NoteText(
            intent.getStringExtra(Taildrop.EXTRA_NOTE_TITLE) ?: "",
            intent.getStringExtra(Taildrop.EXTRA_NOTE_BODY) ?: "",
            intent.getStringExtra(Taildrop.EXTRA_NOTE_SUBTITLE) ?: "",
        )
        when (intent.action) {
            Taildrop.ACTION_CANCEL_RECEIVING -> {
                val sender = intent.getStringExtra(Taildrop.EXTRA_NOTE_SENDER)
                if (sender.isNullOrEmpty()) return
                Taildrop.runInBackground {
                    Taildrop.cancelReceivingFromNotification(app, id, Taildrop.CoreNote.Receiving(tag, sender, name))
                }
            }
            Taildrop.ACTION_SAVE -> {
                val note = Taildrop.CoreNote.Received(tag, name)
                // Пока идёт сохранение — без кнопок (второе нажатие некуда).
                Taildrop.showCoreNotification(app, id, note, text, tag, withActions = false)
                Taildrop.runInBackground { Taildrop.saveFromNotification(app, id, note, text) }
            }
            Taildrop.ACTION_DELETE -> Taildrop.runInBackground {
                Taildrop.deleteFromNotification(app, id, Taildrop.CoreNote.Received(tag, name), text)
            }
        }
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
