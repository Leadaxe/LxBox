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

  @override
  void initState() {
    super.initState();
    _toolbar = LxSelectionToolbarController();
    _focusNode = FocusNode(debugLabel: 'LxCodeEditor');
    widget.controller.addListener(_onSelectionChanged);
  }

  @override
  void didUpdateWidget(LxCodeEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onSelectionChanged);
      widget.controller.addListener(_onSelectionChanged);
      _toolbar.hide(context);
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
    return CodeEditorTapRegion(
      onTapOutside: (_) => _toolbar.hide(context),
      child: CodeEditor(
        controller: widget.controller,
        focusNode: _focusNode,
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
        indicatorBuilder: widget.showLineNumbers
            ? (context, editingController, chunkController, notifier) =>
                DefaultCodeLineNumber(
                  controller: editingController,
                  notifier: notifier,
                )
            : null,
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
          _LxToolbarItem(getLocalText.s("Cut"), controller.cut),
          _LxToolbarItem(getLocalText.s("Copy"), controller.copy),
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
  });

  final String text;
  final double? height;
  final double fontSize;
  final bool showLineNumbers;

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
      fontSize: widget.fontSize,
      showLineNumbers: widget.showLineNumbers,
      language: LxCodeLanguage.json,
    );
    final h = widget.height;
    return h == null ? editor : SizedBox(height: h, child: editor);
  }
}
