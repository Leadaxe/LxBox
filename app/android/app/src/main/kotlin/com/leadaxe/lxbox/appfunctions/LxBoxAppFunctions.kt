package com.leadaxe.lxbox.appfunctions

import android.net.VpnService
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.appfunctions.AppFunctionDeclaration
import androidx.appfunctions.AppFunctionAppUnknownException
import androidx.appfunctions.AppFunctionDisabledException
import androidx.appfunctions.AppFunctionElementNotFoundException
import androidx.appfunctions.AppFunctionInvalidArgumentException
import androidx.appfunctions.AppFunctionLimitExceededException
import androidx.appfunctions.AppFunctionNotSupportedException
import androidx.appfunctions.AppFunctionPermissionRequiredException
import androidx.appfunctions.AppFunctionService
import androidx.appfunctions.AppFunctionServiceEntryPoint
import com.leadaxe.lxbox.vpn.BootReceiver
import com.leadaxe.lxbox.vpn.BoxApplication
import com.leadaxe.lxbox.vpn.BoxVpnService
import com.leadaxe.lxbox.vpn.ConfigManager
import com.leadaxe.lxbox.vpn.TunnelState
import com.leadaxe.lxbox.vpn.VpnStatus
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeoutOrNull

/// §721 — Android AppFunctions (Android 16+): ассистент с разрешением
/// `EXECUTE_APP_FUNCTIONS` включает/выключает VPN и читает статус.
///
/// KSP порождает конкретный сервис `LxBoxAppFunctionService` (манифест) и
/// схему `lxbox_app_functions.xml`. Функции объявлены выключенными
/// (`isEnabled = false`): их включает тумблер «AI assistant control» через
/// [AppFunctionsGate]. Вторая линия — проверка зеркала в каждой функции:
/// при выключенном тумблере функция не исполняется, даже если система
/// считает её включённой (например, после `adb … set-enabled`).
///
/// Процесс может быть холодным: Flutter здесь не нужен, только натив
/// (тот же путь, что у BootReceiver и плитки QS).
@RequiresApi(36)
@AppFunctionServiceEntryPoint(
    serviceName = "LxBoxAppFunctionService",
    appFunctionXmlFileName = "lxbox_app_functions",
)
abstract class LxBoxAppFunctions : AppFunctionService() {

    /**
     * Connects the L×Box VPN tunnel using the configuration selected in the app.
     *
     * Returns the tunnel state after the connection attempt settles.
     */
    @AppFunctionDeclaration(isDescribedByKDoc = true, isEnabled = false)
    suspend fun startVpn(): VpnState {
        ensureEnabled()
        val ctx = applicationContext
        BoxApplication.initialize(ctx)
        val needsConsent = BootReceiver.hasTun(ctx) && VpnService.prepare(ctx) != null
        val decision = AppFunctionsLogic.decideStart(
            status = TunnelState.status,
            needsConsent = needsConsent,
            hasConfig = AppFunctionsLogic.hasConfig(ConfigManager.load()),
        )
        Log.d(TAG, "startVpn: ${decision::class.simpleName}, status=${TunnelState.status}")
        when (decision) {
            AppFunctionsLogic.StartDecision.AlreadyRunning -> return current()
            AppFunctionsLogic.StartDecision.NoPermission ->
                throw AppFunctionPermissionRequiredException(AppFunctionsLogic.MSG_NO_PERMISSION)
            AppFunctionsLogic.StartDecision.NoConfig ->
                throw AppFunctionElementNotFoundException(AppFunctionsLogic.MSG_NO_CONFIG)
            AppFunctionsLogic.StartDecision.Start -> Unit
        }
        BoxVpnService.start(ctx)
        return awaitSettled(VpnStatus.Started)
    }

    /**
     * Disconnects the L×Box VPN tunnel.
     *
     * Returns the tunnel state after the disconnection settles.
     */
    @AppFunctionDeclaration(isDescribedByKDoc = true, isEnabled = false)
    suspend fun stopVpn(): VpnState {
        ensureEnabled()
        Log.d(TAG, "stopVpn: status=${TunnelState.status}")
        if (TunnelState.status == VpnStatus.Stopped) return current()
        BoxVpnService.stop(applicationContext)
        return awaitSettled(VpnStatus.Stopped)
    }

    /**
     * Returns the current state of the L×Box VPN tunnel.
     */
    @AppFunctionDeclaration(isDescribedByKDoc = true, isEnabled = false)
    suspend fun getVpnStatus(): VpnState {
        ensureEnabled()
        return current()
    }

    // ═══════════════════════ §750 ассистент: чтения и действия над ядром ═══════════════════════
    // Исполнитель — [AssistantCore] (общий с методами канала Debug API).
    // `AssistantError` → наследник `AppFunctionException` ([assistant]).

    /**
     * Lists the exits of a routing direction.
     *
     * @param direction The direction identifier, such as "vpn-1".
     * @param query Text to look for in exit names, ignoring case; all exits when empty.
     */
    @AppFunctionDeclaration(isDescribedByKDoc = true, isEnabled = false)
    suspend fun listExits(direction: String, query: String?): ExitList {
        ensureEnabled()
        val m = assistant { AssistantCore.listExits(applicationContext, direction, query) }
        return ExitList(
            direction = m.str("direction"),
            exits = m.strs("exits"),
            total = m.int("total"),
            truncated = m.bool("truncated"),
        )
    }

    /**
     * Checks whether an address opens through the running VPN and reports the
     * failed step and the route taken. Does not start the VPN.
     *
     * @param url The address to check; https is assumed when the scheme is missing.
     * @param appPackage The package name of the app whose routing rules apply; none when empty.
     */
    @AppFunctionDeclaration(isDescribedByKDoc = true, isEnabled = false)
    suspend fun checkUrl(url: String, appPackage: String?): UrlCheckReport {
        ensureEnabled()
        val m = assistant { AssistantCore.checkUrl(applicationContext, url, appPackage) }
        val route = m.sub("route")
        return UrlCheckReport(
            outcome = m.str("outcome"),
            failedStage = m.str("failed_stage"),
            error = m.str("error"),
            httpStatus = m.int("http_status"),
            elapsedMs = m.int("elapsed_ms"),
            route = RouteInfo(
                direction = route.str("direction"),
                exit = route.str("exit"),
                direct = route.bool("direct"),
                blocked = route.bool("blocked"),
            ),
            findings = m.strs("findings"),
            advice = m.str("advice"),
        )
    }

    /**
     * Checks the actual exit of a routing direction: the public IP address and
     * its country.
     *
     * @param direction The direction identifier, such as "vpn-1".
     */
    @AppFunctionDeclaration(isDescribedByKDoc = true, isEnabled = false)
    suspend fun checkExit(direction: String): ExitCheck {
        ensureEnabled()
        val m = assistant { AssistantCore.checkExit(applicationContext, direction) }
        return ExitCheck(
            outcome = m.str("outcome"),
            country = m.str("country"),
            ip = m.str("ip"),
            exit = m.str("exit"),
            error = m.str("error"),
        )
    }

    /**
     * Finds installed apps by a part of the app name or package name, up to 10.
     *
     * @param query At least 2 characters of the app name or package name, ignoring case.
     */
    @AppFunctionDeclaration(isDescribedByKDoc = true, isEnabled = false)
    suspend fun findApps(query: String): List<AppMatch> {
        ensureEnabled()
        val list = assistant { AssistantCore.findApps(applicationContext, query) }
        return list.map { AppMatch(packageName = it.str("package"), label = it.str("label")) }
    }

    /**
     * Selects an exit in a routing direction of the running VPN. The selection
     * lasts until the VPN restarts.
     *
     * @param direction The direction identifier, such as "vpn-1".
     * @param exit The exact exit name from the list of exits.
     */
    @AppFunctionDeclaration(isDescribedByKDoc = true, isEnabled = false)
    suspend fun selectExit(direction: String, exit: String): ExitSelection {
        ensureEnabled()
        val m = assistant { AssistantCore.selectExit(applicationContext, direction, exit) }
        return ExitSelection(
            direction = m.str("direction"),
            exit = m.str("exit"),
            changed = m.bool("changed"),
        )
    }

    // ═══════════════════════ §750 шлюз к Debug API (исполняет Dart) ═══════════════════════
    // Мост — [AssistantBridge]: нет Dart-части — открыть окно и ждать; не
    // дождались — уведомление и `app_not_open`. Политику проверяет Dart.

    /**
     * Returns the list of L×Box API routes available to assistants: method, path, purpose and parameters.
     */
    @AppFunctionDeclaration(isDescribedByKDoc = true, isEnabled = false)
    suspend fun getApiHelp(): ApiResponse {
        ensureEnabled()
        val r = assistant { AssistantBridge.call(applicationContext, "GET", "/assistant/help", null) }
        return ApiResponse(status = r.status, body = r.body)
    }

    /**
     * Calls an L×Box API route from the list of routes available to assistants.
     * Returns the status code of the route and its JSON answer. Routes that
     * change settings run only when the user has allowed changes in the L×Box
     * settings; otherwise they answer with status 403.
     *
     * @param method The request method: GET, POST, PUT, PATCH or DELETE.
     * @param path The route path starting with "/", with the query string if any.
     * @param body The request body as a JSON string; none when empty.
     */
    @AppFunctionDeclaration(isDescribedByKDoc = true, isEnabled = false)
    suspend fun callApi(method: String, path: String, body: String?): ApiResponse {
        ensureEnabled()
        val r = assistant {
            val (m, p) = AssistantLogic.validateApiCall(method, path)
            AssistantBridge.call(applicationContext, m, p, body?.takeIf { it.isNotBlank() })
        }
        return ApiResponse(status = r.status, body = r.body)
    }

    /// Исполнить операцию ассистента: холодный процесс → инициализация
    /// (ConfigManager читает файл через BoxApplication); `AssistantError` →
    /// наследник `AppFunctionException` по коду.
    private suspend fun <T> assistant(block: suspend () -> T): T {
        BoxApplication.initialize(applicationContext)
        try {
            return block()
        } catch (e: AssistantError) {
            Log.d(TAG, "assistant error: ${e.code}")
            val msg = e.message ?: ""
            throw when (e.code) {
                AssistantError.NOT_FOUND -> AppFunctionElementNotFoundException(msg)
                AssistantError.INVALID_ARGUMENT -> AppFunctionInvalidArgumentException(msg)
                AssistantError.BUSY -> AppFunctionLimitExceededException(msg)
                AssistantError.VPN_OFF,
                // §750 — окно L×Box не открылось: функция сейчас недоступна
                // в этом состоянии приложения (ближайший класс rc01).
                AssistantError.APP_NOT_OPEN -> AppFunctionNotSupportedException(msg)
                else -> AppFunctionAppUnknownException(msg)
            }
        }
    }

    private fun ensureEnabled() {
        if (!BootReceiver.isAppFunctionsEnabled(applicationContext)) {
            throw AppFunctionDisabledException(AppFunctionsLogic.MSG_DISABLED)
        }
    }

    private fun current(): VpnState =
        VpnState(AppFunctionsLogic.statusValue(TunnelState.status))

    /// Ждать цели или выхода из переходного состояния, не дольше
    /// [AppFunctionsLogic.SETTLE_TIMEOUT_MS]; вернуть фактическое состояние.
    private suspend fun awaitSettled(target: VpnStatus): VpnState {
        var seenTransient = false
        withTimeoutOrNull(AppFunctionsLogic.SETTLE_TIMEOUT_MS) {
            while (true) {
                val s = TunnelState.status
                if (AppFunctionsLogic.isTransient(s)) seenTransient = true
                if (AppFunctionsLogic.isSettled(s, target, seenTransient)) break
                delay(AppFunctionsLogic.POLL_INTERVAL_MS)
            }
        }
        return current()
    }

    private companion object {
        const val TAG = "LxBoxAppFunctions"
    }
}

// §750 — разбор Map-ответа [AssistantCore] (ключи snake_case) в типы схемы.
private fun Map<String, Any?>.str(key: String): String = this[key] as? String ?: ""
private fun Map<String, Any?>.int(key: String): Int = (this[key] as? Number)?.toInt() ?: 0
private fun Map<String, Any?>.bool(key: String): Boolean = this[key] as? Boolean ?: false
@Suppress("UNCHECKED_CAST")
private fun Map<String, Any?>.sub(key: String): Map<String, Any?> =
    this[key] as? Map<String, Any?> ?: emptyMap()
private fun Map<String, Any?>.strs(key: String): List<String> =
    (this[key] as? List<*>)?.mapNotNull { it as? String } ?: emptyList()
