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
      toolbarController: const _LxSelectionToolbarController(),
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

/// Long-press контекстное меню. У re_editor дефолтного нет
/// (`toolbarController` nullable и без него меню просто не появляется),
/// поэтому минимальный свой — по образцу example пакета.
class _LxSelectionToolbarController implements SelectionToolbarController {
  const _LxSelectionToolbarController();

  @override
  void hide(BuildContext context) {}

  @override
  void show({
    required BuildContext context,
    required CodeLineEditingController controller,
    required TextSelectionToolbarAnchors anchors,
    Rect? renderRect,
    required LayerLink layerLink,
    required ValueNotifier<bool> visibility,
  }) {
    const itemSize = Size(180, 40);
    showMenu<void>(
      context: context,
      position: RelativeRect.fromSize(
        anchors.primaryAnchor & itemSize,
        MediaQuery.of(context).size,
      ),
      items: [
        _item(getLocalText.s("Cut"), controller.cut),
        _item(getLocalText.s("Copy"), controller.copy),
        _item(getLocalText.s("Paste"), controller.paste),
        _item(getLocalText.s("Select all"), controller.selectAll),
      ],
    );
  }

  PopupMenuItem<void> _item(String text, VoidCallback onTap) =>
      PopupMenuItem<void>(
        onTap: onTap,
        height: 40,
        child: Text(text, style: const TextStyle(fontSize: 13)),
      );
}
