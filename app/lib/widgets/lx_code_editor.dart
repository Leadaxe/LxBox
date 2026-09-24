import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';

import '../services/l10n/locale_controller.dart';

/// §333 — обёртка над re_editor для больших редактируемых текстов.
///
/// Зачем не `TextField`: тот держит документ единым `Paragraph` (re-layout
/// всего текста на каждый символ) и на каждый keystroke шлёт весь текст в
/// Android IME. На конфиге в сотни КБ это 100% CPU и смерть от lmkd.
/// `CodeEditor` держит документ построчно: layout — только видимых строк,
/// в IME уезжает только строка с курсором.
class LxCodeEditor extends StatelessWidget {
  const LxCodeEditor({
    super.key,
    required this.controller,
    this.hint,
    this.fontSize = 12,
    this.readOnly = false,
    this.showLineNumbers = false,
    this.wordWrap = true,
  });

  final CodeLineEditingController controller;
  final String? hint;
  final double fontSize;
  final bool readOnly;
  final bool showLineNumbers;
  final bool wordWrap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return CodeEditor(
      controller: controller,
      readOnly: readOnly,
      wordWrap: wordWrap,
      hint: hint,
      padding: const EdgeInsets.all(12),
      border: Border.all(color: cs.outline),
      borderRadius: const BorderRadius.all(Radius.circular(4)),
      style: CodeEditorStyle(
        fontSize: fontSize,
        fontFamily: 'monospace',
        textColor: cs.onSurface,
        hintTextColor: cs.onSurfaceVariant,
      ),
      toolbarController: LxSelectionToolbarController(),
      indicatorBuilder: showLineNumbers
          ? (context, editingController, chunkController, notifier) =>
              DefaultCodeLineNumber(
                controller: editingController,
                notifier: notifier,
              )
          : null,
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
class LxSelectionToolbarController implements SelectionToolbarController {
  LxSelectionToolbarController();

  OverlayEntry? _entry;

  /// Видно ли меню сейчас — для тестов и для идемпотентного `hide`.
  bool get isShown => _entry != null;

  @override
  void hide(BuildContext context) {
    _entry?.remove();
    _entry = null;
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
    hide(context);
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
