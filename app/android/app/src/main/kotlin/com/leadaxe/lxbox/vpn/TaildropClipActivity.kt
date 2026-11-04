package com.leadaxe.lxbox.vpn

import android.app.Activity
import android.app.AlertDialog
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.Editable
import android.text.InputType
import android.text.TextUtils
import android.text.TextWatcher
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.PopupMenu
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import com.leadaxe.lxbox.R
import java.text.DateFormat
import java.util.Date

/// §707 итер. 7 — окно «Send clipboard»: переписка с устройством поверх
/// текущего приложения (диалоговая тема, нижняя половина экрана, своя
/// задача — главное окно L×Box не поднимается; без Flutter).
///
/// Поле заполняется текстом из буфера, когда окно получило фокус (Android
/// 10+ даёт читать буфер только окну на переднем плане), или тем, чем
/// поделились / что выделили (`EXTRA_TEXT`, `EXTRA_PROCESS_TEXT`). ➤ шлёт
/// команду `clipboard`, «Open on <device>» — `open_url` (если текст —
/// одна ссылка). Окно после отправки не закрывается.
class TaildropClipActivity : Activity() {

    companion object {
        const val EXTRA_TEXT = "clip_text"

        /// Сколько ждать снимок узлов ядра.
        private const val SNAPSHOT_TIMEOUT_MS = 4000L

        /// Пока окно на экране — пересчитывать получателей (устройство
        /// могло уйти из сети, VPN — остановиться).
        private const val REFRESH_MS = 10_000L

        fun intent(ctx: Context): Intent =
            Intent(ctx, TaildropClipActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }

    private lateinit var toView: TextView
    private lateinit var feedBox: LinearLayout
    private lateinit var scroll: ScrollView
    private lateinit var reasonView: TextView
    private lateinit var input: EditText
    private lateinit var sendView: TextView
    private lateinit var openButton: Button

    private val handler = Handler(Looper.getMainLooper())
    private var readClipOnFocus = false
    private var spec: TaildropServiceFiles.Spec? = null

    /// Последний снимок получателей; `null` — ещё не пришёл.
    private var targets: ClipTargets? = null
    private var selected: ClipTarget? = null
    private var refreshing = false

    private val feedListener = Runnable { renderFeed() }
    private val periodic = object : Runnable {
        override fun run() {
            refreshTargets()
            handler.postDelayed(this, REFRESH_MS)
        }
    }

    private val night: Boolean
        get() = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
            Configuration.UI_MODE_NIGHT_YES

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        spec = TaildropServiceFiles.spec(this)
        setContentView(buildContent())
        window.setGravity(Gravity.BOTTOM)
        window.setLayout(
            ViewGroup.LayoutParams.MATCH_PARENT,
            (resources.displayMetrics.heightPixels * 0.5).toInt(),
        )
        window.setSoftInputMode(
            WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE or
                WindowManager.LayoutParams.SOFT_INPUT_STATE_HIDDEN,
        )
        setFinishOnTouchOutside(true)
        handleIntent(intent)
        updateHeader()
        updateControls()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
        if (hasWindowFocus() && readClipOnFocus) {
            readClipOnFocus = false
            readClipboard()
        }
    }

    private fun handleIntent(intent: Intent?) {
        val given = intent?.getStringExtra(EXTRA_TEXT)
            ?: intent?.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
        if (given != null) {
            readClipOnFocus = false
            setInput(given)
        } else {
            readClipOnFocus = true
        }
    }

    override fun onResume() {
        super.onResume()
        TaildropClip.addListener(feedListener)
        renderFeed()
        handler.removeCallbacks(periodic)
        handler.post(periodic)
    }

    override fun onPause() {
        TaildropClip.removeListener(feedListener)
        handler.removeCallbacks(periodic)
        super.onPause()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && readClipOnFocus) {
            readClipOnFocus = false
            readClipboard()
        }
    }

    /// Только текст: пусто / не текст — поле пустое. Клип с
    /// `EXTRA_IS_SENSITIVE` показывается как любой (решение владельца
    /// 03.11.2026): отправка только по ➤.
    private fun readClipboard() {
        val text = runCatching {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clip = cm.primaryClip
            if (clip == null || clip.itemCount == 0 || !clip.description.hasMimeType("text/*")) null
            else clip.getItemAt(0).text?.toString()
        }.getOrNull()
        setInput(text ?: "")
    }

    private fun setInput(text: String) {
        input.setText(text)
        input.setSelection(input.text.length)
    }

    // ───────────────────────── получатели ─────────────────────────

    private fun refreshTargets() {
        if (refreshing) return
        refreshing = true
        Thread {
            val cc = BoxService.commandClient
            val r = if (BoxVpnService.currentStatus != VpnStatus.Started || cc == null) {
                TaildropClip.targets(null, emptySet())
            } else {
                val snapshot = runCatching { cc.tailscaleSnapshot(SNAPSHOT_TIMEOUT_MS) }.getOrNull()
                val off = runCatching { Taildrop.taildropOffTags(ConfigManager.load()) }
                    .getOrDefault(emptySet())
                TaildropClip.targets(snapshot, off)
            }
            runOnUiThread {
                refreshing = false
                if (!isFinishing) applyTargets(r)
            }
        }.start()
    }

    private fun applyTargets(r: ClipTargets) {
        targets = r
        val prev = selected
        var sel = prev?.let { p -> r.all.firstOrNull { it.tag == p.tag && it.peerId == p.peerId } }
        if (sel == null) {
            val rem = TaildropClip.remembered(this)
            sel = r.online.firstOrNull { rem != null && it.tag == rem.first && it.peerId == rem.second }
                ?: r.online.firstOrNull()
        }
        selected = sel
        updateHeader()
        if (prev?.tag != sel?.tag || prev?.peerId != sel?.peerId) renderFeed()
        updateControls()
    }

    /// Имя устройства; при нескольких узлах среди получателей — с узлом.
    private fun label(t: ClipTarget): String {
        val multi = targets?.online.orEmpty().map { it.tag }.distinct().size > 1
        return if (multi) "${t.name} · ${t.tag}" else t.name
    }

    private fun chooseTarget() {
        val list = targets?.online.orEmpty()
        if (list.isEmpty()) return
        AlertDialog.Builder(this)
            .setTitle(L10n.str(this, R.string.taildrop_send_to))
            .setItems(list.map { label(it) }.toTypedArray()) { _, which ->
                val t = list[which]
                selected = t
                TaildropClip.remember(this, t)
                updateHeader()
                renderFeed()
                updateControls()
            }
            .show()
    }

    // ───────────────────────── отправка ─────────────────────────

    /// Причина, по которой отправлять нельзя (по порядку таблицы спеки);
    /// `null` — можно (или поле пустое — тогда молча).
    private fun blockReason(text: String): String? {
        val r = targets ?: return null
        r.block?.let { return L10n.str(this, it) }
        val sel = selected ?: return L10n.str(this, R.string.clip_no_devices)
        if (!sel.online) return L10n.str(this, R.string.clip_offline)
        if (text.isBlank()) return null
        val s = spec ?: return null
        if (TaildropClip.bodySize(s, "clipboard", text) > s.maxBytes) {
            return L10n.str(this, R.string.clip_too_large)
        }
        return null
    }

    private fun updateControls() {
        val text = input.text?.toString() ?: ""
        val reason = blockReason(text)
        reasonView.text = reason ?: ""
        reasonView.visibility = if (reason == null) View.GONE else View.VISIBLE
        val can = targets != null && reason == null && text.isNotBlank() && selected != null
        sendView.isEnabled = can
        sendView.alpha = if (can) 1f else 0.35f
        val url = TaildropServiceFiles.singleUrl(text, spec?.kinds?.get("open_url")?.schemes)
        openButton.visibility = if (url == null) View.GONE else View.VISIBLE
        openButton.isEnabled = can && url != null
        selected?.let { openButton.text = L10n.str(this, R.string.clip_open_on, it.name) }
    }

    private fun send(kind: String) {
        val t = selected ?: return
        val text = input.text?.toString() ?: ""
        if (text.isBlank() || blockReason(text) != null) return
        val value = if (kind == "open_url") {
            TaildropServiceFiles.singleUrl(text, spec?.kinds?.get("open_url")?.schemes) ?: return
        } else {
            text
        }
        TaildropClip.send(this, t, kind, value)
        input.setText("")
    }

    // ───────────────────────── лента ─────────────────────────

    private fun renderFeed() {
        if (!::feedBox.isInitialized) return
        feedBox.removeAllViews()
        val t = selected ?: return
        for (m in TaildropClip.feeds.messages(t.tag, t.peerId)) feedBox.addView(bubble(m))
        scroll.post { scroll.fullScroll(View.FOCUS_DOWN) }
    }

    private fun bubble(m: ClipMessage): View {
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = if (m.out) Gravity.END else Gravity.START
            setPadding(0, dp(4), 0, dp(4))
        }
        val body = TextView(this).apply {
            text = m.text
            setTextColor(textColor())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            setPadding(dp(12), dp(8), dp(12), dp(8))
            maxWidth = (resources.displayMetrics.widthPixels * 0.78).toInt()
            maxLines = 12
            ellipsize = TextUtils.TruncateAt.END
            background = GradientDrawable().apply {
                cornerRadius = dp(14).toFloat()
                setColor(bubbleColor(m.out))
            }
            setOnClickListener { copy(m.text) }
        }
        box.addView(body, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { gravity = if (m.out) Gravity.END else Gravity.START })
        val time = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(m.atMs))
        val meta = buildString {
            if (m.kind == "open_url") append("🔗 ")
            append(time)
            if (m.out && m.status == "sent") append(" ✓")
        }
        box.addView(small(meta, secondaryColor()), wrap(m.out))
        if (m.out && m.status == "error" && !m.error.isNullOrEmpty()) {
            box.addView(small(m.error, errorColor()), wrap(m.out))
        }
        return box
    }

    private fun copy(text: String) {
        runCatching {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            cm.setPrimaryClip(ClipData.newPlainText("Taildrop", text))
            Toast.makeText(applicationContext, L10n.str(this, R.string.clip_copied), Toast.LENGTH_SHORT).show()
        }
    }

    // ───────────────────────── разметка ─────────────────────────

    private fun buildContent(): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12), dp(8), dp(12), dp(12))
            isFocusableInTouchMode = true
        }

        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        header.addView(icon("📋", null))
        toView = TextView(this).apply {
            setTextColor(textColor())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            setPadding(dp(8), dp(10), dp(8), dp(10))
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
            setOnClickListener { chooseTarget() }
        }
        header.addView(toView, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        header.addView(icon("⋮", R.string.clip_more) { v -> showMenu(v) })
        header.addView(icon("✕", R.string.taildrop_close) { finish() })
        root.addView(header)

        scroll = ScrollView(this).apply { isFillViewport = true }
        feedBox = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(4), 0, dp(4))
        }
        scroll.addView(feedBox)
        root.addView(scroll, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))

        reasonView = small("", secondaryColor()).apply {
            setPadding(dp(4), dp(4), dp(4), dp(4))
            visibility = View.GONE
        }
        root.addView(reasonView)

        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        input = EditText(this).apply {
            hint = L10n.str(this@TaildropClipActivity, R.string.clip_hint)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
            maxLines = 5
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
                override fun afterTextChanged(s: Editable?) {
                    if (::openButton.isInitialized) updateControls()
                }
            })
        }
        row.addView(input, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        sendView = icon("➤", R.string.clip_send) { send("clipboard") }.apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 24f)
        }
        row.addView(sendView)
        root.addView(row)

        openButton = Button(this).apply {
            isAllCaps = false
            visibility = View.GONE
            setOnClickListener { send("open_url") }
        }
        root.addView(openButton, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ))
        return root
    }

    private fun updateHeader() {
        val name = selected?.let { label(it) } ?: "—"
        toView.text = L10n.str(this, R.string.clip_to, name)
    }

    private fun showMenu(anchor: View) {
        val t = selected ?: return
        PopupMenu(this, anchor).apply {
            menu.add(L10n.str(this@TaildropClipActivity, R.string.clip_clear))
            setOnMenuItemClickListener {
                TaildropClip.clear(t.tag, t.peerId)
                true
            }
        }.show()
    }

    private fun icon(glyph: String, description: Int?, onClick: ((View) -> Unit)? = null): TextView =
        TextView(this).apply {
            text = glyph
            setTextColor(textColor())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
            gravity = Gravity.CENTER
            minWidth = dp(44)
            minHeight = dp(44)
            if (description != null) contentDescription = L10n.str(this@TaildropClipActivity, description)
            if (onClick != null) setOnClickListener { onClick(it) }
        }

    private fun small(text: String?, color: Int): TextView = TextView(this).apply {
        this.text = text
        setTextColor(color)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
        setPadding(dp(6), dp(2), dp(6), 0)
    }

    private fun wrap(end: Boolean) = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
    ).apply { gravity = if (end) Gravity.END else Gravity.START }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    private fun textColor() = if (night) Color.parseColor("#E6FFFFFF") else Color.parseColor("#DE000000")

    private fun secondaryColor() = if (night) Color.parseColor("#99FFFFFF") else Color.parseColor("#8A000000")

    private fun errorColor() = if (night) Color.parseColor("#FF8A80") else Color.parseColor("#C62828")

    private fun bubbleColor(out: Boolean) = when {
        out && night -> Color.parseColor("#2D4A6B")
        out -> Color.parseColor("#D6E8FF")
        night -> Color.parseColor("#3A3A3C")
        else -> Color.parseColor("#EEEEEE")
    }
}
