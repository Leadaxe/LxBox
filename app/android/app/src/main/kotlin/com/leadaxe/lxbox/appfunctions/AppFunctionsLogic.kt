package com.leadaxe.lxbox.appfunctions

import com.leadaxe.lxbox.vpn.VpnStatus

/// §721 — чистая логика AppFunctions без Android API (JVM-тест
/// `AppFunctionsLogicTest`): строка статуса, решение «можно ли стартовать»,
/// условие выхода из ожидания, идентификаторы функций.
object AppFunctionsLogic {

    /// Предел ожидания выхода из переходного состояния после start/stop.
    const val SETTLE_TIMEOUT_MS = 15_000L
    const val POLL_INTERVAL_MS = 200L

    const val MSG_DISABLED = "AI assistant control is turned off in L×Box settings."
    const val MSG_NO_PERMISSION = "VPN permission is not granted. Open L×Box and connect once."
    const val MSG_NO_CONFIG = "No configuration. Open L×Box and add a server."

    /// Идентификатор функции = `<FQN класса с объявлением>#<имя>` (так его
    /// строит appfunctions-compiler rc01, `AnnotatedAppFunction.getAppFunctionIdentifier`).
    private const val DECLARING_CLASS = "com.leadaxe.lxbox.appfunctions.LxBoxAppFunctions"
    val FUNCTION_IDS: List<String> = listOf("startVpn", "stopVpn", "getVpnStatus")
        .map { "$DECLARING_CLASS#$it" }

    fun statusValue(s: VpnStatus): String = when (s) {
        VpnStatus.Stopped -> "stopped"
        VpnStatus.Starting -> "starting"
        VpnStatus.Started -> "started"
        VpnStatus.Stopping -> "stopping"
    }

    fun isTransient(s: VpnStatus): Boolean =
        s == VpnStatus.Starting || s == VpnStatus.Stopping

    sealed class StartDecision {
        /// Уже Started/Starting — вернуть состояние без действия.
        object AlreadyRunning : StartDecision()
        /// Нужен TUN, а согласие на VPN не выдано.
        object NoPermission : StartDecision()
        /// Нет сохранённого конфига.
        object NoConfig : StartDecision()
        object Start : StartDecision()
    }

    /// [needsConsent] — `hasTun && VpnService.prepare(...) != null`.
    /// Stopping считаем «не запущен»: старт после остановки — штатный путь
    /// BoxVpnService (как у плитки QS).
    fun decideStart(status: VpnStatus, needsConsent: Boolean, hasConfig: Boolean): StartDecision =
        when {
            status == VpnStatus.Started || status == VpnStatus.Starting -> StartDecision.AlreadyRunning
            needsConsent -> StartDecision.NoPermission
            !hasConfig -> StartDecision.NoConfig
            else -> StartDecision.Start
        }

    /// Конфиг сохранён: `ConfigManager.load()` отдаёт `{}` при отсутствии
    /// файла — та же проверка, что в `BoxService.startSingbox`.
    fun hasConfig(raw: String): Boolean {
        val t = raw.trim()
        return t.isNotEmpty() && t != "{}"
    }

    /// Ожидание после команды закончено: достигнута цель, либо сервис уже
    /// прошёл переходное состояние и встал в другое конечное (например,
    /// старт упал → Stopped).
    fun isSettled(current: VpnStatus, target: VpnStatus, seenTransient: Boolean): Boolean =
        current == target || (seenTransient && !isTransient(current))
}
