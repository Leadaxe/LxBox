package com.leadaxe.lxbox.editor

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import io.github.rosemoe.sora.event.ColorSchemeUpdateEvent
import io.github.rosemoe.sora.event.ContentChangeEvent
import io.github.rosemoe.sora.event.SelectionChangeEvent
import io.github.rosemoe.sora.langs.textmate.TextMateColorScheme
import io.github.rosemoe.sora.langs.textmate.TextMateLanguage
import io.github.rosemoe.sora.langs.textmate.registry.FileProviderRegistry
import io.github.rosemoe.sora.langs.textmate.registry.GrammarRegistry
import io.github.rosemoe.sora.langs.textmate.registry.ThemeRegistry
import io.github.rosemoe.sora.langs.textmate.registry.dsl.languages
import io.github.rosemoe.sora.langs.textmate.registry.model.ThemeModel
import io.github.rosemoe.sora.langs.textmate.registry.provider.AssetsFileResolver
import io.github.rosemoe.sora.widget.CodeEditor
import io.github.rosemoe.sora.widget.EditorSearcher
import io.github.rosemoe.sora.widget.schemes.EditorColorScheme
import org.eclipse.tm4e.core.registry.IThemeSource

/// Прототип: нативный редактор JSON на sora-editor (Rosemoe, LGPL-2.1)
/// через platform view. Dart-сторона — `lib/widgets/lx_native_code_editor.dart`.
///
/// Зачем: re_editor отдаёт IME только строку с курсором (стрелки кастомных
/// клавиатур, Copy клавиатуры по многострочному выделению); у нативного
/// `CodeEditor` полноценный `InputConnection`.
///
/// Протокол канала `com.leadaxe.lxbox/sora_editor_<id>`:
///  Dart → натив: setText, getText, setReadOnly, setDark, search*.
///  Натив → Dart: `changed` {text?, lines, rowHeight} на каждую правку
///  (текст ≤ [SYNC_LIMIT] — сразу, длиннее — с задержкой [SYNC_DEBOUNCE_MS]
///  и тогда без текста в промежуточных событиях), `cursor` {y, rowHeight,
///  focused} на смену выделения/фокуса/размера — Dart держит курсор над
///  клавиатурой и хранит у себя актуальный текст (пересоздание view не
///  теряет правки).
const val SORA_EDITOR_VIEW_TYPE = "lxbox/sora_editor"
private const val TAG = "SoraEditor"
private const val THEME_LIGHT = "lx-light"
private const val THEME_DARK = "lx-dark"
private const val SYNC_LIMIT = 256 * 1024
private const val SYNC_DEBOUNCE_MS = 300L

class SoraEditorFactory(private val messenger: BinaryMessenger) :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        SoraEditorPlatformView(context, viewId, messenger, args as? Map<*, *>)
}

/// TextMate-реестры sora — глобальные синглтоны; грузим один раз на процесс.
private object SoraTextMate {
    @Volatile private var ready = false

    fun ensure(context: Context) {
        if (ready) return
        synchronized(this) {
            if (ready) return
            val files = FileProviderRegistry.getInstance()
            files.addFileProvider(AssetsFileResolver(context.applicationContext.assets))
            val themes = ThemeRegistry.getInstance()
            for (name in listOf(THEME_LIGHT, THEME_DARK)) {
                val path = "sora/$name.json"
                val model = ThemeModel(
                    IThemeSource.fromInputStream(files.tryGetInputStream(path), path, null),
                    name,
                )
                model.isDark = name == THEME_DARK
                themes.loadTheme(model, false)
            }
            GrammarRegistry.getInstance().loadGrammars(languages {
                language("json") {
                    grammar = "sora/json.tmLanguage.json"
                    defaultScopeName()
                }
            })
            ready = true
        }
    }

    fun setDark(dark: Boolean) {
        ThemeRegistry.getInstance().setTheme(if (dark) THEME_DARK else THEME_LIGHT)
    }
}

class SoraEditorPlatformView(
    context: Context,
    id: Int,
    messenger: BinaryMessenger,
    args: Map<*, *>?,
) : PlatformView, MethodChannel.MethodCallHandler {

    private val editor = CodeEditor(context)
    private val channel = MethodChannel(messenger, "com.leadaxe.lxbox/sora_editor_$id")
    private val main = Handler(Looper.getMainLooper())
    private var readOnly = false
    /// Текст выставлен из Dart — эхо `changed` не нужно.
    private var applyingFromDart = false
    private val flushChanged = Runnable { sendChanged(withText = true) }

    init {
        val t0 = System.nanoTime()
        SoraTextMate.ensure(context)
        SoraTextMate.setDark(args?.get("dark") as? Boolean ?: false)
        editor.colorScheme = TextMateColorScheme.create(ThemeRegistry.getInstance())
        editor.setEditorLanguage(TextMateLanguage.create("source.json", false))
        editor.typefaceText = Typeface.MONOSPACE
        editor.typefaceLineNumber = Typeface.MONOSPACE
        editor.setTextSize((args?.get("fontSize") as? Number)?.toFloat() ?: 13f)
        editor.isLineNumberEnabled = args?.get("lineNumbers") as? Boolean ?: true
        editor.isWordwrap = false
        // По умолчанию sora глушит экранную клавиатуру при подключённой
        // аппаратной (эмулятор, BT-клавиатура) — решение оставляем системе.
        editor.isDisableSoftKbdIfHardKbdAvailable = false
        setReadOnly(args?.get("readOnly") as? Boolean ?: false)
        (args?.get("text") as? String)?.let { setTextFromDart(it) }

        // Клавиатура ужимает view (adjustResize) — sora сам курсор не
        // докручивает (onSizeChanged только клампит скролл).
        editor.addOnLayoutChangeListener { _, _, top, _, bottom, _, oldTop, _, oldBottom ->
            val h = bottom - top
            // Растущее поле: пока view было ниже текста, sora прокрутил его
            // внутри; когда Dart дорастил высоту, текст влез — в начало.
            if (h > oldBottom - oldTop && editor.offsetY > 0 &&
                editor.text.lineCount * editor.rowHeight <= h
            ) {
                editor.post {
                    val s = editor.scroller
                    s.forceFinished(true)
                    s.startScroll(editor.offsetX, editor.offsetY, 0, -editor.offsetY, 0)
                    editor.invalidate()
                }
            }
            if (h < oldBottom - oldTop && editor.hasFocus()) {
                editor.post {
                    editor.ensureSelectionVisible()
                    sendCursor()
                }
            }
        }
        editor.subscribeAlways(ContentChangeEvent::class.java) {
            if (applyingFromDart) return@subscribeAlways
            if (editor.text.length <= SYNC_LIMIT) {
                sendChanged(withText = true)
            } else {
                sendChanged(withText = false)
                main.removeCallbacks(flushChanged)
                main.postDelayed(flushChanged, SYNC_DEBOUNCE_MS)
            }
        }
        editor.subscribeAlways(SelectionChangeEvent::class.java) { sendCursor() }
        editor.subscribeAlways(ColorSchemeUpdateEvent::class.java) { applyReadOnlyColors() }
        editor.setOnFocusChangeListener { _, _ -> sendCursor() }
        channel.setMethodCallHandler(this)
        Log.d(TAG, "created id=$id in ${(System.nanoTime() - t0) / 1_000_000} ms")
    }

    override fun getView(): View = editor

    override fun dispose() {
        main.removeCallbacks(flushChanged)
        channel.setMethodCallHandler(null)
        editor.release()
    }

    private fun setTextFromDart(text: String) {
        applyingFromDart = true
        try {
            editor.setText(text)
        } finally {
            applyingFromDart = false
        }
        sendChanged(withText = false)
    }

    private fun setReadOnly(value: Boolean) {
        readOnly = value
        editor.isEditable = !value
        editor.isSoftKeyboardEnabled = !value
        if (value) editor.hideSoftInput()
        applyReadOnlyColors()
    }

    /// Только чтение: без каретки и подсветки текущей строки. Тема (ре)применяет
    /// цвета при смене — поэтому повтор на ColorSchemeUpdateEvent.
    private fun applyReadOnlyColors() {
        if (!readOnly) return
        val scheme = editor.colorScheme
        scheme.setColor(EditorColorScheme.SELECTION_INSERT, Color.TRANSPARENT)
        scheme.setColor(EditorColorScheme.CURRENT_LINE, Color.TRANSPARENT)
    }

    private fun sendChanged(withText: Boolean) {
        val args = HashMap<String, Any>()
        if (withText) args["text"] = editor.text.toString()
        args["lines"] = editor.text.lineCount
        args["rowHeight"] = editor.rowHeight
        channel.invokeMethod("changed", args)
    }

    private fun sendCursor() {
        val line = editor.cursor.leftLine
        channel.invokeMethod(
            "cursor",
            hashMapOf(
                "y" to line * editor.rowHeight - editor.offsetY,
                "rowHeight" to editor.rowHeight,
                "focused" to editor.hasFocus(),
            ),
        )
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setText" -> {
                val t0 = System.nanoTime()
                val text = call.argument<String>("text") ?: ""
                setTextFromDart(text)
                Log.d(TAG, "setText ${text.length} chars in ${(System.nanoTime() - t0) / 1_000_000} ms")
                result.success(null)
            }
            "getText" -> result.success(editor.text.toString())
            "setReadOnly" -> {
                setReadOnly(call.argument<Boolean>("readOnly") ?: false)
                result.success(null)
            }
            "setDark" -> {
                SoraTextMate.setDark(call.argument<Boolean>("dark") ?: false)
                result.success(null)
            }
            "search" -> {
                val q = call.argument<String>("query") ?: ""
                val searcher = editor.searcher
                if (q.isEmpty()) {
                    searcher.stopSearch()
                } else {
                    searcher.search(q, EditorSearcher.SearchOptions(true, false))
                }
                result.success(null)
            }
            "searchNext" -> {
                if (editor.searcher.hasQuery()) editor.searcher.gotoNext()
                result.success(null)
            }
            "searchPrevious" -> {
                if (editor.searcher.hasQuery()) editor.searcher.gotoPrevious()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}
