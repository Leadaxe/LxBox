package com.leadaxe.lxbox.vpn

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
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
/// вызова, кадры потока лога, копия состояния туннеля, гейт пробы, условия
/// завершения `:bg`, роль процесса. Без Android.
class BgBoundaryTest {

    private lateinit var savedClock: () -> Long

    @Before
    fun setUp() {
        savedClock = TunnelState.clock
        TunnelState.resetForTest()
        ProbeGate.end()
    }

    @After
    fun tearDown() {
        TunnelState.resetForTest()
        TunnelState.clock = savedClock
        ProbeGate.end()
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
        assertEquals(0, BgCodec.encode(null).size)
        assertNull(BgCodec.decode(BgCodec.encode(null)))
        assertNull(BgCodec.decode(null))
    }

    @Test
    fun `codec keeps a bare scalar result`() {
        assertEquals(false, BgCodec.decode(BgCodec.encode(false)))
        assertEquals("x", BgCodec.decode(BgCodec.encode("x")))
        assertEquals(0L, BgCodec.decode(BgCodec.encode(0L)))
    }

    // ───────────── кадры лога ─────────────

    @Test
    fun `log frames keep multiline lines and order`() {
        val lines = listOf("INFO one", "panic:\n  goroutine 1\n  main.go:1", "", "WARN юникод")
        val buf = ByteArrayOutputStream()
        DataOutputStream(buf).use { out -> lines.forEach { LogFrames.write(out, it) } }
        val input = DataInputStream(ByteArrayInputStream(buf.toByteArray()))
        assertEquals(lines, List(lines.size) { LogFrames.read(input) })
        try {
            LogFrames.read(input)
            fail("expected end of stream")
        } catch (_: EOFException) {
        }
    }

    @Test
    fun `log frame with absurd length ends the stream`() {
        val buf = ByteArrayOutputStream()
        DataOutputStream(buf).use { it.writeInt(-5) }
        try {
            LogFrames.read(DataInputStream(ByteArrayInputStream(buf.toByteArray())))
            fail("expected end of stream")
        } catch (_: EOFException) {
        }
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

    // ───────────── гейт пробы ─────────────

    @Test
    fun `probe is refused while the tunnel is not stopped`() {
        assertFalse(ProbeGate.begin(tunnelStopped = false))
        assertFalse(ProbeGate.isActive)
        assertTrue(ProbeGate.begin(tunnelStopped = true))
        assertTrue(ProbeGate.isActive)
        ProbeGate.end()
        assertFalse(ProbeGate.isActive)
    }

    @Test
    fun `tunnel start does not wait when no probe runs`() {
        assertTrue(ProbeGate.awaitIdle(2000))
    }

    @Test
    fun `tunnel start waits for the probe to end`() {
        assertTrue(ProbeGate.begin(tunnelStopped = true))
        val waiting = CountDownLatch(1)
        val done = CountDownLatch(1)
        var result = false
        Thread {
            waiting.countDown()
            result = ProbeGate.awaitIdle(10_000)
            done.countDown()
        }.start()
        assertTrue(waiting.await(5, TimeUnit.SECONDS))
        ProbeGate.end()
        assertTrue(done.await(5, TimeUnit.SECONDS))
        assertTrue(result)
    }

    @Test
    fun `tunnel start gives up on a probe that never ends`() {
        assertTrue(ProbeGate.begin(tunnelStopped = true))
        // Часы теста: срок уже вышел к первой проверке.
        var t = 0L
        assertFalse(ProbeGate.awaitIdle(2000) { t.also { t += 3_000_000_000L } })
        // Отметка снята силой: следующий старт не ждёт.
        assertFalse(ProbeGate.isActive)
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
