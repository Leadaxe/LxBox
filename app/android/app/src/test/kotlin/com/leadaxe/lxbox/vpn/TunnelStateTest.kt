package com.leadaxe.lxbox.vpn

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/// §742 — переходы владельца состояния туннеля (логика §187/§276).
class TunnelStateTest {

    private var now = 1_000L
    private lateinit var savedClock: () -> Long

    @Before
    fun setUp() {
        savedClock = TunnelState.clock
        TunnelState.clock = { now }
        TunnelState.resetForTest()
    }

    @After
    fun tearDown() {
        TunnelState.resetForTest()
        TunnelState.clock = savedClock
    }

    @Test
    fun `Stopped with revoked keeps the mark`() {
        TunnelState.setStatus(VpnStatus.Stopped, revoked = true)
        assertEquals(VpnStatus.Stopped, TunnelState.status)
        assertTrue(TunnelState.revoked)
    }

    @Test
    fun `Starting and Started clear revoked`() {
        TunnelState.setStatus(VpnStatus.Stopped, revoked = true)
        TunnelState.setStatus(VpnStatus.Starting, revoked = true)
        assertFalse(TunnelState.revoked)

        TunnelState.setStatus(VpnStatus.Stopped, revoked = true)
        TunnelState.setStatus(VpnStatus.Started, revoked = true)
        assertFalse(TunnelState.revoked)
    }

    @Test
    fun `start time is fixed once on repeated Started`() {
        TunnelState.setStatus(VpnStatus.Starting)
        assertEquals(0L, TunnelState.startedElapsedMs)
        now = 5_000L
        TunnelState.setStatus(VpnStatus.Started)
        assertEquals(5_000L, TunnelState.startedElapsedMs)
        now = 9_000L
        TunnelState.setStatus(VpnStatus.Started)
        assertEquals(5_000L, TunnelState.startedElapsedMs)
        TunnelState.setStatus(VpnStatus.Stopping)
        assertEquals(5_000L, TunnelState.startedElapsedMs)
    }

    @Test
    fun `Stopped resets start time`() {
        now = 5_000L
        TunnelState.setStatus(VpnStatus.Started)
        TunnelState.setStatus(VpnStatus.Stopped)
        assertEquals(0L, TunnelState.startedElapsedMs)
        now = 7_000L
        TunnelState.setStatus(VpnStatus.Started)
        assertEquals(7_000L, TunnelState.startedElapsedMs)
    }

    @Test
    fun `setSessionAllowBypass leaves the rest untouched`() {
        now = 5_000L
        TunnelState.setStatus(VpnStatus.Started)
        val before = TunnelState.snapshot
        TunnelState.setSessionAllowBypass(true)
        val after = TunnelState.snapshot
        assertTrue(after.sessionAllowBypass)
        assertEquals(before.copy(sessionAllowBypass = true), after)

        TunnelState.setStatus(VpnStatus.Stopped, revoked = true)
        assertTrue(TunnelState.sessionAllowBypass)
        TunnelState.setSessionAllowBypass(false)
        assertEquals(VpnStatus.Stopped, TunnelState.status)
        assertTrue(TunnelState.revoked)
    }
}
