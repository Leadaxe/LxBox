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
  static const _arrowsMoveFocus = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.arrowUp):
        _GroupArrowIntent(TraversalDirection.up),
    SingleActivator(LogicalKeyboardKey.arrowDown):
        _GroupArrowIntent(TraversalDirection.down),
    SingleActivator(LogicalKeyboardKey.arrowLeft):
        _GroupArrowIntent(TraversalDirection.left),
    SingleActivator(LogicalKeyboardKey.arrowRight):
        _GroupArrowIntent(TraversalDirection.right),
  };

  @override
  Widget build(BuildContext context) {
    return RadioGroup<T>(
      groupValue: groupValue,
      onChanged: onChanged,
      child: Shortcuts(
        shortcuts: _arrowsMoveFocus,
        child: Actions(
          actions: <Type, Action<Intent>>{
            _GroupArrowIntent: _GroupArrowAction(),
          },
          child: child,
        ),
      ),
    );
  }
}

class _GroupArrowIntent extends Intent {
  const _GroupArrowIntent(this.direction);

  final TraversalDirection direction;
}

/// §746 — внутри группы бывают поля ввода (OpenConnect: поле отпечатка под
/// пунктом «Закреплённый отпечаток»). Обычный `DirectionalFocusIntent` поле
/// глушит, и стрелки съедались целиком — ни выхода, ни каретки. Поэтому при
/// фокусе в поле действие выключено: клавиша идёт выше — `RadioGroup` её
/// пропускает (фокус не на радио), и решает общий слой `DpadTextFieldExit`
/// (каретка или выход на краю).
class _GroupArrowAction extends Action<_GroupArrowIntent> {
  @override
  bool isEnabled(_GroupArrowIntent intent) {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return true;
    return context.widget is! EditableText &&
        context.findAncestorWidgetOfExactType<EditableText>() == null;
  }

  @override
  void invoke(_GroupArrowIntent intent) {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return;
    Actions.maybeInvoke(context, DirectionalFocusIntent(intent.direction));
  }
}
