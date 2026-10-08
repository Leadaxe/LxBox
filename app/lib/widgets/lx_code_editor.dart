import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';

import '../services/l10n/locale_controller.dart';

/// §333 — обёртка над re_editor для больших редактируемых текстов.
///
/// Зачем не `TextField`: тот держит документ единым `Paragraph` (re-layout
/// всего текста на каждый символ) и на каждый keystroke шлёт весь текст в
/// Android IME. На конфиге в сотни КБ это 100% CPU и смерть от lmkd.
/// `CodeEditor` держит документ построчно: layout — только видимых строк,
/// в IME уезжает только строка с курсором.
///
/// §521 — `StatefulWidget`, а не `StatelessWidget`. Контроллер меню обязан
/// жить столько же, сколько сам редактор: см. докблок
/// `LxSelectionToolbarController`.
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
    this.autofocus,
    this.folding,
    this.find,
    this.actions = const [],
  });

  final CodeLineEditingController controller;
  final String? hint;
  final double fontSize;
  final bool readOnly;
  final bool showLineNumbers;
  final bool wordWrap;

  /// §554 — язык подсветки синтаксиса. `null` — без подсветки (поле ссылки
  /// в мастере). Подсветка живёт в `re_highlight`, тема — по яркости темы
  /// приложения; ключ `root` темы вырезан, чтобы фон редактора остался
  /// фоном экрана.
  final LxCodeLanguage? language;

  /// `null` — умолчание пакета (`CodeEditor` берёт фокус при появлении).
  /// Просмотрщик ([LxJsonView]) передаёт `false`: без этого вкладка JSON
  /// забирает фокус и запускает мигание курсора в тексте только для чтения.
  final bool? autofocus;

  /// §614 — свёртка блоков `{}`/`[]` (индикаторы в gutter). `null` — как
  /// [showLineNumbers]: где есть номера строк, там есть и свёртка.
  final bool? folding;

  /// §614 — поиск по тексту: иконка в правом верхнем углу поля открывает
  /// панель поиска над текстом. `null` — как [showLineNumbers].
  final bool? find;

  /// §614 — свои кнопки поля (например, Copy конфига) в правом верхнем
  /// углу рядом с иконкой поиска; на время открытой панели поиска прячутся,
  /// чтобы не лечь поверх неё.
  final List<Widget> actions;

  bool get _folding => folding ?? showLineNumbers;
  bool get _find => find ?? showLineNumbers;

  @override
  State<LxCodeEditor> createState() => _LxCodeEditorState();
}

/// §554 — языки, которые умеет подсвечивать [LxCodeEditor].
enum LxCodeLanguage { json }

CodeHighlightTheme _highlightTheme(LxCodeLanguage language, Brightness b) {
  final base = b == Brightness.dark ? atomOneDarkTheme : atomOneLightTheme;
  final theme = Map<String, TextStyle>.of(base)..remove('root');
  final mode = switch (language) {
    LxCodeLanguage.json => CodeHighlightThemeMode(mode: langJson),
  };
  return CodeHighlightTheme(
    languages: {language.name: mode},
    theme: theme,
  );
}

class _LxCodeEditorState extends State<LxCodeEditor> {
  /// Один контроллер меню на весь срок жизни редактора — создаётся здесь, а
  /// не в `build()`. Это и есть фикс §521: пока он пересоздавался на каждом
  /// `build`, у нового экземпляра `_entry == null`, и он не мог снять оверлей,
  /// вставленный предыдущим, — меню копились на экране.
  late final LxSelectionToolbarController _toolbar;

  /// Фокус свой, а не пакетный: нода должна переживать пересборку виджета
  /// вместе с контроллером меню. Пакет создаёт её сам в `initState`
  /// (`code_editor.dart:448-454`) и живёт с ней столько же, сколько мы, так
  /// что поведение то же — но теперь снятие меню не зависит от того, чья
  /// нода в дереве после очередного `build`.
  late final FocusNode _focusNode;

  /// §614 — контроллер поиска свой: иконка открытия живёт снаружи
  /// `CodeEditor` и должна видеть, открыта ли панель.
  late CodeFindController _findController;

  @override
  void initState() {
    super.initState();
    _toolbar = LxSelectionToolbarController()..readOnly = widget.readOnly;
    _focusNode = FocusNode(debugLabel: 'LxCodeEditor');
    _findController = CodeFindController(widget.controller);
    widget.controller.addListener(_onSelectionChanged);
  }

  @override
  void didUpdateWidget(LxCodeEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    _toolbar.readOnly = widget.readOnly;
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onSelectionChanged);
      widget.controller.addListener(_onSelectionChanged);
      _toolbar.hide(context);
      // Пакет сам переподписывается на смену findController в своём
      // didUpdateWidget; старый — наш, его и закрываем.
      final old = _findController;
      _findController = CodeFindController(widget.controller);
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
  }

  /// Выделение схлопнулось (тап по пустому месту, стрелка, правка) — меню
  /// больше нечему принадлежать.
  ///
  /// Страховка, а не единственный путь: в харнессе пакет и сам зовёт
  /// `hideToolbar` на этих жестах (`_code_selection.dart:172-176,188-192`).
  /// Но он зовёт его у `widget.toolbarController` — того экземпляра, что в
  /// дереве сейчас; §521 как раз о том, что висеть мог оверлей другого.
  /// Здесь снимает тот, кто записью и владеет.
  void _onSelectionChanged() {
    if (widget.controller.selection.isCollapsed && _toolbar.isShown) {
      _toolbar.hide(context);
    }
  }

  /// Смена маршрута/ухода экрана: оверлей живёт в root-overlay и переживает
  /// уход нашего поддерева, поэтому снимаем его руками.
  @override
  void deactivate() {
    _toolbar.hide(context);
    super.deactivate();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onSelectionChanged);
    _toolbar.dispose();
    _focusNode.dispose();
    _findController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Тап вне редактора и вне меню (пустое место экрана). `groupId` тот же,
    // что у обёртки меню, поэтому тап по кнопке меню «внутри» группы и здесь
    // НЕ считается тапом вне — Copy копирует выделенное, а не пустую строку.
    //
    // Страховка поверх штатного пути: пакет на такой тап делает `unfocus`
    // (`_code_editable.dart:266-269`), а потеря фокуса зовёт `hideToolbar`
    // (`:318-331`). Нам нужно снять оверлей даже если фокус в этот момент
    // принадлежит не нам.
    final folding = widget._folding;
    final find = widget._find;
    final editor = CodeEditorTapRegion(
      onTapOutside: (_) => _toolbar.hide(context),
      child: CodeEditor(
        controller: widget.controller,
        findController: _findController,
        findBuilder: find
            ? (context, controller, readOnly) =>
                _LxFindPanel(controller: controller)
            : null,
        chunkAnalyzer: folding
            ? const DefaultCodeChunkAnalyzer()
            : const NonCodeChunkAnalyzer(),
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        readOnly: widget.readOnly,
        wordWrap: widget.wordWrap,
        hint: widget.hint,
        padding: const EdgeInsets.all(12),
        border: Border.all(color: cs.outline),
        borderRadius: const BorderRadius.all(Radius.circular(4)),
        style: CodeEditorStyle(
          fontSize: widget.fontSize,
          fontFamily: 'monospace',
          textColor: cs.onSurface,
          hintTextColor: cs.onSurfaceVariant,
          codeTheme: widget.language == null
              ? null
              : _highlightTheme(widget.language!, Theme.of(context).brightness),
        ),
        toolbarController: _toolbar,
        indicatorBuilder: widget.showLineNumbers || folding
            ? (context, editingController, chunkController, notifier) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.showLineNumbers)
                      DefaultCodeLineNumber(
                        controller: editingController,
                        notifier: notifier,
                      ),
                    if (folding)
                      DefaultCodeChunkIndicator(
                        width: 16,
                        controller: chunkController,
                        notifier: notifier,
                      ),
                  ],
                )
            : null,
      ),
    );
    if (!find && widget.actions.isEmpty) return editor;
    // Иконка поиска — в правом верхнем углу поля, пока панель закрыта.
    // Панель встаёт в верх поля (её высоту пакет добавляет к отступу
    // текста), поэтому экранная клавиатура её не перекрывает.
    return Stack(
      fit: StackFit.passthrough,
      children: [
        editor,
        Positioned(
          top: 2,
          right: 2,
          child: ListenableBuilder(
            listenable: _findController,
            builder: (context, _) => _findController.value != null
                ? const SizedBox.shrink()
                : CodeEditorTapRegion(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (find)
                          IconButton(
                            key: const ValueKey('lx-code-editor-find'),
                            icon: const Icon(Icons.search, size: 18),
                            tooltip: getLocalText.s("Find"),
                            visualDensity: VisualDensity.compact,
                            onPressed: _findController.findMode,
                          ),
                        ...widget.actions,
                      ],
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

/// §614 — панель поиска над текстом редактора: поле, счёт совпадений,
/// предыдущее/следующее, закрыть. Свой виджет, а не панель из примера
/// пакета: та шириной 360 и с заменой, на телефоне не помещается.
class _LxFindPanel extends StatelessWidget implements PreferredSizeWidget {
  const _LxFindPanel({required this.controller});

  final CodeFindController controller;

  static const double _height = 40;

  @override
  Size get preferredSize =>
      Size(double.infinity, controller.value == null ? 0 : _height);

  @override
  Widget build(BuildContext context) {
    final value = controller.value;
    if (value == null) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final result = value.result;
    final count = result == null || result.matches.isEmpty
        ? '0/0' // l10n-exempt: счёт совпадений
        : '${result.index + 1}/${result.matches.length}';
    return CodeEditorTapRegion(
      child: Container(
        key: const ValueKey('lx-code-editor-find-panel'),
        height: _height,
        padding: const EdgeInsets.fromLTRB(8, 2, 2, 2),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          border: Border(bottom: BorderSide(color: cs.outlineVariant)),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller.findInputController,
                focusNode: controller.findInputFocusNode,
                style: const TextStyle(fontSize: 13),
                textInputAction: TextInputAction.search,
                onSubmitted: (_) {
                  controller.nextMatch();
                  controller.focusOnFindInput();
                },
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: getLocalText.s("Find"),
                ),
              ),
            ),
            Text(count, style: Theme.of(context).textTheme.bodySmall),
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_up, size: 18),
              tooltip: getLocalText.s("Previous match"),
              visualDensity: VisualDensity.compact,
              onPressed: controller.previousMatch,
            ),
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_down, size: 18),
              tooltip: getLocalText.s("Next match"),
              visualDensity: VisualDensity.compact,
              onPressed: controller.nextMatch,
            ),
            IconButton(
              key: const ValueKey('lx-code-editor-find-close'),
              icon: const Icon(Icons.close, size: 18),
              tooltip: getLocalText.s("Close"),
              visualDensity: VisualDensity.compact,
              onPressed: controller.close,
            ),
          ],
        ),
      ),
    );
  }
}

/// §517 — контекстное меню выделения через `OverlayEntry`, а не `showMenu`.
///
/// Было: `showMenu` = `Navigator.push` модального `PopupRoute`. Маршрут
/// забирает фокус у редактора и ставит поверх барьер; re_editor снимает
/// выделение на любом тапе вне текста (`_code_selection.dart:172-176,188-192`
/// — `_selectPosition` + `hideHandle` + `hideToolbar`), поэтому выделение
/// схлопывалось в каретку ещё до того, как сработает `onTap` элемента меню
/// (у `PopupMenuItem` он вызывается ПОСЛЕ закрытия маршрута) — `copy`
/// копировал не то, что человек выделил.
///
/// Стало: оверлей, как и задумано контрактом пакета (`show` получает
/// `layerLink` и `visibility` именно под `CompositedTransformFollower`).
/// Оверлей фокус не забирает, `CodeEditorTapRegion` помечает меню «своим»
/// для редактора — тап по кнопке не считается тапом вне текста, выделение
/// живо, действия работают с настоящим диапазоном.
///
/// Свой класс, а не штатный `MobileSelectionToolbarController`: тот делает
/// `offset: -renderRect!.topLeft` (`_code_selection.dart:1134`), а
/// `renderRect` не-null только на мобильной ветке — на desktop/в тестах
/// `_DesktopSelectionOverlayController.showToolbar` (`:454-461`) передаёт
/// `null` и штатный контроллер падает.
///
/// §521 — экземпляр обязан жить столько же, сколько редактор, и владеть им
/// должен `State`, а не `build()`. Пакет капризен именно здесь: свой
/// `_selectionOverlayController` он собирает один раз в `initState`
/// (`code_editor.dart:386`) и читает `widget.toolbarController` в момент
/// каждого показа (`:395`, `:409`), а в `didUpdateWidget` (`:447-490`) это
/// поле не сверяет и старому контроллеру `hide()` не зовёт. Значит при
/// подмене экземпляра между сборками дерева живой `OverlayEntry` остаётся
/// висеть на экране, а `show()` нового экземпляра снимать его не может —
/// у того `_entry == null`. Ровно так на экране и накапливались три меню.
class LxSelectionToolbarController implements SelectionToolbarController {
  LxSelectionToolbarController();

  /// §607 — read-only редактор: в меню только Copy и Select all.
  /// `cut()`/`paste()` пакета безусловны (его `readOnly` держит лишь
  /// клавиатурный ввод), поэтому правящие пункты сюда просто не кладём.
  bool readOnly = false;

  OverlayEntry? _entry;
  bool _disposed = false;

  /// Видно ли меню сейчас — для тестов и для идемпотентного `hide`.
  bool get isShown => _entry != null;

  @override
  void hide(BuildContext context) {
    // `mounted` у entry: пакет может позвать `hide` после того, как оверлей
    // уже снесён вместе с `Overlay` (уход маршрута) — `remove()` по такому
    // entry бросает assert.
    final entry = _entry;
    _entry = null;
    if (entry != null && entry.mounted) {
      entry.remove();
    }
  }

  /// Вызывается из `dispose` редактора: после него `show` — no-op, чтобы
  /// запоздавший `showToolbar` не вставил оверлей в мёртвое дерево.
  void dispose() {
    final entry = _entry;
    _entry = null;
    _disposed = true;
    if (entry != null && entry.mounted) {
      entry.remove();
    }
  }

  @override
  void show({
    required BuildContext context,
    required CodeLineEditingController controller,
    required TextSelectionToolbarAnchors anchors,
    Rect? renderRect,
    required LayerLink layerLink,
    required ValueNotifier<bool> visibility,
  }) {
    // Снять прежний ВСЕГДА и до всех проверок (инвариант с §517: один живой
    // `OverlayEntry` на экземпляр). Проверено прогонами: для одного
    // экземпляра этого достаточно и при повторных долгих тапах, и при
    // перетаскивании ручек выделения — там `showToolbar` идёт пачкой
    // (`_code_selection.dart:699,731,825,904`). Накопление §521 приходило не
    // отсюда, а от подмены самого экземпляра — см. докблок класса.
    hide(context);
    if (_disposed) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    // `anchors` — в глобальных координатах, а follower смещается от левого
    // верхнего угла редактора: вычитаем его. На desktop `renderRect == null`
    // — тогда смещения нет, follower уже стоит на редакторе.
    final origin = renderRect?.topLeft ?? Offset.zero;
    final entry = OverlayEntry(
      builder: (_) => _LxToolbarOverlay(
        visibility: visibility,
        layerLink: layerLink,
        offset: anchors.primaryAnchor - origin,
        items: [
          if (!readOnly)
            _LxToolbarItem(getLocalText.s("Cut"), controller.cut),
          _LxToolbarItem(getLocalText.s("Copy"), controller.copy),
          if (!readOnly)
            _LxToolbarItem(getLocalText.s("Paste"), controller.paste),
          _LxToolbarItem(getLocalText.s("Select all"), controller.selectAll),
        ],
        onDismiss: () => hide(context),
      ),
    );
    overlay.insert(entry);
    _entry = entry;
  }
}

/// Пункт меню: подпись + действие над живым выделением.
class _LxToolbarItem {
  const _LxToolbarItem(this.label, this.onTap);
  final String label;
  final VoidCallback onTap;
}

/// Сам оверлей. `CodeEditorTapRegion` (`groupId: CodeEditor`) — ключевая
/// деталь: без неё тап по кнопке считается тапом вне редактора и снимает
/// выделение ровно так же, как раньше это делал барьер модального меню.
class _LxToolbarOverlay extends StatelessWidget {
  const _LxToolbarOverlay({
    required this.visibility,
    required this.layerLink,
    required this.offset,
    required this.items,
    required this.onDismiss,
  });

  final ValueListenable<bool> visibility;
  final LayerLink layerLink;
  final Offset offset;
  final List<_LxToolbarItem> items;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return CodeEditorTapRegion(
      child: ValueListenableBuilder<bool>(
        valueListenable: visibility,
        builder: (context, visible, child) =>
            visible ? child! : const SizedBox.shrink(),
        child: CompositedTransformFollower(
          link: layerLink,
          showWhenUnlinked: false,
          offset: offset,
          child: _menu(context),
        ),
      ),
    );
  }

  Widget _menu(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.topLeft,
      child: Material(
        elevation: 4,
        color: cs.surfaceContainerHighest,
        borderRadius: const BorderRadius.all(Radius.circular(4)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final item in items)
              TextButton(
                onPressed: () {
                  // Порядок важен: действие — над ещё живым выделением,
                  // и только потом снимаем меню.
                  item.onTap();
                  onDismiss();
                },
                child: Text(item.label,
                    style: TextStyle(fontSize: 13, color: cs.onSurface)),
              ),
          ],
        ),
      ),
    );
  }
}

/// §554 — просмотр JSON с подсветкой синтаксиса, только чтение.
///
/// Обёртка над [LxCodeEditor] для экранов, где текст показывался
/// `SelectableText`/`TextField(readOnly)` без подсветки (вкладка JSON узла,
/// инспектор узла подписки). Контроллер живёт здесь и пересобирается при
/// смене [text]. `CodeEditor` не умеет сжиматься по содержимому, поэтому в
/// прокручиваемом родителе нужна [height]; в ограниченном — не нужна.
class LxJsonView extends StatefulWidget {
  const LxJsonView({
    super.key,
    required this.text,
    this.height,
    this.fontSize = 12,
    this.showLineNumbers = false,
    this.language = LxCodeLanguage.json,
  });

  final String text;
  final double? height;
  final double fontSize;
  final bool showLineNumbers;

  /// §614 — `null` — без подсветки (тело подписки не-JSON: base64, ссылки).
  final LxCodeLanguage? language;

  @override
  State<LxJsonView> createState() => _LxJsonViewState();
}

class _LxJsonViewState extends State<LxJsonView> {
  late CodeLineEditingController _ctrl =
      CodeLineEditingController.fromText(widget.text);

  @override
  void didUpdateWidget(covariant LxJsonView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _ctrl.dispose();
      _ctrl = CodeLineEditingController.fromText(widget.text);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editor = LxCodeEditor(
      controller: _ctrl,
      readOnly: true,
      autofocus: false,
      fontSize: widget.fontSize,
      showLineNumbers: widget.showLineNumbers,
      language: widget.language,
    );
    final h = widget.height;
    return h == null ? editor : SizedBox(height: h, child: editor);
  }
}

/// §614 — [LxCodeEditor] поверх обычного `TextEditingController`.
///
/// Поля форм (Source узла, DNS-сервер, правила) держат текст в
/// `TextEditingController`, и на нём же их валидация и сохранение. Менять
/// это ради подсветки незачем: виджет заводит свой
/// `CodeLineEditingController` и синхронизирует его с [controller] в обе
/// стороны. [onChanged] — как у `TextField`: только на правку в поле, не на
/// запись в [controller] из кода.
///
/// Высота, как у полей до перевода:
/// - [height] — фиксированная;
/// - [minLines] (и [maxLines]) — растёт по числу строк, как `TextField`
///   с `minLines`, но не выше [maxLines] (дальше прокрутка внутри);
/// - ничего — заполняет ограниченного родителя (`Expanded`).
class LxTextCodeField extends StatefulWidget {
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

  /// `null` — без подсветки (ссылка, WireGuard INI).
  final LxCodeLanguage? language;
  final ValueChanged<String>? onChanged;
  final double? height;
  final int? minLines;
  final int? maxLines;
  final double fontSize;
  final bool showLineNumbers;
  final String? hint;

  /// Подпись над полем (у `TextField` была `labelText`).
  final String? label;

  /// Ошибка под полем (у `TextField` была `errorText`).
  final String? errorText;
  final bool readOnly;

  /// Фокус при открытии (у `TextField` диалога был `autofocus: true`).
  final bool autofocus;

  @override
  State<LxTextCodeField> createState() => _LxTextCodeFieldState();
}

class _LxTextCodeFieldState extends State<LxTextCodeField> {
  late CodeLineEditingController _code;
  bool _syncing = false;
  int _lines = 1;

  @override
  void initState() {
    super.initState();
    _code = CodeLineEditingController.fromText(widget.controller.text);
    _lines = _code.lineCount;
    _code.addListener(_fromCode);
    widget.controller.addListener(_fromText);
  }

  @override
  void didUpdateWidget(LxTextCodeField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_fromText);
      widget.controller.addListener(_fromText);
      _fromText();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_fromText);
    _code.removeListener(_fromCode);
    _code.dispose();
    super.dispose();
  }

  /// Правка в поле → [LxTextCodeField.controller] и [onChanged].
  void _fromCode() {
    if (_syncing) return;
    _updateLines();
    final text = _code.text;
    if (text == widget.controller.text) return;
    _syncing = true;
    widget.controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _syncing = false;
    widget.onChanged?.call(text);
  }

  /// Запись в контроллер из кода (загрузка, подстановка) → поле.
  void _fromText() {
    if (_syncing) return;
    final text = widget.controller.text;
    if (text == _code.text) return;
    _syncing = true;
    _code.text = text;
    _syncing = false;
    _updateLines();
  }

  void _updateLines() {
    if (widget.minLines == null) return;
    final n = _code.lineCount;
    if (n != _lines && mounted) setState(() => _lines = n);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final editor = LxCodeEditor(
      controller: _code,
      autofocus: widget.autofocus,
      readOnly: widget.readOnly,
      fontSize: widget.fontSize,
      showLineNumbers: widget.showLineNumbers,
      language: widget.language,
      hint: widget.hint,
    );
    final error = widget.errorText;
    final min = widget.minLines;
    final double? height;
    if (widget.height != null) {
      height = widget.height;
    } else if (min != null) {
      final max = widget.maxLines ?? (min > 24 ? min : 24);
      final lines = _lines.clamp(min, max);
      // Высота строки — `fontHeight` пакета (1.4) + отступы LxCodeEditor
      // (12 сверху и снизу) + рамка.
      height = lines * widget.fontSize * 1.4 + 24 + 2;
    } else {
      height = null;
    }
    final label = widget.label;
    final children = <Widget>[
      if (label != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(label,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
      if (height == null)
        Expanded(child: editor)
      else
        SizedBox(width: double.infinity, height: height, child: editor),
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
    ];
    return Column(
      mainAxisSize: height == null ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}
