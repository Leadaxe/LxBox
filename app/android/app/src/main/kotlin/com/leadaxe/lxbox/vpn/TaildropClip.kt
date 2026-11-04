package com.leadaxe.lxbox.vpn

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.leadaxe.lxbox.R
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.security.SecureRandom
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.atomic.AtomicLong

/// §707 итер. 7 — сообщение ленты окна «Send clipboard». [out] — отправлено
/// с этого телефона; [kind] — `clipboard` или `open_url`; [status] у
/// отправленного — `sending`, `sent` или `error` ([error] — причина).
data class ClipMessage(
    val id: Long,
    val out: Boolean,
    val kind: String,
    val text: String,
    val atMs: Long,
    val status: String = "",
    val error: String? = null,
)

/// Ленты окна по устройствам (ключ — тег узла + stable ID пира): последние
/// [max] сообщений на устройство. Только в памяти (решение владельца
/// 03.11.2026): остановка VPN и смерть процесса ленты стирают.
class ClipFeeds(private val max: Int = MAX_MESSAGES) {
    private val feeds = LinkedHashMap<Pair<String, String>, ArrayList<ClipMessage>>()

    @Synchronized
    fun add(tag: String, peerId: String, msg: ClipMessage) {
        val list = feeds.getOrPut(tag to peerId) { ArrayList() }
        list.add(msg)
        while (list.size > max) list.removeAt(0)
    }

    @Synchronized
    fun messages(tag: String, peerId: String): List<ClipMessage> =
        feeds[tag to peerId]?.toList().orEmpty()

    /// Итог отправки сообщения [id]; `false` — сообщения уже нет (лента
    /// очищена или обрезана).
    @Synchronized
    fun update(tag: String, peerId: String, id: Long, status: String, error: String?): Boolean {
        val list = feeds[tag to peerId] ?: return false
        val i = list.indexOfFirst { it.id == id }
        if (i < 0) return false
        list[i] = list[i].copy(status = status, error = error)
        return true
    }

    @Synchronized
    fun clear(tag: String, peerId: String) {
        feeds.remove(tag to peerId)
    }

    @Synchronized
    fun clearAll() = feeds.clear()

    /// (тег, ID пира, число сообщений) непустых лент.
    @Synchronized
    fun counts(): List<Triple<String, String, Int>> =
        feeds.filterValues { it.isNotEmpty() }.map { (k, v) -> Triple(k.first, k.second, v.size) }

    companion object {
        const val MAX_MESSAGES = 50
    }
}

/// Получатель окна: устройство [peerId] узла [tag].
data class ClipTarget(val tag: String, val peerId: String, val name: String, val online: Boolean)

/// Получатели по снимку ядра: [block] — причина, по которой отправлять
/// нельзя совсем (`null` — можно); [online] — кого предложить в `To: ▾`;
/// [all] — и устройства не в сети (выбранное могло уйти из сети).
class ClipTargets(val block: Int?, val online: List<ClipTarget>, val all: List<ClipTarget>)

/// §707 итер. 7 — окно «Send clipboard» вне активности: ленты, запомненный
/// получатель, отправка служебного файла, видимость «Поделиться» и «Send to
/// device». Текст буфера и ссылок в журнал не пишется.
object TaildropClip {
    private const val TAG = "TaildropClip"

    /// «Send to device» (PROCESS_TEXT) — alias окна.
    private const val PROCESS_TEXT_ALIAS = "com.leadaxe.lxbox.vpn.TaildropProcessTextActivity"

    val feeds = ClipFeeds()
    private val nextId = AtomicLong(1)
    private val listeners = CopyOnWriteArraySet<Runnable>()
    private val main by lazy { Handler(Looper.getMainLooper()) }
    private val random by lazy { SecureRandom() }

    /// VPN поднят и в работающем конфиге есть узел Tailscale с Allow
    /// Taildrop: кнопка в уведомлении VPN, «Поделиться» и «Send to device»
    /// видны только тогда.
    @Volatile var available = false
        private set

    // ───────────────────────── ленты ─────────────────────────

    fun addListener(l: Runnable) { listeners.add(l) }

    fun removeListener(l: Runnable) { listeners.remove(l) }

    private fun changed() {
        if (listeners.isEmpty()) return
        main.post { for (l in listeners) runCatching { l.run() } }
    }

    fun clear(tag: String, peerId: String) {
        feeds.clear(tag, peerId)
        changed()
    }

    /// Приём (итерация 4) выполнил команду от устройства [peerId] узла [tag].
    fun addIncoming(tag: String, peerId: String, kind: String, text: String) {
        if (tag.isEmpty() || peerId.isEmpty()) return
        feeds.add(tag, peerId, ClipMessage(nextId.getAndIncrement(), false, kind, text, System.currentTimeMillis()))
        changed()
    }

    // ───────────────────────── получатель ─────────────────────────

    /// Запомненный получатель: (тег, ID, имя) или `null`. Кэш Kotlin
    /// ([NativeCache]), не настройка: в бэкап не идёт.
    fun remembered(ctx: Context): Triple<String, String, String>? = NativeCache.clipTarget(ctx)

    fun remember(ctx: Context, t: ClipTarget) {
        NativeCache.setClipTarget(ctx, t.tag, t.peerId, t.name)
    }

    /// Причины, по которым отправлять нельзя совсем (по порядку таблицы
    /// спеки).
    val BLOCK_NEED_VPN get() = R.string.clip_need_vpn
    val BLOCK_TAILDROP_OFF get() = R.string.clip_taildrop_off
    val BLOCK_NO_DEVICES get() = R.string.clip_no_devices

    /// Получатели по снимку ядра [snapshot] (`null` — VPN не поднят) и
    /// тегам узлов с выключенным Allow Taildrop [off]: свои устройства,
    /// которые принимают файлы, со всех работающих узлов; по имени.
    @Suppress("UNCHECKED_CAST")
    fun targets(snapshot: List<Map<String, Any>>?, off: Set<String>): ClipTargets {
        val running = snapshot.orEmpty().filter { it["backend_state"] == "Running" }
        if (running.isEmpty()) return ClipTargets(BLOCK_NEED_VPN, emptyList(), emptyList())
        val nodes = running.filter { "${it["tag"] ?: ""}" !in off }
        if (nodes.isEmpty()) return ClipTargets(BLOCK_TAILDROP_OFF, emptyList(), emptyList())
        val all = ArrayList<ClipTarget>()
        for (n in nodes) {
            if (n["can_share_files"] == false) continue
            val tag = "${n["tag"] ?: ""}"
            val groups = n["user_groups"] as? List<Map<String, Any>> ?: continue
            for (p in groups.flatMap { (it["peers"] as? List<Map<String, Any>>).orEmpty() }) {
                if (p["can_receive_files"] != true || p["sharee_node"] == true) continue
                val id = "${p["stable_id"] ?: ""}"
                if (id.isEmpty()) continue
                all.add(ClipTarget(tag, id, "${p["host_name"] ?: ""}", p["online"] == true))
            }
        }
        all.sortWith(compareBy({ it.name.lowercase() }, { it.tag }))
        val online = all.filter { it.online }
        return ClipTargets(if (online.isEmpty()) BLOCK_NO_DEVICES else null, online, all)
    }

    // ───────────────────────── отправка ─────────────────────────

    /// Байты тела одной команды [kind] с [value] — для проверки предела до
    /// отправки.
    fun bodySize(spec: TaildropServiceFiles.Spec, kind: String, value: String): Int =
        TaildropServiceFiles.body(spec, JSONArray().put(TaildropServiceFiles.command(kind, value))).size

    /// Отправить [value] командой [kind] получателю [t]: сообщение сразу в
    /// ленту (`sending`), итог передачи — в него же. Тем же путём, что «Send
    /// file…», без уведомлений отправки: итог виден в ленте.
    fun send(ctx: Context, t: ClipTarget, kind: String, value: String) {
        val app = ctx.applicationContext
        val msg = ClipMessage(nextId.getAndIncrement(), true, kind, value, System.currentTimeMillis(), "sending")
        feeds.add(t.tag, t.peerId, msg)
        changed()
        fun done(status: String, error: String?) {
            feeds.update(t.tag, t.peerId, msg.id, status, error)
            changed()
        }
        val spec = TaildropServiceFiles.spec(app)
        if (spec == null) {
            done("error", L10n.str(app, R.string.taildrop_failed_title, t.name))
            return
        }
        val commands = JSONArray().put(TaildropServiceFiles.command(kind, value))
        when (val b = TaildropServiceFiles.build(spec, commands, System.currentTimeMillis(), random)) {
            is TaildropServiceFiles.Built.Ok -> {
                val item = Taildrop.Item(b.name, b.bytes.size.toLong(), ByteArrayInputStream(b.bytes))
                val started = Taildrop.send(app, t.tag, t.peerId, t.name, listOf(item), quiet = true) { status, err ->
                    if (status == "sent") done("sent", null) else done("error", err ?: status)
                }
                if (!started) done("error", L10n.str(app, R.string.taildrop_reason_vpn_off))
            }
            is TaildropServiceFiles.Built.TooLarge -> done("error", L10n.str(app, R.string.clip_too_large))
            TaildropServiceFiles.Built.Unsupported ->
                done("error", L10n.str(app, R.string.taildrop_failed_title, t.name))
        }
    }

    // ───────────────────────── VPN ─────────────────────────

    /// Есть ли в собранном конфиге endpoint `tailscale` без
    /// `disable_taildrop: true`.
    internal fun hasTaildropNode(configJson: String): Boolean = runCatching {
        val eps = JSONObject(configJson).optJSONArray("endpoints") ?: return false
        (0 until eps.length()).any { i ->
            val ep = eps.optJSONObject(i)
            ep != null && ep.optString("type") == "tailscale" && !ep.optBoolean("disable_taildrop", false)
        }
    }.getOrDefault(false)

    /// Старт VPN или перезагрузка конфига [configJson]. `true` — видимость
    /// поменялась (уведомление VPN надо перерисовать).
    fun onConfig(ctx: Context, configJson: String): Boolean = setAvailable(ctx, hasTaildropNode(configJson))

    /// VPN остановлен: ленты стираются, пункты скрываются.
    fun onVpnStopped(ctx: Context?) {
        feeds.clearAll()
        changed()
        if (ctx != null) setAvailable(ctx, false) else available = false
    }

    /// Старт процесса: VPN этого процесса ещё не поднят — пункты, оставшиеся
    /// включёнными после падения, выключаются.
    fun syncOnProcessStart(ctx: Context) {
        setAvailable(ctx, false, force = true)
    }

    private fun setAvailable(ctx: Context, value: Boolean, force: Boolean = false): Boolean {
        val was = available
        available = value
        if (was == value && !force) return false
        val pm = ctx.packageManager
        val state = if (value) PackageManager.COMPONENT_ENABLED_STATE_ENABLED
        else PackageManager.COMPONENT_ENABLED_STATE_DISABLED
        for (cls in listOf(TaildropShareActivity::class.java.name, PROCESS_TEXT_ALIAS)) {
            runCatching {
                val cn = ComponentName(ctx.packageName, cls)
                if (pm.getComponentEnabledSetting(cn) != state) {
                    pm.setComponentEnabledSetting(cn, state, PackageManager.DONT_KILL_APP)
                }
            }.onFailure { Log.w(TAG, "component state failed: ${it.javaClass.simpleName}") }
        }
        return was != value
    }

    /// Debug API (`GET /taildrop`): получатель и число сообщений лент.
    fun state(ctx: Context): Map<String, Any?> = mapOf(
        "target" to remembered(ctx)?.let { (tag, peer, name) ->
            mapOf("tag" to tag, "peer_id" to peer, "name" to name)
        },
        "feeds" to feeds.counts().map { (tag, peer, n) ->
            mapOf("tag" to tag, "peer_id" to peer, "messages" to n)
        },
        "available" to available,
    )
}
