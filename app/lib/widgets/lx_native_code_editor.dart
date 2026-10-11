import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// Прототип: нативный редактор JSON (sora-editor) через platform view,
/// hybrid composition. Kotlin-сторона — `editor/SoraEditorPlatformView.kt`.
///
/// Три обёртки над общим [_SoraView]:
///  * [LxNativeCodeEditor] + [LxNativeCodeEditorController] — во всю высоту
///    (экран Config);
///  * [LxNativeTextCodeField] — поле на [TextEditingController], фиксированная
///    высота или рост по строкам (`minLines`/`maxLines`);
///  * [LxNativeJsonView] — только чтение, фиксированная высота.
///
/// Текст — истина на стороне Dart: натив присылает его на каждую правку
/// (`changed`), creation params пересоздаваемого view берут актуальный.

/// Минимум, что общему view нужно от владельца текста.
abstract class _SoraTextHost {
  /// Текст для creation params (на пересоздании view — актуальный).
  String get currentText;

  /// Правка из натива. `text == null` — текст длинный, придёт позже целиком.
  void onNativeText(String? text);
}

class _SoraView extends StatefulWidget {
  const _SoraView({
    required this.host,
    required this.readOnly,
    required this.lineNumbers,
    required this.fontSize,
    required this.scrollable,
    this.onMetrics,
    this.onChannel,
  });

  final _SoraTextHost host;
  final bool readOnly;
  final bool lineNumbers;
  final double fontSize;

  /// Нужен ли внутренний вертикальный скролл. `false` — вертикальные свайпы
  /// уходят родительской прокрутке (поле в странице), view получает тапы,
  /// долгий тап и горизонтальный свайп.
  final bool scrollable;

  /// Число строк и высота строки (логические px) — для растущего поля.
  final void Function(int lines, double rowHeight)? onMetrics;
  final void Function(MethodChannel? channel)? onChannel;

  @override
  State<_SoraView> createState() => _SoraViewState();
}

class _SoraViewState extends State<_SoraView> with WidgetsBindingObserver {
  static const _viewType = 'lxbox/sora_editor';
  MethodChannel? _channel;
  bool? _dark;
  bool _focused = false;
  Rect? _cursorRect;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (_dark != null && _dark != dark) {
      unawaited(_channel?.invokeMethod<void>('setDark', {'dark': dark}));
    }
    _dark = dark;
  }

  @override
  void didUpdateWidget(_SoraView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.readOnly != widget.readOnly) {
      unawaited(_channel?.invokeMethod<void>(
          'setReadOnly', {'readOnly': widget.readOnly}));
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
    _channel?.setMethodCallHandler(null);
    widget.onChannel?.call(null);
    super.dispose();
  }

  void _revealCursor() {
    final rect = _cursorRect;
    if (!mounted || rect == null) return;
    final box = context.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      box.showOnScreen(
        rect: rect.inflate(8),
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    }
  }

  Future<Object?> _onCall(MethodCall call) async {
    final args = (call.arguments as Map?) ?? const {};
    final dpr = MediaQuery.of(context).devicePixelRatio;
    switch (call.method) {
      case 'changed':
        widget.host.onNativeText(args['text'] as String?);
        widget.onMetrics?.call(
          args['lines'] as int? ?? 1,
          ((args['rowHeight'] as num?) ?? 0) / dpr,
        );
      case 'cursor':
        _focused = args['focused'] as bool? ?? false;
        final rowH = ((args['rowHeight'] as num?) ?? 0) / dpr;
        final y = ((args['y'] as num?) ?? 0) / dpr;
        final box = context.findRenderObject();
        final width = box is RenderBox && box.hasSize ? box.size.width : 1.0;
        _cursorRect = Rect.fromLTWH(0, y, width, rowH);
        if (_focused) _revealCursor();
    }
    return null;
  }

  void _attach(int id) {
    final ch = MethodChannel('com.leadaxe.lxbox/sora_editor_$id');
    ch.setMethodCallHandler(_onCall);
    _channel = ch;
    widget.onChannel?.call(ch);
  }

  @override
  Widget build(BuildContext context) {
    final recognizers = <Factory<OneSequenceGestureRecognizer>>{
      if (widget.scrollable)
        const Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new)
      else ...[
        const Factory<OneSequenceGestureRecognizer>(
            HorizontalDragGestureRecognizer.new),
        const Factory<OneSequenceGestureRecognizer>(
            LongPressGestureRecognizer.new),
      ],
    };
    return PlatformViewLink(
      viewType: _viewType,
      surfaceFactory: (context, controller) => AndroidViewSurface(
        controller: controller as AndroidViewController,
        gestureRecognizers: recognizers,
        hitTestBehavior: PlatformViewHitTestBehavior.opaque,
      ),
      onCreatePlatformView: (params) {
        final c = PlatformViewsService.initExpensiveAndroidView(
          id: params.id,
          viewType: _viewType,
          layoutDirection: TextDirection.ltr,
          creationParams: <String, Object?>{
            'dark': _dark ?? false,
            'readOnly': widget.readOnly,
            'lineNumbers': widget.lineNumbers,
            'fontSize': widget.fontSize,
            'text': widget.host.currentText,
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
}

// ---------------------------------------------------------------------------
// Экран Config: во всю высоту, текст через контроллер.
// ---------------------------------------------------------------------------

class LxNativeCodeEditorController implements _SoraTextHost {
  MethodChannel? _channel;
  String _text = '';

  @override
  String get currentText => _text;

  @override
  void onNativeText(String? text) {
    if (text != null) _text = text;
  }

  /// Точный текст: у натива (длинный текст Dart получает с задержкой).
  Future<String> getText() async {
    final ch = _channel;
    if (ch == null) return _text;
    final t = await ch.invokeMethod<String>('getText') ?? _text;
    _text = t;
    return t;
  }

  Future<void> setText(String text) async {
    _text = text;
    await _channel?.invokeMethod<void>('setText', {'text': text});
  }

  Future<void> search(String query) async =>
      _channel?.invokeMethod<void>('search', {'query': query});

  Future<void> searchNext() async => _channel?.invokeMethod<void>('searchNext');

  Future<void> searchPrevious() async =>
      _channel?.invokeMethod<void>('searchPrevious');
}

class LxNativeCodeEditor extends StatelessWidget {
  const LxNativeCodeEditor({
    super.key,
    required this.controller,
    this.readOnly = false,
  });

  final LxNativeCodeEditorController controller;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    return _SoraView(
      host: controller,
      readOnly: readOnly,
      lineNumbers: true,
      fontSize: 13,
      scrollable: true,
      onChannel: (ch) => controller._channel = ch,
    );
  }
}

// ---------------------------------------------------------------------------
// Поле на TextEditingController: фиксированная высота или рост по строкам.
// ---------------------------------------------------------------------------

class LxNativeTextCodeField extends StatefulWidget {
  const LxNativeTextCodeField({
    super.key,
    required this.controller,
    this.onChanged,
    this.height,
    this.minLines,
    this.maxLines,
    this.fontSize = 12,
    this.showLineNumbers = true,
    this.label,
    this.errorText,
    this.readOnly = false,
  });

  final TextEditingController controller;
  final ValueChanged<String>? onChanged;

  /// Фиксированная высота; иначе — рост от [minLines] до [maxLines].
  final double? height;
  final int? minLines;
  final int? maxLines;
  final double fontSize;
  final bool showLineNumbers;
  final String? label;
  final String? errorText;
  final bool readOnly;

  @override
  State<LxNativeTextCodeField> createState() => _LxNativeTextCodeFieldState();
}

class _LxNativeTextCodeFieldState extends State<LxNativeTextCodeField>
    implements _SoraTextHost {
  static const _vPad = 8.0;
  MethodChannel? _channel;
  late String _lastNative = widget.controller.text;
  int _lines = 1;
  double _rowH = 0;

  @override
  void initState() {
    super.initState();
    _lines = '\n'.allMatches(widget.controller.text).length + 1;
    widget.controller.addListener(_onController);
  }

  @override
  void didUpdateWidget(LxNativeTextCodeField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onController);
      widget.controller.addListener(_onController);
      _onController();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onController);
    super.dispose();
  }

  @override
  String get currentText => widget.controller.text;

  @override
  void onNativeText(String? text) {
    if (text == null || text == widget.controller.text) return;
    _lastNative = text;
    widget.controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    widget.onChanged?.call(text);
  }

  /// Правка контроллера из Dart (вставка, сброс) — в натив; эхо пропускаем.
  void _onController() {
    final t = widget.controller.text;
    if (t == _lastNative) return;
    _lastNative = t;
    unawaited(_channel?.invokeMethod<void>('setText', {'text': t}));
  }

  void _onMetrics(int lines, double rowH) {
    if (lines == _lines && rowH == _rowH) return;
    setState(() {
      _lines = lines;
      _rowH = rowH;
    });
  }

  double get _rowHeight =>
      _rowH > 0 ? _rowH : widget.fontSize * MediaQuery.textScalerOf(context).scale(1) * 1.5;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final double h;
    final bool scrollable;
    if (widget.height != null) {
      h = widget.height!;
      scrollable = _lines * _rowHeight + _vPad > h;
    } else {
      final minL = widget.minLines ?? 1;
      final maxL = widget.maxLines ?? 1 << 20;
      final shown = _lines.clamp(minL, math.max(minL, maxL));
      h = shown * _rowHeight + _vPad;
      scrollable = _lines > shown;
    }
    final err = widget.errorText;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.label != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(widget.label!,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          ),
        Container(
          height: h,
          decoration: BoxDecoration(
            border: Border.all(color: err != null ? cs.error : cs.outline),
            borderRadius: BorderRadius.circular(4),
          ),
          clipBehavior: Clip.hardEdge,
          child: _SoraView(
            host: this,
            readOnly: widget.readOnly,
            lineNumbers: widget.showLineNumbers,
            fontSize: widget.fontSize,
            scrollable: scrollable,
            onMetrics: _onMetrics,
            onChannel: (ch) => _channel = ch,
          ),
        ),
        if (err != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 12),
            child: Text(err, style: TextStyle(fontSize: 12, color: cs.error)),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Только чтение, фиксированная высота.
// ---------------------------------------------------------------------------

class LxNativeJsonView extends StatefulWidget {
  const LxNativeJsonView({
    super.key,
    required this.text,
    this.height = 300,
    this.fontSize = 12,
  });

  final String text;
  final double height;
  final double fontSize;

  @override
  State<LxNativeJsonView> createState() => _LxNativeJsonViewState();
}

class _LxNativeJsonViewState extends State<LxNativeJsonView>
    implements _SoraTextHost {
  MethodChannel? _channel;
  int _lines = 1;
  double _rowH = 0;

  @override
  void initState() {
    super.initState();
    _lines = '\n'.allMatches(widget.text).length + 1;
  }

  @override
  void didUpdateWidget(LxNativeJsonView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      unawaited(
          _channel?.invokeMethod<void>('setText', {'text': widget.text}));
    }
  }

  @override
  String get currentText => widget.text;

  @override
  void onNativeText(String? text) {}

  @override
  Widget build(BuildContext context) {
    final rowH = _rowH > 0 ? _rowH : widget.fontSize * 1.5;
    return SizedBox(
      height: widget.height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: _SoraView(
          host: this,
          readOnly: true,
          lineNumbers: false,
          fontSize: widget.fontSize,
          scrollable: _lines * rowH > widget.height,
          onMetrics: (lines, rowH) {
            if (lines != _lines || rowH != _rowH) {
              setState(() {
                _lines = lines;
                _rowH = rowH;
              });
            }
          },
          onChannel: (ch) => _channel = ch,
        ),
      ),
    );
  }
}
