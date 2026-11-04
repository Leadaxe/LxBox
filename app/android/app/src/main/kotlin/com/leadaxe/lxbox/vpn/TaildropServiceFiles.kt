package com.leadaxe.lxbox.vpn

import android.app.PendingIntent
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import com.leadaxe.lxbox.R
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.util.concurrent.atomic.AtomicInteger

/// §707 итер. 4 — служебные файлы поверх Taildrop (контракт 1.1.148–1.1.150,
/// `docs/SERVICE_FILES.md`): `lx-<время>-<метка>.json` с командами
/// `clipboard` и `open_url`. Константы — реестр `service_files.json` из
/// ассетов приложения (зеркало контракта), не литералы: нет реестра — нет и
/// служебных файлов, всё принятое остаётся обычными файлами.
///
/// Текст буфера, ссылки, имена файлов и устройств не пишутся ни в logcat,
/// ни в AppLog.
object TaildropServiceFiles {
    private const val TAG = "TaildropService"
    private const val ASSET = "flutter_assets/assets/contract/registry/service_files.json"

    /// Сколько ждать снимок входящих ядра (отправитель файла).
    private const val SNAPSHOT_TIMEOUT_MS = 3000L

    class Kind(val fields: Map<String, String>, val schemes: Set<String>?)

    class Spec(
        val prefix: String,
        val suffix: String,
        val timeFormat: String,
        val labelLength: Int,
        val maxBytes: Long,
        val versions: Set<Long>,
        val ttlSeconds: Long,
        val kinds: Map<String, Kind>,
    )

    @Volatile private var cached: Spec? = null
    @Volatile private var loadFailed = false

    fun spec(ctx: Context): Spec? {
        cached?.let { return it }
        if (loadFailed) return null
        val s = runCatching {
            ctx.applicationContext.assets.open(ASSET).use { parseSpec(String(it.readBytes(), StandardCharsets.UTF_8)) }
        }.getOrNull()
        if (s == null) {
            loadFailed = true
            Log.w(TAG, "service_files registry not available")
        }
        cached = s
        return s
    }

    /// Разбор `service_files.json`; `null` — реестр не той формы.
    internal fun parseSpec(json: String): Spec? = runCatching {
        val sf = JSONObject(json).getJSONObject("service_files")
        fun value(key: String) = sf.getJSONObject(key).get("value")
        val versions = HashSet<Long>()
        val va = value("versions") as JSONArray
        for (i in 0 until va.length()) versions.add(va.getLong(i))
        val kinds = LinkedHashMap<String, Kind>()
        val ko = sf.getJSONObject("kinds")
        for (name in ko.keys()) {
            val k = ko.optJSONObject(name) ?: continue
            val fields = LinkedHashMap<String, String>()
            k.optJSONObject("fields")?.let { f -> for (fk in f.keys()) fields[fk] = f.optString(fk) }
            val schemes = k.optJSONArray("schemes")?.let { a ->
                (0 until a.length()).map { a.getString(it).lowercase() }.toSet()
            }
            kinds[name] = Kind(fields, schemes)
        }
        Spec(
            prefix = value("name_prefix") as String,
            suffix = value("name_suffix") as String,
            timeFormat = value("name_time_format") as String,
            labelLength = (value("name_label_length") as Number).toInt(),
            maxBytes = (value("max_bytes") as Number).toLong(),
            versions = versions,
            ttlSeconds = (value("ttl_seconds") as Number).toLong(),
            kinds = kinds,
        )
    }.getOrNull()

    // ─────────────────────────── отправитель ───────────────────────────

    /// Итог сборки служебного файла (§707 итер. 7).
    sealed class Built {
        class Ok(val name: String, val bytes: ByteArray) : Built()

        /// Тело больше `max_bytes` (§7 п.2).
        class TooLarge(val size: Int, val maxBytes: Long) : Built()

        /// Формат времени имени реестру неизвестен этой версии.
        object Unsupported : Built()
    }

    private const val TIME_FORMAT = "YYYYMMDDTHHMMSSZ"
    private const val LABEL_ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789"

    /// §3 — тело `{"lx": <версия>, "commands": [...]}` в UTF-8; `lx` —
    /// старшая из `versions`.
    internal fun body(spec: Spec, commands: JSONArray): ByteArray =
        JSONObject()
            .put("lx", spec.versions.maxOrNull() ?: 1L)
            .put("commands", commands)
            .toString()
            .toByteArray(StandardCharsets.UTF_8)

    /// §2–§3 — служебный файл с командами [commands]: имя
    /// `<name_prefix><UTC YYYYMMDDTHHMMSSZ>-<метка [a-z0-9]><name_suffix>`.
    /// Команды не проверяются (Debug API шлёт и битые — проверять разбор
    /// получателя); предел `max_bytes` — проверяется.
    internal fun build(spec: Spec, commands: JSONArray, nowMs: Long, random: java.util.Random): Built {
        if (spec.timeFormat != TIME_FORMAT) return Built.Unsupported
        val bytes = body(spec, commands)
        if (bytes.size.toLong() > spec.maxBytes) return Built.TooLarge(bytes.size, spec.maxBytes)
        val stamp = java.text.SimpleDateFormat("yyyyMMdd'T'HHmmss'Z'", java.util.Locale.US)
            .apply { timeZone = java.util.TimeZone.getTimeZone("UTC") }
            .format(java.util.Date(nowMs))
        val label = buildString {
            repeat(spec.labelLength) { append(LABEL_ALPHABET[random.nextInt(LABEL_ALPHABET.length)]) }
        }
        return Built.Ok("${spec.prefix}$stamp-$label${spec.suffix}", bytes)
    }

    /// Одна команда вида [kind] со значением [value] (`clipboard` → `text`,
    /// `open_url` → `url`).
    internal fun command(kind: String, value: String): JSONObject =
        JSONObject().put("kind", kind).put(if (kind == "open_url") "url" else "text", value)

    /// «Ссылка целиком»: текст после trim — одна ссылка схемы из [schemes]
    /// (`open_url.schemes` реестра), без пробелов внутри, с непустым адресом
    /// после `://`. Иначе `null`.
    internal fun singleUrl(text: String, schemes: Set<String>?): String? {
        val t = text.trim()
        if (t.isEmpty() || schemes.isNullOrEmpty() || t.any { it.isWhitespace() }) return null
        val i = t.indexOf("://")
        if (i <= 0 || i + 3 >= t.length || t[i + 3] == '/') return null
        if (t.substring(0, i).lowercase() !in schemes) return null
        return t
    }

    /// Кандидат — по префиксу и суффиксу имени (ядро может переименовать файл
    /// при совпадении имён), §2.
    fun isCandidate(spec: Spec, name: String): Boolean =
        name.length > spec.prefix.length + spec.suffix.length &&
            name.startsWith(spec.prefix) && name.endsWith(spec.suffix)

    /// §4 — тело служебного файла: список команд (не-объекты пропущены).
    /// `null` — файл обычный (больше предела, не UTF-8 / JSON, `lx` нет или не
    /// из `versions`, `commands` нет или не список).
    internal fun parseBody(spec: Spec, bytes: ByteArray): List<JSONObject>? {
        if (bytes.size.toLong() > spec.maxBytes) return null
        val text = runCatching {
            StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes)).toString()
        }.getOrNull() ?: return null
        // «JSON в UTF-8 без BOM»: с BOM — не наш файл.
        if (text.startsWith('﻿')) return null
        val root = runCatching { JSONObject(text) }.getOrNull() ?: return null
        val lx = root.opt("lx") as? Number ?: return null
        val lxLong = lx.toLong()
        if (lx.toDouble() != lxLong.toDouble() || lxLong !in spec.versions) return null
        val arr = root.opt("commands") as? JSONArray ?: return null
        val out = ArrayList<JSONObject>()
        for (i in 0 until arr.length()) arr.optJSONObject(i)?.let { out.add(it) }
        return out
    }

    // ─────────────────────────── разрешение ───────────────────────────

    /// §707 итер. 9, контракт SERVICE_FILES §5 (1.1.157) — команда выполняется,
    /// только если у узла [tag] стоит галка `taildrop_commands` (тег в зеркале
    /// `taildrop_commands_tags`), `senderID` файла непустой и пир с этим ID
    /// есть в статусе узла [ownPeers] — свои устройства, без sharee. Fallback по
    /// имени нет: после перезапуска ядра `senderID` пуст — команды не
    /// выполняются, файл удаляется как всегда.
    internal fun allowed(ctx: Context, tag: String, senderId: String, ownPeers: Set<String>): Boolean =
        senderId.isNotEmpty() && senderId in ownPeers && tag in BootReceiver.taildropCommandsTags(ctx)

    /// Stable ID своих устройств узла [tag] по снимку ядра: пиры всех групп
    /// пользователя без признака `sharee_node` (как получатели окна Send).
    @Suppress("UNCHECKED_CAST")
    private fun ownPeers(snapshot: List<Map<String, Any>>?, tag: String): Set<String> {
        val node = snapshot.orEmpty().firstOrNull { "${it["tag"] ?: ""}" == tag } ?: return emptySet()
        val groups = node["user_groups"] as? List<Map<String, Any>> ?: return emptySet()
        return groups.flatMap { (it["peers"] as? List<Map<String, Any>>).orEmpty() }
            .filter { it["sharee_node"] != true }
            .mapNotNull { p -> "${p["stable_id"] ?: ""}".takeIf { it.isNotEmpty() } }
            .toSet()
    }

    // ─────────────────────────── счётчики ───────────────────────────

    /// §707 итер. 5 — счётчики разбора с начала процесса для Debug API
    /// (`GET /taildrop/service-files`). Только в памяти; текст последней
    /// выполненной команды отдаётся Debug API лишь с `?reveal=true`.
    private object Stats {
        val received = AtomicInteger(0)
        val clipboard = AtomicInteger(0)
        val openUrl = AtomicInteger(0)
        val noPermission = AtomicInteger(0)
        val expired = AtomicInteger(0)
        val invalid = AtomicInteger(0)
        val unknownKind = AtomicInteger(0)
        val badScheme = AtomicInteger(0)
        val noHandler = AtomicInteger(0)
        @Volatile var last: Triple<String, Long, String>? = null
    }

    private fun executed(kind: String, value: String) {
        Stats.last = Triple(kind, System.currentTimeMillis(), value)
    }

    /// Снимок счётчиков для канала: `last` — вид, время (мс), значение
    /// (текст буфера или ссылка).
    fun stats(): Map<String, Any?> {
        val last = Stats.last
        return mapOf(
            "received" to Stats.received.get(),
            "executed" to mapOf(
                "clipboard" to Stats.clipboard.get(),
                "open_url" to Stats.openUrl.get(),
            ),
            "skipped_no_permission" to Stats.noPermission.get(),
            "expired" to Stats.expired.get(),
            "invalid" to Stats.invalid.get(),
            "unknown_kind" to Stats.unknownKind.get(),
            "skipped_scheme" to Stats.badScheme.get(),
            "no_handler" to Stats.noHandler.get(),
            "last" to last?.let { mapOf("kind" to it.first, "at_ms" to it.second, "value" to it.third) },
        )
    }

    // ─────────────────────────── обработка ───────────────────────────

    /// Принятый файл входящих: имя и путь на диске.
    class Incoming(val name: String, val file: File)

    private class Clip(val text: String, val modifiedAt: Long, val name: String, val peerId: String)

    /// §6 — разобрать кандидатов [items] узла [tag] (пачка: один `clipboard` —
    /// последний). Возвращает имена служебных файлов (команды выполнены,
    /// файл удалён или удаление не удалось); остальные — обычные файлы.
    /// [viaCore] — ядро работает: отправитель из снимка входящих, удаление
    /// через ядро. Блокирующий — звать с IO.
    fun process(ctx: Context, tag: String, items: List<Incoming>, viaCore: Boolean): Set<String> {
        val spec = spec(ctx) ?: return emptySet()
        val candidates = items.filter { isCandidate(spec, it.name) }
        if (candidates.isEmpty()) return emptySet()
        val app = ctx.applicationContext
        val cc = if (viaCore) BoxService.commandClient else null
        var senders: Map<String, Pair<String, String>>? = null
        var own: Set<String>? = null
        val handled = LinkedHashSet<String>()
        var lastClip: Clip? = null
        var bad = 0
        val nowSec = System.currentTimeMillis() / 1000
        for (item in candidates) {
            val f = item.file
            if (!f.isFile || f.length() > spec.maxBytes) continue
            val bytes = runCatching { f.readBytes() }.getOrNull() ?: continue
            val commands = parseBody(spec, bytes) ?: continue
            handled.add(item.name)
            Stats.received.incrementAndGet()
            val modifiedAt = f.lastModified() / 1000
            val fresh = nowSec - modifiedAt <= spec.ttlSeconds
            if (!fresh) Stats.expired.incrementAndGet()
            if (fresh && commands.isNotEmpty()) {
                if (senders == null) senders = cc?.taildropInboxSnapshot(tag, SNAPSHOT_TIMEOUT_MS) ?: emptyMap()
                // Снимок статуса — только если у узла стоит галка команд.
                if (own == null) {
                    own = if (tag !in BootReceiver.taildropCommandsTags(app)) emptySet()
                    else ownPeers(runCatching { cc?.tailscaleSnapshot(SNAPSHOT_TIMEOUT_MS) }.getOrNull(), tag)
                }
                val (senderId, senderName) = senders[item.name] ?: ("" to "")
                for (cmd in commands) {
                    val kindName = cmd.opt("kind") as? String
                    val kind = kindName?.let { spec.kinds[it] }
                    if (kind == null) { // неизвестный — пропуск
                        Stats.unknownKind.incrementAndGet()
                        continue
                    }
                    if (!fieldsOk(cmd, kind)) {
                        bad++
                        continue
                    }
                    if (!allowed(app, tag, senderId, own ?: emptySet())) {
                        Stats.noPermission.incrementAndGet()
                        continue
                    }
                    when (kindName) {
                        "clipboard" -> {
                            val text = cmd.getString("text").removePrefix("﻿")
                            if (text.isEmpty()) {
                                bad++
                                continue
                            }
                            val c = Clip(text, modifiedAt, item.name, senderId)
                            val prev = lastClip
                            if (prev == null || later(spec, c, prev)) lastClip = c
                        }
                        "open_url" -> {
                            val url = cmd.getString("url")
                            val scheme = Uri.parse(url).scheme?.lowercase()
                            val schemes = kind.schemes
                            if (scheme == null || schemes == null || scheme !in schemes) {
                                Stats.badScheme.incrementAndGet()
                                continue
                            }
                            if (showLink(app, tag, item.name, senderName, url)) {
                                Stats.openUrl.incrementAndGet()
                                executed(kindName, url)
                                // §707 итер. 7 — в ленту окна «Send clipboard».
                                TaildropClip.addIncoming(
                                    tag, senderId, kindName, url,
                                )
                            } else {
                                Stats.noHandler.incrementAndGet()
                            }
                        }
                    }
                }
            }
            // §6 п.3 — удаление всегда.
            val err = cc?.taildropDelete(tag, item.name)
            if (cc == null || err != null) runCatching { f.delete() }
        }
        lastClip?.let {
            setClipboard(app, it.text)
            Stats.clipboard.incrementAndGet()
            executed("clipboard", it.text)
            TaildropClip.addIncoming(tag, it.peerId, "clipboard", it.text)
        }
        if (bad > 0) {
            Stats.invalid.addAndGet(bad)
            val line = "taildrop service file: $bad malformed command(s) skipped"
            Log.w(TAG, line)
            BoxService.appLogWarning(line)
        }
        return handled
    }

    /// Поля вида — по `fields` реестра (сейчас все строковые).
    private fun fieldsOk(cmd: JSONObject, kind: Kind): Boolean =
        kind.fields.all { (name, type) ->
            when (type) {
                "string" -> cmd.opt(name) is String
                else -> cmd.has(name)
            }
        }

    /// [a] позже [b]: по `modifiedAt`, при равенстве — по времени в имени
    /// (формат фиксированной ширины, сравнение строк).
    private fun later(spec: Spec, a: Clip, b: Clip): Boolean {
        if (a.modifiedAt != b.modifiedAt) return a.modifiedAt > b.modifiedAt
        return a.name.removePrefix(spec.prefix) >= b.name.removePrefix(spec.prefix)
    }

    private fun setClipboard(ctx: Context, text: String) {
        Handler(Looper.getMainLooper()).post {
            runCatching {
                val cm = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                cm.setPrimaryClip(ClipData.newPlainText("Taildrop", text))
            }.onFailure { Log.w(TAG, "clipboard write failed: ${it.javaClass.simpleName}") }
        }
    }

    /// «Link from <device>» с адресом в тексте; тап открывает `ACTION_VIEW`.
    /// Обработчика нет — ничего.
    private fun showLink(ctx: Context, tag: String, name: String, sender: String, url: String): Boolean {
        val view = Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (view.resolveActivity(ctx.packageManager) == null) return false
        val id = 6000 + ("$tag/$name/$url".hashCode() and 0x3fff)
        val pi = PendingIntent.getActivity(
            ctx, id, view,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        Taildrop.ensureChannel(ctx)
        val b = NotificationCompat.Builder(ctx, Taildrop.CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setContentTitle(L10n.str(ctx, R.string.taildrop_link_from, sender.ifEmpty { tag }))
            .setContentText(url)
            .setStyle(NotificationCompat.BigTextStyle().bigText(url))
            .setContentIntent(pi)
            .setAutoCancel(true)
        runCatching {
            (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager).notify(id, b.build())
        }.onFailure { Log.w(TAG, "link notify failed: ${it.javaClass.simpleName}") }
        return true
    }
}
