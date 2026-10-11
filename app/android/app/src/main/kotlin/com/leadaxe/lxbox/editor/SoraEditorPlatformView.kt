package com.leadaxe.lxbox.editor

import android.content.Context
import android.graphics.Typeface
import android.util.Log
import android.view.View
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
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
import org.eclipse.tm4e.core.registry.IThemeSource

/// Прототип: нативный редактор конфига на sora-editor (Rosemoe, LGPL-2.1)
/// через platform view. Dart-сторона — `lib/widgets/lx_native_code_editor.dart`.
///
/// Зачем: re_editor отдаёт IME только строку с курсором (стрелки кастомных
/// клавиатур, Copy клавиатуры по многострочному выделению); у нативного
/// `CodeEditor` полноценный `InputConnection`.
const val SORA_EDITOR_VIEW_TYPE = "lxbox/sora_editor"
private const val TAG = "SoraEditor"
private const val THEME_LIGHT = "lx-light"
private const val THEME_DARK = "lx-dark"

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

    init {
        val t0 = System.nanoTime()
        SoraTextMate.ensure(context)
        SoraTextMate.setDark(args?.get("dark") as? Boolean ?: false)
        editor.colorScheme = TextMateColorScheme.create(ThemeRegistry.getInstance())
        editor.setEditorLanguage(TextMateLanguage.create("source.json", false))
        editor.typefaceText = Typeface.MONOSPACE
        editor.typefaceLineNumber = Typeface.MONOSPACE
        editor.setTextSize(13f)
        editor.isLineNumberEnabled = true
        editor.isWordwrap = false
        // По умолчанию sora глушит экранную клавиатуру при подключённой
        // аппаратной (эмулятор, BT-клавиатура) — решение оставляем системе.
        editor.isDisableSoftKbdIfHardKbdAvailable = false
        editor.isEditable = !(args?.get("readOnly") as? Boolean ?: false)
        (args?.get("text") as? String)?.let { editor.setText(it) }
        // Клавиатура ужимает view (adjustResize) — sora сам курсор не
        // докручивает (onSizeChanged только клампит скролл).
        editor.addOnLayoutChangeListener { _, _, top, _, bottom, _, oldTop, _, oldBottom ->
            if (bottom - top < oldBottom - oldTop && editor.hasFocus()) {
                editor.post { editor.ensureSelectionVisible() }
            }
        }
        channel.setMethodCallHandler(this)
        Log.d(TAG, "created id=$id in ${(System.nanoTime() - t0) / 1_000_000} ms")
    }

    override fun getView(): View = editor

    override fun dispose() {
        channel.setMethodCallHandler(null)
        editor.release()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setText" -> {
                val t0 = System.nanoTime()
                val text = call.argument<String>("text") ?: ""
                editor.setText(text)
                Log.d(TAG, "setText ${text.length} chars in ${(System.nanoTime() - t0) / 1_000_000} ms")
                result.success(null)
            }
            "getText" -> result.success(editor.text.toString())
            "setReadOnly" -> {
                editor.isEditable = !(call.argument<Boolean>("readOnly") ?: false)
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
