package com.leadaxe.lxbox.vpn

import android.os.Handler
import android.os.Looper
import android.util.Log
import io.nekohasekai.libbox.CommandClient
import io.nekohasekai.libbox.CommandClientOptions
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.OpenConnectEndpointStatus
import io.nekohasekai.libbox.OpenConnectStatusHandler
import io.nekohasekai.libbox.OpenConnectStatusSubscription
import io.nekohasekai.libbox.OpenConnectStatusUpdate
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.TailscaleStatusHandler
import io.nekohasekai.libbox.TailscaleStatusSubscription
import io.nekohasekai.libbox.TailscaleStatusUpdate
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/// §745 — то, что `VpnPlugin` вправе делать с сервисным клиентом: openconnect
/// целиком живёт у сервиса (слушатель SSO должен работать, пока пользователь в
/// браузере, а UI в фоне), а UI читает снимок, отвечает на челлендж и
/// поднимает слушатель на том же состоянии. Это перечисленный остаток общей
/// памяти между сторонами (docs/ARCHITECTURE.md, «Process boundary»); при
/// разделении на процессы эти пять вызовов станут командами сервису.
interface OpenConnectControl {
    fun openConnectSnapshot(): Map<String, Any>
    fun submitOpenConnectForm(tag: String, challengeId: String, values: List<Pair<String, String>>): String?
    fun cancelOpenConnectChallenge(tag: String, challengeId: String): String?
    fun startOpenConnectCallback(tag: String, challengeId: String, port: Int, prefixes: List<String>): String?
    fun stopOpenConnectCallback(keepState: Boolean = false)
}

/// §745 — клиент `command.sock` сервисной роли: то, что нужно сервису без
/// Flutter-движка (раньше — часть `BoxCommandClient`, код перенесён без
/// изменений).
///
///  - **openconnect** — подписка на статус endpoint'ов, уведомление «Sign-in
///    required», слушатель SSO, ответы на челлендж, снимок для UI;
///  - **подпись узла** в шторке при старте без движка ([selectedNodeLabel]);
///  - **Taildrop** из уведомлений и активити: клиент под одну передачу
///    ([newCallClient]), удаление, отмена приёма, разовые снимки входящих и
///    узлов Tailscale.
///
/// Создаёт и закрывает `BoxService` (после `startCommandServer()` и Started /
/// в `closeCommandServerAtomic`), держит `CoreSession.client`. Статус-стрима,
/// экрана и профайлера здесь нет — это роль UI ([BoxCommandClient], держатель
/// `UiCoreSession`).
///
/// **JNI-no-throw**: каждый колбэк ядра обёрнут в try/catch — исключение через
/// JNI роняет процесс.
///
/// Единственный приёмник Flutter, в который пишет сервисный клиент, —
/// `UiSinks.ccOpenConnectSink` (остаток общей памяти, см. [OpenConnectControl]).
class ServiceCommandClient(private val host: Host) : OpenConnectControl {

    /// §742 — то, что клиенту нужно от стороны, которая его создала.
    interface Host {
        /// Уведомление «Sign-in required» для openconnect-endpoint'а [tag].
        fun showSignIn(tag: String)
        /// Снять уведомление «Sign-in required» для [tag].
        fun cancelSignIn(tag: String)
    }

    private companion object {
        private const val TAG = CC_LOG_TAG
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    /// §209 — unary-клиент сервисной роли: свой, не общий с клиентом UI
    /// (`cancelPing` и `resyncForReopen` у UI рвут только клиент UI).
    /// Поднимается лениво, закрывается в [shutdownAll].
    private val unaryClient = AtomicReference<CommandClient?>(null)

    private fun ensurePingClient(): CommandClient? = ensureUnaryClient(unaryClient)

    /// Полный teardown — из `BoxService.closeCommandServerAtomic`, после
    /// слушателей `CoreSession` «перед закрытием» (клиент UI уже закрыт) и до
    /// закрытия сервера. Синхронно, в потоке вызывающего.
    fun shutdownAll() {
        disconnectClient(unaryClient, "shutdownAll")
        stopOpenConnectStatus() // §654
    }

    // ═══════════════════════ §707 Taildrop ═══════════════════════

    /// Новый подключённый клиент без подписок — под поток одной передачи.
    /// Блокирующий connect — звать не с main.
    fun newCallClient(): CommandClient? = newCommandCallClient()

    /// Удалить принятый файл. `null` = успех, иначе текст ошибки ядра.
    fun taildropDelete(tag: String, name: String): String? =
        taildropDeleteVia(ensurePingClient(), tag, name)

    /// Прервать приём файла. `null` = успех, иначе текст ошибки ядра.
    fun taildropCancelReceiving(tag: String, senderID: String, name: String): String? =
        taildropCancelReceivingVia(ensurePingClient(), tag, senderID, name)

    /// §707 итер. 5 — разовый снимок входящих узла [tag] (форма потока вкладки
    /// Network). Блокирует до [timeoutMs]; `null` — клиента нет или ядро не
    /// ответило.
    fun taildropInboxOnce(tag: String, timeoutMs: Long): Map<String, Any>? =
        taildropInboxOnceCall(tag, timeoutMs)

    /// §707 итер. 4 — разовый снимок входящих узла [tag]: имя файла →
    /// (senderID, senderName). Нужен разбору служебных файлов: уведомление
    /// ядра отправителя не несёт. Блокирует до [timeoutMs]; `null` — клиента
    /// нет или ядро не ответило. Имена в журнал не пишутся.
    fun taildropInboxSnapshot(tag: String, timeoutMs: Long): Map<String, Pair<String, String>>? {
        val inbox = taildropInboxOnce(tag, timeoutMs) ?: return null
        val m = HashMap<String, Pair<String, String>>()
        @Suppress("UNCHECKED_CAST")
        for (f in inbox["files"] as List<Map<String, Any>>) {
            val name = f["name"] as? String ?: continue
            m[name] = (f["sender_id"] as? String ?: "") to (f["sender_name"] as? String ?: "")
        }
        return m
    }

    /// Разовый снимок узлов Tailscale работающего конфига (первое обновление
    /// подписки `SubscribeTailscaleStatus` на своём клиенте) — экрану
    /// «Поделиться», у которого нет Flutter. Блокирует до [timeoutMs];
    /// `null` — клиента нет или ядро не ответило.
    fun tailscaleSnapshot(timeoutMs: Long): List<Map<String, Any>>? {
        val client = newCallClient() ?: return null
        val latch = java.util.concurrent.CountDownLatch(1)
        val out = AtomicReference<List<Map<String, Any>>?>(null)
        var sub: TailscaleStatusSubscription? = null
        try {
            sub = client.subscribeTailscaleStatus(object : TailscaleStatusHandler {
                override fun onStatusUpdate(update: TailscaleStatusUpdate?) {
                    runCatching {
                        if (update == null || latch.count == 0L) return@runCatching
                        val list = ArrayList<Map<String, Any>>()
                        val iter = update.endpoints()
                        while (iter != null && iter.hasNext()) {
                            val e = iter.next() ?: continue
                            list.add(tailscaleEndpointMap(e))
                        }
                        out.set(list)
                        latch.countDown()
                    }
                }

                override fun onError(message: String?) {
                    runCatching { latch.countDown() }
                }
            })
            latch.await(timeoutMs, java.util.concurrent.TimeUnit.MILLISECONDS)
        } catch (t: Exception) {
            Log.w(TAG, "tailscaleSnapshot failed: ${t.javaClass.simpleName}")
        } finally {
            sub?.runCatching { close() }
            client.runCatching { disconnect() }
        }
        return out.get()
    }

    // ═══════════════════════ §750 ассистент ═══════════════════════
    // Чтения и действия ассистента над работающим ядром без Flutter (функции
    // AppFunctions и методы канала `assistant*`). Тот же unary-клиент сервисной
    // роли; блокирующие вызовы — звать вне main.

    /// Дерево групп (форма `serializeGroup`). null — не прочитали.
    fun groups(): List<Map<String, Any>>? = getGroupsVia(ensurePingClient())

    /// Тег → `endpointState` (ядро SPEC 097: заполнено только у WG/AWG).
    /// Тот же RPC `GetOutbounds`, что у клиента UI (§535). null — не прочитали.
    fun endpointStates(): Map<String, String>? {
        val client = ensurePingClient() ?: return null
        return runCatching {
            val out = HashMap<String, String>()
            val it = client.getOutbounds()
            while (it.hasNext()) {
                val item = it.next() ?: continue
                val tag = item.tag ?: continue
                out[tag] = item.endpointState ?: ""
            }
            out
        }.getOrElse {
            Log.d(TAG, "endpointStates unavailable: ${it.message}")
            null
        }
    }

    /// Выбор узла [tag] в селекторе [group]. `null` — успех, иначе текст ошибки.
    fun selectOutbound(group: String, tag: String): String? {
        val client = ensurePingClient() ?: return "no command client"
        return runCatching { client.selectOutbound(group, tag); null }
            .getOrElse { Log.w(TAG, "selectOutbound failed: ${it.message}"); it.message ?: "failed" }
    }

    /// §392 — GET через узел/группу [tag] (ядро SPEC 058), тело ответа.
    /// Неудача ядра приходит исключением (обёртка libbox), её текст — в
    /// `error`; не-2xx — результат со статусом. ГРАБЛЯ: у `GetURLResult`
    /// геттеры без `get`-префикса.
    fun getUrlViaOutbound(tag: String, link: String, timeoutMs: Int, maxBytes: Int, userAgent: String): Map<String, Any> {
        val client = ensurePingClient() ?: return mapOf("error" to "command client not connected")
        return runCatching {
            val r = client.getURLViaOutbound(tag, link, timeoutMs, maxBytes, userAgentHeaders(userAgent))
            mapOf(
                "status" to r.status(),
                "content" to (r.content() ?: ""),
                "error" to "",
            )
        }.getOrElse { mapOf("error" to (it.message ?: "getURLViaOutbound failed")) }
    }

    // ═══════════════════════ §654 OpenConnect status ═══════════════════════
    // Подписка `SubscribeOpenConnectStatus` на ОТДЕЛЬНОМ клиенте (как Tailscale).
    // Держит её натив, не Dart: челлендж второго фактора приходит сразу после
    // старта, а старт бывает с QS-плитки или при загрузке, когда Flutter-движка
    // нет. Живёт, пока VPN запущен и в конфиге есть endpoint `openconnect`
    // ([syncOpenConnectStatus] после старта и после reload); снимается в
    // [shutdownAll]. Уведомление «Sign-in required» ставит тоже натив.

    private val openConnectClient = AtomicReference<CommandClient?>(null)
    private val openConnectSub = AtomicReference<OpenConnectStatusSubscription?>(null)
    private val openConnectGen = AtomicInteger(0)
    private val openConnectEmitter = SnapshotEmitter(mainHandler) { UiSinks.ccOpenConnectSink }
    /// Последний снапшот endpoint'ов: Dart забирает его при подключении
    /// (висящий челлендж при открытии приложения).
    @Volatile private var openConnectEndpoints: List<Map<String, Any>> = emptyList()
    /// Состояние слушателя SSO: `{tag, challenge_id, state, error}`; пусто — нет.
    @Volatile private var openConnectCallbackState: Map<String, Any>? = null
    private val openConnectCallback = AtomicReference<OpenConnectCallbackServer?>(null)
    /// tag → id челленджа, о котором уже стоит уведомление.
    private val openConnectNotified = java.util.concurrent.ConcurrentHashMap<String, String>()

    /// Поднять подписку, если в конфиге есть endpoint `openconnect`, иначе
    /// снять. Блокирующий gRPC — звать вне main.
    fun syncOpenConnectStatus(configJson: String) {
        if (hasOpenConnectEndpoint(configJson)) startOpenConnectStatus() else stopOpenConnectStatus()
    }

    private fun hasOpenConnectEndpoint(configJson: String): Boolean = runCatching {
        val arr = org.json.JSONObject(configJson).optJSONArray("endpoints") ?: return@runCatching false
        (0 until arr.length()).any { arr.optJSONObject(it)?.optString("type") == "openconnect" }
    }.getOrDefault(false)

    fun startOpenConnectStatus() {
        stopOpenConnectStatus()
        val gen = openConnectGen.incrementAndGet()
        runCatching {
            val client = CommandClient(CcPingHandler(), CommandClientOptions())
            client.connect()
            openConnectClient.getAndSet(client)?.runCatching { disconnect() }
            val sub = client.subscribeOpenConnectStatus(OpenConnectHandler(gen))
            openConnectSub.getAndSet(sub)?.runCatching { close() }
            Log.i(TAG, "openconnect status subscribed (gen=$gen)")
        }.onFailure { Log.w(TAG, "startOpenConnectStatus failed (gen=$gen): ${it.message}") }
    }

    fun stopOpenConnectStatus() {
        openConnectGen.incrementAndGet()
        val hadSub = openConnectSub.getAndSet(null)?.let { sub ->
            sub.runCatching { close() }
                .onFailure { Log.w(TAG, "openconnect sub close failed: ${it.message}") }
            true
        } ?: false
        disconnectClient(openConnectClient, "stopOpenConnectStatus")
        stopOpenConnectCallback()
        for (tag in openConnectNotified.keys.toList()) {
            host.cancelSignIn(tag)
        }
        openConnectNotified.clear()
        if (hadSub || openConnectEndpoints.isNotEmpty()) {
            openConnectEndpoints = emptyList()
            emitOpenConnect()
        }
    }

    /// Текущий снапшот для Dart (`ccGetOpenConnectStatus`).
    override fun openConnectSnapshot(): Map<String, Any> {
        val m = HashMap<String, Any>()
        m["endpoints"] = openConnectEndpoints
        openConnectCallbackState?.let { m["callback"] = it }
        return m
    }

    private fun emitOpenConnect() = openConnectEmitter.offer(openConnectSnapshot())

    /// Колбэки приходят из Go-потока: ни одного исключения наружу (JNI abort).
    private inner class OpenConnectHandler(private val gen: Int) : OpenConnectStatusHandler {
        override fun onStatusUpdate(update: OpenConnectStatusUpdate?) {
            runCatching {
                if (gen != openConnectGen.get() || update == null) return@runCatching
                val out = ArrayList<Map<String, Any>>()
                val iter = update.endpoints() ?: return@runCatching
                while (iter.hasNext()) {
                    val e = iter.next() ?: continue
                    out.add(openConnectEndpointMap(e))
                }
                openConnectEndpoints = out
                syncOpenConnectSideEffects(out)
                emitOpenConnect()
            }.onFailure { Log.w(TAG, "openconnect onStatusUpdate failed: ${it.javaClass.simpleName}") }
        }

        override fun onError(message: String?) {
            runCatching { Log.w(TAG, "openconnect status stream error (gen=$gen): $message") }
        }
    }

    /// id висящего челленджа endpoint'а; пусто — нет.
    @Suppress("UNCHECKED_CAST")
    private fun pendingChallengeId(e: Map<String, Any>): String =
        ((e["challenge"] as? Map<String, Any>)?.get("id") as? String) ?: ""

    /// Уведомление «Sign-in required» на новый челлендж, снятие — когда его
    /// нет; слушатель SSO гаснет, когда его челлендж исчез или сменился.
    private fun syncOpenConnectSideEffects(endpoints: List<Map<String, Any>>) {
        val pending = HashMap<String, String>()
        for (e in endpoints) {
            val tag = e["tag"] as? String ?: continue
            val id = pendingChallengeId(e)
            if (tag.isNotEmpty() && id.isNotEmpty()) pending[tag] = id
        }
        for ((tag, id) in pending) {
            if (openConnectNotified[tag] != id) {
                openConnectNotified[tag] = id
                host.showSignIn(tag)
            }
        }
        for (tag in openConnectNotified.keys.toList()) {
            if (!pending.containsKey(tag)) {
                openConnectNotified.remove(tag)
                host.cancelSignIn(tag)
            }
        }
        openConnectCallback.get()?.let { cb ->
            if (pending[cb.tag] != cb.challengeId) stopOpenConnectCallback()
        }
    }

    private fun stringList(iter: StringIterator?): ArrayList<String> {
        val out = ArrayList<String>()
        while (iter != null && iter.hasNext()) iter.next()?.let { out.add(it) }
        return out
    }

    /// Запись `OpenConnectEndpointStatus` в map канала. Значения полей формы,
    /// ссылки и тексты шлюза в лог не пишутся.
    private fun openConnectEndpointMap(e: OpenConnectEndpointStatus): HashMap<String, Any> {
        val m = HashMap<String, Any>()
        m["tag"] = e.endpointTag ?: ""
        m["state"] = e.state ?: ""
        m["state_text"] = e.stateText ?: ""
        m["error"] = e.error ?: ""
        e.authChallenge?.let { ch ->
            val c = HashMap<String, Any>()
            c["id"] = ch.id ?: ""
            c["banner"] = ch.banner ?: ""
            c["message"] = ch.message ?: ""
            c["error"] = ch.error ?: ""
            ch.form?.let { form ->
                val fields = ArrayList<Map<String, Any>>()
                val fi = form.fields()
                while (fi != null && fi.hasNext()) {
                    val f = fi.next() ?: continue
                    val options = ArrayList<Map<String, Any>>()
                    val oi = f.options()
                    while (oi != null && oi.hasNext()) {
                        val o = oi.next() ?: continue
                        options.add(mapOf("value" to (o.value ?: ""), "label" to (o.label ?: "")))
                    }
                    fields.add(mapOf(
                        "submission_key" to (f.submissionKey ?: ""),
                        "name" to (f.name ?: ""),
                        "label" to (f.label ?: ""),
                        "kind" to (f.kind ?: ""),
                        "value" to (f.value ?: ""),
                        "options" to options,
                    ))
                }
                c["form"] = fields
            }
            ch.browser?.let { b ->
                c["browser"] = mapOf(
                    "url" to (b.url ?: ""),
                    "final_url" to (b.finalURL ?: ""),
                    "callback_url_prefixes" to stringList(b.callbackURLPrefixes()),
                    "cookie_names" to stringList(b.cookieNames()),
                    "header_names" to stringList(b.headerNames()),
                )
            }
            m["challenge"] = c
        }
        e.tunnelInfo?.let { t ->
            m["tunnel"] = mapOf(
                "server" to (t.server ?: ""),
                "flavor" to (t.flavor ?: ""),
                "transport" to (t.transport ?: ""),
                "mtu" to t.mtu,
                "connected_since" to t.connectedSince,
            )
        }
        return m
    }

    /// Ответ формой: пары ключ → значение в порядке полей. `null` = успех,
    /// иначе текст ошибки ядра. Блокирующий gRPC — звать с `Dispatchers.IO`.
    override fun submitOpenConnectForm(tag: String, challengeId: String, values: List<Pair<String, String>>): String? {
        val client = ensurePingClient() ?: return "no command client"
        return runCatching {
            val fv = Libbox.newOpenConnectFormValues()
            for ((k, v) in values) fv.add(k, v)
            client.submitOpenConnectAuthResponse(tag, challengeId, Libbox.newOpenConnectAuthFormResponse(fv))
            null
        }.getOrElse { Log.w(TAG, "submitOpenConnectForm failed"); it.message ?: "failed" }
    }

    /// Ответ браузерного челленджа: URL редиректа. `null` = успех.
    fun submitOpenConnectBrowser(tag: String, challengeId: String, finalUrl: String): String? {
        val client = ensurePingClient() ?: return "no command client"
        return runCatching {
            val r = Libbox.newOpenConnectBrowserResult(finalUrl)
            client.submitOpenConnectAuthResponse(tag, challengeId, Libbox.newOpenConnectBrowserAuthResponse(r))
            null
        }.getOrElse { Log.w(TAG, "submitOpenConnectBrowser failed"); it.message ?: "failed" }
    }

    /// Отмена челленджа: ядро начинает новый логин (у FortiGate — новый код).
    override fun cancelOpenConnectChallenge(tag: String, challengeId: String): String? {
        val client = ensurePingClient() ?: return "no command client"
        return runCatching { client.cancelOpenConnectAuthChallenge(tag, challengeId); null }
            .getOrElse { Log.w(TAG, "cancelOpenConnectChallenge failed"); it.message ?: "failed" }
    }

    /// Слушатель SSO на `127.0.0.1:port` на время челленджа. Пойманный URL
    /// уходит ядру отсюда же (Dart может быть в фоне). `null` — слушает,
    /// иначе текст ошибки (порт занят).
    override fun startOpenConnectCallback(tag: String, challengeId: String, port: Int, prefixes: List<String>): String? {
        openConnectCallback.get()?.let { cur ->
            if (cur.tag == tag && cur.challengeId == challengeId) return null
        }
        stopOpenConnectCallback()
        val server = OpenConnectCallbackServer(tag, challengeId, port, prefixes) { url ->
            setCallbackState(tag, challengeId, "submitting", "")
            val err = submitOpenConnectBrowser(tag, challengeId, url)
            if (err == null) {
                setCallbackState(tag, challengeId, "submitted", "")
                stopOpenConnectCallback(keepState = true)
            } else {
                setCallbackState(tag, challengeId, "failed", err)
            }
        }
        val err = server.start()
        if (err != null) return err
        openConnectCallback.set(server)
        setCallbackState(tag, challengeId, "listening", "")
        return null
    }

    override fun stopOpenConnectCallback(keepState: Boolean) {
        openConnectCallback.getAndSet(null)?.close()
        if (!keepState && openConnectCallbackState != null) {
            openConnectCallbackState = null
            emitOpenConnect()
        }
    }

    private fun setCallbackState(tag: String, challengeId: String, state: String, error: String) {
        openConnectCallbackState = mapOf(
            "tag" to tag, "challenge_id" to challengeId, "state" to state, "error" to error,
        )
        emitOpenConnect()
    }

    /// §223 Часть B (#23) — native-fallback подтекста уведомления, когда UI не
    /// открывался (старт с QS-плитки → нет Flutter-движка → Dart лейбл не
    /// прислал). Один unary-pull `getGroups()` (через ensurePingClient —
    /// lifecycle-независим, БЕЗ подписки): читаем «главную» группу и её
    /// выбранную ноду, возвращаем готовую строку «<группа>: <нода>».
    ///
    /// Повторяет логику выбора selectedGroup из home_controller.dart:807
    /// (Dart-источник): исключить GLOBAL → взять route.final если он валидный
    /// selector, иначе первую группу. `null` = групп нет / RPC не удался
    /// (caller оставит статусный fallback "Connected"). Ловит ТОЛЬКО начальную
    /// ноду — последующее URLTest-переключение без UI вне скоупа (нет фонового
    /// подписчика по энергомодели).
    fun selectedNodeLabel(configRaw: String): String? {
        val groups = getGroupsVia(ensurePingClient()) ?: return null
        val selectors = groups.filter { (it["tag"] as? String) != "GLOBAL" }
        if (selectors.isEmpty()) return null

        val finalTag = routeFinalTag(configRaw)
        val group = selectors.firstOrNull { (it["tag"] as? String) == finalTag }
            ?: selectors.first()

        val groupTag = group["tag"] as? String ?: return null
        val node = (group["selected"] as? String).orEmpty()
        return if (node.isNotEmpty()) "$groupTag: $node" else groupTag
    }

    /// Разбор route.final из сырого конфига — эквивалент Dart
    /// RouteConfig.finalTag (config/route_config.dart). org.json надёжнее regex.
    private fun routeFinalTag(configRaw: String): String? = runCatching {
        org.json.JSONObject(configRaw)
            .optJSONObject("route")
            ?.optString("final")
            ?.takeIf { it.isNotEmpty() }
    }.getOrNull()
}
