package com.leadaxe.lxbox.vpn

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.Random

/// §707 итер. 7 — чистая логика окна «Send clipboard»: сборщик служебного
/// файла по реестру (имя, тело, предел), «ссылка целиком», ленты (50 на
/// устройство, очистка при остановке VPN), получатели по снимку ядра.
class TaildropClipTest {

    private val spec: TaildropServiceFiles.Spec by lazy {
        val raw = File("../../assets/contract/registry/service_files.json").readText()
        TaildropServiceFiles.parseSpec(raw) ?: error("registry not parsed")
    }

    /// 2026-11-02T14:30:05Z.
    private val now = 1793629805000L

    @Test
    fun buildNameAndBodyFollowTheRegistry() {
        val cmds = JSONArray().put(TaildropServiceFiles.command("clipboard", "copied"))
        val b = TaildropServiceFiles.build(spec, cmds, now, Random(1)) as TaildropServiceFiles.Built.Ok
        assertTrue(b.name, Regex("""^lx-20261102T143005Z-[a-z0-9]{5}\.json$""").matches(b.name))
        val body = JSONObject(String(b.bytes, Charsets.UTF_8))
        assertEquals(1, body.getInt("lx"))
        val c = body.getJSONArray("commands").getJSONObject(0)
        assertEquals("clipboard", c.getString("kind"))
        assertEquals("copied", c.getString("text"))
        // Разбор получателя (итерация 4) принимает то, что собрал отправитель.
        assertEquals(1, TaildropServiceFiles.parseBody(spec, b.bytes)?.size)
        assertTrue(TaildropServiceFiles.isCandidate(spec, b.name))
    }

    /// Контракт 1.1.154 (TASKS_LXBOX §150): `lx` строкой, дробью или вне
    /// `versions` — обычный файл, не служебный.
    @Test
    fun lxNotAnIntegerVersionIsAnOrdinaryFile() {
        for (lx in listOf("\"1\"", "1.5", "99", "null")) {
            val raw = """{"lx":$lx,"commands":[{"kind":"clipboard","text":"x"}]}"""
            assertNull(lx, TaildropServiceFiles.parseBody(spec, raw.toByteArray(Charsets.UTF_8)))
        }
    }

    @Test
    fun labelsDifferBetweenFiles() {
        val cmds = JSONArray().put(TaildropServiceFiles.command("open_url", "https://ya.ru"))
        val r = Random(7)
        val names = (1..20).map {
            (TaildropServiceFiles.build(spec, cmds, now, r) as TaildropServiceFiles.Built.Ok).name
        }.toSet()
        assertEquals(20, names.size)
        val url = (TaildropServiceFiles.build(spec, cmds, now, r) as TaildropServiceFiles.Built.Ok).bytes
        val c = JSONObject(String(url, Charsets.UTF_8)).getJSONArray("commands").getJSONObject(0)
        assertEquals("https://ya.ru", c.getString("url"))
    }

    @Test
    fun bodyOverMaxBytesIsRefused() {
        val text = "x".repeat(spec.maxBytes.toInt())
        val cmds = JSONArray().put(TaildropServiceFiles.command("clipboard", text))
        val b = TaildropServiceFiles.build(spec, cmds, now, Random(1))
        assertTrue(b is TaildropServiceFiles.Built.TooLarge)
        assertEquals(spec.maxBytes, (b as TaildropServiceFiles.Built.TooLarge).maxBytes)
        assertTrue(TaildropClip.bodySize(spec, "clipboard", text) > spec.maxBytes)
        assertTrue(TaildropClip.bodySize(spec, "clipboard", "short") <= spec.maxBytes)
    }

    @Test
    fun singleUrlOnlyForOneWholeHttpLink() {
        val schemes = spec.kinds["open_url"]?.schemes
        assertEquals("https://ya.ru", TaildropServiceFiles.singleUrl("https://ya.ru", schemes))
        assertEquals("http://a.b/c?d=1", TaildropServiceFiles.singleUrl("  http://a.b/c?d=1\n", schemes))
        assertEquals("HTTPS://YA.RU", TaildropServiceFiles.singleUrl("HTTPS://YA.RU", schemes))
        assertNull(TaildropServiceFiles.singleUrl("https://ya.ru and more", schemes))
        assertNull(TaildropServiceFiles.singleUrl("see https://ya.ru", schemes))
        assertNull(TaildropServiceFiles.singleUrl("https://a\tb", schemes))
        assertNull(TaildropServiceFiles.singleUrl("ftp://ya.ru", schemes))
        assertNull(TaildropServiceFiles.singleUrl("intent://x", schemes))
        assertNull(TaildropServiceFiles.singleUrl("ya.ru", schemes))
        assertNull(TaildropServiceFiles.singleUrl("https://", schemes))
        assertNull(TaildropServiceFiles.singleUrl("http:///path", schemes))
        assertNull(TaildropServiceFiles.singleUrl("", schemes))
        assertNull(TaildropServiceFiles.singleUrl("https://ya.ru", null))
    }

    private fun msg(id: Long) = ClipMessage(id, true, "clipboard", "t$id", id, "sending")

    @Test
    fun feedKeepsLast50PerDevice() {
        val f = ClipFeeds()
        for (i in 1L..60L) f.add("ts", "nA", msg(i))
        f.add("ts", "nB", msg(100))
        f.add("other", "nA", msg(200))
        val a = f.messages("ts", "nA")
        assertEquals(50, a.size)
        assertEquals(11L, a.first().id)
        assertEquals(60L, a.last().id)
        assertEquals(1, f.messages("ts", "nB").size)
        assertEquals(1, f.messages("other", "nA").size)

        assertTrue(f.update("ts", "nA", 60L, "sent", null))
        assertEquals("sent", f.messages("ts", "nA").last().status)
        assertFalse(f.update("ts", "nA", 1L, "sent", null)) // обрезано

        f.clear("ts", "nA")
        assertTrue(f.messages("ts", "nA").isEmpty())
        assertEquals(1, f.messages("ts", "nB").size)
    }

    @Test
    fun vpnStopClearsAllFeeds() {
        TaildropClip.feeds.add("ts", "nA", msg(1))
        TaildropClip.feeds.add("ts2", "nB", msg(2))
        assertEquals(2, TaildropClip.feeds.counts().size)
        TaildropClip.onVpnStopped(null)
        assertTrue(TaildropClip.feeds.counts().isEmpty())
        assertTrue(TaildropClip.feeds.messages("ts", "nA").isEmpty())
        assertFalse(TaildropClip.available)
    }

    @Test
    fun taildropNodeInConfig() {
        assertTrue(TaildropClip.hasTaildropNode("""{"endpoints":[{"type":"tailscale","tag":"a"}]}"""))
        assertTrue(TaildropClip.hasTaildropNode(
            """{"endpoints":[{"type":"tailscale","tag":"a","disable_taildrop":true},
               {"type":"tailscale","tag":"b","disable_taildrop":false}]}""",
        ))
        assertFalse(TaildropClip.hasTaildropNode(
            """{"endpoints":[{"type":"tailscale","tag":"a","disable_taildrop":true},{"type":"wireguard"}]}""",
        ))
        assertFalse(TaildropClip.hasTaildropNode("""{"outbounds":[]}"""))
        assertFalse(TaildropClip.hasTaildropNode(""))
    }

    private fun peer(id: String, name: String, online: Boolean = true, receive: Boolean = true, sharee: Boolean = false) =
        mapOf<String, Any>(
            "stable_id" to id, "host_name" to name, "online" to online,
            "can_receive_files" to receive, "sharee_node" to sharee,
        )

    private fun node(tag: String, vararg peers: Map<String, Any>, state: String = "Running") =
        mapOf<String, Any>(
            "tag" to tag, "backend_state" to state, "can_share_files" to true,
            "user_groups" to listOf(mapOf("peers" to peers.toList())),
        )

    @Test
    fun targetsAndRefusalsInSpecOrder() {
        assertEquals(TaildropClip.BLOCK_NEED_VPN, TaildropClip.targets(null, emptySet()).block)
        assertEquals(
            TaildropClip.BLOCK_NEED_VPN,
            TaildropClip.targets(listOf(node("a", state = "NeedsLogin")), emptySet()).block,
        )
        assertEquals(
            TaildropClip.BLOCK_TAILDROP_OFF,
            TaildropClip.targets(listOf(node("a", peer("n1", "pc"))), setOf("a")).block,
        )
        assertEquals(
            TaildropClip.BLOCK_NO_DEVICES,
            TaildropClip.targets(
                listOf(node("a", peer("n1", "pc", receive = false), peer("n2", "tv", sharee = true))),
                emptySet(),
            ).block,
        )
        val r = TaildropClip.targets(
            listOf(
                node("a", peer("n1", "Zeta"), peer("n2", "alpha", online = false)),
                node("b", peer("n3", "beta")),
            ),
            emptySet(),
        )
        assertNull(r.block)
        assertEquals(listOf("beta", "Zeta"), r.online.map { it.name })
        assertEquals(listOf("alpha", "beta", "Zeta"), r.all.map { it.name })
        assertEquals("b", r.online.first().tag)
    }
}
