import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../services/l10n/locale_controller.dart';

/// §624 — JSON-поля приложения на нативном редакторе sora-editor (Android
/// View через platform view, hybrid composition). Kotlin-сторона —
/// `android/.../editor/SoraEditorPlatformView.kt`.
///
/// Зачем натив: re_editor (§333) отдавал IME только строку с курсором —
/// стрелки кастомных клавиатур сворачивали клавиатуру, Copy клавиатуры
/// копировал одну строку, курсор в последних строках уходил под клавиатуру.
/// У нативного `CodeEditor` полноценный `InputConnection`, как у `EditText`,
/// и он держит документ построчно, как и требовал §333 для конфигов в сотни
/// КБ.
///
/// Три публичных виджета — [LxCodeEditor] (во всю высоту, экран Config),
/// [LxTextCodeField] (поле формы с подписью, ошибкой и ростом по строкам) и
/// [LxJsonView] (только чтение). Все три — один [LxCodeEditor] внутри.
///
/// Истина текста — на стороне Dart (`TextEditingController`): натив шлёт
/// текст на каждую правку, пересозданный view (уход с вкладки, смена темы)
/// получает актуальный текст в creation params. Текст длиннее 256 КБ натив
/// присылает с задержкой — перед Save/Copy/Share экран зовёт
/// [LxCodeEditorState.flush].
///
/// Не Android (`flutter test`, desktop) — заглушка на `TextField` с той же
/// раскладкой, без подсветки.

/// Язык подсветки. `null` у виджетов — голый текст.
enum LxCodeLanguage { json, ini, uri }

final _iniSection = RegExp(r'^\[[\p{L}\p{N}_\- ]+\]$', unicode: true);
final _iniKeyValue = RegExp(r'^[^=\s#;\[][^=]*=');
final _uriLine = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://');

/// Язык подсветки по виду текста — общий для всех экранов, где в поле может
/// оказаться и JSON, и ссылка, и WireGuard `.conf`.
///
/// Правило — по первой непустой строке (без BOM и ведущих пробелов):
/// - `{`, или `[`, который не заголовок секции INI, — [LxCodeLanguage.json];
/// - `[Имя]` во всю строку (буквы, цифры, `_`, `-`, пробел) или
///   `#`/`;`-комментарий, за которым первой значимой строкой идёт
///   `Ключ = значение`, — [LxCodeLanguage.ini];
/// - `схема://…` — [LxCodeLanguage.uri];
/// - иначе (base64-подписка, YAML и т.п.) — `null`.
LxCodeLanguage? detectCodeLanguage(String text) {
  final lines = text.split('\n');
  var i = 0;
  String clean(String s) => s.replaceAll('﻿', '').trim();
  while (i < lines.length && clean(lines[i]).isEmpty) {
    i++;
  }
  if (i == lines.length) return null;
  final first = clean(lines[i]);
  if (_iniSection.hasMatch(first)) return LxCodeLanguage.ini;
  if (first.startsWith('{') || first.startsWith('[')) return LxCodeLanguage.json;
  if (first.startsWith('#') || first.startsWith(';')) {
    for (var j = i + 1; j < lines.length; j++) {
      final l = clean(lines[j]);
      if (l.isEmpty || l.startsWith('#') || l.startsWith(';')) continue;
      return _iniSection.hasMatch(l) || _iniKeyValue.hasMatch(l)
          ? LxCodeLanguage.ini
          : null;
    }
    return null;
  }
  if (_uriLine.hasMatch(first)) return LxCodeLanguage.uri;
  return null;
}

/// Нативный редактор только на Android. Не `defaultTargetPlatform`: под
/// `flutter test` он возвращает `android`, и тесты полезли бы в platform view.
bool get _nativeEditor => !kIsWeb && Platform.isAndroid;

const _viewType = 'lxbox/sora_editor';
const double _pad = 6;

/// Как поле занимает место по вертикали.
enum _Fit {
  /// Заполняет ограниченного родителя (`Expanded`, экран Config).
  fill,

  /// Фиксированная высота.
  fixed,

  /// Растёт по числу строк от `minLines` до `maxLines`.
  grow,
}

/// Редактор кода во всю высоту родителя (экран Config, мастер добавления
/// сервера); основа [LxTextCodeField] и [LxJsonView].
class LxCodeEditor extends StatefulWidget {
  const LxCodeEditor({
    super.key,
    required this.controller,
    this.hint,
    this.fontSize = 12,
    this.readOnly = false,
    this.showLineNumbers = false,
    this.wordWrap = true,
    this.language,
    this.autofocus = false,
    this.find,
    this.stickyHeaders = false,
    this.actions = const [],
  })  : _fit = _Fit.fill,
        _height = null,
        _minLines = null,
        _maxLines = null,
        _onEdited = null;

  const LxCodeEditor._sized({
    required this.controller,
    required _Fit fit,
    double? height,
    int? minLines,
    int? maxLines,
    ValueChanged<String>? onEdited,
    this.hint,
    this.fontSize = 12,
    this.readOnly = false,
    this.showLineNumbers = false,
    this.language,
    this.autofocus = false,
    this.stickyHeaders = false,
  })  : find = null,
        _fit = fit,
        _height = height,
        _minLines = minLines,
        _maxLines = maxLines,
        _onEdited = onEdited,
        wordWrap = true,
        actions = const [];

  /// Текст поля. Запись из кода (Paste, Load from file) уходит в натив,
  /// правка в поле — сюда.
  final TextEditingController controller;
  final String? hint;

  /// Логические пиксели, как у Flutter-текста (без системного масштаба
  /// шрифта — как было у re_editor).
  final double fontSize;
  final bool readOnly;
  final bool showLineNumbers;
  final bool wordWrap;

  /// `null` — без подсветки. Меняется на лету без пересоздания view.
  final LxCodeLanguage? language;

  /// Фокус и клавиатура при открытии. По умолчанию нет (решение 3 §624).
  final bool autofocus;

  /// Поиск: иконка в правом верхнем углу открывает панель над текстом.
  /// `null` — как [showLineNumbers].
  final bool? find;

  /// Липкие заголовки: при прокрутке сверху закреплены до трёх строк
  /// объемлющих блоков (`"outbounds": [` → `{` → …). Вместо свёртки §614.
  final bool stickyHeaders;

  /// Свои кнопки поля (Copy конфига) в правом верхнем углу рядом с поиском;
  /// на время панели поиска прячутся.
  final List<Widget> actions;

  final _Fit _fit;
  final double? _height;
  final int? _minLines;
  final int? _maxLines;

  /// Правка пользователя (не запись в контроллер из кода).
  final ValueChanged<String>? _onEdited;

  bool get _find => find ?? showLineNumbers;

  @override
  State<LxCodeEditor> createState() => LxCodeEditorState();
}

/// Держатель канала view. Живёт дольше `State`: натив в `dispose` сбрасывает
/// задержанную правку длинного текста уже после того, как `State` ушёл, и
/// финальный `changed` должен лечь в контроллер, а не потеряться.
class _SoraLink {
  _SoraLink(int viewId, this.controller)
      : channel = MethodChannel('com.leadaxe.lxbox/sora_editor_$viewId') {
    channel.setMethodCallHandler(_handle);
  }

  final MethodChannel channel;
  final TextEditingController controller;
  LxCodeEditorState? state;

  Future<Object?> _handle(MethodCall call) async {
    final s = state;
    if (s != null) return s._onNativeCall(call);
    switch (call.method) {
      case 'changed':
        final text = (call.arguments as Map?)?['text'] as String?;
        if (text == null || text == controller.text) return null;
        try {
          controller.value = TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
          );
        } catch (_) {
          // Экран уже освободил контроллер — правку некуда класть.
        }
      case 'disposed':
        channel.setMethodCallHandler(null);
    }
    return null;
  }

  void detach() {
    state = null;
  }
}

class LxCodeEditorState extends State<LxCodeEditor>
    with WidgetsBindingObserver {
  _SoraLink? _link;

  /// Текст, который сейчас в нативе (или уйдёт в creation params). Эхо
  /// своей же записи в контроллер обратно в натив не шлём.
  String _nativeText = '';
  bool _syncing = false;

  int _rows = 1;
  double _rowH = 0;
  double _textOffsetX = 0;

  bool _focused = false;
  Rect? _cursorRect;

  bool _dark = false;
  Map<String, int> _colors = const {};

  bool _findOpen = false;
  final _findCtrl = TextEditingController();
  int _matchIndex = -1;
  int _matchCount = 0;

  MethodChannel? get _channel => _link?.channel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _nativeText = widget.controller.text;
    _rows = _countLines(_nativeText);
    widget.controller.addListener(_onController);
  }

  static int _countLines(String t) => '\n'.allMatches(t).length + 1;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final dark = Theme.of(context).brightness == Brightness.dark;
    final colors = _schemeColors(context);
    if (dark != _dark || !mapEquals(colors, _colors)) {
      final first = _colors.isEmpty;
      _dark = dark;
      _colors = colors;
      if (!first) {
        unawaited(_invoke('setDark', {'dark': dark, 'colors': colors}));
      }
    }
  }

  @override
  void didUpdateWidget(LxCodeEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onController);
      widget.controller.addListener(_onController);
      _onController();
    }
    if (oldWidget.readOnly != widget.readOnly) {
      unawaited(_invoke('setReadOnly', {'readOnly': widget.readOnly}));
    }
    if (oldWidget.language != widget.language) {
      unawaited(_invoke('setLanguage', {'language': widget.language?.name}));
    }
  }

  @override
  void didChangeMetrics() {
    // Клавиатура поднялась — страница ужалась; Flutter не знает, где
    // нативная каретка, поэтому докручиваем по последнему `cursor`.
    if (_focused) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealCursor());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_onController);
    _link?.detach();
    _findCtrl.dispose();
    super.dispose();
  }

  Future<T?> _invoke<T>(String method, [Object? args]) async {
    final ch = _channel;
    if (ch == null) return null;
    try {
      return await ch.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Задержанный текст из натива — в контроллер. Экран Config зовёт перед
  /// Save / Copy / Share: текст длиннее 256 КБ натив отдаёт не на каждую
  /// правку.
  Future<void> flush() async {
    if (_channel == null) return;
    final text = await _invoke<String>('getText');
    if (text == null || !mounted) return;
    _applyNativeText(text);
  }

  /// Запись в контроллер из кода → натив.
  void _onController() {
    if (_syncing) return;
    final t = widget.controller.text;
    if (t == _nativeText) return;
    _nativeText = t;
    if (_channel == null) {
      // View ещё нет: метрики — по тексту, натив возьмёт его при создании.
      final n = _countLines(t);
      if (n != _rows && mounted) setState(() => _rows = n);
      return;
    }
    unawaited(_invoke('setText', {'text': t}));
  }

  void _applyNativeText(String text) {
    _nativeText = text;
    if (text == widget.controller.text) return;
    _syncing = true;
    try {
      widget.controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    } finally {
      _syncing = false;
    }
    widget._onEdited?.call(text);
  }

  Future<Object?> _onNativeCall(MethodCall call) async {
    if (!mounted) return null;
    final args = (call.arguments as Map?) ?? const {};
    final dpr = MediaQuery.devicePixelRatioOf(context);
    switch (call.method) {
      case 'changed':
        final text = args['text'] as String?;
        if (text != null) _applyNativeText(text);
        final rows = (args['lines'] as num?)?.toInt() ?? _rows;
        final rowH = ((args['rowHeight'] as num?) ?? 0) / dpr;
        final offX = ((args['textOffsetX'] as num?) ?? 0) / dpr;
        if (rows != _rows || rowH != _rowH || offX != _textOffsetX) {
          setState(() {
            _rows = rows;
            _rowH = rowH;
            _textOffsetX = offX;
          });
        } else if (text != null) {
          // Пустой/непустой текст — показать или спрятать hint.
          setState(() {});
        }
      case 'cursor':
        _focused = args['focused'] as bool? ?? false;
        final rowH = ((args['rowHeight'] as num?) ?? 0) / dpr;
        final y = ((args['y'] as num?) ?? 0) / dpr;
        _cursorRect = Rect.fromLTWH(0, y, 1, rowH);
        if (_focused) _revealCursor();
      case 'searchResult':
        setState(() {
          _matchIndex = (args['index'] as num?)?.toInt() ?? -1;
          _matchCount = (args['count'] as num?)?.toInt() ?? 0;
        });
      case 'disposed':
        _link?.channel.setMethodCallHandler(null);
    }
    return null;
  }

  /// Строка каретки — над клавиатурой: ближайший `Scrollable` докручивает
  /// её. Полноэкранный редактор докручивается внутри себя (натив).
  void _revealCursor() {
    final rect = _cursorRect;
    if (!mounted || rect == null) return;
    final box = _viewKey.currentContext?.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      box.showOnScreen(
        rect: Rect.fromLTWH(0, rect.top, box.size.width, rect.height)
            .inflate(8),
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    }
  }

  void _attach(int id) {
    if (!mounted) return;
    final link = _SoraLink(id, widget.controller)..state = this;
    _link = link;
    // Контроллер успел поменяться между созданием view и его готовностью
    // (экран Config грузит конфиг асинхронно) — догоняем.
    if (widget.controller.text != _creationText) {
      _nativeText = widget.controller.text;
      unawaited(_invoke('setText', {'text': _nativeText}));
    }
  }

  String _creationText = '';
  final _viewKey = GlobalKey();

  /// Цвета поля из `ColorScheme`: фон — как у поверхности, на которой лежит
  /// поле (экран, шторка, диалог), иначе поле выглядит инородно. Цвета
  /// токенов — из тем `lx-light/lx-dark.json`.
  static Map<String, int> _schemeColors(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final bg = _surfaceColor(context) ?? theme.scaffoldBackgroundColor;
    return {
      'background': bg.toARGB32(),
      'text': cs.onSurface.toARGB32(),
      'lineNumber': cs.onSurfaceVariant.withValues(alpha: 0.7).toARGB32(),
      'divider': cs.outlineVariant.toARGB32(),
      'selection': (theme.textSelectionTheme.selectionColor ??
              cs.primary.withValues(alpha: 0.4))
          .toARGB32(),
      'caret': cs.primary.toARGB32(),
      'currentLine': cs.onSurface.withValues(alpha: 0.05).toARGB32(),
      'match': cs.tertiary.withValues(alpha: 0.35).toARGB32(),
      'menuBackground': cs.surfaceContainerHigh.toARGB32(),
      'menuIcon': cs.onSurface.toARGB32(),
    };
  }

  /// Цвет ближайшего непрозрачного `Material` выше по дереву.
  static Color? _surfaceColor(BuildContext context) {
    Color? found;
    context.visitAncestorElements((e) {
      final w = e.widget;
      if (w is Material && w.type != MaterialType.transparency) {
        final c = w.color;
        if (c != null && c.a == 1) {
          found = c;
          return false;
        }
      }
      return true;
    });
    return found;
  }

  double get _rowHeight => _rowH > 0 ? _rowH : widget.fontSize * 1.4;

  void _toggleFind(bool open) {
    setState(() => _findOpen = open);
    if (!open) {
      _findCtrl.clear();
      _matchIndex = -1;
      _matchCount = 0;
      unawaited(_invoke('search', {'query': ''}));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final w = widget;
    double? height;
    var scrollable = true;
    switch (w._fit) {
      case _Fit.fill:
        height = null;
      case _Fit.fixed:
        height = w._height;
        scrollable = _rows * _rowHeight + 2 * _pad + 2 > height!;
      case _Fit.grow:
        final min = w._minLines ?? 1;
        final max = w._maxLines ?? (min > 24 ? min : 24);
        final shown = _rows.clamp(min, max < min ? min : max);
        height = shown * _rowHeight + 2 * _pad + 2;
        scrollable = _rows > shown;
    }

    Widget field = _nativeEditor ? _buildNative(scrollable) : _buildStub();
    if (_nativeEditor) {
      field = DecoratedBox(
        decoration: BoxDecoration(
          color: Color(_colors['background'] ?? 0),
          border: Border.all(color: cs.outline),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Padding(
          padding: const EdgeInsets.all(_pad + 1),
          child: ClipRect(child: field),
        ),
      );
    }
    final hint = w.hint;
    final overlays = <Widget>[
      if (_nativeEditor && hint != null && widget.controller.text.isEmpty)
        Positioned(
          left: _pad + 1 + _textOffsetX,
          top: _pad + 1,
          right: _pad + 1,
          child: IgnorePointer(
            child: SizedBox(
              height: _rowHeight,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  hint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textScaler: TextScaler.noScaling,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontFamily: 'monospace',
                        fontSize: w.fontSize,
                        color: cs.onSurfaceVariant,
                      ),
                ),
              ),
            ),
          ),
        ),
      if (!_findOpen && (w._find || w.actions.isNotEmpty))
        Positioned(
          top: 2,
          right: 2,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (w._find)
                IconButton(
                  key: const ValueKey('lx-code-editor-find'),
                  icon: const Icon(Icons.search, size: 18),
                  tooltip: getLocalText.s("Find"),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _toggleFind(true),
                ),
              ...w.actions,
            ],
          ),
        ),
    ];
    if (overlays.isNotEmpty) {
      field = Stack(
        fit: StackFit.passthrough,
        children: [field, ...overlays],
      );
    }
    if (_findOpen) {
      field = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _LxFindPanel(
            controller: _findCtrl,
            index: _matchIndex,
            count: _matchCount,
            onQuery: (q) => unawaited(_invoke('search', {'query': q})),
            onNext: () => unawaited(_invoke('searchNext')),
            onPrevious: () => unawaited(_invoke('searchPrevious')),
            onClose: () => _toggleFind(false),
          ),
          Expanded(child: field),
        ],
      );
    }
    return height == null
        ? field
        : SizedBox(width: double.infinity, height: height, child: field);
  }

  /// Заглушка вне Android: обычный `TextField` с той же раскладкой.
  Widget _buildStub() {
    final w = widget;
    // Высоту задаёт обёртка (родитель, фиксированная или по строкам).
    return TextField(
      controller: w.controller,
      readOnly: w.readOnly,
      autofocus: w.autofocus,
      expands: true,
      maxLines: null,
      onChanged: (t) {
        _nativeText = t;
        final n = _countLines(t);
        if (n != _rows) setState(() => _rows = n);
        w._onEdited?.call(t);
      },
      textAlignVertical: TextAlignVertical.top,
      style: TextStyle(fontFamily: 'monospace', fontSize: w.fontSize),
      decoration: InputDecoration(
        hintText: w.hint,
        border: const OutlineInputBorder(),
        isDense: true,
        contentPadding: const EdgeInsets.all(_pad + 1),
      ),
    );
  }

  Widget _buildNative(bool scrollable) {
    final w = widget;
    // Текст помещается — вертикальные свайпы уходят странице; нет — их
    // забирает редактор. Тап, долгий тап, горизонтальный свайп — редактору.
    final recognizers = <Factory<OneSequenceGestureRecognizer>>{
      if (scrollable)
        const Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new)
      else ...[
        const Factory<OneSequenceGestureRecognizer>(
            HorizontalDragGestureRecognizer.new),
        const Factory<OneSequenceGestureRecognizer>(
            LongPressGestureRecognizer.new),
      ],
    };
    return PlatformViewLink(
      key: _viewKey,
      viewType: _viewType,
      surfaceFactory: (context, controller) => AndroidViewSurface(
        controller: controller as AndroidViewController,
        gestureRecognizers: recognizers,
        hitTestBehavior: PlatformViewHitTestBehavior.opaque,
      ),
      onCreatePlatformView: (params) {
        _creationText = widget.controller.text;
        _nativeText = _creationText;
        final c = PlatformViewsService.initExpensiveAndroidView(
          id: params.id,
          viewType: _viewType,
          layoutDirection: TextDirection.ltr,
          creationParams: <String, Object?>{
            'text': _creationText,
            'readOnly': w.readOnly,
            'dark': _dark,
            'colors': _colors,
            'lineNumbers': w.showLineNumbers,
            'fontSize': w.fontSize,
            'wordWrap': w.wordWrap,
            'language': w.language?.name,
            'locale': LocaleController.I.effectiveTag,
            'autofocus': w.autofocus,
            'stickyHeaders': w.stickyHeaders,
          },
          creationParamsCodec: const StandardMessageCodec(),
          onFocus: () => params.onFocusChanged(true),
        );
        c.addOnPlatformViewCreatedListener(params.onPlatformViewCreated);
        c.addOnPlatformViewCreatedListener(_attach);
        unawaited(c.create());
        return c;
      },
    );
  }

  /// Канал без view — для тестов Dart-логики (контроллер ↔ натив, метрики,
  /// задержка, докрутка) на заглушке.
  @visibleForTesting
  void debugAttachChannel(int viewId) {
    _creationText = widget.controller.text;
    _attach(viewId);
  }

  /// Высота, которую поле сейчас занимает по метрикам (для тестов роста).
  @visibleForTesting
  int get debugRows => _rows;
}

/// Панель поиска над текстом редактора: поле, счёт совпадений,
/// предыдущее/следующее, закрыть. Пустой запрос снимает подсветку.
class _LxFindPanel extends StatelessWidget {
  const _LxFindPanel({
    required this.controller,
    required this.index,
    required this.count,
    required this.onQuery,
    required this.onNext,
    required this.onPrevious,
    required this.onClose,
  });

  final TextEditingController controller;
  final int index;
  final int count;
  final ValueChanged<String> onQuery;
  final VoidCallback onNext;
  final VoidCallback onPrevious;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final shown = count == 0
        ? '0/0' // l10n-exempt: счёт совпадений
        : '${index < 0 ? '-' : index + 1}/$count';
    return Container(
      key: const ValueKey('lx-code-editor-find-panel'),
      height: 40,
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(8, 2, 2, 2),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              autofocus: true,
              style: const TextStyle(fontSize: 13),
              textInputAction: TextInputAction.search,
              onChanged: onQuery,
              onSubmitted: (_) => onNext(),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: getLocalText.s("Find"),
              ),
            ),
          ),
          Text(shown, style: Theme.of(context).textTheme.bodySmall),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_up, size: 18),
            tooltip: getLocalText.s("Previous match"),
            visualDensity: VisualDensity.compact,
            onPressed: onPrevious,
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down, size: 18),
            tooltip: getLocalText.s("Next match"),
            visualDensity: VisualDensity.compact,
            onPressed: onNext,
          ),
          IconButton(
            key: const ValueKey('lx-code-editor-find-close'),
            icon: const Icon(Icons.close, size: 18),
            tooltip: getLocalText.s("Close"),
            visualDensity: VisualDensity.compact,
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

/// Только чтение: JSON узла, outbound, инспектор узла подписки, Source
/// подписки. Без [height] — заполняет ограниченного родителя.
class LxJsonView extends StatefulWidget {
  const LxJsonView({
    super.key,
    required this.text,
    this.height,
    this.fontSize = 12,
    this.showLineNumbers = false,
    this.language = LxCodeLanguage.json,
    this.stickyHeaders = false,
  });

  final String text;
  final double? height;
  final double fontSize;
  final bool showLineNumbers;

  /// `null` — без подсветки (тело подписки не-JSON: base64, ссылки).
  final LxCodeLanguage? language;
  final bool stickyHeaders;

  @override
  State<LxJsonView> createState() => _LxJsonViewState();
}

class _LxJsonViewState extends State<LxJsonView> {
  late final _ctrl = TextEditingController(text: widget.text);

  @override
  void didUpdateWidget(LxJsonView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _ctrl.text = widget.text;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.height;
    return LxCodeEditor._sized(
      controller: _ctrl,
      fit: h == null ? _Fit.fill : _Fit.fixed,
      height: h,
      readOnly: true,
      fontSize: widget.fontSize,
      showLineNumbers: widget.showLineNumbers,
      language: widget.language,
      stickyHeaders: widget.stickyHeaders,
    );
  }
}

/// Поле формы с подсветкой поверх обычного `TextEditingController`: Source
/// узла, DNS-сервер, правила. [onChanged] — как у `TextField`: только на
/// правку в поле, не на запись в [controller] из кода.
///
/// Высота:
/// - [height] — фиксированная;
/// - [minLines] (и [maxLines]) — растёт по числу строк, но не выше
///   [maxLines] (по умолчанию `max(minLines, 24)`), дальше прокрутка внутри;
/// - ничего — заполняет ограниченного родителя (`Expanded`).
class LxTextCodeField extends StatelessWidget {
  const LxTextCodeField({
    super.key,
    required this.controller,
    this.language = LxCodeLanguage.json,
    this.onChanged,
    this.height,
    this.minLines,
    this.maxLines,
    this.fontSize = 12,
    this.showLineNumbers = true,
    this.hint,
    this.label,
    this.errorText,
    this.readOnly = false,
    this.autofocus = false,
  });

  final TextEditingController controller;

  /// `null` — без подсветки.
  final LxCodeLanguage? language;
  final ValueChanged<String>? onChanged;
  final double? height;
  final int? minLines;
  final int? maxLines;
  final double fontSize;
  final bool showLineNumbers;
  final String? hint;

  /// Подпись над полем.
  final String? label;

  /// Ошибка под полем.
  final String? errorText;
  final bool readOnly;

  /// Фокус и клавиатура при открытии (диалог Edit server в папке).
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fit = height != null
        ? _Fit.fixed
        : minLines != null
            ? _Fit.grow
            : _Fit.fill;
    final editor = LxCodeEditor._sized(
      controller: controller,
      fit: fit,
      height: height,
      minLines: minLines,
      maxLines: maxLines,
      onEdited: onChanged,
      hint: hint,
      fontSize: fontSize,
      readOnly: readOnly,
      showLineNumbers: showLineNumbers,
      language: language,
      autofocus: autofocus,
    );
    final error = errorText;
    final label = this.label;
    return Column(
      mainAxisSize: fit == _Fit.fill ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (label != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(label,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
        if (fit == _Fit.fill) Expanded(child: editor) else editor,
        if (error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: Text(
              error,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ),
      ],
    );
  }
}
