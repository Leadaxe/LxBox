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

    @Test
    fun `an unencodable reply becomes an error reply, other frames are dropped`() {
        val cause = IllegalArgumentException("Unsupported value")
        val bytes = BgEventPipe.unencodable(EventFrames.REPLY, mapOf("id" to 42L, "r" to Any()), cause)!!
        val m = BgCodec.decode(bytes) as Map<*, *>
        assertEquals(42L, (m["id"] as Number).toLong())
        assertEquals(BgControlProvider.ERROR_CALL_FAILED, m["ec"])
        assertFalse(m.containsKey("r"))
        // Событие потока Dart просто теряется; ответ без номера — тоже.
        assertNull(BgEventPipe.unencodable("lxbox/cc/groups", Any(), cause))
        assertNull(BgEventPipe.unencodable(EventFrames.REPLY, mapOf("r" to 1), cause))
    }

    @Test
    fun `only old parcels are orphans`() {
        val now = 1_000_000_000L
        val tenMin = BgControlProvider.XFER_ORPHAN_MS
        // Свежая посылка может принадлежать вызову в пути.
        assertFalse(BgControlProvider.xferOrphan(now - 1_000, now, tenMin))
        assertFalse(BgControlProvider.xferOrphan(now, now, tenMin))
        assertTrue(BgControlProvider.xferOrphan(now - tenMin, now, tenMin))
        assertTrue(BgControlProvider.xferOrphan(now - 3 * tenMin, now, tenMin))
        // Время изменения далеко в будущем (перевели часы) — тоже сирота.
        assertTrue(BgControlProvider.xferOrphan(now + 2 * tenMin, now, tenMin))
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

    @Test
    fun `revoked mark survives a new owner process until the next start`() {
        // Новый процесс `:bg`: состояние с нуля, метка — из сохранённого.
        TunnelState.clock = { 700L }
        TunnelState.restoreRevoked()
        assertEquals(VpnStatus.Stopped, TunnelState.status)
        assertTrue(TunnelState.revoked)
        val restored = TunnelState.wire()
        assertTrue(restored.snapshot.revoked)
        // Старт туннеля метку снимает, как и раньше.
        TunnelState.setStatus(VpnStatus.Starting)
        assertFalse(TunnelState.revoked)
        // При идущем туннеле восстановление ничего не делает.
        TunnelState.restoreRevoked()
        assertFalse(TunnelState.revoked)
        // Обычный Stopped без отзыва — без метки; отзыв — с меткой.
        TunnelState.setStatus(VpnStatus.Stopped)
        assertFalse(TunnelState.revoked)
        TunnelState.setStatus(VpnStatus.Stopped, revoked = true)
        assertTrue(TunnelState.revoked)
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
        pendingReplies = false,
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
        assertFalse(bgMayExit(idle.copy(pendingReplies = true)))
    }

    @Test
    fun `veto names every reason that holds the process`() {
        assertTrue(bgExitVeto(idle).isEmpty())
        // Окно само в список не входит: под ним процесс перезапускается.
        assertTrue(bgExitVeto(idle.copy(uiAttached = true)).isEmpty())
        assertEquals(listOf("start-pending"), bgExitVeto(idle.copy(startPending = true)))
        assertEquals(
            listOf("tunnel-not-stopped", "service-alive", "calls=2"),
            bgExitVeto(idle.copy(tunnelStopped = false, serviceAlive = true, activeCalls = 2)),
        )
        // Список пуст ровно тогда, когда процесс без окна может завершиться.
        val reasons = listOf(
            idle.copy(tunnelStopped = false), idle.copy(serviceAlive = true),
            idle.copy(startPending = true), idle.copy(activeCalls = 1),
            idle.copy(pendingReplies = true), idle.copy(probeActive = true),
            idle.copy(taildropBusy = true), idle.copy(nativeWindows = 1),
            idle.copy(holds = 1), idle.copy(watchdogPending = true),
        )
        for (s in reasons) {
            assertFalse(bgMayExit(s))
            assertEquals(1, bgExitVeto(s).size)
        }
    }

    @Test
    fun `a start on its way holds the process with and without the window`() {
        // Команда старта принята, сервис ещё не создан: ни завершения, ни
        // перезапуска ради ядра — иначе старт ушёл бы в умирающий процесс.
        val starting = idle.copy(startPending = true)
        assertFalse(bgMayExit(starting))
        assertFalse(bgMayRecycle(starting.copy(uiAttached = true), true, BgLifecycle.CORE_IDLE_MS))
        // Сервис создан — пометка снята, держит уже сам сервис.
        val created = idle.copy(serviceAlive = true)
        assertFalse(bgMayExit(created))
        assertFalse(bgMayRecycle(created.copy(uiAttached = true), true, BgLifecycle.CORE_IDLE_MS))
    }

    // ───────────── перезапуск `:bg` под открытым окном ─────────────

    private val underWindow = idle.copy(uiAttached = true)
    private val longIdle = BgLifecycle.CORE_IDLE_MS

    @Test
    fun `bg restarts under the window only to drop a loaded idle core`() {
        assertTrue(bgMayRecycle(underWindow, coreLoaded = true, coreIdleMs = longIdle))
        // Ядро не загружено — перезапускаться незачем.
        assertFalse(bgMayRecycle(underWindow, coreLoaded = false, coreIdleMs = longIdle))
        // Ядром только что пользовались без туннеля (проба, проверка конфига).
        assertFalse(bgMayRecycle(underWindow, coreLoaded = true, coreIdleMs = longIdle - 1))
        // Без окна это обычное завершение, а не перезапуск.
        assertFalse(bgMayRecycle(idle, coreLoaded = true, coreIdleMs = longIdle))
        assertTrue(bgMayExit(idle))
    }

    @Test
    fun `a new tunnel start cancels the restart`() {
        // Команда старта отправлена, сервис ещё не создан.
        assertFalse(bgMayRecycle(underWindow.copy(startPending = true), true, longIdle))
        // Сервис создан, туннель поднимается.
        assertFalse(bgMayRecycle(underWindow.copy(serviceAlive = true), true, longIdle))
        assertFalse(bgMayRecycle(underWindow.copy(tunnelStopped = false), true, longIdle))
    }

    @Test
    fun `every other reason to live cancels the restart`() {
        assertFalse(bgMayRecycle(underWindow.copy(probeActive = true), true, longIdle))
        assertFalse(bgMayRecycle(underWindow.copy(nativeWindows = 1), true, longIdle))
        assertFalse(bgMayRecycle(underWindow.copy(taildropBusy = true), true, longIdle))
        assertFalse(bgMayRecycle(underWindow.copy(activeCalls = 1), true, longIdle))
        assertFalse(bgMayRecycle(underWindow.copy(pendingReplies = true), true, longIdle))
        assertFalse(bgMayRecycle(underWindow.copy(holds = 1), true, longIdle))
        assertFalse(bgMayRecycle(underWindow.copy(watchdogPending = true), true, longIdle))
    }

    @Test
    fun `pipe reports replies that are not written yet`() {
        val q = PipeQueues()
        assertFalse(q.hasReliable)
        q.latest("lxbox/cc/status", "s")
        q.log("l")
        assertFalse(q.hasReliable)
        q.reliable(EventFrames.REPLY, 1)
        assertTrue(q.hasReliable)
        q.next()
        assertFalse(q.hasReliable)
    }

    // ───────────── удержание процесса окна ─────────────

    @Test
    fun `the window is held only while the tunnel is not stopped and the window is attached`() {
        for (status in listOf(VpnStatus.Starting, VpnStatus.Started, VpnStatus.Stopping)) {
            assertTrue(uiHoldWanted(status, uiAttached = true))
            // Окна нет (закрыто, не открывалось) — держать и воскрешать нечего.
            assertFalse(uiHoldWanted(status, uiAttached = false))
        }
        // Туннель остановлен: удержания нет — окно завершается по закрытию,
        // а `:bg` под ним может перезапуститься.
        assertFalse(uiHoldWanted(VpnStatus.Stopped, uiAttached = true))
        assertFalse(uiHoldWanted(VpnStatus.Stopped, uiAttached = false))
    }

    @Test
    fun `a call to the window holds it even with the tunnel stopped`() {
        assertTrue(uiHoldWanted(VpnStatus.Stopped, uiAttached = true, pendingCalls = 1))
        assertFalse(uiHoldWanted(VpnStatus.Stopped, uiAttached = true, pendingCalls = 0))
        // Окна нет — держать нечего, вызов его не поднимает.
        assertFalse(uiHoldWanted(VpnStatus.Stopped, uiAttached = false, pendingCalls = 1))
    }

    // ───────────── обратный вызов `:bg` → Dart ─────────────

    @Test
    fun `a reply reaches the call with its number only`() {
        val calls = PendingCalls<String>()
        val (id1, e1) = calls.open()
        val (id2, e2) = calls.open()
        assertTrue(id1 != id2)
        assertTrue(calls.complete(id2, "two"))
        assertTrue(e2.result.isCompleted)
        assertFalse(e1.result.isCompleted)
        assertEquals(1, calls.size)
        // Чужой и повторный номер никому не достаётся.
        assertFalse(calls.complete(999L, "x"))
        assertFalse(calls.complete(id2, "again"))
        assertTrue(calls.complete(id1, "one"))
        assertEquals(0, calls.size)
    }

    @Test
    fun `ack tells a live window from a silent one`() {
        val calls = PendingCalls<String>()
        val (id, e) = calls.open()
        assertFalse(e.acked.isCompleted)
        assertTrue(calls.ack(id))
        assertTrue(e.acked.isCompleted)
        assertFalse(e.result.isCompleted)
        // Ответ без отдельного подтверждения тоже значит «окно живо».
        val (id2, e2) = calls.open()
        assertTrue(calls.complete(id2, "r"))
        assertTrue(e2.acked.isCompleted)
        assertFalse(calls.ack(424242L))
    }

    @Test
    fun `a reply after the timeout is dropped`() {
        val calls = PendingCalls<String>()
        val (id, e) = calls.open()
        val waited = kotlinx.coroutines.runBlocking {
            kotlinx.coroutines.withTimeoutOrNull(20L) { e.result.await() }
        }
        assertNull(waited)
        // Вызывающий сдался и снял запись: запоздавший ответ никому не нужен.
        calls.close(id)
        assertFalse(calls.complete(id, "late"))
        assertFalse(calls.ack(id))
        assertEquals(0, calls.size)
    }

    // ───────────── остановка сервиса и новый старт ─────────────

    @Test
    fun `a stop does not take down a start requested after it`() {
        val ledger = StartLedger()
        ledger.delivered(1)
        val gen = ledger.begin()
        // Туннель поколения 1 остановлен; новый старт (2) запрошен у системы,
        // но сервису ещё не доставлен.
        val token = ledger.stopToken()
        assertEquals(1, token)
        assertFalse(StartLedger.systemStops(token, lastRequested = 2))
        // Нового старта нет — остановка исполняется.
        assertTrue(StartLedger.systemStops(token, lastRequested = 1))
        assertTrue(ledger.owns(gen))
    }

    @Test
    fun `a stop covers the starts the service received but ignored`() {
        val ledger = StartLedger()
        ledger.delivered(1)
        ledger.begin()
        // Во время остановки пришёл старт 2: сервис его принял (обещание
        // foreground выполнено) и не стал исполнять. Остановка сносит и его —
        // иначе сервис остался бы запущенным без туннеля.
        ledger.delivered(2)
        assertEquals(2, ledger.stopToken())
        assertTrue(StartLedger.systemStops(ledger.stopToken(), lastRequested = 2))
        // А старт 3, запрошенный уже после, — нет.
        assertFalse(StartLedger.systemStops(ledger.stopToken(), lastRequested = 3))
        // Номера приходят по возрастанию; запоздавший меньший ничего не меняет.
        ledger.delivered(1)
        assertEquals(2, ledger.stopToken())
    }

    @Test
    fun `a force-stop teardown of an older tunnel does not own a newer start`() {
        val ledger = StartLedger()
        ledger.delivered(1)
        val old = ledger.begin()
        assertTrue(ledger.owns(old))
        // Force-stop объявил Stopped и доводит закрытие в фоне; начался старт 2.
        ledger.delivered(2)
        val fresh = ledger.begin()
        assertFalse(ledger.owns(old))
        assertTrue(ledger.owns(fresh))
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
