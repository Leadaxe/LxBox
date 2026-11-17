import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// §744 — группа переключателей (radio), по которой можно пройти пультом.
///
/// Стандартный [RadioGroup] вешает на стрелки «выбрать соседний пункт» и
/// крутит выбор по кругу; выйти из группы можно только по Tab, которого у
/// пульта Android TV нет (issue #222: тема менялась при простом перемещении,
/// из списка нельзя было уйти). Здесь стрелки только двигают фокус — по
/// геометрии экрана, как везде вне группы: с крайнего пункта фокус уходит к
/// соседнему виджету в ту же сторону. Выбор — OK/Enter/Space и тап.
///
/// Семантика радиогруппы (TalkBack) и регистрация `Radio`/`RadioListTile`
/// остаются за [RadioGroup]: виджет лишь кладёт перед ним свои шорткаты
/// (ближе к фокусу — значит, раньше). Приём впервые применён в §622
/// (`import_preview_dialog.dart`).
///
/// В `app/lib` прямой `RadioGroup<…>(` пишется только здесь.
class DpadRadioGroup<T> extends StatelessWidget {
  const DpadRadioGroup({
    super.key,
    required this.groupValue,
    required this.onChanged,
    required this.child,
  });

  final T? groupValue;
  final ValueChanged<T?> onChanged;
  final Widget child;

  /// Стрелки — переход фокуса, а не выбор соседнего пункта.
  static const arrowsMoveFocus = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(
      TraversalDirection.up,
    ),
    SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(
      TraversalDirection.down,
    ),
    SingleActivator(LogicalKeyboardKey.arrowLeft): DirectionalFocusIntent(
      TraversalDirection.left,
    ),
    SingleActivator(LogicalKeyboardKey.arrowRight): DirectionalFocusIntent(
      TraversalDirection.right,
    ),
  };

  @override
  Widget build(BuildContext context) {
    return RadioGroup<T>(
      groupValue: groupValue,
      onChanged: onChanged,
      child: Shortcuts(shortcuts: arrowsMoveFocus, child: child),
    );
  }
}
