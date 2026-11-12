package com.leadaxe.lxbox.appfunctions

import com.leadaxe.lxbox.appfunctions.AppFunctionsLogic.StartDecision
import com.leadaxe.lxbox.vpn.VpnStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/// §721 — чистая логика AppFunctions: значение статуса для агента, решение
/// «можно ли стартовать», условие конца ожидания.
class AppFunctionsLogicTest {

    @Test
    fun statusValuesAreTheDeclaredEnum() {
        val values = VpnStatus.values().map(AppFunctionsLogic::statusValue)
        assertEquals(listOf("stopped", "starting", "started", "stopping"), values)
    }

    @Test
    fun runningTunnelIsNotStartedAgain() {
        for (s in listOf(VpnStatus.Started, VpnStatus.Starting)) {
            assertEquals(StartDecision.AlreadyRunning,
                AppFunctionsLogic.decideStart(s, needsConsent = true, hasConfig = false))
        }
    }

    @Test
    fun missingConsentWinsOverMissingConfig() {
        assertEquals(StartDecision.NoPermission,
            AppFunctionsLogic.decideStart(VpnStatus.Stopped, needsConsent = true, hasConfig = false))
        assertEquals(StartDecision.NoConfig,
            AppFunctionsLogic.decideStart(VpnStatus.Stopped, needsConsent = false, hasConfig = false))
        assertEquals(StartDecision.Start,
            AppFunctionsLogic.decideStart(VpnStatus.Stopping, needsConsent = false, hasConfig = true))
    }

    @Test
    fun emptyConfigIsNoConfig() {
        assertFalse(AppFunctionsLogic.hasConfig(""))
        assertFalse(AppFunctionsLogic.hasConfig(" {} "))
        assertTrue(AppFunctionsLogic.hasConfig("""{"outbounds":[]}"""))
    }

    @Test
    fun waitEndsOnTargetOrAfterTransition() {
        // Сразу после start статус ещё Stopped — ждём, пока не было перехода.
        assertFalse(AppFunctionsLogic.isSettled(VpnStatus.Stopped, VpnStatus.Started, seenTransient = false))
        assertFalse(AppFunctionsLogic.isSettled(VpnStatus.Starting, VpnStatus.Started, seenTransient = true))
        assertTrue(AppFunctionsLogic.isSettled(VpnStatus.Started, VpnStatus.Started, seenTransient = false))
        // Старт упал: Starting → Stopped.
        assertTrue(AppFunctionsLogic.isSettled(VpnStatus.Stopped, VpnStatus.Started, seenTransient = true))
    }

    @Test
    fun functionIdsNameTheDeclaringClass() {
        assertEquals(
            listOf("startVpn", "stopVpn", "getVpnStatus").map {
                "com.leadaxe.lxbox.appfunctions.LxBoxAppFunctions#$it"
            },
            AppFunctionsLogic.FUNCTION_IDS,
        )
        assertEquals(LxBoxAppFunctions::class.java.name,
            AppFunctionsLogic.FUNCTION_IDS.first().substringBefore('#'))
    }
}
