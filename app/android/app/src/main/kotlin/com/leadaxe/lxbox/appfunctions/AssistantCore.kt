package com.leadaxe.lxbox.appfunctions

import android.content.Context
import android.util.Log
import com.leadaxe.lxbox.vpn.ConfigManager
import com.leadaxe.lxbox.vpn.CoreSession
import com.leadaxe.lxbox.vpn.ServiceCommandClient
import com.leadaxe.lxbox.vpn.TunnelState
import com.leadaxe.lxbox.vpn.VpnStatus
import io.nekohasekai.libbox.CommandClient
import io.nekohasekai.libbox.ConnectionTestAttrIterator
import io.nekohasekai.libbox.ConnectionTestHandler
import io.nekohasekai.libbox.ConnectionTestResult
import io.nekohasekai.libbox.ConnectionTestSession
import io.nekohasekai.libbox.ConnectionTestStage
import io.nekohasekai.libbox.Libbox
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/// §750 — операции ИИ-ассистента над работающим ядром: обзор сети, выходы
/// Направления, проверка адреса (§687), фактический выход (§392), поиск
/// приложения, маршрут приложения по индексу, выбор выхода.
///
/// Общий исполнитель для AppFunctions (`LxBoxAppFunctions`) и методов канала
/// `assistant*` (Debug API). Сервисная сторона границы: не знает Flutter,
/// `VpnPlugin`, клиента UI и `UiSinks` — после §747 уезжает в `:bg`. К ядру —
/// только через `CoreSession.client` (сервисный клиент). Блокирующие вызовы
/// libbox и PackageManager — на `Dispatchers.IO`. Ответ — Map с ключами
/// snake_case; ошибка — [AssistantError]. Все имена в ответах очищены
/// ([AssistantLogic.clean]).
object AssistantCore {

    private const val TAG = "AssistantCore"

    /// Предел ожидания итога проверки адреса.
    const val CHECK_URL_TIMEOUT_MS = 20_000L
    private const val TRACE_URL = "https://1.1.1.1/cdn-cgi/trace"
    private const val TRACE_TIMEOUT_MS = 10_000
    private const val TRACE_MAX_BYTES = 4096
    private const val USER_AGENT = "LxBox"
    private const val TAILSCALE_SNAPSHOT_MS = 2_000L

    /// Глубина `http` (`ConnectionTestDepth` ядра).
    private const val DEPTH_HTTP = 0

    /// Одна проверка адреса за раз.
    private val checkRunning = AtomicBoolean(false)

    // ═══════════════════════ общее ═══════════════════════

    private fun tunnelUp(): Boolean = TunnelState.status == VpnStatus.Started

    /// Индекс приходит аргументом вызова (Dart собирает его по требованию,
    /// §750: никакого хранения). Пустой или битый → `invalid_argument`.
    private fun requireIndex(indexJson: String): ParsedIndex =
        AssistantLogic.parseIndex(indexJson)
            ?: throw AssistantError(AssistantError.INVALID_ARGUMENT, AssistantLogic.MSG_BAD_INDEX)

    /// Сервисный клиент работающего ядра; туннель не поднят → `vpn_off`.
    private fun requireCore(): ServiceCommandClient {
        if (!tunnelUp()) throw AssistantError(AssistantError.VPN_OFF, AssistantLogic.MSG_VPN_OFF)
        return CoreSession.client
            ?: throw AssistantError(AssistantError.CORE_ERROR, AssistantLogic.MSG_CORE_DOWN)
    }

    /// Живые группы ядра: тег → (selected, members, selectable). null —
    /// туннель не поднят или ядро не ответило.
    private data class LiveGroup(val selected: String, val members: List<String>, val selectable: Boolean)

    private fun liveGroups(): Map<String, LiveGroup>? {
        if (!tunnelUp()) return null
        val raw = CoreSession.client?.groups() ?: return null
        val out = LinkedHashMap<String, LiveGroup>()
        for (g in raw) {
            val tag = g["tag"] as? String ?: continue
            @Suppress("UNCHECKED_CAST")
            val items = (g["items"] as? List<Map<String, Any>>).orEmpty()
                .mapNotNull { it["tag"] as? String }
            out[tag] = LiveGroup(
                selected = g["selected"] as? String ?: "",
                members = items,
                selectable = g["selectable"] as? Boolean ?: false,
            )
        }
        return out
    }

    /// Члены группы [tag] из сохранённого `singbox_config.json` (туннель
    /// остановлен). null — группы в конфиге нет.
    private fun configMembers(tag: String): List<String>? = runCatching {
        val arr = JSONObject(ConfigManager.load()).optJSONArray("outbounds") ?: return@runCatching null
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            if (o.optString("tag") != tag) continue
            val type = o.optString("type")
            if (type != "selector" && type != "urltest") return@runCatching null
            val m = o.optJSONArray("outbounds") ?: return@runCatching emptyList<String>()
            return@runCatching (0 until m.length()).mapNotNull { m.optString(it).takeIf { s -> s.isNotEmpty() } }
        }
        null
    }.getOrNull()

    /// Выбранный узел группы с проходом вложенных групп (Направление → auto →
    /// узел); пусто — не выбран.
    private fun leafOf(groups: Map<String, LiveGroup>, tag: String): String {
        var cur = groups[tag]?.selected ?: return ""
        val seen = hashSetOf(tag)
        while (cur.isNotEmpty() && seen.add(cur)) {
            val next = groups[cur]?.selected ?: break
            if (next.isEmpty()) break
            cur = next
        }
        return cur
    }

    /// Направление по аргументу — только тег (§750: поиска по подписи нет):
    /// живая группа, при остановленном туннеле — группа сохранённого
    /// конфига. Возвращает тег или null.
    private fun resolveDirection(live: Map<String, LiveGroup>?, arg: String): String? {
        val a = arg.trim()
        if (a.isEmpty()) return null
        if (live?.containsKey(a) == true) return a
        if (live == null && configMembers(a) != null) return a
        return null
    }

    /// Выходы Направления [tag]: живые группы ядра → сохранённый конфиг.
    private fun exitsOf(live: Map<String, LiveGroup>?, tag: String): List<String> =
        live?.get(tag)?.members
            ?: configMembers(tag)
            ?: emptyList()

    // ═══════════════════════ обзор сети (Debug API /assistant/overview) ═══════════════════════

    suspend fun overview(ctx: Context, indexJson: String): Map<String, Any?> = withContext(Dispatchers.IO) {
        val index = requireIndex(indexJson)
        val up = tunnelUp()
        val live = liveGroups()
        val directions = index.directions.map { d ->
            mapOf(
                "tag" to AssistantLogic.clean(d.tag),
                "name" to AssistantLogic.clean(d.name.ifEmpty { d.tag }),
                "exit_count" to exitsOf(live, d.tag).size,
                "current_exit" to if (live != null) AssistantLogic.clean(leafOf(live, d.tag)) else "",
            )
        }
        mapOf(
            "vpn_status" to AppFunctionsLogic.statusValue(TunnelState.status),
            "default_route" to AssistantLogic.normalizeTarget(index.routeFinal),
            "directions" to directions,
            "connections" to connections(index, up),
        )
    }

    private fun connections(index: ParsedIndex, up: Boolean): List<Map<String, Any?>> {
        val cc = if (up) CoreSession.client else null
        val active = index.connections.filter { it.enabled }
        val types = active.map { it.type }.toSet()
        val wg = if (cc != null && ("wireguard" in types || "amneziawg" in types)) cc.endpointStates() else null
        val ts: Map<String, String>? = if (cc != null && "tailscale" in types) {
            cc.tailscaleSnapshot(TAILSCALE_SNAPSHOT_MS)?.associate {
                (it["tag"] as? String ?: "") to (it["backend_state"] as? String ?: "")
            }
        } else null
        val oc: Map<String, String>? = if (cc != null && "openconnect" in types) {
            @Suppress("UNCHECKED_CAST")
            (cc.openConnectSnapshot()["endpoints"] as? List<Map<String, Any>>)?.associate {
                (it["tag"] as? String ?: "") to (it["state"] as? String ?: "")
            }
        } else null
        return index.connections.map { c ->
            val coreState = when (c.type) {
                "wireguard", "amneziawg" -> wg?.get(c.id)
                "tailscale" -> ts?.get(c.id)
                "openconnect" -> oc?.get(c.id)
                else -> null // openvpn: состояния в ядре для натива нет
            }
            mapOf(
                "id" to AssistantLogic.clean(c.id),
                "name" to AssistantLogic.clean(c.name.ifEmpty { c.id }),
                "type" to c.type,
                "enabled" to c.enabled,
                "state" to AssistantLogic.connectionState(c.type, c.enabled, up && cc != null, coreState),
            )
        }
    }

    // ═══════════════════════ listExits ═══════════════════════

    suspend fun listExits(ctx: Context, direction: String, query: String?): Map<String, Any?> =
        withContext(Dispatchers.IO) {
            val live = liveGroups()
            val tag = resolveDirection(live, direction)
                ?: throw AssistantError(AssistantError.NOT_FOUND, "No such direction.")
            val r = AssistantLogic.filterExits(exitsOf(live, tag), query)
            mapOf(
                "direction" to AssistantLogic.clean(tag),
                "exits" to r.exits,
                "total" to r.total,
                "truncated" to r.truncated,
            )
        }

    // ═══════════════════════ selectExit ═══════════════════════

    suspend fun selectExit(ctx: Context, direction: String, exit: String): Map<String, Any?> =
        withContext(Dispatchers.IO) {
            val cc = requireCore()
            val live = liveGroups()
                ?: throw AssistantError(AssistantError.CORE_ERROR, AssistantLogic.MSG_CORE_DOWN)
            val tag = resolveDirection(live, direction)
                ?.takeIf { live.containsKey(it) }
                ?: throw AssistantError(AssistantError.NOT_FOUND, "No such direction.")
            val group = live.getValue(tag)
            // Имя сверяем и с сырым, и с очищенным видом: агент видел очищенный.
            val member = group.members.firstOrNull { it == exit }
                ?: group.members.firstOrNull { AssistantLogic.clean(it) == exit }
                ?: throw AssistantError(AssistantError.NOT_FOUND, "No such exit in this direction.")
            if (!group.selectable) {
                throw AssistantError(AssistantError.INVALID_ARGUMENT, "This direction picks its exit automatically.")
            }
            val changed = group.selected != member
            if (changed) {
                cc.selectOutbound(tag, member)?.let {
                    throw AssistantError(AssistantError.CORE_ERROR, AssistantLogic.cleanError(it))
                }
            }
            mapOf(
                "direction" to AssistantLogic.clean(tag),
                "exit" to AssistantLogic.clean(member),
                "changed" to changed,
            )
        }

    // ═══════════════════════ checkExit ═══════════════════════

    suspend fun checkExit(ctx: Context, direction: String): Map<String, Any?> =
        withContext(Dispatchers.IO) {
            if (!tunnelUp()) {
                return@withContext exitCheck(AssistantLogic.OUTCOME_VPN_OFF, error = AssistantLogic.MSG_VPN_OFF)
            }
            val cc = requireCore()
            val live = liveGroups()
            val tag = resolveDirection(live, direction)
                ?.takeIf { live == null || live.containsKey(it) }
                ?: throw AssistantError(AssistantError.NOT_FOUND, "No such direction.")
            val exit = live?.let { AssistantLogic.clean(leafOf(it, tag)) } ?: ""
            val r = cc.getUrlViaOutbound(tag, TRACE_URL, TRACE_TIMEOUT_MS, TRACE_MAX_BYTES, USER_AGENT)
            val err = r["error"] as? String ?: ""
            if (AssistantLogic.isCoreTransportError(err)) {
                throw AssistantError(AssistantError.CORE_ERROR, AssistantLogic.MSG_CORE_DOWN)
            }
            if (err.isNotEmpty()) {
                return@withContext exitCheck(AssistantLogic.OUTCOME_FAILED, exit = exit, error = AssistantLogic.cleanError(err))
            }
            val (ip, country) = AssistantLogic.parseTrace(r["content"] as? String)
            if (ip.isEmpty() && country.isEmpty()) {
                val status = (r["status"] as? Number)?.toInt() ?: 0
                return@withContext exitCheck(
                    AssistantLogic.OUTCOME_FAILED, exit = exit,
                    error = "Unexpected answer from the check service (HTTP $status).",
                )
            }
            exitCheck(AssistantLogic.OUTCOME_OK, country = country, ip = ip, exit = exit)
        }

    private fun exitCheck(
        outcome: String,
        country: String = "",
        ip: String = "",
        exit: String = "",
        error: String = "",
    ): Map<String, Any?> = mapOf(
        "outcome" to outcome, "country" to country, "ip" to ip, "exit" to exit, "error" to error,
    )

    // ═══════════════════════ findApps / appRoute ═══════════════════════

    suspend fun findApps(ctx: Context, query: String): List<Map<String, Any?>> {
        val q = query.trim()
        if (q.length < AssistantLogic.APP_QUERY_MIN) {
            throw AssistantError(AssistantError.INVALID_ARGUMENT, "The search text must have at least 2 characters.")
        }
        return withContext(Dispatchers.IO) {
            val pm = ctx.packageManager
            val apps = pm.getInstalledApplications(0).map { info ->
                info.packageName to (runCatching { pm.getApplicationLabel(info).toString() }.getOrNull() ?: info.packageName)
            }
            AssistantLogic.rankApps(apps, q).map { (pkg, label) -> mapOf("package" to pkg, "label" to label) }
        }
    }

    suspend fun appRoute(ctx: Context, indexJson: String, appPackage: String): Map<String, Any?> = withContext(Dispatchers.IO) {
        val pkg = appPackage.trim()
        if (pkg.isEmpty()) throw AssistantError(AssistantError.INVALID_ARGUMENT, "The app package is empty.")
        val index = requireIndex(indexJson)
        val r = AssistantLogic.appRoute(index, pkg)
        mapOf(
            "app" to AssistantLogic.clean(pkg, 200),
            "target" to AssistantLogic.clean(r.target),
            "target_name" to r.targetName,
            "rule_name" to r.ruleName,
            "conditional" to r.conditional,
        )
    }

    // ═══════════════════════ checkUrl (§687) ═══════════════════════

    suspend fun checkUrl(ctx: Context, url: String, appPackage: String?): Map<String, Any?> {
        val link = AssistantLogic.normalizeUrl(url)
            ?: throw AssistantError(AssistantError.INVALID_ARGUMENT, "The address must be an http or https URL.")
        if (!tunnelUp()) return urlReport(AssistantLogic.OUTCOME_VPN_OFF)
        val cc = requireCore()
        if (!checkRunning.compareAndSet(false, true)) return urlReport(AssistantLogic.OUTCOME_BUSY)
        try {
            // §750 — runInterruptible: отмена корутины прерывает ожидание
            // итога (latch), клиент и сессия освобождаются сразу, а не через
            // 20 с; до правки флаг «идёт проверка» держался всё это время.
            return runInterruptible(Dispatchers.IO) { runUrlCheck(cc, link, appPackage?.trim().orEmpty()) }
        } finally {
            checkRunning.set(false)
        }
    }

    /// Один прогон: свой `CommandClient`, стадии собираются по id (стадия с
    /// тем же id приходит повторно при завершении), итог — первый `onResult`
    /// или `onError`; ждём не дольше [CHECK_URL_TIMEOUT_MS].
    private fun runUrlCheck(cc: ServiceCommandClient, link: String, pkg: String): Map<String, Any?> {
        val client: CommandClient = cc.newCallClient()
            ?: throw AssistantError(AssistantError.CORE_ERROR, AssistantLogic.MSG_CORE_DOWN)
        val collector = UrlCheckCollector()
        var session: ConnectionTestSession? = null
        try {
            val request = Libbox.newConnectionTestRequest().apply {
                setLink(link)
                if (pkg.isNotEmpty()) setPackageName(pkg)
                setAppDNS(true)
                setDepth(DEPTH_HTTP)
                setFresh(true)
            }
            session = client.startConnectionTest(request, collector)
            val finished = collector.done.await(CHECK_URL_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            return collector.report(finished)
        } catch (e: AssistantError) {
            throw e
        } catch (e: InterruptedException) {
            // Отмена корутины (runInterruptible) — не ошибка ядра.
            throw e
        } catch (t: Exception) {
            Log.w(TAG, "checkUrl failed: ${t.javaClass.simpleName}")
            if (AssistantLogic.isCoreTransportError(t.message)) {
                throw AssistantError(AssistantError.CORE_ERROR, AssistantLogic.MSG_CORE_DOWN)
            }
            throw AssistantError(AssistantError.CORE_ERROR, AssistantLogic.cleanError(t.message ?: "Connection test failed."))
        } finally {
            session?.runCatching { cancel() }
            client.runCatching { disconnect() }
        }
    }

    private fun urlReport(
        outcome: String,
        failedStage: String = "",
        error: String = "",
        httpStatus: Int = 0,
        elapsedMs: Int = 0,
        route: RouteSummary = RouteSummary("", "", direct = false, blocked = false),
        findings: List<String> = emptyList(),
    ): Map<String, Any?> = mapOf(
        "outcome" to outcome,
        "failed_stage" to failedStage,
        "error" to error,
        "http_status" to httpStatus,
        "elapsed_ms" to elapsedMs,
        "route" to mapOf(
            "direction" to route.direction,
            "exit" to route.exit,
            "direct" to route.direct,
            "blocked" to route.blocked,
        ),
        "findings" to findings,
        "advice" to AssistantLogic.advice(outcome, failedStage, findings, httpStatus, route.direct, route.blocked),
    )

    /// Обработчик событий одной проверки. Колбэки из Go-потока: исключения
    /// наружу не выходят (JNI abort).
    private class Outcome(
        val error: String,
        val rootCause: Int,
        val httpStatus: Int,
        val elapsedMs: Int,
        val findings: List<String>,
    )

    private class UrlCheckCollector : ConnectionTestHandler {
        val done = CountDownLatch(1)
        private val stages = ConcurrentHashMap<Int, TraceStage>()
        private val order = java.util.concurrent.ConcurrentLinkedQueue<Int>()
        private val outcome = AtomicReference<Outcome?>(null)
        private val streamError = AtomicReference<String?>(null)

        override fun onStage(stage: ConnectionTestStage?) {
            runCatching {
                if (stage == null) return@runCatching
                val s = TraceStage(
                    id = stage.id(),
                    parent = stage.parent(),
                    kind = stage.kind() ?: "",
                    subject = stage.subject() ?: "",
                    result = stage.result(),
                    error = stage.errorMessage() ?: "",
                    attrs = attrs(stage.attrs()),
                )
                if (stages.put(s.id, s) == null) order.add(s.id)
            }
        }

        override fun onResult(result: ConnectionTestResult?) {
            runCatching {
                if (result == null) return@runCatching
                val codes = ArrayList<String>()
                val it = result.findings()
                while (it != null && it.hasNext()) {
                    val code = it.next()?.code() ?: continue
                    if (code.isNotEmpty() && code !in codes) codes.add(AssistantLogic.clean(code))
                }
                outcome.compareAndSet(null, Outcome(
                    error = result.errorMessage() ?: "",
                    rootCause = result.rootCause(),
                    httpStatus = result.httpStatus(),
                    elapsedMs = result.elapsedMs(),
                    findings = codes,
                ))
            }
            done.countDown()
        }

        override fun onError(message: String?) {
            runCatching { streamError.compareAndSet(null, message ?: "failed") }
            done.countDown()
        }

        private fun attrs(iter: ConnectionTestAttrIterator?): List<Pair<String, String>> {
            val out = ArrayList<Pair<String, String>>()
            while (iter != null && iter.hasNext()) {
                val a = iter.next() ?: continue
                out.add((a.key() ?: "") to (a.value() ?: ""))
            }
            return out
        }

        fun report(finished: Boolean): Map<String, Any?> {
            val list = order.mapNotNull { stages[it] }
            val route = AssistantLogic.routeFromStages(list)
            val o = outcome.get()
            if (o == null) {
                val err = streamError.get()
                if (finished && AssistantLogic.isCoreTransportError(err)) {
                    throw AssistantError(AssistantError.CORE_ERROR, AssistantLogic.MSG_CORE_DOWN)
                }
                return if (!finished || err == null) urlReport(AssistantLogic.OUTCOME_TIMEOUT, route = route)
                else urlReport(AssistantLogic.OUTCOME_FAILED, error = AssistantLogic.cleanError(err), route = route)
            }
            if (o.error == "busy") return urlReport(AssistantLogic.OUTCOME_BUSY)
            if (o.error.isNotEmpty()) {
                return urlReport(
                    AssistantLogic.OUTCOME_FAILED, error = AssistantLogic.cleanError(o.error),
                    elapsedMs = o.elapsedMs, route = route, findings = o.findings,
                )
            }
            if (o.rootCause != 0) {
                val root = stages[o.rootCause]
                return urlReport(
                    AssistantLogic.OUTCOME_FAILED,
                    failedStage = root?.let { AssistantLogic.stageClass(it.kind) } ?: AssistantLogic.STAGE_CONNECT,
                    error = AssistantLogic.cleanError(root?.error),
                    httpStatus = o.httpStatus,
                    elapsedMs = o.elapsedMs,
                    route = route,
                    findings = o.findings,
                )
            }
            return urlReport(
                AssistantLogic.OUTCOME_OK,
                httpStatus = o.httpStatus,
                elapsedMs = o.elapsedMs,
                route = route,
                findings = o.findings,
            )
        }

        private fun urlReport(
            outcome: String,
            failedStage: String = "",
            error: String = "",
            httpStatus: Int = 0,
            elapsedMs: Int = 0,
            route: RouteSummary = RouteSummary("", "", direct = false, blocked = false),
            findings: List<String> = emptyList(),
        ) = AssistantCore.urlReport(outcome, failedStage, error, httpStatus, elapsedMs, route, findings)
    }
}
