package com.leadaxe.lxbox.editor

import android.content.Context
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Rect
import android.graphics.Typeface
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.ContextThemeWrapper
import android.view.KeyEvent
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
import io.github.rosemoe.sora.event.ScrollEvent
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
import io.github.rosemoe.sora.widget.component.Magnifier
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
///  setLanguage, search / searchNext / searchPrevious, replaceAll (Format:
///  замена всего текста правкой — в undo, с `changed`), setMagnifier
///  {enabled} (лупа выделения, §660), setWordWrap {wordWrap} и setText
///  {waitLayout: true} — ответ приходит, когда фоновая раскладка после них
///  кончилась (§660: кнопки переноса и ⋮ недоступны до ответа).
///  Натив → Dart: `changed` {text?, lines, rowHeight, textOffsetX} на каждую
///  правку (текст ≤ [SYNC_LIMIT] — сразу, длиннее — с задержкой
///  [SYNC_DEBOUNCE_MS], в промежуточных событиях без текста); `cursor`
///  {y, rowHeight, focused}; `scrollState` {canScrollX, scrollTop,
///  scrollBottom} — только при смене значений (Flutter решает, кому жест,
///  §649); `layoutBusy` {busy} — фоновая раскладка строк началась /
///  кончилась (полоса прогресса); `searchResult` {index, count}; `disposed` — последнее сообщение view. Истина
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

/// `CodeEditor` с двумя поправками под встраивание во Flutter:
///  - [suppressFocus]: переход поиска (`gotoNext`) зовёт `setSelectionRegion`,
///    а тот — `requestFocus()`; фокус и клавиатура уходили из поля запроса
///    панели поиска в редактор, следующая буква ложилась в текст;
///  - DPAD_CENTER (пульт ТВ) открывает клавиатуру;
///  - [onLayoutReady]: раскладка строк с переносом (`WordwrapLayout`)
///    считается в фоне и заканчивается `setLayoutBusy(false)` на главном
///    потоке — только после этого `layout.rowCount` верен (смена текста,
///    ширины, шрифта, переноса).
private class LxSoraEditor(context: Context) : CodeEditor(context) {
    var suppressFocus = false
    var onLayoutReady: (() -> Unit)? = null

    /// Начало и конец фоновой раскладки — для полосы прогресса во Flutter
    /// (перенос большого тела считается долго, §649).
    var onLayoutBusy: ((Boolean) -> Unit)? = null

    override fun setLayoutBusy(busy: Boolean) {
        super.setLayoutBusy(busy)
        onLayoutBusy?.invoke(busy)
        if (!busy) onLayoutReady?.invoke()
    }

    override fun requestFocus(direction: Int, previouslyFocusedRect: Rect?): Boolean =
        if (suppressFocus) false else super.requestFocus(direction, previouslyFocusedRect)

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        if (keyCode == KeyEvent.KEYCODE_DPAD_CENTER && isEditable) {
            showSoftInput()
            return true
        }
        return super.onKeyDown(keyCode, event)
    }
}

class SoraEditorPlatformView(
    context: Context,
    id: Int,
    messenger: BinaryMessenger,
    args: Map<*, *>?,
) : PlatformView, MethodChannel.MethodCallHandler {

    private val editor = LxSoraEditor(localized(context, args?.get("locale") as? String))
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
    /// Свои цвета ставим мы — события об этом не наши.
    private var applyingColors = false
    private var colorsPosted = false
    /// Format заменяет текст: промежуточные события (удаление, вставка) не шлём.
    private var replacing = false
    /// Последнее отправленное число экранных строк.
    private var sentRows = -1

    /// Последнее отправленное `scrollState` битами (canScrollX = 1,
    /// scrollTop = 2, scrollBottom = 4); -1 — ещё не слали.
    private var sentScroll = -1

    /// Последнее отправленное `layoutBusy`.
    private var sentLayoutBusy = false

    /// Ответы `setWordWrap` и `setText {waitLayout}`, ждущие конца
    /// раскладки (§660: кнопки переноса и ⋮ «заняты» до ответа). Обе раскладки
    /// sora (`WordwrapLayout`, `LineBreakLayout`) всегда ставят задачу,
    /// которая начинается `setLayoutBusy(true)` в фоне и кончается
    /// `setLayoutBusy(false)` на главном потоке; ответ уходит на первый
    /// `false` после переключения. Dart ждёт не дольше 30 с.
    private val layoutReplies = mutableListOf<MethodChannel.Result>()

    init {
        val t0 = System.nanoTime()
        SoraTextMate.ensure(context)
        SoraTextMate.setDark(args?.get("dark") as? Boolean ?: false)
        colors = parseColors(args?.get("colors"))
        editor.colorScheme = TextMateColorScheme.create(ThemeRegistry.getInstance())
        setLanguage(args?.get("language") as? String)
        // Перенос строк (`WordwrapLayout`) меряет строку целым run advance,
        // а текст рисуется с хинтингом, где каждый глиф округлён: 43 символа
        // строки uuid в раскладке 800 px, на экране 817 px (12 dp, 420 dpi).
        // Строка в раскладке выходила шире поля, последний символ уходил за
        // правый край (uuid терял символ при переносе). Без хинтинга и с
        // линейной метрикой меры совпадают. До шрифта и размера: их установка
        // сбрасывает кеш ширин символов.
        editor.textPaint.apply {
            isSubpixelText = true
            isLinearText = true
            hinting = android.graphics.Paint.HINTING_OFF
        }
        editor.typefaceText = Typeface.MONOSPACE
        editor.typefaceLineNumber = Typeface.MONOSPACE
        // Логические пиксели Flutter × density, без fontScale — как
        // Flutter-текст с textScaler по умолчанию.
        editor.setTextSizePx(((args?.get("fontSize") as? Number)?.toFloat() ?: 12f) * density)
        editor.isLineNumberEnabled = args?.get("lineNumbers") as? Boolean ?: true
        applyWordWrap(args?.get("wordWrap") as? Boolean ?: true)
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
        // Лупа выделения на API 26+ копирует кусок окна (`PixelCopy`) по
        // `getLocationInWindow()` редактора; под hybrid composition Flutter
        // координаты врут — лупа белая или со строками не из-под пальца
        // (форум 13.10). Рисуем её из самого редактора.
        editor.getComponent(Magnifier::class.java).isWithinEditorForcibly = true
        // Лупу можно выключить (настройка приложения, §660).
        editor.getComponent(Magnifier::class.java).isEnabled =
            args?.get("magnifier") as? Boolean ?: true
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
            // Высота поля меняет предел прокрутки по вертикали.
            if (h != oldBottom - oldTop) editor.post { sendScrollState() }
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
        // Растущее поле: высоту в Dart задаёт число экранных строк, а с
        // переносом оно известно только после фоновой раскладки.
        editor.onLayoutReady = { editor.post { sendChanged(withText = false) } }
        editor.onLayoutBusy = { busy ->
            main.post {
                if (!busy) replyLayoutDone()
                if (!editor.isReleased && busy != sentLayoutBusy) {
                    sentLayoutBusy = busy
                    channel.invokeMethod("layoutBusy", hashMapOf("busy" to busy))
                }
            }
        }
        editor.subscribeAlways(ContentChangeEvent::class.java) {
            if (applyingFromDart || replacing) return@subscribeAlways
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
            // Перенос пересчитан после события — число строк догоняем.
            editor.post { if (!editor.isReleased && rows() != sentRows) sendChanged(withText = false) }
        }
        editor.subscribeAlways(SelectionChangeEvent::class.java) {
            sendCursor()
            if (editor.searcher.hasQuery()) sendSearchResult()
        }
        editor.subscribeAlways(PublishSearchResultEvent::class.java) { sendSearchResult() }
        // Прокрутка: событие несёт конечную точку (анимированная докрутка
        // ещё в пути — offsetY старый).
        editor.subscribeAlways(ScrollEvent::class.java) { sendScrollState(it.endY) }
        // Не синхронно: тема (`applyDefault`) ставит цвета по одному, и
        // каждый setColor шлёт событие — повтор из обработчика рекурсивно
        // уходил в StackOverflowError (API 28, ТВ). Свои события пропускаем,
        // чужие сводим в один повтор после текущего кадра.
        editor.subscribeAlways(ColorSchemeUpdateEvent::class.java) {
            if (applyingColors || colorsPosted) return@subscribeAlways
            colorsPosted = true
            editor.post {
                colorsPosted = false
                if (!editor.isReleased) applyColors()
            }
        }
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
        replyLayoutDone()
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

    /**
     * Перенос строк: при создании и на лету (кнопка просмотрщика JSON, §649).
     * Липкие заголовки sora при переносе сама не рисует — их не трогаем.
     */
    private fun applyWordWrap(on: Boolean) {
        editor.isWordwrap = on
        // С переносом логическая строка бывает на весь экран (компактный
        // JSON) — подсветка текущей строки заливала всё поле.
        editor.isHighlightCurrentLine = !on
        // Без переноса раскладка не фоновая (onLayoutReady не придёт) —
        // пределы прокрутки догоняем после кадра.
        editor.post { sendScrollState() }
    }

    /// Ответить ждущим конца раскладки (§660).
    private fun replyLayoutDone() {
        if (layoutReplies.isEmpty()) return
        val pending = layoutReplies.toList()
        layoutReplies.clear()
        pending.forEach { it.success(null) }
    }

    private fun setReadOnly(value: Boolean) {
        readOnly = value
        editor.isEditable = !value
        editor.isSoftKeyboardEnabled = !value
        // Без каретки подсветка пары скобок в начале текста бессмысленна.
        editor.setHighlightBracketPair(!value)
        if (value) editor.hideSoftInput()
        applyColors()
    }

    /// Цвета из `ColorScheme` приложения поверх темы токенов; в режиме только
    /// чтения — без каретки и подсветки текущей строки. Тема (ре)применяет
    /// свои цвета при смене — поэтому повтор на ColorSchemeUpdateEvent
    /// (отложенный, см. подписку в init).
    private fun applyColors() {
        if (applyingColors) return
        applyingColors = true
        try {
            val scheme = editor.colorScheme
            for ((key, value) in colors) scheme.setColor(key, value)
            // Парная скобка у каретки: цвет каретки без фона — тема токенов
            // в тёмном режиме красила её в цвет фона, скобка пропадала.
            scheme.setColor(EditorColorScheme.HIGHLIGHTED_DELIMITERS_BACKGROUND, Color.TRANSPARENT)
            if (readOnly) {
                scheme.setColor(EditorColorScheme.SELECTION_INSERT, Color.TRANSPARENT)
                scheme.setColor(EditorColorScheme.CURRENT_LINE, Color.TRANSPARENT)
            }
        } finally {
            applyingColors = false
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
        put("caret", EditorColorScheme.SELECTION_INSERT, EditorColorScheme.SELECTION_HANDLE,
            EditorColorScheme.HIGHLIGHTED_DELIMITERS_FOREGROUND,
            EditorColorScheme.HIGHLIGHTED_DELIMITERS_UNDERLINE)
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
        val n = rows()
        sentRows = n
        args["lines"] = n
        args["rowHeight"] = editor.rowHeight
        args["textOffsetX"] = editor.measureTextRegionOffset().toDouble()
        channel.invokeMethod("changed", args)
        // Текст, перенос, ширина — пределы прокрутки другие.
        sendScrollState()
    }

    /// Состояние прокрутки для решения «кому жест» во Flutter (§649):
    /// есть куда вбок, прокрутка у верхнего / нижнего края. Шлётся только
    /// при смене значений — не на каждый пиксель прокрутки.
    private fun sendScrollState(offsetY: Int = editor.offsetY) {
        if (editor.isReleased) return
        val maxX = runCatching { editor.scrollMaxX }.getOrDefault(0)
        val maxY = runCatching { editor.scrollMaxY }.getOrDefault(0)
        val canScrollX = maxX > 0
        val top = offsetY <= 0
        val bottom = offsetY >= maxY
        val bits = (if (canScrollX) 1 else 0) or (if (top) 2 else 0) or (if (bottom) 4 else 0)
        if (bits == sentScroll) return
        sentScroll = bits
        channel.invokeMethod(
            "scrollState",
            hashMapOf(
                "canScrollX" to canScrollX,
                "scrollTop" to top,
                "scrollBottom" to bottom,
            ),
        )
    }

    private fun sendCursor() {
        if (editor.isReleased) return
        val c = editor.cursor
        // Низ строки каретки в координатах документа (с учётом переноса).
        val rowH = editor.rowHeight
        val bottom = runCatching {
            editor.layout.getCharLayoutOffset(c.leftLine, c.leftColumn)[0]
        }.getOrDefault(((c.leftLine + 1) * rowH).toFloat())
        val rightBottom = runCatching {
            editor.layout.getCharLayoutOffset(c.rightLine, c.rightColumn)[0]
        }.getOrDefault(((c.rightLine + 1) * rowH).toFloat())
        val layoutH = runCatching { editor.layout.layoutHeight.toFloat() }
            .getOrDefault((editor.text.lineCount * rowH).toFloat())
        channel.invokeMethod(
            "cursor",
            hashMapOf(
                "y" to (bottom - rowH - editor.offsetY).toDouble(),
                "rowHeight" to rowH,
                "focused" to editor.hasFocus(),
                // Каретка в первой / последней экранной строке: стрелка
                // вверх / вниз отсюда уводит фокус из поля (D-pad, §624).
                "atTop" to (bottom <= rowH * 1.5f),
                "atBottom" to (rightBottom >= layoutH - rowH * 0.5f),
                // Есть выделение — Flutter отдаёт view все жесты, иначе
                // ручки выделения перехватывают вкладки и страница (§628).
                "selected" to c.isSelected,
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

    /// Переход по совпадениям из панели поиска не забирает фокус у её поля.
    private inline fun withoutFocusSteal(block: () -> Unit) {
        if (editor.hasFocus()) return block()
        editor.suppressFocus = true
        try {
            block()
        } finally {
            editor.suppressFocus = false
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setText" -> {
                val t0 = System.nanoTime()
                val text = call.argument<String>("text") ?: ""
                setTextFromDart(text)
                Log.d(TAG, "setText ${text.length} chars in ${(System.nanoTime() - t0) / 1_000_000} ms")
                // Format / Show original просмотрщика ждут конца раскладки (§660).
                if (call.argument<Boolean>("waitLayout") == true) {
                    layoutReplies.add(result)
                } else {
                    result.success(null)
                }
            }
            "replaceAll" -> {
                val text = call.argument<String>("text") ?: ""
                main.removeCallbacks(flushChanged)
                pending = false
                replacing = true
                try {
                    val content = editor.text
                    content.replace(0, content.length, text)
                } finally {
                    replacing = false
                }
                editor.setSelection(0, 0)
                sendChanged(withText = true)
                editor.post { sendChanged(withText = false) }
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
            "setWordWrap" -> {
                val on = call.argument<Boolean>("wordWrap") ?: true
                if (on == editor.isWordwrap) {
                    result.success(null)
                } else {
                    layoutReplies.add(result)
                    applyWordWrap(on)
                }
            }
            "setMagnifier" -> {
                editor.getComponent(Magnifier::class.java).isEnabled =
                    call.argument<Boolean>("enabled") ?: true
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
                if (editor.searcher.hasQuery()) withoutFocusSteal { editor.searcher.gotoNext() }
                result.success(null)
            }
            "searchPrevious" -> {
                if (editor.searcher.hasQuery()) withoutFocusSteal { editor.searcher.gotoPrevious() }
                result.success(null)
            }
            "focus" -> {
                // Фокус пришёл со стороны Flutter (D-pad, обход фокуса):
                // нативный view его сам не берёт. Клавиатуру не открываем —
                // её открывает DPAD_CENTER или тап.
                if (!editor.isReleased && !editor.hasFocus()) editor.requestFocus()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}
