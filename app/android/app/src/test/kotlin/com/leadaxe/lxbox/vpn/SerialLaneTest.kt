package com.leadaxe.lxbox.vpn

import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertTrue
import org.junit.Test

/// §732 — полоса блокирующих вызовов ядра и пауза реконнекта.
class SerialLaneTest {

    @Test
    fun `post returns at once while the task blocks on the lane thread`() {
        val lane = SerialLane("t-lane")
        val release = CountDownLatch(1)
        val started = CountDownLatch(1)
        var ran: Thread? = null
        val t0 = System.nanoTime()
        lane.post("block") {
            ran = Thread.currentThread()
            started.countDown()
            release.await(5, TimeUnit.SECONDS)
        }
        val postMs = (System.nanoTime() - t0) / 1_000_000
        assertTrue("task did not start", started.await(2, TimeUnit.SECONDS))
        // Вызывающий (в приложении — главный поток) не ждал задачу.
        assertTrue("post blocked for ${postMs}ms", postMs < 500)
        assertNotSame(Thread.currentThread(), ran)
        release.countDown()
    }

    @Test
    fun `tasks run one at a time in posting order`() {
        val lane = SerialLane("t-lane")
        val order = Collections.synchronizedList(ArrayList<Int>())
        val done = CountDownLatch(20)
        repeat(20) { i ->
            lane.post("n$i") {
                if (i % 5 == 0) Thread.sleep(20) // медленная не пропускает следующих
                order += i
                done.countDown()
            }
        }
        assertTrue(done.await(5, TimeUnit.SECONDS))
        assertEquals((0 until 20).toList(), order.toList())
    }

    @Test
    fun `a throwing task is reported and does not stop the lane`() {
        val errors = Collections.synchronizedList(ArrayList<String>())
        val lane = SerialLane("t-lane", onError = { label, _ -> errors += label })
        val done = CountDownLatch(1)
        lane.post("boom") { error("x") }
        lane.post("next") { done.countDown() }
        assertTrue(done.await(2, TimeUnit.SECONDS))
        assertEquals(listOf("boom"), errors.toList())
    }

    @Test
    fun `a slow task is named while it hangs and again when it returns`() {
        val slow = Collections.synchronizedList(ArrayList<String>())
        val lane = SerialLane("t-lane", slowMs = 50, onSlow = { slow += it })
        val hanging = CountDownLatch(1)
        val done = CountDownLatch(1)
        lane.post("connect") {
            hanging.await(5, TimeUnit.SECONDS)
        }
        lane.post("after") { done.countDown() }
        Thread.sleep(200)
        // Вызов ещё висит, а строка о нём уже есть.
        assertEquals(1, slow.size)
        assertTrue(slow[0], slow[0].contains("t-lane: connect still running"))
        hanging.countDown()
        assertTrue(done.await(2, TimeUnit.SECONDS))
        assertEquals(2, slow.size)
        assertTrue(slow[1], slow[1].contains("t-lane: connect returned after"))
    }

    @Test
    fun `a fast task is not reported as slow`() {
        val slow = Collections.synchronizedList(ArrayList<String>())
        val lane = SerialLane("t-lane", slowMs = 500, onSlow = { slow += it })
        val done = CountDownLatch(1)
        lane.post("quick") { done.countDown() }
        assertTrue(done.await(2, TimeUnit.SECONDS))
        Thread.sleep(100)
        assertTrue(slow.isEmpty())
    }

    @Test
    fun `postDelayed runs after the delay`() {
        val lane = SerialLane("t-lane")
        val done = CountDownLatch(1)
        val t0 = System.nanoTime()
        lane.postDelayed("later", 150) { done.countDown() }
        assertTrue(done.await(2, TimeUnit.SECONDS))
        assertTrue((System.nanoTime() - t0) / 1_000_000 >= 140)
    }

    @Test
    fun `backoff doubles to the cap and resets`() {
        val b = ReconnectBackoff(500, 8_000)
        assertEquals(listOf(500L, 1_000L, 2_000L, 4_000L, 8_000L, 8_000L), List(6) { b.next() })
        b.reset()
        assertEquals(500L, b.next())
    }

    @Test
    fun `first connect failure is reported once per series even after a stream drop took the first delay`() {
        val b = ReconnectBackoff(500, 8_000)
        // Потеря сокета: сначала обрыв потока забирает первую паузу…
        assertEquals(500L, b.next())
        // …затем первый сбой подключения — о нём сообщить, о следующих нет.
        b.next()
        assertTrue(b.firstFailure())
        b.next()
        assertFalse(b.firstFailure())
        // Успех — новая серия.
        b.reset()
        assertTrue(b.firstFailure())
    }

    @Test
    fun `probe stops the network monitor only when the vpn service is fully stopped`() {
        assertTrue(probeMayStopMonitor(false, VpnStatus.Stopped))
        // Служба стартует: commandClient ещё null, монитор уже её.
        assertFalse(probeMayStopMonitor(false, VpnStatus.Starting))
        assertFalse(probeMayStopMonitor(false, VpnStatus.Stopping))
        assertFalse(probeMayStopMonitor(false, VpnStatus.Started))
        assertFalse(probeMayStopMonitor(true, VpnStatus.Started))
        assertFalse(probeMayStopMonitor(true, VpnStatus.Stopped))
    }
}
