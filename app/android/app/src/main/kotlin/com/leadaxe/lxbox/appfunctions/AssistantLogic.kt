package com.leadaxe.lxbox.appfunctions

import org.json.JSONArray
import org.json.JSONObject

/// §750 — ошибка операции ассистента. [code]: `vpn_off`, `no_index`,
/// `not_found`, `busy`, `invalid_argument`, `core_error`. Текст — английский,
/// из таблиц приложения (кроме `core_error`, где он очищен через
/// [AssistantLogic.cleanError]).
class AssistantError(val code: String, message: String) : Exception(message) {
    companion object {
        const val VPN_OFF = "vpn_off"
        const val NOT_FOUND = "not_found"
        const val BUSY = "busy"
        const val INVALID_ARGUMENT = "invalid_argument"
        const val CORE_ERROR = "core_error"
        /// §750 — Dart-часть не поднялась за отведённое время ([AssistantBridge]).
        const val APP_NOT_OPEN = "app_not_open"
    }
}

/// §750 — индекс для натива: Dart собирает по требованию и передаёт
/// аргументом `index` вызовов `assistantOverview` / `assistantAppRoute`.
data class IndexDirection(
    val tag: String,
    val name: String,
    val enabled: Boolean,
    /// Запасной список выходов (спека 750, «Индекс для натива»); Dart может не
    /// присылать — тогда берётся из сохранённого конфига.
    val exits: List<String>,
)

data class IndexConnection(
    /// Тег узла в конфиге ядра.
    val id: String,
    val name: String,
    /// `wireguard` | `amneziawg` | `openvpn` | `openconnect` | `tailscale`.
    val type: String,
    val enabled: Boolean,
)

data class IndexAppRule(
    val name: String,
    val packages: List<String>,
    val packageRegexes: List<String>,
    val outbound: String,
    val conditional: Boolean,
)

data class ParsedIndex(
    val routeFinal: String,
    val directions: List<IndexDirection>,
    val connections: List<IndexConnection>,
    /// В порядке применения, только включённые (так их пишет Dart).
    val appRules: List<IndexAppRule>,
)

/// Стадия URL Check (§687) в той форме, которая нужна разбору.
data class TraceStage(
    val id: Int,
    val parent: Int,
    val kind: String,
    val subject: String,
    val result: Int,
    val error: String,
    val attrs: List<Pair<String, String>>,
) {
    fun attr(key: String): String = attrs.firstOrNull { it.first == key }?.second ?: ""
}

/// Чем закончился выбор маршрута в проверке адреса.
data class RouteSummary(
    val direction: String,
    val exit: String,
    val direct: Boolean,
    val blocked: Boolean,
)

data class ExitFilterResult(val exits: List<String>, val total: Int, val truncated: Boolean)

data class AppRouteResult(
    val target: String,
    val targetName: String,
    val ruleName: String,
    val conditional: Boolean,
)

/// §750 — чистая логика ассистента без Android API (JVM-тест
/// `AssistantLogicTest`): очистка чужого текста, разбор индекса, выходы
/// Направления, маршрут приложения, разбор `cdn-cgi/trace`, класс стадии
/// URL Check и совет, состояния подключений.
object AssistantLogic {

    const val NAME_MAX = 64
    const val ERROR_MAX = 200
    const val EXITS_LIMIT = 200
    const val APPS_LIMIT = 10
    const val APP_QUERY_MIN = 2

    const val MSG_BAD_INDEX = "The index is empty or not valid JSON."
    const val MSG_VPN_OFF = "The VPN is off. Start it first."
    const val MSG_CORE_DOWN = "The VPN core is not reachable yet. Try again in a few seconds."

    // ═══════════════════════ очистка текста ═══════════════════════

    /// Имя из чужого источника (подписка, пользователь) → одна строка без
    /// управляющих символов, не длиннее [max] знаков (суррогатную пару не
    /// режем). Переводы строк и табы → пробел, пробелы схлопываются.
    fun clean(raw: String?, max: Int = NAME_MAX): String {
        if (raw.isNullOrEmpty()) return ""
        val b = StringBuilder(raw.length)
        var lastSpace = false
        for (ch in raw) {
            val type = Character.getType(ch)
            val isBreak = ch == '\n' || ch == '\r' || ch == '\t' ||
                ch == ' ' || ch == ' ' || ch == '\u0085'
            when {
                isBreak || ch == ' ' || ch == ' ' -> {
                    if (!lastSpace && b.isNotEmpty()) b.append(' ')
                    lastSpace = true
                }
                type == Character.CONTROL.toInt() -> Unit
                // Управление направлением текста (bidi) — переворачивает строку
                // при показе; ZWJ эмодзи-флагов не трогаем.
                ch in '‪'..'‮' || ch in '⁦'..'⁩' -> Unit
                else -> {
                    b.append(ch)
                    lastSpace = false
                }
            }
        }
        var s = b.toString().trimEnd()
        if (s.length > max) {
            var cut = max
            if (Character.isHighSurrogate(s[cut - 1])) cut -= 1
            s = s.substring(0, cut).trimEnd()
        }
        return s
    }

    /// Текст ошибки ядра: одной строкой, до [ERROR_MAX] знаков.
    fun cleanError(raw: String?): String = clean(raw, ERROR_MAX)

    /// Ошибка не проверки, а связи с ядром: сервисный вызов не дошёл
    /// (`rpc error: …`) — так отвечает ядро, пока перезагружается после
    /// смены настроек. Отказ самой проверки (`Get "…": …`, `timeout`)
    /// приходит без этой приставки. Вызывающий отдаёт [MSG_CORE_DOWN].
    fun isCoreTransportError(raw: String?): Boolean =
        raw != null && raw.contains("rpc error:")

    // ═══════════════════════ индекс ═══════════════════════

    /// Разбор индекса. Незнакомые поля игнорируются, отсутствующие — пустые;
    /// битый JSON → null (как «индекса нет»).
    fun parseIndex(json: String?): ParsedIndex? {
        if (json.isNullOrBlank()) return null
        val root = runCatching { JSONObject(json) }.getOrNull() ?: return null
        val directions = objects(root.optJSONArray("directions")).mapNotNull { o ->
            val tag = o.optString("tag")
            if (tag.isEmpty()) null
            else IndexDirection(
                tag = tag,
                name = o.optString("name"),
                enabled = o.optBoolean("enabled", true),
                exits = strings(o.optJSONArray("exits")),
            )
        }
        val connections = objects(root.optJSONArray("connections")).mapNotNull { o ->
            val id = o.optString("id")
            if (id.isEmpty()) null
            else IndexConnection(
                id = id,
                name = o.optString("name"),
                type = o.optString("type"),
                enabled = o.optBoolean("enabled", true),
            )
        }
        val rules = objects(root.optJSONArray("app_rules")).map { o ->
            IndexAppRule(
                name = o.optString("name"),
                packages = strings(o.optJSONArray("packages")),
                packageRegexes = strings(o.optJSONArray("package_regexes")),
                outbound = o.optString("outbound"),
                conditional = o.optBoolean("conditional", false),
            )
        }
        return ParsedIndex(
            routeFinal = root.optString("route_final"),
            directions = directions,
            connections = connections,
            appRules = rules,
        )
    }

    private fun objects(arr: JSONArray?): List<JSONObject> {
        if (arr == null) return emptyList()
        return (0 until arr.length()).mapNotNull { arr.optJSONObject(it) }
    }

    private fun strings(arr: JSONArray?): List<String> {
        if (arr == null) return emptyList()
        return (0 until arr.length()).mapNotNull { i ->
            if (arr.isNull(i)) null else arr.optString(i).takeIf { it.isNotEmpty() }
        }
    }

    // ═══════════════════════ выходы ═══════════════════════

    /// Выходы Направления, в имени которых есть [query] (без учёта регистра;
    /// пусто — все). Не больше [limit] имён; [ExitFilterResult.total] — сколько
    /// подошло всего. Имена очищены.
    fun filterExits(exits: List<String>, query: String?, limit: Int = EXITS_LIMIT): ExitFilterResult {
        val q = query?.trim().orEmpty().lowercase()
        val matched = if (q.isEmpty()) exits else exits.filter { it.lowercase().contains(q) }
        val out = matched.take(limit).map { clean(it) }
        return ExitFilterResult(out, matched.size, matched.size > limit)
    }

    // ═══════════════════════ маршрут приложения ═══════════════════════

    const val TARGET_DIRECT = "direct"
    const val TARGET_BLOCK = "block"

    /// Цель правила для ассистента: тег Направления как есть, `direct-out` →
    /// `direct`, `reject` → `block`.
    fun normalizeTarget(outbound: String): String = when (outbound) {
        "direct-out", "direct" -> TARGET_DIRECT
        "reject", "block" -> TARGET_BLOCK
        else -> outbound
    }

    /// Подпись цели: имя Направления из индекса; `Direct` / `Block`; иначе тег.
    fun targetName(index: ParsedIndex, target: String): String = when (target) {
        TARGET_DIRECT -> "Direct"
        TARGET_BLOCK -> "Block"
        else -> clean(index.directions.firstOrNull { it.tag == target }?.name?.takeIf { it.isNotEmpty() } ?: target)
    }

    /// Первое правило, ловящее [pkg] (точное имя или регулярка; битая
    /// регулярка пропускается). Нет правила — `route_final`, [AppRouteResult.ruleName] пуст.
    fun appRoute(index: ParsedIndex, pkg: String): AppRouteResult {
        for (r in index.appRules) {
            val hit = pkg in r.packages || r.packageRegexes.any { re ->
                runCatching { Regex(re).containsMatchIn(pkg) }.getOrDefault(false)
            }
            if (hit) {
                val target = normalizeTarget(r.outbound)
                return AppRouteResult(target, targetName(index, target), clean(r.name), r.conditional)
            }
        }
        val target = normalizeTarget(index.routeFinal)
        return AppRouteResult(target, targetName(index, target), "", false)
    }

    // ═══════════════════════ приложения ═══════════════════════

    /// Совпадения по подстроке в названии или пакете (без учёта регистра):
    /// сначала названия, начинающиеся с запроса, затем остальные; внутри — по
    /// алфавиту. Не больше [limit]. Пары (package, label), label очищен.
    fun rankApps(apps: List<Pair<String, String>>, query: String, limit: Int = APPS_LIMIT): List<Pair<String, String>> {
        val q = query.trim().lowercase()
        val matched = apps.filter { (pkg, label) ->
            label.lowercase().contains(q) || pkg.lowercase().contains(q)
        }
        val sorted = matched.sortedWith(
            compareBy<Pair<String, String>>({ if (it.second.lowercase().startsWith(q)) 0 else 1 })
                .thenBy { it.second.lowercase() }
                .thenBy { it.first },
        )
        return sorted.take(limit).map { (pkg, label) -> pkg to clean(label.ifEmpty { pkg }) }
    }

    // ═══════════════════════ cdn-cgi/trace ═══════════════════════

    /// Строки `ip=` и `loc=` ответа `https://1.1.1.1/cdn-cgi/trace`.
    /// Пары (ip, country); чего нет — пусто. Страна — верхним регистром.
    fun parseTrace(body: String?): Pair<String, String> {
        var ip = ""
        var loc = ""
        body.orEmpty().lineSequence().forEach { line ->
            val t = line.trim()
            when {
                t.startsWith("ip=") -> ip = clean(t.substring(3), NAME_MAX)
                t.startsWith("loc=") -> loc = clean(t.substring(4), 8).uppercase()
            }
        }
        return ip to loc
    }

    // ═══════════════════════ URL Check ═══════════════════════

    const val STAGE_DNS = "dns"
    const val STAGE_ROUTE = "route"
    const val STAGE_TUNNEL = "tunnel"
    const val STAGE_CONNECT = "connect"
    const val STAGE_TLS = "tls"
    const val STAGE_HTTP = "http"

    /// `kind` стадии ядра (sing-box-lx SPEC 139, `lxtrace.Begin`) → класс.
    /// Неизвестный → `connect`. `tls`/`quic`/`reality` ядро пишет для
    /// соединения с сервером узла (туннель); TLS сайта — `target_tls`.
    fun stageClass(kind: String): String = when (kind) {
        "app_dns", "lookup", "dns", "dns_member", "dns_rules" -> STAGE_DNS
        "route", "group" -> STAGE_ROUTE
        "detour", "chain", "node", "wake", "wg_handshake", "auth", "quic",
        "masque", "transport", "transport_response", "xhttp", "reality", "tls",
        "proxy_header" -> STAGE_TUNNEL
        "dial", "tcp_connect", "udp", "remote", "target" -> STAGE_CONNECT
        "target_tls" -> STAGE_TLS
        "first_byte", "http" -> STAGE_HTTP
        else -> STAGE_CONNECT
    }

    /// Маршрут по стадиям: стадия `route` (attrs `action`, `outbound`,
    /// `outbound_type`) и цепочка стадий `group` (subject = тег группы, attr
    /// `selected`). Если групп по пути нет — выход = subject первой `dial`
    /// (ядро само проходит селекторы, `route/conntest_lx.go`).
    fun routeFromStages(stages: List<TraceStage>): RouteSummary {
        val route = stages.firstOrNull { it.kind == "route" }
            ?: return RouteSummary("", "", direct = false, blocked = false)
        val action = route.attr("action")
        val outbound = route.attr("outbound")
        val outboundType = route.attr("outbound_type")
        val blocked = action.startsWith("reject") || outboundType == "block"
        val direct = !blocked && (outboundType == "direct" || outbound == "direct-out")
        if (blocked || direct || outbound.isEmpty()) {
            return RouteSummary("", "", direct, blocked)
        }
        var cur = outbound
        val seen = HashSet<String>()
        while (seen.add(cur)) {
            val next = stages.firstOrNull { it.kind == "group" && it.subject == cur }
                ?.attr("selected")?.takeIf { it.isNotEmpty() } ?: break
            cur = next
        }
        if (cur == outbound) {
            stages.firstOrNull { it.kind == "dial" && it.subject.isNotEmpty() }?.let { cur = it.subject }
        }
        val exit = if (cur == outbound) "" else cur
        return RouteSummary(clean(outbound), clean(exit), direct = false, blocked = false)
    }

    const val OUTCOME_OK = "ok"
    const val OUTCOME_FAILED = "failed"
    const val OUTCOME_VPN_OFF = "vpn_off"
    const val OUTCOME_BUSY = "busy"
    const val OUTCOME_TIMEOUT = "timeout"

    /// Совет «что сделать» — постоянная таблица (английский текст приложения,
    /// без чужих строк).
    fun advice(
        outcome: String,
        failedStage: String,
        findings: List<String>,
        httpStatus: Int,
        direct: Boolean,
        blocked: Boolean,
    ): String {
        when (outcome) {
            OUTCOME_VPN_OFF -> return "The VPN is off. Start it and repeat the check."
            OUTCOME_BUSY -> return "Another check is running. Repeat the check in a few seconds."
            OUTCOME_TIMEOUT ->
                return "The check did not finish in time. Repeat it; if it times out again, switch to another exit."
        }
        if ("excluded_from_vpn" in findings) {
            return "This app is excluded from the VPN, so its traffic bypasses L×Box. " +
                "Change the app list in the VPN settings if it should go through the VPN."
        }
        if (blocked) return "A routing rule blocks this address."
        if (outcome == OUTCOME_OK) {
            return if (httpStatus >= 400) "The site answered with an error itself; the network path works."
            else "The address opens through this route."
        }
        val fakeIp = findings.any { it.startsWith("fakeip_") }
        return when (failedStage) {
            STAGE_DNS ->
                if (fakeIp) "Cached DNS answers do not match. Restart the VPN and repeat the check."
                else "The name does not resolve. Check the DNS servers in L×Box or try another exit."
            STAGE_ROUTE -> "Routing failed for this address. Check the routing rules in L×Box."
            STAGE_TUNNEL, STAGE_CONNECT -> when {
                "reality_not_recognized" in findings ->
                    "The exit server does not accept the connection settings. Update the subscription or switch to another exit."
                "quic_rejected" in findings ->
                    "The network blocks QUIC to the exit server. Switch to an exit with another protocol."
                direct ->
                    "The site does not accept connections on the direct route. Check the address or route it through a VPN exit."
                else -> "The exit server does not respond. Switch to another exit."
            }
            STAGE_TLS ->
                if (direct) "The site refuses the secure connection. Check the address or route it through a VPN exit."
                else "The site refuses the secure connection through this exit. Try another exit or a direct route."
            STAGE_HTTP ->
                if (direct) "The site accepted the connection but did not answer. Try again later or route it through a VPN exit."
                else "The site accepted the connection but did not answer. Try again later or switch to another exit."
            else -> "The check failed. Repeat it or switch to another exit."
        }
    }

    /// URL для проверки: без схемы → `https://`; только http/https с хостом,
    /// иначе null.
    fun normalizeUrl(raw: String?): String? {
        val t = raw?.trim().orEmpty()
        if (t.isEmpty() || t.any { it.isWhitespace() || Character.getType(it) == Character.CONTROL.toInt() }) return null
        val withScheme = if (t.contains("://")) t else "https://$t"
        val scheme = withScheme.substringBefore("://").lowercase()
        if (scheme != "http" && scheme != "https") return null
        val host = withScheme.substringAfter("://").substringBefore('/').substringBefore('?')
            .substringBefore('#').substringAfterLast('@')
        if (host.isEmpty() || host.startsWith(":")) return null
        return withScheme
    }

    // ═══════════════════════ подключения ═══════════════════════

    const val CONN_UP = "up"
    const val CONN_CONNECTING = "connecting"
    const val CONN_IDLE = "idle"
    const val CONN_NEEDS_LOGIN = "needs_login"
    const val CONN_DOWN = "down"
    const val CONN_DISABLED = "disabled"
    const val CONN_UNKNOWN = "unknown"

    /// Состояние подключения. [coreState] — слово ядра по типу: WG/AWG —
    /// `endpointState` (§535), Tailscale — `backend_state`, OpenConnect —
    /// `state` (§654); null — ядро о узле ничего не сказало.
    fun connectionState(type: String, enabled: Boolean, tunnelUp: Boolean, coreState: String?): String {
        if (!enabled) return CONN_DISABLED
        if (!tunnelUp) return CONN_DOWN
        if (coreState.isNullOrEmpty()) return CONN_UNKNOWN
        return when (type) {
            "wireguard", "amneziawg" -> when (coreState) {
                "up" -> CONN_UP
                "building" -> CONN_CONNECTING
                "asleep", "never_built", "torn_down" -> CONN_IDLE
                "disabled" -> CONN_DISABLED
                "down" -> CONN_DOWN
                else -> CONN_UNKNOWN
            }
            "tailscale" -> when (coreState) {
                "Running" -> CONN_UP
                "Starting", "NoState" -> CONN_CONNECTING
                "NeedsLogin", "NeedsMachineAuth" -> CONN_NEEDS_LOGIN
                "Stopped" -> CONN_DOWN
                else -> CONN_UNKNOWN
            }
            "openconnect", "openvpn" -> when (coreState) {
                "connected" -> CONN_UP
                "connecting" -> CONN_CONNECTING
                "auth-pending" -> CONN_NEEDS_LOGIN
                "error" -> CONN_DOWN
                else -> CONN_UNKNOWN
            }
            else -> CONN_UNKNOWN
        }
    }

    // ═══════════════════════ §750 мост шлюза в Dart ═══════════════════════
    // Чистая часть [AssistantBridge]: разбор ответа Dart и решение
    // «вызвать / открыть окно / ждать / сдаться».

    /// Сколько ждать Dart-часть после попытки открыть окно.
    const val BRIDGE_WAIT_MS = 10_000L
    const val BRIDGE_POLL_MS = 200L
    /// Предел одного вызова `assistantCall`.
    const val BRIDGE_CALL_TIMEOUT_MS = 30_000L

    const val MSG_APP_NOT_OPEN = "L×Box is not open. Open the app and repeat."
    const val MSG_BRIDGE_TIMEOUT = "L×Box did not answer in time. Repeat the request."
    const val MSG_BRIDGE_BAD_REPLY = "L×Box returned an unexpected answer."

    /// Ответ шлюза: `status` — как HTTP-код обработчика, `body` — JSON строкой.
    data class ApiResult(val status: Int, val body: String)

    /// Разбор ответа Dart `{"status": Int, "body": String}`; иное — null.
    fun parseBridgeReply(reply: Any?): ApiResult? {
        val m = reply as? Map<*, *> ?: return null
        val status = (m["status"] as? Number)?.toInt() ?: return null
        val body = m["body"] as? String ?: ""
        return ApiResult(status, body)
    }

    /// «Движок есть, контроллеры ещё не подняты» — повторить позже.
    fun isNotReady(r: ApiResult): Boolean = r.status == 503 && r.body.contains("not_ready")

    enum class BridgeStep { LAUNCH, WAIT, GIVE_UP }

    /// Что делать, когда моста нет или Dart ответил `not_ready`: окно ещё не
    /// открывали — открыть (один раз); открывали — ждать до [BRIDGE_WAIT_MS]
    /// с момента попытки, потом сдаться.
    fun bridgeStep(launched: Boolean, sinceLaunchMs: Long): BridgeStep = when {
        !launched -> BridgeStep.LAUNCH
        sinceLaunchMs < BRIDGE_WAIT_MS -> BridgeStep.WAIT
        else -> BridgeStep.GIVE_UP
    }

    private val API_METHODS = setOf("GET", "POST", "PUT", "PATCH", "DELETE")

    /// Проверка аргументов `callApi`: метод (без учёта регистра) → верхний
    /// регистр; путь начинается с `/`. Иначе [AssistantError.INVALID_ARGUMENT].
    fun validateApiCall(method: String, path: String): Pair<String, String> {
        val m = method.trim().uppercase(java.util.Locale.ROOT)
        if (m !in API_METHODS) {
            throw AssistantError(AssistantError.INVALID_ARGUMENT, "The method must be GET, POST, PUT, PATCH or DELETE.")
        }
        val p = path.trim()
        if (!p.startsWith("/")) {
            throw AssistantError(AssistantError.INVALID_ARGUMENT, "The path must start with /.")
        }
        return m to p
    }
}
