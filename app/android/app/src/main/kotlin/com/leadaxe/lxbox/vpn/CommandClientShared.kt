package com.leadaxe.lxbox.vpn

import android.os.Handler
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.nekohasekai.libbox.CommandClient
import io.nekohasekai.libbox.CommandClientHandler
import io.nekohasekai.libbox.CommandClientOptions
import io.nekohasekai.libbox.ConnectionEvents
import io.nekohasekai.libbox.DnsQuery
import io.nekohasekai.libbox.LogIterator
import io.nekohasekai.libbox.OutboundGroup
import io.nekohasekai.libbox.OutboundGroupItemIterator
import io.nekohasekai.libbox.OutboundGroupIterator
import io.nekohasekai.libbox.StatusMessage
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.TaildropInbox
import io.nekohasekai.libbox.TaildropInboxHandler
import io.nekohasekai.libbox.TaildropInboxSubscription
import io.nekohasekai.libbox.TailscaleEndpointStatus
import io.nekohasekai.libbox.TailscalePeer
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/// §745 — общее двух клиентов `command.sock`: [BoxCommandClient] (роль UI) и
/// [ServiceCommandClient] (роль сервиса). Файл без роли: здесь нет состояния
/// клиента, только то, что обе роли делают одинаково, — полоса блокирующих
/// вызовов, no-op обработчик, разрыв клиента, ленивый unary-клиент, эмиттеры,
/// разбор типов ядра в map канала и unary-вызовы, нужные обеим ролям. Код
/// перенесён из `BoxCommandClient` без изменений; у каждого клиента поверх —
/// тонкая обёртка со своим unary-клиентом.

/// Тег logcat прежний у обоих клиентов и у общего кода: по нему фильтруют
/// дампы, и строки сервисного клиента (openconnect) не должны сменить тег.
internal const val CC_LOG_TAG = "BoxCommandClient"

private const val TAG = CC_LOG_TAG

/// Cap очереди эмиттера — drop-newest при переполнении (producer не блокируется).
/// Эмиттер coalesce'ит до последнего снапшота, так что cap — страховка.
private const val QUEUE_MAX = 4096

/// §732 — полоса для connect()/disconnect() клиентов. `connect()` ядра
/// ждёт командный сервер до 3,25 с; раньше он шёл с главного потока
/// (обработчики `cc*` в VpnPlugin и реконнект через mainHandler), и
/// при молчащем сервере главный поток стоял почти непрерывно —
/// MethodChannel отвечал таймаутами (issue #210). Одна на процесс:
/// задачи прошлого экземпляра клиента гасит его же `tunnelAlive`.
///
/// §745 — вынесена из `BoxCommandClient.companion`: полоса не принадлежит ни
/// одной роли. Задачи на неё сейчас ставит только клиент UI.
internal object CommandLane {
    val lane = SerialLane(
        "lxbox-cc",
        onSlow = { msg ->
            Log.e(TAG, "[cc §732] $msg")
            warningSink?.invoke("[cc §732] $msg")
        },
        onError = { label, t -> Log.w(TAG, "[cc §732] $label failed: ${t.message}") },
    )

    /// §742 — приёмник WARN-строк полосы [lane] (она одна на процесс, без
    /// экземпляра клиента). Назначает `BoxService` вместе со своим `current`
    /// и снимает вместе с ним; null — сервиса нет, строка только в logcat.
    @Volatile
    var warningSink: ((String) -> Unit)? = null
}

/// Закрыть клиента в [ref] (атомарно снять и разорвать). Идемпотентно.
internal fun disconnectClient(ref: AtomicReference<CommandClient?>, reason: String) {
    ref.getAndSet(null)?.runCatching { disconnect() }
        ?.onFailure { Log.w(TAG, "disconnect($reason) failed: ${it.message}") }
}

/// §175/§209 — поднять unary-клиент в [ref] лениво. Голый [CcPingHandler]:
/// подписок нет, только unary RPC. Свой ctx/conn — disconnect рвёт лишь его
/// вызовы. Идемпотентно (CAS): возвращает живой, если есть.
internal fun ensureUnaryClient(ref: AtomicReference<CommandClient?>): CommandClient? {
    ref.get()?.let { return it }
    return runCatching {
        val options = CommandClientOptions() // подписок нет — unary RPC
        val client = CommandClient(CcPingHandler(), options)
        client.connect()
        if (ref.compareAndSet(null, client)) client
        else { client.runCatching { disconnect() }; ref.get() }
    }.getOrElse { Log.w(TAG, "ensurePingClient failed: ${it.message}"); null }
}

/// Новый подключённый клиент без подписок — под поток одной передачи
/// (отправка, выгрузка файла, разовый снимок), чтобы его закрытие не задевало
/// другие. Блокирующий connect — звать не с main.
internal fun newCommandCallClient(): CommandClient? = runCatching {
    CommandClient(CcPingHandler(), CommandClientOptions()).also { it.connect() }
}.getOrElse { Log.w(TAG, "newCallClient failed: ${it.message}"); null }

// ═══════════════════════ Handlers ═══════════════════════
// Базовый no-op handler — все колбэки в try/catch fail-safe (JNI-no-throw).
// Конкретные клиенты переопределяют только нужные write*.

internal abstract class CcBaseHandler(protected val gen: Int) : CommandClientHandler {
    override fun connected() { runCatching { Log.d(TAG, "connected gen=$gen") } }
    override fun disconnected(message: String) {
        runCatching { Log.d(TAG, "disconnected gen=$gen: $message") }
    }
    override fun clearLogs() { runCatching { } }
    override fun setDefaultLogLevel(level: Int) { runCatching { } }
    override fun initializeClashMode(modeList: StringIterator?, currentMode: String?) { runCatching { } }
    override fun updateClashMode(newMode: String?) { runCatching { } }
    override fun writeLogs(messageList: LogIterator?) { runCatching { } }
    override fun writeStatus(message: StatusMessage?) { runCatching { } }
    override fun writeGroups(groups: OutboundGroupIterator?) { runCatching { } }
    override fun writeOutbounds(outbounds: OutboundGroupItemIterator?) { runCatching { } }
    override fun writeConnectionEvents(message: ConnectionEvents?) { runCatching { } }
    // §261 — CommandClientHandler расширен writeDNSQuery. Только ProfilerHandler
    // слушает DNS реально; остальные (status/screen/ping) — no-op.
    override fun writeDNSQuery(query: DnsQuery?) { runCatching { } }
}
/// §175 — клиент без подписок (unary RPC, носитель отдельной подписки). Все
/// колбэки — no-op из [CcBaseHandler] (fail-safe try/catch).
internal class CcPingHandler : CcBaseHandler(0)

// ═══════════════════════ разбор типов ядра ═══════════════════════

/// §581 — запись `TailscaleEndpointStatus` в map канала: полное состояние
/// для вкладки Network. Имена, адреса и ссылка входа в лог не пишутся
/// (раздел 9). §645 — тот же разбор у потока и у `getTailscaleStatus`.
internal fun tailscaleEndpointMap(e: TailscaleEndpointStatus): HashMap<String, Any> {
    val groups = ArrayList<Map<String, Any>>()
    val gi = e.userGroups()
    while (gi != null && gi.hasNext()) {
        val g = gi.next() ?: continue
        val peers = ArrayList<Map<String, Any>>()
        val pi = g.peers()
        while (pi != null && pi.hasNext()) {
            val p = pi.next() ?: continue
            peers.add(tailscalePeerMap(p))
        }
        groups.add(mapOf(
            "user_id" to g.userID,
            "login_name" to (g.loginName ?: ""),
            "display_name" to (g.displayName ?: ""),
            "peers" to peers,
        ))
    }
    val m = HashMap<String, Any>()
    m["tag"] = e.endpointTag ?: ""
    m["backend_state"] = e.backendState ?: ""
    m["state_text"] = e.stateText ?: ""
    m["auth_url"] = e.authURL ?: ""
    m["network_name"] = e.networkName ?: ""
    m["magic_dns_suffix"] = e.magicDNSSuffix ?: ""
    m["key_auth"] = e.keyAuth
    e.self?.let { m["self"] = tailscalePeerMap(it) }
    e.exitNode?.let { m["exit_node"] = tailscalePeerMap(it) }
    m["user_groups"] = groups
    // §613 (ядро SPEC 115, lx.12) — предупреждения бэкенда.
    val health = ArrayList<String>()
    val hi = e.health()
    while (hi != null && hi.hasNext()) hi.next()?.let { health.add(it) }
    m["health"] = health
    // §707 — Taildrop: право узла на обмен файлами и счётчики входящих.
    m["can_share_files"] = e.canShareFiles
    m["waiting_file_count"] = e.waitingFileCount
    m["receiving_file_count"] = e.receivingFileCount
    m["unread_file_count"] = e.unreadFileCount
    return m
}

/// §581 — `TailscalePeer` в map канала. `key_expiry`/`last_seen` — Unix-секунды
/// ядра (`Time.Unix()`), 0 = нет значения.
internal fun tailscalePeerMap(p: TailscalePeer): Map<String, Any> {
    val ips = ArrayList<String>()
    val iter = p.tailscaleIPs()
    while (iter != null && iter.hasNext()) iter.next()?.let { ips.add(it) }
    return mapOf(
        "stable_id" to (p.stableID ?: ""),
        "host_name" to (p.hostName ?: ""),
        "dns_name" to (p.dnsName ?: ""),
        "os" to (p.os ?: ""),
        "online" to p.online,
        "exit_node" to p.exitNode,
        "exit_node_option" to p.exitNodeOption,
        "sharee_node" to p.shareeNode,
        "expired" to p.expired,
        "key_expiry" to p.keyExpiry,
        "last_seen" to p.lastSeen,
        "ips" to ips,
        // §613 (ядро SPEC 115, lx.12) — путь до пира: DIRECT / PEER_RELAY /
        // DERP / NONE; `last_handshake` — Unix-секунды, 0 = не было.
        "path" to (p.path ?: ""),
        "endpoint" to (p.endpoint ?: ""),
        "peer_relay" to (p.peerRelay ?: ""),
        "derp_region_code" to (p.derpRegionCode ?: ""),
        "last_handshake" to p.lastHandshake,
        // §707 — пир принимает файлы Taildrop (своё устройство, право есть).
        "can_receive_files" to p.canReceiveFiles,
    )
}

internal fun taildropInboxMap(inbox: TaildropInbox, tag: String): Map<String, Any> {
    val files = ArrayList<Map<String, Any>>()
    val fi = inbox.files()
    while (fi != null && fi.hasNext()) {
        val f = fi.next() ?: continue
        files.add(mapOf(
            "name" to (f.name ?: ""),
            "size" to f.size,
            "sender_id" to (f.senderID ?: ""),
            "sender_name" to (f.senderName ?: ""),
            "modified_at" to f.modifiedAt,
        ))
    }
    val receiving = ArrayList<Map<String, Any>>()
    val ri = inbox.receiving()
    while (ri != null && ri.hasNext()) {
        val f = ri.next() ?: continue
        receiving.add(mapOf(
            "name" to (f.name ?: ""),
            "size" to f.size,
            "received_bytes" to f.receivedBytes,
            "sender_id" to (f.senderID ?: ""),
            "sender_name" to (f.senderName ?: ""),
        ))
    }
    return mapOf(
        "tag" to (inbox.endpointTag?.takeIf { it.isNotEmpty() } ?: tag),
        "files" to files,
        "receiving" to receiving,
    )
}

/// Сериализация одной группы в Map — единый формат для push (writeGroups) и
/// pull (getGroups). Менять формат — только здесь.
internal fun serializeGroup(g: OutboundGroup): Map<String, Any> {
    val items = ArrayList<Map<String, Any>>()
    val gi = g.getItems()
    while (gi.hasNext()) {
        val item = gi.next()
        items.add(mapOf(
            "tag" to item.tag,
            "type" to item.type,
            "urlTestDelay" to item.urlTestDelay,
            "urlTestTime" to item.urlTestTime,
        ))
    }
    return mapOf(
        "tag" to g.getTag(),
        "type" to g.getType(),
        "selectable" to g.getSelectable(),
        "selected" to g.getSelected(),
        "isExpand" to g.getIsExpand(),
        "items" to items,
    )
}

// ═══════════════════════ unary-вызовы обеих ролей ═══════════════════════
// [client] — unary-клиент вызывающей роли (`ensureUnaryClient` её ссылки).

/// §122/SPEC015 — unary pull-снапшот групп. Закрывает дыру pull-vs-push:
/// если стартовый `SubscribeGroups`-push не доехал (гонка waitForStarted —
/// сервис не STARTED в момент подписки) или порвался, перечитать дерево групп
/// больше нечем (push-only). Формат Map ИДЕНТИЧЕН writeGroups (общий
/// `serializeGroup`) → Dart-парсер один. null ≠ пустой список: null = «не
/// смогли прочитать», []=«групп нет» (не трогаем state).
internal fun getGroupsVia(client: CommandClient?): List<Map<String, Any>>? {
    client ?: run {
        Log.w(TAG, "getGroups: no command client (paused/down)")
        return null
    }
    return runCatching {
        val out = ArrayList<Map<String, Any>>()
        val it: OutboundGroupIterator = client.getGroups()
        while (it.hasNext()) out.add(serializeGroup(it.next()))
        out
    }.getOrElse {
        // не-STARTED / транспорт — НЕ ошибка приложения, просто пока нет данных.
        Log.d(TAG, "getGroups unavailable: ${it.message}")
        null
    }
}

/// Удалить принятый файл. `null` = успех, иначе текст ошибки ядра.
internal fun taildropDeleteVia(client: CommandClient?, tag: String, name: String): String? {
    client ?: return "no command client"
    return runCatching { client.deleteTaildropFile(tag, name); null }
        .getOrElse { Log.w(TAG, "deleteTaildropFile failed"); it.message ?: "failed" }
}

/// Прервать приём файла. `null` = успех, иначе текст ошибки ядра.
internal fun taildropCancelReceivingVia(
    client: CommandClient?,
    tag: String,
    senderID: String,
    name: String,
): String? {
    client ?: return "no command client"
    return runCatching { client.cancelTaildropReceiving(tag, senderID, name); null }
        .getOrElse { Log.w(TAG, "cancelTaildropReceiving failed"); it.message ?: "failed" }
}

/// §707 итер. 5 — разовый снимок входящих узла [tag] той же формы, что
/// поток вкладки Network (`taildropInboxMap`): первое обновление
/// `SubscribeTaildropInbox` на своём клиенте. Блокирует до [timeoutMs];
/// `null` — клиента нет или ядро не ответило.
internal fun taildropInboxOnceCall(tag: String, timeoutMs: Long): Map<String, Any>? {
    val client = newCommandCallClient() ?: return null
    val latch = java.util.concurrent.CountDownLatch(1)
    val out = AtomicReference<Map<String, Any>?>(null)
    var sub: TaildropInboxSubscription? = null
    try {
        sub = client.subscribeTaildropInbox(tag, object : TaildropInboxHandler {
            override fun onInboxUpdate(inbox: TaildropInbox?) {
                runCatching {
                    if (inbox == null || latch.count == 0L) return@runCatching
                    out.set(taildropInboxMap(inbox, tag))
                    latch.countDown()
                }
            }

            override fun onError(message: String?) {
                runCatching { latch.countDown() }
            }
        })
        latch.await(timeoutMs, java.util.concurrent.TimeUnit.MILLISECONDS)
    } catch (t: Exception) {
        Log.w(TAG, "taildropInboxOnce failed: ${t.javaClass.simpleName}")
    } finally {
        sub?.runCatching { close() }
        client.runCatching { disconnect() }
    }
    return out.get()
}

// ═══════════════════════ Emitters (по образцу core-log drainer) ═══════════════════════

/// Дросселированный эмиттер: queue + drop-newest + single Runnable + main-Handler + batch.
/// Для status/outbounds/groups/connections эмитим ПОСЛЕДНИЙ снапшот (coalesce —
/// промежуточные не нужны, UI рисует актуальное). sink.success на main-looper.
internal class SnapshotEmitter(
    private val mainHandler: Handler,
    private val sinkProvider: () -> EventChannel.EventSink?,
) {
    private val queue = LinkedBlockingQueue<Any>()
    private val scheduled = AtomicBoolean(false)

    fun offer(snapshot: Any) {
        // coalesce: держим только последний снапшот (drop старые).
        // §219 — после clear() размер всегда 0, проверка QUEUE_MAX была
        // избыточна (в отличие от EventEmitter.offer без предварит. clear).
        queue.clear()
        queue.offer(snapshot)
        if (scheduled.compareAndSet(false, true)) {
            mainHandler.post(drainer)
        }
    }

    private val drainer = Runnable {
        scheduled.set(false)
        val sink = sinkProvider() ?: run { queue.clear(); return@Runnable }
        val latest = queue.poll() ?: return@Runnable
        queue.clear()
        runCatching { sink.success(latest) }
            .onFailure { Log.w(TAG, "emitter sink.success failed: ${it.message}") }
    }
}

/// §180 — событийный эмиттер для DNS: НЕ coalesce (в отличие от SnapshotEmitter,
/// который держит только последний снапшот). DNS-события дискретны — потеря
/// промежуточного резолва = пропавший домен в Live. Копим в очереди, drain
/// отдаёт БАТЧ списком (sink.success(List<Map>)), главный-Handler как у снапшота.
/// drop-newest при переполнении QUEUE_MAX (наблюдатель, не аудит — как буфер
/// observable ядра 256). Контракт sink: Dart-сторона разворачивает список.
internal class EventEmitter(
    private val mainHandler: Handler,
    private val sinkProvider: () -> EventChannel.EventSink?,
) {
    private val queue = LinkedBlockingQueue<Any>()
    private val scheduled = AtomicBoolean(false)

    fun offer(event: Any) {
        if (queue.size < QUEUE_MAX) queue.offer(event)
        if (scheduled.compareAndSet(false, true)) {
            mainHandler.post(drainer)
        }
    }

    private val drainer = Runnable {
        scheduled.set(false)
        val sink = sinkProvider() ?: run { queue.clear(); return@Runnable }
        val batch = ArrayList<Any>()
        queue.drainTo(batch)
        if (batch.isEmpty()) return@Runnable
        runCatching { sink.success(batch) }
            .onFailure { Log.w(TAG, "dns emitter sink.success failed: ${it.message}") }
    }
}
