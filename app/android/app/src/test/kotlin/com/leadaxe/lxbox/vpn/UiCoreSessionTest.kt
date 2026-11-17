package com.leadaxe.lxbox.vpn

import java.util.concurrent.CountDownLatch
import java.util.concurrent.CyclicBarrier
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/// §745 — держатель клиента UI: логика `UiCoreSession` (`ClientHolder`) на
/// подменной фабрике, без libbox; условие создания — настоящий `TunnelState`.
/// Плюс слушатели `CoreSession` «перед закрытием».
class UiCoreSessionTest {

    private class FakeClient {
        val shutdowns = AtomicInteger(0)
    }

    private val created = AtomicInteger(0)
    private lateinit var savedClock: () -> Long

    private fun holder() = ClientHolder(
        started = { TunnelState.status == VpnStatus.Started },
        create = { created.incrementAndGet(); FakeClient() },
        shutdown = { it.shutdowns.incrementAndGet() },
    )

    @Before
    fun setUp() {
        savedClock = TunnelState.clock
        TunnelState.clock = { 1_000L }
        TunnelState.resetForTest()
        CoreSession.clearBeforeCloseListenersForTest()
    }

    @After
    fun tearDown() {
        TunnelState.resetForTest()
        TunnelState.clock = savedClock
        CoreSession.clearBeforeCloseListenersForTest()
    }

    @Test
    fun `ensure without Started creates nothing`() {
        val h = holder()
        for (s in listOf(VpnStatus.Stopped, VpnStatus.Starting, VpnStatus.Stopping)) {
            TunnelState.setStatus(s)
            assertNull(h.ensure())
        }
        assertNull(h.client)
        assertEquals(0, created.get())
    }

    @Test
    fun `ensure with Started creates once`() {
        val h = holder()
        TunnelState.setStatus(VpnStatus.Started)
        val first = h.ensure()
        assertNotNull(first)
        assertSame(first, h.ensure())
        assertSame(first, h.client)
        assertEquals(1, created.get())
    }

    @Test
    fun `existing client is returned after the tunnel left Started`() {
        val h = holder()
        TunnelState.setStatus(VpnStatus.Started)
        val c = h.ensure()
        TunnelState.setStatus(VpnStatus.Stopping)
        assertSame(c, h.ensure())
        assertEquals(1, created.get())
    }

    @Test
    fun `concurrent ensure creates one client`() {
        val h = holder()
        TunnelState.setStatus(VpnStatus.Started)
        val n = 8
        val barrier = CyclicBarrier(n)
        val done = CountDownLatch(n)
        val got = java.util.Collections.synchronizedList(ArrayList<Any?>())
        repeat(n) {
            Thread {
                barrier.await(5, TimeUnit.SECONDS)
                got.add(h.ensure())
                done.countDown()
            }.start()
        }
        assertTrue(done.await(5, TimeUnit.SECONDS))
        assertEquals(1, created.get())
        assertEquals(n, got.size)
        assertTrue(got.all { it === h.client })
    }

    @Test
    fun `close is idempotent and shuts the client down once`() {
        val h = holder()
        h.close() // клиента нет — no-op
        TunnelState.setStatus(VpnStatus.Started)
        val c = h.ensure()!!
        h.close()
        h.close()
        assertNull(h.client)
        assertEquals(1, c.shutdowns.get())
    }

    @Test
    fun `close then ensure creates a new client while Started`() {
        val h = holder()
        TunnelState.setStatus(VpnStatus.Started)
        val first = h.ensure()
        h.close()
        val second = h.ensure()
        assertNotNull(second)
        assertFalse(first === second)
        assertEquals(2, created.get())
    }

    @Test
    fun `close with a runner drops the reference before shutdown runs`() {
        val h = holder()
        TunnelState.setStatus(VpnStatus.Started)
        val c = h.ensure()!!
        var deferred: (() -> Unit)? = null
        h.close { task -> deferred = task }
        assertNull(h.client)
        assertEquals(0, c.shutdowns.get())
        deferred!!.invoke()
        assertEquals(1, c.shutdowns.get())
    }

    @Test
    fun `shutdown failure does not escape close`() {
        val h = ClientHolder(
            started = { true },
            create = { FakeClient() },
            shutdown = { throw IllegalStateException("boom") },
        )
        h.ensure()
        h.close()
        assertNull(h.client)
    }

    @Test
    fun `before-close listeners run in order and survive a failing one`() {
        val order = ArrayList<String>()
        CoreSession.addBeforeCloseListener { order.add("a") }
        CoreSession.addBeforeCloseListener { throw IllegalStateException("boom") }
        CoreSession.addBeforeCloseListener { order.add("c") }
        CoreSession.notifyBeforeClose()
        assertEquals(listOf("a", "c"), order)
    }

    @Test
    fun `before-close listener closes the holder`() {
        val h = holder()
        TunnelState.setStatus(VpnStatus.Started)
        val c = h.ensure()!!
        CoreSession.addBeforeCloseListener { h.close() }
        CoreSession.notifyBeforeClose()
        CoreSession.notifyBeforeClose()
        assertNull(h.client)
        assertEquals(1, c.shutdowns.get())
    }
}
