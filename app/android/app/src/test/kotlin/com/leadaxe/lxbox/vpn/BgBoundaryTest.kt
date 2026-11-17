package com.leadaxe.lxbox.vpn

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

/// §747 — чистая логика границы процессов `:ui` / `:bg`: кодек значений
/// вызова, кадры и очереди канала событий, копия состояния туннеля, условия
/// завершения `:bg`, роль процесса. Без Android.
class BgBoundaryTest {

    private lateinit var savedClock: () -> Long

    @Before
    fun setUp() {
        savedClock = TunnelState.clock
        TunnelState.resetForTest()
    }

    @After
    fun tearDown() {
        TunnelState.resetForTest()
        TunnelState.clock = savedClock
    }

    // ───────────── кодек ─────────────

    @Test
    fun `codec keeps MethodChannel value types`() {
        val value = mapOf(
            "s" to "текст",
            "b" to true,
            "i" to 42,
            "l" to 5_000_000_000L,
            "d" to 1.5,
            "n" to null,
            "list" to listOf("a", 1, false),
            "map" to mapOf("k" to "v"),
        )
        val back = BgCodec.decode(BgCodec.encode(value)) as Map<*, *>
        assertEquals("текст", back["s"])
        assertEquals(true, back["b"])
        assertEquals(42, back["i"])
        assertEquals(5_000_000_000L, back["l"])
        assertEquals(1.5, back["d"])
        assertTrue(back.containsKey("n"))
        assertNull(back["n"])
        assertEquals(listOf("a", 1, false), back["list"])
        assertEquals(mapOf("k" to "v"), back["map"])
    }

    @Test
    fun `codec keeps bytes and null`() {
        val bytes = ByteArray(1000) { (it % 251).toByte() }
        assertArrayEquals(bytes, BgCodec.decode(BgCodec.encode(bytes)) as ByteArray)
        // null — один байт, как внутри списка: кадр с пустым значением валиден.
        assertEquals(1, BgCodec.encode(null).size)
        assertNull(BgCodec.decode(BgCodec.encode(null)))
        assertNull(BgCodec.decode(null))
    }

    @Test
    fun `codec keeps a bare scalar result`() {
        assertEquals(false, BgCodec.decode(BgCodec.encode(false)))
        assertEquals("x", BgCodec.decode(BgCodec.encode("x")))
        assertEquals(0L, BgCodec.decode(BgCodec.encode(0L)))
    }

    @Test
    fun `event envelope is what an EventChannel would send`() {
        // double выравнивается от начала сообщения: конверт строится целиком,
        // а не приписыванием байта к голому значению.
        val value = mapOf("up" to 1.5, "names" to listOf("a", "b"), "n" to 7L)
        assertEquals(value, BgCodec.decodeEventEnvelope(BgCodec.encodeEventEnvelope(value)))
        assertNull(BgCodec.decodeEventEnvelope(BgCodec.encodeEventEnvelope(null)))
    }

    // ───────────── кадры канала событий ─────────────

    @Test
    fun `frames keep stream names, payloads and order`() {
        val frames = listOf(
            "lxbox/cc/groups" to byteArrayOf(0, 1, 2, 3),
            EventFrames.REPLY to ByteArray(0),
            "lxbox/coreLog" to ByteArray(70_000) { (it % 127).toByte() },
        )
        val buf = ByteArrayOutputStream()
        DataOutputStream(buf).use { out -> frames.forEach { EventFrames.write(out, it.first, it.second) } }
        val input = DataInputStream(ByteArrayInputStream(buf.toByteArray()))
        for ((name, payload) in frames) {
            val (n, p) = EventFrames.read(input)
            assertEquals(name, n)
            assertArrayEquals(payload, p)
        }
        try {
            EventFrames.read(input)
            fail("expected end of stream")
        } catch (_: EOFException) {
        }
    }

    @Test
    fun `frame with absurd length ends the stream`() {
        val buf = ByteArrayOutputStream()
        DataOutputStream(buf).use { it.writeInt(-5) }
        try {
            EventFrames.read(DataInputStream(ByteArrayInputStream(buf.toByteArray())))
            fail("expected end of stream")
        } catch (_: EOFException) {
        }
    }

    // ───────────── очереди канала событий ─────────────

    @Test
    fun `a newer snapshot replaces the waiting one`() {
        val q = PipeQueues()
        q.latest("lxbox/cc/groups", "g1")
        q.latest("lxbox/cc/status", "s1")
        q.latest("lxbox/cc/groups", "g2")
        // Отставший читатель получает по одному снимку на поток — свежему.
        assertEquals("lxbox/cc/groups" to "g2", q.next())
        assertEquals("lxbox/cc/status" to "s1", q.next())
        assertNull(q.next())
        assertTrue(q.isEmpty)
    }

    @Test
    fun `replies go first and are never dropped`() {
        val q = PipeQueues(eventsMax = 2, logMax = 2)
        q.log("l1")
        q.latest("lxbox/cc/status", "s")
        q.event("lxbox/cc/dns", "e1")
        repeat(1000) { q.reliable(EventFrames.REPLY, it) }
        for (i in 0 until 1000) assertEquals(EventFrames.REPLY to i, q.next())
        assertEquals("lxbox/cc/dns" to "e1", q.next())
        assertEquals("lxbox/cc/status" to "s", q.next())
        assertEquals(BgEventPipe.STREAM_LOG to listOf("l1"), q.next())
        assertEquals(0L, q.dropped)
    }

    @Test
    fun `events and log are bounded when nobody reads`() {
        val q = PipeQueues(eventsMax = 3, logMax = 5, logBatchMax = 4)
        repeat(10) { q.event("lxbox/cc/dns", it) }
        repeat(10) { q.log("line $it") }
        assertEquals(12L, q.dropped)
        assertEquals("lxbox/cc/dns" to 0, q.next())
        assertEquals("lxbox/cc/dns" to 1, q.next())
        assertEquals("lxbox/cc/dns" to 2, q.next())
        // Лог уходит пачками.
        assertEquals(BgEventPipe.STREAM_LOG to listOf("line 0", "line 1", "line 2", "line 3"), q.next())
        assertEquals(BgEventPipe.STREAM_LOG to listOf("line 4"), q.next())
        assertNull(q.next())
    }

    @Test
    fun `an unsubscribed stream is forgotten`() {
        val q = PipeQueues()
        q.latest("lxbox/cc/groups", "g")
        q.event("lxbox/cc/dns", "d")
        q.event("lxbox/cc/connection_test", "t")
        q.log("l")
        q.forget("lxbox/cc/groups")
        q.forget("lxbox/cc/dns")
        q.forget(BgEventPipe.STREAM_LOG)
        assertEquals("lxbox/cc/connection_test" to "t", q.next())
        assertNull(q.next())
    }

    // ───────────── копия состояния туннеля в окне ─────────────

    private fun wire(epoch: Long, seq: Long, status: VpnStatus, started: Long = 0L) =
        TunnelState.Wire(epoch, seq, TunnelState.Snapshot(status = status, startedElapsedMs = started))

    @Test
    fun `mirror takes newer snapshots only`() {
        assertTrue(TunnelState.acceptMirror(wire(10, 3, VpnStatus.Started, started = 77)))
        assertEquals(VpnStatus.Started, TunnelState.status)
        assertEquals(77L, TunnelState.startedElapsedMs)
        // Ответ вызова, обогнанный broadcast'ом: тот же или меньший номер.
        assertFalse(TunnelState.acceptMirror(wire(10, 3, VpnStatus.Stopped)))
        assertFalse(TunnelState.acceptMirror(wire(10, 2, VpnStatus.Stopped)))
        assertEquals(VpnStatus.Started, TunnelState.status)
        assertTrue(TunnelState.acceptMirror(wire(10, 4, VpnStatus.Stopping, started = 77)))
        assertEquals(VpnStatus.Stopping, TunnelState.status)
    }

    @Test
    fun `mirror takes a restarted owner with a small sequence`() {
        assertTrue(TunnelState.acceptMirror(wire(10, 40, VpnStatus.Started, started = 5)))
        // Перезапущенный `:bg`: метка запуска больше, счёт записей с нуля.
        assertTrue(TunnelState.acceptMirror(wire(20, 0, VpnStatus.Stopped)))
        assertEquals(VpnStatus.Stopped, TunnelState.status)
        // Запоздавший снимок прежнего процесса не возвращает прежнее.
        assertFalse(TunnelState.acceptMirror(wire(10, 41, VpnStatus.Started)))
        assertEquals(VpnStatus.Stopped, TunnelState.status)
    }

    @Test
    fun `owner wire grows with every write`() {
        TunnelState.clock = { 500L }
        val a = TunnelState.wire()
        TunnelState.setStatus(VpnStatus.Starting)
        val b = TunnelState.wire()
        TunnelState.setSessionAllowBypass(true)
        val c = TunnelState.wire()
        assertEquals(a.epoch, b.epoch)
        assertTrue(b.seq > a.seq)
        assertTrue(c.seq > b.seq)
        assertEquals(VpnStatus.Starting, c.snapshot.status)
        assertTrue(c.snapshot.sessionAllowBypass)
    }

    // ───────────── завершение `:bg` ─────────────

    private val idle = BgExitState(
        tunnelStopped = true,
        serviceAlive = false,
        uiAttached = false,
        nativeWindows = 0,
        holds = 0,
        activeCalls = 0,
        taildropBusy = false,
        watchdogPending = false,
        probeActive = false,
        startPending = false,
    )

    @Test
    fun `bg exits when nothing needs it`() {
        assertTrue(bgMayExit(idle))
    }

    @Test
    fun `every reason alone keeps bg alive`() {
        assertFalse(bgMayExit(idle.copy(tunnelStopped = false)))
        assertFalse(bgMayExit(idle.copy(serviceAlive = true)))
        assertFalse(bgMayExit(idle.copy(uiAttached = true)))
        assertFalse(bgMayExit(idle.copy(nativeWindows = 1)))
        assertFalse(bgMayExit(idle.copy(holds = 1)))
        assertFalse(bgMayExit(idle.copy(activeCalls = 1)))
        assertFalse(bgMayExit(idle.copy(taildropBusy = true)))
        assertFalse(bgMayExit(idle.copy(watchdogPending = true)))
        assertFalse(bgMayExit(idle.copy(probeActive = true)))
        assertFalse(bgMayExit(idle.copy(startPending = true)))
    }

    // ───────────── роль процесса ─────────────

    @Test
    fun `process role comes from the name suffix`() {
        assertEquals(ProcessRole.Role.Ui, ProcessRole.roleOf("com.leadaxe.lxbox:ui"))
        assertEquals(ProcessRole.Role.Bg, ProcessRole.roleOf("com.leadaxe.lxbox:bg"))
        assertEquals(ProcessRole.Role.Unnamed, ProcessRole.roleOf("com.leadaxe.lxbox"))
        assertEquals(ProcessRole.Role.Unnamed, ProcessRole.roleOf(""))
        assertEquals(ProcessRole.Role.Unnamed, ProcessRole.roleOf(null))
    }
}
