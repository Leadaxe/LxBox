package com.leadaxe.lxbox.vpn

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.Toast
import com.leadaxe.lxbox.R

/// §707 — цель системного «Поделиться» (файлы или текст) для Taildrop.
///
/// Отдельная активность без Flutter: MainActivity не трогается. Экран —
/// цепочка системных диалогов: узел Tailscale (если работающих несколько)
/// → устройство → передача уходит в [Taildrop.send] и активность
/// закрывается; прогресс — в уведомлении. VPN выключен или нет работающего
/// узла — причина и Close, ничего не откладывается (P7).
class TaildropShareActivity : Activity() {

    private val uris = ArrayList<Uri>()
    private var text: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        readIntent(intent)
        if (uris.isEmpty() && text.isNullOrEmpty()) {
            toast(L10n.str(this, R.string.taildrop_nothing_to_send))
            finish()
            return
        }
        val cc = BoxService.commandClient
        if (BoxVpnService.currentStatus != VpnStatus.Started || cc == null) {
            message(L10n.str(this, R.string.taildrop_need_vpn))
            return
        }
        Thread {
            val snapshot = runCatching { cc.tailscaleSnapshot(4000) }.getOrNull()
            // §707 итер. 4 — узлы с выключенным Taildrop не предлагаются.
            val off = runCatching { Taildrop.taildropOffTags(ConfigManager.load()) }.getOrDefault(emptySet())
            runOnUiThread { if (!isFinishing) onSnapshot(snapshot, off) }
        }.start()
    }

    @Suppress("DEPRECATION")
    private fun readIntent(intent: Intent?) {
        intent ?: return
        when (intent.action) {
            Intent.ACTION_SEND -> {
                val stream = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                if (stream != null) {
                    uris.add(stream)
                } else {
                    text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
                }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                    ?.filterNotNull()?.let { uris.addAll(it) }
            }
        }
        if (uris.isEmpty() && text == null) {
            val clip = intent.clipData ?: return
            for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let { uris.add(it) }
        }
    }

    private fun onSnapshot(snapshot: List<Map<String, Any>>?, off: Set<String>) {
        val running = snapshot.orEmpty().filter { it["backend_state"] == "Running" }
        val nodes = running.filter { "${it["tag"] ?: ""}" !in off }
        when {
            running.isNotEmpty() && nodes.isEmpty() -> message(L10n.str(this, R.string.taildrop_off_all))
            nodes.isEmpty() -> message(L10n.str(this, R.string.taildrop_need_vpn))
            nodes.size == 1 -> onNode(nodes.first())
            else -> {
                val labels = nodes.map { "${it["tag"] ?: ""}" }.toTypedArray()
                dialog()
                    .setTitle(L10n.str(this, R.string.taildrop_choose_node))
                    .setItems(labels) { _, which -> onNode(nodes[which]) }
                    .show()
            }
        }
    }

    private fun onNode(node: Map<String, Any>) {
        if (node["can_share_files"] == false) {
            message(L10n.str(this, R.string.taildrop_sharing_off))
            return
        }
        val tag = "${node["tag"] ?: ""}"
        val peers = taildropTargets(node)
        if (peers.isEmpty()) {
            message(L10n.str(this, R.string.taildrop_no_devices))
            return
        }
        val labels = peers.map { "${it["host_name"] ?: ""}" }.toTypedArray()
        dialog()
            .setTitle(L10n.str(this, R.string.taildrop_send_to))
            .setItems(labels) { _, which -> onPeer(tag, peers[which]) }
            .show()
    }

    private fun onPeer(tag: String, peer: Map<String, Any>) {
        val items = text?.let { listOf(Taildrop.noteItem(it)) } ?: Taildrop.openUris(this, uris)
        if (items.isEmpty()) {
            message(L10n.str(this, R.string.taildrop_reason_cant_read))
            return
        }
        val ok = Taildrop.send(
            this, tag, "${peer["stable_id"] ?: ""}", "${peer["host_name"] ?: ""}", items,
        )
        if (!ok) {
            message(L10n.str(this, R.string.taildrop_need_vpn))
            return
        }
        finish()
    }

    private fun dialog(): AlertDialog.Builder =
        AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
            .setOnCancelListener { finish() }

    private fun message(text: String) {
        dialog()
            .setTitle(L10n.str(this, R.string.taildrop_share_label))
            .setMessage(text)
            .setPositiveButton(L10n.str(this, R.string.taildrop_close)) { _, _ -> finish() }
            .show()
    }

    private fun toast(text: String) {
        Toast.makeText(applicationContext, text, Toast.LENGTH_SHORT).show()
    }

    companion object {
        /// Устройства, которым можно отправить: в сети, принимают файлы
        /// (ядро уже учло, что они свои и право есть) и не расшарены извне.
        /// По имени.
        @Suppress("UNCHECKED_CAST")
        fun taildropTargets(node: Map<String, Any>): List<Map<String, Any>> {
            val groups = node["user_groups"] as? List<Map<String, Any>> ?: return emptyList()
            return groups.flatMap { (it["peers"] as? List<Map<String, Any>>).orEmpty() }
                .filter {
                    it["online"] == true && it["can_receive_files"] == true &&
                        it["sharee_node"] != true
                }
                .sortedBy { "${it["host_name"] ?: ""}".lowercase() }
        }
    }
}
