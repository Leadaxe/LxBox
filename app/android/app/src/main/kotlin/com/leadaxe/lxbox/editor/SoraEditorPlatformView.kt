package com.leadaxe.lxbox.editor

import android.content.Context
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.ContextThemeWrapper
import android.view.View
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import io.github.rosemoe.sora.event.ColorSchemeUpdateEvent
import io.github.rosemoe.sora.event.ContentChangeEvent
import io.github.rosemoe.sora.event.PublishSearchResultEvent
import io.github.rosemoe.sora.event.SelectionChangeEvent
import io.github.rosemoe.sora.lang.EmptyLanguage
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
import java.util.Locale

/// §624 — нативный редактор JSON-полей на sora-editor (Rosemoe, LGPL-2.1)
/// через platform view (hybrid composition). Dart-сторона —
/// `lib/widgets/lx_code_editor.dart` (`LxCodeEditor`, `LxTextCodeField`,
/// `LxJsonView`).
///
/// Зачем: re_editor отдаёт IME только строку с курсором (стрелки кастомных
/// клавиатур, Copy клавиатуры по многострочному выделению); у нативного
/// `CodeEditor` полноценный `InputConnection`.
///
/// Протокол канала `com.leadaxe.lxbox/sora_editor_<id>`:
///  Dart → натив: setText, getText, setReadOnly, setDark (+colors),
///  setLanguage, search / searchNext / searchPrevious.
///  Натив → Dart: `changed` {text?, lines, rowHeight, textOffsetX} на каждую
///  правку (текст ≤ [SYNC_LIMIT] — сразу, длиннее — с задержкой
///  [SYNC_DEBOUNCE_MS], в промежуточных событиях без текста); `cursor`
///  {y, rowHeight, focused}; `searchResult` {index, count}; `disposed` — последнее сообщение view. Истина
///  текста — на стороне Dart: пересозданный view получает его в creation
///  params, поэтому задержанный текст сбрасывается при потере фокуса,
///  на `getText` и в [dispose].
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
                    scopeName = "source.json"
                    // Скобки — для блоков (липкие заголовки).
                    languageConfiguration = "sora/json.language-configuration.json"
                }
                language("ini") {
                    grammar = "sora/ini.tmLanguage.json"
                    scopeName = "source.ini"
                }
                language("lxuri") {
                    grammar = "sora/uri.tmLanguage.json"
                    scopeName = "source.lxuri"
                }
            })
            ready = true
        }
    }

    fun setDark(dark: Boolean) {
        val name = if (dark) THEME_DARK else THEME_LIGHT
        val themes = ThemeRegistry.getInstance()
        if (themes.currentThemeModel?.name != name) themes.setTheme(name)
    }

    fun scopeOf(language: String?): String? = when (language) {
        "json" -> "source.json"
        "ini" -> "source.ini"
        "uri" -> "source.lxuri"
        else -> null
    }
}

/// Контекст view на языке приложения: строки нативного меню выделения
/// (`@android:string/copy` и т.п.) берутся из него. На API < 33 контекст
/// Activity остаётся на системном языке, отсюда явная подмена.
private fun localized(context: Context, tag: String?): Context {
    if (tag.isNullOrEmpty()) return context
    val config = Configuration(context.resources.configuration)
    config.setLocale(Locale.forLanguageTag(tag))
    return ContextThemeWrapper(context, context.theme).apply {
        applyOverrideConfiguration(config)
    }
}

class SoraEditorPlatformView(
    context: Context,
    id: Int,
    messenger: BinaryMessenger,
    args: Map<*, *>?,
) : PlatformView, MethodChannel.MethodCallHandler {

    private val editor = CodeEditor(localized(context, args?.get("locale") as? String))
    private val channel = MethodChannel(messenger, "com.leadaxe.lxbox/sora_editor_$id")
    private val main = Handler(Looper.getMainLooper())
    private val density = context.resources.displayMetrics.density
    private var readOnly = false
    private var language: String? = null
    private var colors: Map<Int, Int> = emptyMap()
    /// Текст выставлен из Dart — эхо `changed` не нужно.
    private var applyingFromDart = false
    /// Длинный текст правился, Dart его ещё не получил.
    private var pending = false
    private val flushChanged = Runnable { flushPending() }

    init {
        val t0 = System.nanoTime()
        SoraTextMate.ensure(context)
        SoraTextMate.setDark(args?.get("dark") as? Boolean ?: false)
        colors = parseColors(args?.get("colors"))
        editor.colorScheme = TextMateColorScheme.create(ThemeRegistry.getInstance())
        setLanguage(args?.get("language") as? String)
        editor.typefaceText = Typeface.MONOSPACE
        editor.typefaceLineNumber = Typeface.MONOSPACE
        // Логические пиксели Flutter × density, без fontScale — как
        // Flutter-текст с textScaler по умолчанию.
        editor.setTextSizePx(((args?.get("fontSize") as? Number)?.toFloat() ?: 12f) * density)
        editor.isLineNumberEnabled = args?.get("lineNumbers") as? Boolean ?: true
        editor.isWordwrap = args?.get("wordWrap") as? Boolean ?: true
        editor.setScalable(false)
        // Линии блоков (направляющие от `{` до `}`) — выключены (владелец).
        editor.isBlockLineEnabled = false
        editor.props.drawSideBlockLine = false
        val sticky = args?.get("stickyHeaders") as? Boolean ?: false
        editor.props.stickyScroll = sticky
        editor.props.stickyScrollMaxLines = 3
        // По умолчанию sora глушит экранную клавиатуру при подключённой
        // аппаратной (эмулятор, BT-клавиатура) — решение оставляем системе.
        editor.isDisableSoftKbdIfHardKbdAvailable = false
        setReadOnly(args?.get("readOnly") as? Boolean ?: false)
        setTextFromDart(args?.get("text") as? String ?: "")
        if (args?.get("autofocus") == true && !readOnly) {
            editor.post {
                if (editor.isReleased) return@post
                editor.requestFocus()
                editor.showSoftInput()
            }
        }

        editor.addOnLayoutChangeListener { _, left, top, right, bottom, oldLeft, oldTop, oldRight, oldBottom ->
            val h = bottom - top
            // Ширина изменилась — перенос строк пересчитан, число строк другое.
            if (right - left != oldRight - oldLeft) editor.post { sendChanged(withText = false) }
            // Растущее поле: пока view было ниже текста, sora прокрутил его
            // внутри; когда Dart дорастил высоту, текст влез — в начало.
            if (h > oldBottom - oldTop && editor.offsetY > 0 &&
                editor.layout.layoutHeight <= h
            ) {
                editor.post {
                    val s = editor.scroller
                    s.forceFinished(true)
                    s.startScroll(editor.offsetX, editor.offsetY, 0, -editor.offsetY, 0)
                    editor.invalidate()
                }
            }
            // Клавиатура ужимает view (adjustResize) — sora сам курсор не
            // докручивает (onSizeChanged только клампит скролл).
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
                main.removeCallbacks(flushChanged)
                pending = false
                sendChanged(withText = true)
            } else {
                pending = true
                sendChanged(withText = false)
                main.removeCallbacks(flushChanged)
                main.postDelayed(flushChanged, SYNC_DEBOUNCE_MS)
            }
        }
        editor.subscribeAlways(SelectionChangeEvent::class.java) {
            sendCursor()
            if (editor.searcher.hasQuery()) sendSearchResult()
        }
        editor.subscribeAlways(PublishSearchResultEvent::class.java) { sendSearchResult() }
        editor.subscribeAlways(ColorSchemeUpdateEvent::class.java) { applyColors() }
        editor.setOnFocusChangeListener { _, focused ->
            if (!focused) flushPending()
            sendCursor()
        }
        channel.setMethodCallHandler(this)
        Log.d(TAG, "created id=$id in ${(System.nanoTime() - t0) / 1_000_000} ms")
    }

    override fun getView(): View = editor

    override fun dispose() {
        // Порядок важен: задержанная правка уходит в Dart до снятия канала,
        // иначе уход с экрана сразу после правки длинного текста её теряет.
        flushPending()
        channel.invokeMethod("disposed", null)
        channel.setMethodCallHandler(null)
        editor.release()
    }

    private fun flushPending() {
        main.removeCallbacks(flushChanged)
        if (!pending) return
        pending = false
        sendChanged(withText = true)
    }

    private fun setTextFromDart(text: String) {
        main.removeCallbacks(flushChanged)
        pending = false
        applyingFromDart = true
        try {
            editor.setText(text)
        } finally {
            applyingFromDart = false
        }
        // Раскладка строк ещё не пересчитана — метрики после неё.
        editor.post { sendChanged(withText = false) }
    }

    private fun setLanguage(value: String?) {
        language = value
        val scope = SoraTextMate.scopeOf(value)
        editor.setEditorLanguage(
            if (scope == null) EmptyLanguage() else TextMateLanguage.create(scope, false),
        )
    }

    private fun setReadOnly(value: Boolean) {
        readOnly = value
        editor.isEditable = !value
        editor.isSoftKeyboardEnabled = !value
        if (value) editor.hideSoftInput()
        applyColors()
    }

    /// Цвета из `ColorScheme` приложения поверх темы токенов; в режиме только
    /// чтения — без каретки и подсветки текущей строки. Тема (ре)применяет
    /// свои цвета при смене — поэтому повтор на ColorSchemeUpdateEvent
    /// (setColor с тем же значением событие не шлёт — рекурсии нет).
    private fun applyColors() {
        val scheme = editor.colorScheme
        for ((key, value) in colors) scheme.setColor(key, value)
        if (readOnly) {
            scheme.setColor(EditorColorScheme.SELECTION_INSERT, Color.TRANSPARENT)
            scheme.setColor(EditorColorScheme.CURRENT_LINE, Color.TRANSPARENT)
        }
    }

    private fun parseColors(raw: Any?): Map<Int, Int> {
        val map = raw as? Map<*, *> ?: return emptyMap()
        val out = HashMap<Int, Int>()
        fun put(name: String, vararg keys: Int) {
            val v = (map[name] as? Number)?.toInt() ?: return
            for (k in keys) out[k] = v
        }
        put("background", EditorColorScheme.WHOLE_BACKGROUND,
            EditorColorScheme.LINE_NUMBER_BACKGROUND)
        put("text", EditorColorScheme.TEXT_NORMAL, EditorColorScheme.LINE_NUMBER_CURRENT)
        put("lineNumber", EditorColorScheme.LINE_NUMBER)
        put("divider", EditorColorScheme.LINE_DIVIDER, EditorColorScheme.STICKY_SCROLL_DIVIDER)
        put("selection", EditorColorScheme.SELECTED_TEXT_BACKGROUND)
        put("caret", EditorColorScheme.SELECTION_INSERT, EditorColorScheme.SELECTION_HANDLE)
        put("currentLine", EditorColorScheme.CURRENT_LINE)
        put("match", EditorColorScheme.MATCHED_TEXT_BACKGROUND)
        put("menuBackground", EditorColorScheme.TEXT_ACTION_WINDOW_BACKGROUND)
        put("menuIcon", EditorColorScheme.TEXT_ACTION_WINDOW_ICON_COLOR)
        return out
    }

    private fun rows(): Int {
        val layoutRows = runCatching { editor.layout.rowCount }.getOrDefault(0)
        return maxOf(layoutRows, editor.text.lineCount)
    }

    private fun sendChanged(withText: Boolean) {
        if (editor.isReleased) return
        val args = HashMap<String, Any>()
        if (withText) args["text"] = editor.text.toString()
        args["lines"] = rows()
        args["rowHeight"] = editor.rowHeight
        args["textOffsetX"] = editor.measureTextRegionOffset().toDouble()
        channel.invokeMethod("changed", args)
    }

    private fun sendCursor() {
        if (editor.isReleased) return
        val c = editor.cursor
        // Низ строки каретки в координатах документа (с учётом переноса).
        val bottom = runCatching {
            editor.layout.getCharLayoutOffset(c.leftLine, c.leftColumn)[0]
        }.getOrDefault(((c.leftLine + 1) * editor.rowHeight).toFloat())
        channel.invokeMethod(
            "cursor",
            hashMapOf(
                "y" to (bottom - editor.rowHeight - editor.offsetY).toDouble(),
                "rowHeight" to editor.rowHeight,
                "focused" to editor.hasFocus(),
            ),
        )
    }

    /// Счёт совпадений для панели поиска: `index` = -1, пока курсор не на
    /// совпадении.
    private fun sendSearchResult() {
        if (editor.isReleased) return
        val s = editor.searcher
        val has = s.hasQuery()
        channel.invokeMethod(
            "searchResult",
            hashMapOf(
                "index" to if (has) s.currentMatchedPositionIndex else -1,
                "count" to if (has) s.matchedPositionCount else 0,
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
            "getText" -> {
                main.removeCallbacks(flushChanged)
                pending = false
                result.success(editor.text.toString())
            }
            "setReadOnly" -> {
                setReadOnly(call.argument<Boolean>("readOnly") ?: false)
                result.success(null)
            }
            "setDark" -> {
                colors = parseColors(call.argument<Any>("colors"))
                SoraTextMate.setDark(call.argument<Boolean>("dark") ?: false)
                applyColors()
                result.success(null)
            }
            "setLanguage" -> {
                val value = call.argument<String>("language")
                if (value != language) setLanguage(value)
                result.success(null)
            }
            "search" -> {
                val q = call.argument<String>("query") ?: ""
                val searcher = editor.searcher
                if (q.isEmpty()) {
                    searcher.stopSearch()
                    sendSearchResult()
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
