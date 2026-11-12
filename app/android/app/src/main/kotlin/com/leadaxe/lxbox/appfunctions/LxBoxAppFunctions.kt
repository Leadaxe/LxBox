package com.leadaxe.lxbox.appfunctions

import android.net.VpnService
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.appfunctions.AppFunctionDeclaration
import androidx.appfunctions.AppFunctionDisabledException
import androidx.appfunctions.AppFunctionElementNotFoundException
import androidx.appfunctions.AppFunctionPermissionRequiredException
import androidx.appfunctions.AppFunctionService
import androidx.appfunctions.AppFunctionServiceEntryPoint
import com.leadaxe.lxbox.vpn.BootReceiver
import com.leadaxe.lxbox.vpn.BoxApplication
import com.leadaxe.lxbox.vpn.BoxVpnService
import com.leadaxe.lxbox.vpn.ConfigManager
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
            status = BoxVpnService.currentStatus,
            needsConsent = needsConsent,
            hasConfig = AppFunctionsLogic.hasConfig(ConfigManager.load()),
        )
        Log.d(TAG, "startVpn: ${decision::class.simpleName}, status=${BoxVpnService.currentStatus}")
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
        Log.d(TAG, "stopVpn: status=${BoxVpnService.currentStatus}")
        if (BoxVpnService.currentStatus == VpnStatus.Stopped) return current()
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

    private fun ensureEnabled() {
        if (!BootReceiver.isAppFunctionsEnabled(applicationContext)) {
            throw AppFunctionDisabledException(AppFunctionsLogic.MSG_DISABLED)
        }
    }

    private fun current(): VpnState =
        VpnState(AppFunctionsLogic.statusValue(BoxVpnService.currentStatus))

    /// Ждать цели или выхода из переходного состояния, не дольше
    /// [AppFunctionsLogic.SETTLE_TIMEOUT_MS]; вернуть фактическое состояние.
    private suspend fun awaitSettled(target: VpnStatus): VpnState {
        var seenTransient = false
        withTimeoutOrNull(AppFunctionsLogic.SETTLE_TIMEOUT_MS) {
            while (true) {
                val s = BoxVpnService.currentStatus
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
