import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../config/config_parse.dart';
import '../services/l10n/locale_controller.dart';
import '../services/settings_storage.dart';

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
  if (first.startsWith('{') || first.startsWith('[')) {
    return LxCodeLanguage.json;
  }
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
    this.header,
    this.format = false,
    this.wrapToggle = false,
  }) : _fit = _Fit.fill,
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
    this.wordWrap = true,
    this.actions = const [],
    this.header,
    this.format = false,
    this.wrapToggle = false,
  }) : find = null,
       _fit = fit,
       _height = height,
       _minLines = minLines,
       _maxLines = maxLines,
       _onEdited = onEdited;

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
  ///
  /// sora-editor 0.23.6 рисует их только без переноса строк
  /// (`EditorRenderer.getStuckCodeBlocks` при `isWordwrap` возвращает
  /// пусто): при [wordWrap] параметр ни на что не влияет.
  final bool stickyHeaders;

  /// Свои кнопки поля (Copy конфига) — в строке кнопок над рамкой, справа,
  /// рядом с поиском, перед меню ⋮; на время панели поиска прячутся.
  final List<Widget> actions;

  /// Подпись слева в строке кнопок над рамкой (Source узла: «sing-box JSON:
  /// sent to the core as is…»): переносится в ширине, оставшейся от кнопок.
  final Widget? header;

  /// Пункт Format в меню ⋮ редактируемого поля (§660): виден, когда текст
  /// — JSON ([detectCodeLanguage]). Разбор JSON5, отступ 2 пробела; правка
  /// обычная — в undo и в `onChanged`. У поля только для чтения Format есть
  /// всегда, когда текст — JSON, и меняет только показ (Show original
  /// возвращает исходный); параметр там не нужен.
  final bool format;

  /// Кнопка переноса строк в строке кнопок (§649): у [LxJsonView] с липкими
  /// заголовками JSON и у редактора Config — там, где перенос по умолчанию
  /// выключен.
  /// Исходное значение — [wordWrap]; выбор живёт в `State` и нигде не
  /// хранится.
  final bool wrapToggle;

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

/// Пункты меню ⋮ редактора (§660).
enum _LxEditorMenu { format, magnifier }

/// Индикатор «занят» вместо иконки кнопки (§660), размер иконки 18.
class _LxBusyIcon extends StatelessWidget {
  const _LxBusyIcon({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox(
    width: 18,
    height: 18,
    child: CircularProgressIndicator(strokeWidth: 2),
  );
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

  /// В редакторе есть выделение — его ручки тянут и по вертикали, и по
  /// горизонтали, поэтому жесты целиком уходят редактору (§628).
  bool _selected = false;

  /// Текст не помещается в поле по вертикали.
  bool _scrollable = true;

  /// Поле во всю высоту (экран Config): страницы вокруг нет, касание
  /// целиком у редактора.
  bool _fill = false;

  /// Состояние прокрутки натива (`scrollState`): есть куда вбок, прокрутка
  /// у верхнего / нижнего края (§649).
  bool _canScrollX = false;
  bool _scrollTop = true;
  bool _scrollBottom = false;

  /// Натив считает раскладку строк (`layoutBusy`); полоса — только если
  /// счёт длится дольше [_layoutBusyDelay] (§649).
  Timer? _layoutBusyTimer;
  bool _showLayoutBusy = false;
  static const _layoutBusyDelay = Duration(milliseconds: 300);

  /// Порог сдвига, на котором решается, кому жест: не больше порога
  /// drag-распознавателей вкладок и страницы (`Scrollable` берёт его из
  /// `MediaQuery.gestureSettings`, на Android он меньше [kTouchSlop]).
  double _dragSlop = kTouchSlop;

  /// `PlatformViewLink` кэширует поверхность вместе с распознавателями,
  /// поэтому набор постоянный, а условия читаются заново на каждом
  /// касании (§628). Кому жест — §649: при выделении (или во всю высоту)
  /// редактору сразу, иначе по направлению на пороге сдвига
  /// ([lxEditorOwnsDrag]). Отдельного горизонтального drag нет: вбок,
  /// когда некуда, жест уходит вкладкам.
  late final Set<Factory<OneSequenceGestureRecognizer>> _recognizers = {
    Factory<OneSequenceGestureRecognizer>(
      () => LxEditorDragRecognizer(
        takesAtDown: () => _fill || _selected,
        takesDrag: (delta) => lxEditorOwnsDrag(
          delta,
          canScrollX: _canScrollX,
          scrollable: _scrollable,
          scrollTop: _scrollTop,
          scrollBottom: _scrollBottom,
        ),
        slop: () => _dragSlop,
      ),
    ),
    const Factory<OneSequenceGestureRecognizer>(LongPressGestureRecognizer.new),
  };
  Rect? _cursorRect;

  /// Каретка в первой / последней экранной строке (из `cursor`): стрелка
  /// вверх / вниз отсюда отдаёт фокус соседнему виджету.
  bool _atTop = true;
  bool _atBottom = true;

  bool _dark = false;
  Map<String, int> _colors = const {};

  bool _findOpen = false;
  final _findCtrl = TextEditingController();
  final _findFocus = FocusNode(debugLabel: 'lx-code-editor-find');
  int _matchIndex = -1;
  int _matchCount = 0;

  /// Пункт Format в меню виден (см. [LxCodeEditor.format]).
  bool _canFormat = false;

  /// Только чтение: показ отформатирован (§660), в редакторе этот текст
  /// вместо [LxCodeEditor.controller]; контроллер не трогаем. `null` —
  /// показ исходного текста. Новый текст сверху сбрасывает показ.
  String? _formattedView;

  /// Заглушка вне Android показывает [_formattedView] через свой контроллер.
  final _stubView = TextEditingController();

  /// Тело длиннее — форматирование показа вне главного изолята.
  static const _isolateFormatLimit = 64 * 1024;

  /// Редактор занят переносом или Format (§660): от нажатия до конца
  /// раскладки нового текста. Одно состояние на обе кнопки — перенос и ⋮
  /// недоступны, вместо иконок индикатор. Конец — ответ натива: на
  /// `setWordWrap` и `setText` с `waitLayout` натив отвечает после
  /// раскладки (первый `layoutBusy(false)`), `replaceAll` раскладывает
  /// синхронно; без натива ответ сразу.
  bool _busy = false;

  /// Страховка: натив не ответил — кнопки снова доступны.
  static const _busyTimeout = Duration(seconds: 30);

  /// Лупа выделения (§660): одна настройка на приложение, кэш на процесс.
  /// `null` — ещё не читали; до чтения — включена.
  static bool? _magnifier;
  static bool get _magnifierOn => _magnifier ?? true;
  static Future<void>? _magnifierWarm;

  /// Значение лупы, ушедшее в creation params.
  bool _creationMagnifier = true;

  /// Текст в редакторе: отформатированный показ или контроллер.
  String get _shownText => _formattedView ?? widget.controller.text;

  /// Текущий перенос строк: из [LxCodeEditor.wordWrap], кнопка
  /// [LxCodeEditor.wrapToggle] переключает на лету (§649).
  bool _wordWrap = true;

  MethodChannel? get _channel => _link?.channel;

  bool _computeCanFormat() =>
      (widget.readOnly || widget.format) &&
      detectCodeLanguage(widget.controller.text) == LxCodeLanguage.json;

  void _refreshFormat() {
    final v = _computeCanFormat();
    if (v != _canFormat && mounted) setState(() => _canFormat = v);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _nativeText = widget.controller.text;
    _rows = _countLines(_nativeText);
    _canFormat = _computeCanFormat();
    _wordWrap = widget.wordWrap;
    widget.controller.addListener(_onController);
    if (_nativeEditor && _magnifier == null) unawaited(_warmMagnifier());
  }

  /// Прогрев кэша лупы: первое чтение настройки на процесс (§660).
  Future<void> _warmMagnifier() async {
    await (_magnifierWarm ??= () async {
      try {
        final v = await SettingsStorage.getEditorMagnifier();
        _magnifier ??= v;
      } catch (_) {
        // Хранилище недоступно — лупа как по умолчанию.
      }
    }());
    if (!mounted) return;
    if (_channel != null && _magnifierOn != _creationMagnifier) {
      _creationMagnifier = _magnifierOn;
      unawaited(_invoke('setMagnifier', {'enabled': _magnifierOn}));
    }
    setState(() {});
  }

  /// Пункт Magnifier: сразу в этом редакторе, остальные — при создании.
  Future<void> _toggleMagnifier() async {
    final on = !_magnifierOn;
    setState(() => _magnifier = on);
    _creationMagnifier = on;
    unawaited(_invoke('setMagnifier', {'enabled': on}));
    try {
      await SettingsStorage.setEditorMagnifier(on);
    } catch (_) {
      // Не записалось — значение живёт до перезапуска.
    }
  }

  /// Сброс кэша лупы между тестами.
  @visibleForTesting
  static void debugResetMagnifier() {
    _magnifier = null;
    _magnifierWarm = null;
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
    if (oldWidget.wordWrap != widget.wordWrap) _setWordWrap(widget.wordWrap);
    _canFormat = _computeCanFormat();
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
    _layoutBusyTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_onController);
    _link?.detach();
    _stubView.dispose();
    _findCtrl.dispose();
    _findFocus.dispose();
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
    // В нативе отформатированный показ, не текст поля (§660).
    if (_channel == null || _formattedView != null) return;
    final text = await _invoke<String>('getText');
    if (text == null || !mounted) return;
    _applyNativeText(text);
  }

  /// Запись в контроллер из кода → натив.
  void _onController() {
    if (_syncing) return;
    _refreshFormat();
    final t = widget.controller.text;
    if (_formattedView != null) {
      // Сверху пришёл новый текст — показ снова исходный (§660).
      setState(() => _formattedView = null);
    }
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
    _refreshFormat();
    widget._onEdited?.call(text);
  }

  /// Перенос строк на лету: натив без пересоздания view (§649).
  /// Быстрые пересчёты (ввод, смена ширины) полосой не мигают: она
  /// появляется, только если раскладка не готова за [_layoutBusyDelay].
  void _onLayoutBusy(bool busy) {
    _layoutBusyTimer?.cancel();
    _layoutBusyTimer = null;
    if (busy) {
      _layoutBusyTimer = Timer(_layoutBusyDelay, () {
        if (mounted) setState(() => _showLayoutBusy = true);
      });
    } else if (_showLayoutBusy) {
      setState(() => _showLayoutBusy = false);
    }
  }

  /// Пока прошлое переключение не кончилось, вызов игнорируется (§660):
  /// повторные нажатия, D-pad, событие до перерисовки не копятся.
  void _setWordWrap(bool on) {
    if (_busy || on == _wordWrap) return;
    setState(() => _wordWrap = on);
    unawaited(
      _whileBusy(
        () => _invoke('setWordWrap', {
          'wordWrap': on,
        }).timeout(_busyTimeout, onTimeout: () => null),
      ),
    );
  }

  /// [job] под общим «занят» (§660); пока занято — не запускается.
  Future<void> _whileBusy(Future<void> Function() job) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await job();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Format в просмотрщике (только чтение, §660): меняет показ, хранимое
  /// тело (контроллер) не трогает. Комментарии JSON5 теряются без диалога —
  /// Show original вернёт всё. Тело больше [_isolateFormatLimit] —
  /// в изоляте, на это время полоса раскладки и пункт недоступен.
  Future<void> _formatView() async {
    final text = widget.controller.text;
    String? formatted;
    String? error;
    try {
      formatted = text.length > _isolateFormatLimit
          ? await compute(formatJson5, text)
          : formatJson5(text);
    } on FormatException catch (e) {
      error = e.message;
    }
    if (!mounted || widget.controller.text != text) return;
    if (error != null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(getLocalText.s("Failed to parse JSON: %s", error)),
        ),
      );
      return;
    }
    await _showView(formatted);
  }

  /// Показ в редакторе: [formatted] или (`null`) исходный текст контроллера.
  /// Завершается, когда натив разложил новый текст.
  Future<void> _showView(String? formatted) async {
    setState(() => _formattedView = formatted);
    final shown = _shownText;
    _nativeText = shown;
    if (formatted != null) _stubView.text = formatted;
    if (_channel != null) {
      await _invoke('setText', {
        'text': shown,
        'waitLayout': true,
      }).timeout(_busyTimeout, onTimeout: () => null);
    } else {
      final n = _countLines(shown);
      if (n != _rows) setState(() => _rows = n);
    }
  }

  /// Format: JSON5 → JSON с отступом 2 пробела (как Config при открытии).
  /// Правка обычная: натив кладёт её в undo и шлёт `changed`, экран видит
  /// несохранённые правки. Битый текст — снек, текст не меняется;
  /// комментарии теряются — сперва диалог.
  Future<void> _format() async {
    await flush();
    if (!mounted) return;
    final text = widget.controller.text;
    final String formatted;
    try {
      formatted = formatJson5(text);
    } on FormatException catch (e) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(getLocalText.s("Failed to parse JSON: %s", e.message)),
        ),
      );
      return;
    }
    if (formatted == text) return;
    if (hasJson5Comments(text)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(getLocalText.s("Comments will be removed")),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(getLocalText.s("Cancel")),
            ),
            FilledButton(
              key: const ValueKey('lx-code-editor-format-confirm'),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(getLocalText.s("Format")),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    if (_channel != null) {
      // Натив заменяет текст правкой (undo) и присылает `changed`; раскладка
      // правки синхронная — «занят» до ответа (§660).
      await _whileBusy(() => _invoke('replaceAll', {'text': formatted}));
      return;
    }
    _nativeText = formatted;
    _syncing = true;
    try {
      widget.controller.value = TextEditingValue(
        text: formatted,
        selection: const TextSelection.collapsed(offset: 0),
      );
    } finally {
      _syncing = false;
    }
    final n = _countLines(formatted);
    if (n != _rows) setState(() => _rows = n);
    _refreshFormat();
    widget._onEdited?.call(formatted);
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
        final focused = args['focused'] as bool? ?? false;
        if (focused != _focused) setState(() => _focused = focused);
        final selected = args['selected'] as bool? ?? false;
        _selected = selected;
        _atTop = args['atTop'] as bool? ?? true;
        _atBottom = args['atBottom'] as bool? ?? true;
        final rowH = ((args['rowHeight'] as num?) ?? 0) / dpr;
        final y = ((args['y'] as num?) ?? 0) / dpr;
        _cursorRect = Rect.fromLTWH(0, y, 1, rowH);
        if (_focused) _revealCursor();
      case 'layoutBusy':
        _onLayoutBusy(args['busy'] as bool? ?? false);
      case 'scrollState':
        _canScrollX = args['canScrollX'] as bool? ?? false;
        _scrollTop = args['scrollTop'] as bool? ?? true;
        _scrollBottom = args['scrollBottom'] as bool? ?? false;
      case 'searchResult':
        setState(() {
          _matchIndex = (args['index'] as num?)?.toInt() ?? -1;
          _matchCount = (args['count'] as num?)?.toInt() ?? 0;
        });
      case 'disposed':
        _link?.channel.setMethodCallHandler(null);
        _onLayoutBusy(false);
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
        rect: Rect.fromLTWH(
          0,
          rect.top,
          box.size.width,
          rect.height,
        ).inflate(8),
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
    if (_shownText != _creationText) {
      _nativeText = _shownText;
      unawaited(_invoke('setText', {'text': _nativeText}));
    }
    if (_magnifierOn != _creationMagnifier) {
      _creationMagnifier = _magnifierOn;
      unawaited(_invoke('setMagnifier', {'enabled': _magnifierOn}));
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
      'selection':
          (theme.textSelectionTheme.selectionColor ??
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
    if (open) {
      // Не `autofocus`: он не срабатывает, если в области фокуса уже есть
      // фокус — а он есть, когда открыт редактор (узел platform view), и
      // запрос уходил в текст.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _findOpen) _findFocus.requestFocus();
      });
    } else {
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

    _scrollable = scrollable;
    _fill = w._fit == _Fit.fill;
    final deviceSlop = MediaQuery.maybeGestureSettingsOf(context)?.touchSlop;
    _dragSlop = deviceSlop != null && deviceSlop < kTouchSlop
        ? deviceSlop
        : kTouchSlop;
    Widget field = _nativeEditor ? _buildNative() : _buildStub();
    if (_nativeEditor) {
      field = DecoratedBox(
        decoration: BoxDecoration(
          color: Color(_colors['background'] ?? 0),
          // Фокус в поле — рамка цвета акцента (на ТВ это единственный
          // признак, что D-pad привёл фокус сюда).
          border: _focused
              ? Border.all(color: cs.primary, width: 2)
              : Border.all(color: cs.outline),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Padding(
          padding: EdgeInsets.all(_focused ? _pad : _pad + 1),
          child: ClipRect(child: field),
        ),
      );
    }
    if (_showLayoutBusy) {
      // Натив долго считает раскладку (перенос большого тела, §649) —
      // тонкая полоса у верхнего края рамки, раскладку поля не меняет.
      final inset = _focused ? 2.0 : 1.0;
      field = Stack(
        fit: StackFit.passthrough,
        children: [
          field,
          Positioned(
            top: inset,
            left: inset,
            right: inset,
            child: const LinearProgressIndicator(
              key: ValueKey('lx-code-editor-layout-busy'),
              minHeight: 2,
            ),
          ),
        ],
      );
    }
    final hint = w.hint;
    if (_nativeEditor && hint != null && widget.controller.text.isEmpty) {
      field = Stack(
        fit: StackFit.passthrough,
        children: [
          field,
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
        ],
      );
    }
    if (height != null) {
      field = SizedBox(width: double.infinity, height: height, child: field);
    }

    // Кнопки поля — строкой над рамкой, справа; слева подпись [header].
    // Внутри рамки кнопок нет: текст с обычного отступа.
    final header = w.header;
    final buttons = <Widget>[
      if (w._find)
        IconButton(
          key: const ValueKey('lx-code-editor-find'),
          icon: const Icon(Icons.search, size: 18),
          tooltip: getLocalText.s("Find"),
          visualDensity: VisualDensity.compact,
          onPressed: () => _toggleFind(true),
        ),
      if (w.wrapToggle)
        IconButton(
          key: const ValueKey('lx-code-editor-wrap'),
          // Раскладка после переключения ещё идёт — индикатор (§660).
          icon: _busy
              ? const _LxBusyIcon(key: ValueKey('lx-code-editor-wrap-busy'))
              : const Icon(Icons.wrap_text, size: 18),
          tooltip: _wordWrap
              ? getLocalText.s("Unwrap lines")
              : getLocalText.s("Wrap lines"),
          visualDensity: VisualDensity.compact,
          // Включённый перенос — тональная подложка, как у
          // `IconButton.filledTonal`; выключенный — обычная кнопка.
          isSelected: _wordWrap,
          style: _wordWrap
              ? IconButton.styleFrom(
                  backgroundColor: cs.secondaryContainer,
                  foregroundColor: cs.onSecondaryContainer,
                )
              : null,
          onPressed: _busy ? null : () => _setWordWrap(!_wordWrap),
        ),
      ...w.actions,
      _buildMenu(),
    ];
    final top = <Widget>[
      if (!_findOpen)
        Row(
          key: const ValueKey('lx-code-editor-bar'),
          children: [
            Expanded(child: header ?? const SizedBox.shrink()),
            ...buttons,
          ],
        ),
      // Панель поиска заменяет строку кнопок; подпись остаётся над ней.
      if (_findOpen && header != null)
        Padding(padding: const EdgeInsets.only(bottom: 4), child: header),
      if (_findOpen)
        _LxFindPanel(
          controller: _findCtrl,
          focusNode: _findFocus,
          index: _matchIndex,
          count: _matchCount,
          onQuery: (q) => unawaited(_invoke('search', {'query': q})),
          onNext: () => unawaited(_invoke('searchNext')),
          onPrevious: () => unawaited(_invoke('searchPrevious')),
          onClose: () => _toggleFind(false),
        ),
    ];
    if (top.isEmpty) return field;
    return Column(
      mainAxisSize: height == null ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...top,
        if (height == null) Expanded(child: field) else field,
      ],
    );
  }

  /// Меню ⋮ — последним справа в строке кнопок (§660): Format (или Show
  /// original в просмотрщике) и лупа выделения.
  Widget _buildMenu() {
    final shownFormatted = _formattedView != null;
    return PopupMenuButton<_LxEditorMenu>(
      key: const ValueKey('lx-code-editor-menu'),
      icon: _busy
          ? const _LxBusyIcon(key: ValueKey('lx-code-editor-menu-busy'))
          : const Icon(Icons.more_vert, size: 18),
      enabled: !_busy,
      tooltip: getLocalText.s("More options"),
      style: IconButton.styleFrom(visualDensity: VisualDensity.compact),
      onSelected: (item) {
        switch (item) {
          case _LxEditorMenu.format:
            // Редактируемое поле: «занят» — только замена текста, не
            // диалог про комментарии.
            unawaited(
              !widget.readOnly
                  ? _format()
                  : _whileBusy(
                      shownFormatted ? () => _showView(null) : _formatView,
                    ),
            );
          case _LxEditorMenu.magnifier:
            unawaited(_toggleMagnifier());
        }
      },
      itemBuilder: (context) => [
        if (_canFormat)
          PopupMenuItem(
            key: const ValueKey('lx-code-editor-format'),
            value: _LxEditorMenu.format,
            child: Text(
              shownFormatted
                  ? getLocalText.s("Show original")
                  : getLocalText.s("Format"),
            ),
          ),
        CheckedPopupMenuItem(
          key: const ValueKey('lx-code-editor-magnifier'),
          value: _LxEditorMenu.magnifier,
          checked: _magnifierOn,
          child: Text(getLocalText.s("Magnifier")),
        ),
      ],
    );
  }

  /// Заглушка вне Android: обычный `TextField` с той же раскладкой.
  Widget _buildStub() {
    final w = widget;
    // Высоту задаёт обёртка (родитель, фиксированная или по строкам).
    return TextField(
      controller: _formattedView != null ? _stubView : w.controller,
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

  Widget _buildNative() {
    // Текст помещается — вертикальные свайпы уходят странице; нет — их
    // забирает редактор. Тап, долгий тап, горизонтальный свайп — редактору.
    // Пока есть выделение — всё редактору: иначе ручку выделения уводят
    // вертикальный скролл страницы и свайп вкладок (§628).
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (has) {
        // Фокус пришёл обходом Flutter (D-pad на ТВ, Tab) — нативный view
        // сам его не берёт.
        if (has && !_focused) unawaited(_invoke('focus'));
      },
      onKeyEvent: _onKey,
      child: _buildView(),
    );
  }

  /// Клавиши при фокусе в редакторе — натив, мимо `Shortcuts` приложения:
  /// иначе стрелки (с модификаторами и без, от аппаратной клавиатуры и от
  /// IME через `sendKeyEvent`) забирал `DirectionalFocusIntent`, фокус
  /// уходил из view и клавиатура сворачивалась. Исключения — Escape
  /// (закрыть диалог / шторку) и простые ↑/↓ на первой / последней строке:
  /// они уводят фокус к соседнему виджету (D-pad на ТВ).
  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    final key = e.logicalKey;
    if (key == LogicalKeyboardKey.escape) return KeyEventResult.ignored;
    if (e is! KeyUpEvent) {
      final hk = HardwareKeyboard.instance;
      final plain =
          !hk.isShiftPressed &&
          !hk.isControlPressed &&
          !hk.isAltPressed &&
          !hk.isMetaPressed;
      if (plain &&
          ((key == LogicalKeyboardKey.arrowUp && _atTop) ||
              (key == LogicalKeyboardKey.arrowDown && _atBottom))) {
        return KeyEventResult.ignored;
      }
    }
    return KeyEventResult.skipRemainingHandlers;
  }

  Widget _buildView() {
    final w = widget;
    return PlatformViewLink(
      key: _viewKey,
      viewType: _viewType,
      surfaceFactory: (context, controller) => AndroidViewSurface(
        controller: controller as AndroidViewController,
        gestureRecognizers: _recognizers,
        hitTestBehavior: PlatformViewHitTestBehavior.opaque,
      ),
      onCreatePlatformView: (params) {
        _creationText = _shownText;
        _nativeText = _creationText;
        _creationMagnifier = _magnifierOn;
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
            'wordWrap': _wordWrap,
            'language': w.language?.name,
            'locale': LocaleController.I.effectiveTag,
            'autofocus': w.autofocus,
            'stickyHeaders': w.stickyHeaders,
            'magnifier': _creationMagnifier,
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
    _creationText = _shownText;
    _creationMagnifier = _magnifierOn;
    _attach(viewId);
  }

  /// Высота, которую поле сейчас занимает по метрикам (для тестов роста).
  @visibleForTesting
  int get debugRows => _rows;
}

/// Панель поиска над текстом редактора: поле, счёт совпадений,
/// предыдущее/следующее, закрыть. Пустой запрос снимает подсветку.
/// Кому жест без выделения (§649), по сдвигу [delta] на пороге:
/// - вбок (|dx| > |dy|) — редактору, если есть куда вбок ([canScrollX]);
/// - вертикально — редактору, если текст не помещается ([scrollable]) и
///   в эту сторону есть куда мотать: палец вниз — прокрутка не у верхнего
///   края ([scrollTop]), палец вверх — не у нижнего ([scrollBottom]);
/// - иначе — вкладкам / странице.
@visibleForTesting
bool lxEditorOwnsDrag(
  Offset delta, {
  required bool canScrollX,
  required bool scrollable,
  required bool scrollTop,
  required bool scrollBottom,
}) {
  if (delta.dx.abs() > delta.dy.abs()) return canScrollX;
  if (!scrollable) return false;
  return delta.dy > 0 ? !scrollTop : !scrollBottom;
}

/// Распознаватель platform view редактора (§649). Если [takesAtDown]
/// истинен — берёт касание сразу, как [EagerGestureRecognizer] (ручки
/// выделения тянут в любую сторону, §628). Иначе ждёт сдвига пальца больше
/// [slop] по любой оси и решает по [takesDrag]: принять — вся
/// последовательность (с буферизованными до решения событиями) уходит
/// native view; отклонить — жест разыгрывают вкладки и страница. Решение —
/// на весь жест.
@visibleForTesting
class LxEditorDragRecognizer extends OneSequenceGestureRecognizer {
  LxEditorDragRecognizer({
    required this.takesAtDown,
    required this.takesDrag,
    required this.slop,
  });

  final bool Function() takesAtDown;
  final bool Function(Offset delta) takesDrag;
  final double Function() slop;

  /// Точка касания указателей, по которым решение ещё не принято.
  final Map<int, Offset> _origins = {};

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    if (takesAtDown()) {
      resolvePointer(event.pointer, GestureDisposition.accepted);
      stopTrackingPointer(event.pointer);
      return;
    }
    _origins[event.pointer] = event.position;
  }

  @override
  void handleEvent(PointerEvent event) {
    final origin = _origins[event.pointer];
    if (origin != null && event is PointerMoveEvent) {
      final delta = event.position - origin;
      final s = slop();
      if (delta.dx.abs() > s || delta.dy.abs() > s) {
        _origins.remove(event.pointer);
        resolvePointer(
          event.pointer,
          takesDrag(delta)
              ? GestureDisposition.accepted
              : GestureDisposition.rejected,
        );
        stopTrackingPointer(event.pointer);
        return;
      }
    }
    stopTrackingIfPointerNoLongerDown(event);
  }

  @override
  void acceptGesture(int pointer) {
    _origins.remove(pointer);
  }

  @override
  void rejectGesture(int pointer) {
    _origins.remove(pointer);
    stopTrackingPointer(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _origins.remove(pointer);
  }

  @override
  String get debugDescription => 'lx editor drag';
}

class _LxFindPanel extends StatelessWidget {
  const _LxFindPanel({
    required this.controller,
    required this.focusNode,
    required this.index,
    required this.count,
    required this.onQuery,
    required this.onNext,
    required this.onPrevious,
    required this.onClose,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
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
              focusNode: focusNode,
              style: const TextStyle(fontSize: 13),
              textInputAction: TextInputAction.search,
              onChanged: onQuery,
              onSubmitted: (_) => onNext(),
              // Search на клавиатуре — к следующему совпадению, фокус и
              // клавиатура остаются в поле запроса.
              onEditingComplete: () {},
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
    this.actions = const [],
    this.header,
  });

  final String text;
  final double? height;
  final double fontSize;
  final bool showLineNumbers;

  /// `null` — без подсветки (тело подписки не-JSON: base64, ссылки).
  final LxCodeLanguage? language;
  final bool stickyHeaders;

  /// Кнопки (Copy) и подпись над рамкой — см. [LxCodeEditor.actions],
  /// [LxCodeEditor.header].
  final List<Widget> actions;
  final Widget? header;

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
    // Липкие заголовки sora рисует только без переноса строк; в
    // просмотрщике JSON прокрутка вбок допустима, перенос уступает им.
    final sticky =
        widget.stickyHeaders && widget.language == LxCodeLanguage.json;
    return LxCodeEditor._sized(
      controller: _ctrl,
      fit: h == null ? _Fit.fill : _Fit.fixed,
      height: h,
      wordWrap: !sticky,
      readOnly: true,
      fontSize: widget.fontSize,
      showLineNumbers: widget.showLineNumbers,
      language: widget.language,
      stickyHeaders: widget.stickyHeaders,
      wrapToggle: sticky,
      actions: widget.actions,
      header: widget.header,
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
    this.header,
    this.format = true,
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

  /// Подпись над полем — слева в строке кнопок (как [header]).
  final String? label;

  /// Подпись-виджет слева в строке кнопок над рамкой; важнее [label].
  final Widget? header;

  /// Кнопка Format (см. [LxCodeEditor.format]).
  final bool format;

  /// Ошибка под полем.
  final String? errorText;
  final bool readOnly;

  /// Фокус и клавиатура при открытии (диалог Edit server в папке).
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = this.label;
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
      format: format,
      header:
          header ??
          (label == null
              ? null
              : Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                )),
    );
    final error = errorText;
    return Column(
      mainAxisSize: fit == _Fit.fill ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (fit == _Fit.fill) Expanded(child: editor) else editor,
        if (error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: Text(
              error,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }
}
