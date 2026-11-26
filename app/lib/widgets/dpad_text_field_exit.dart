import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// §746 — пульт TV уходит из любого текстового поля приложения.
///
/// Во Flutter стрелки в поле забирает `DefaultTextEditingShortcuts`
/// (каретка), а обычный `DirectionalFocusIntent` (`ignoreTextFields: true`)
/// поле глушит своим `DirectionalFocusAction.forTextField()`. Пульт,
/// попав в поле, из него не выходил (§736 — поля поиска, §746 — формы).
///
/// Слой ставится один раз в `MaterialApp.builder`: он глубже
/// `DefaultTextEditingShortcuts` (тот висит в `WidgetsApp` над builder),
/// поэтому срабатывает раньше. Стрелка без модификаторов уводит фокус к
/// соседу (`DirectionalFocusIntent(ignoreTextFields: false)`), только если
/// каретка на краю:
///
/// - однострочное поле: ↑/↓ — всегда; ←/→ — когда каретка без выделения
///   в начале/конце текста (пустое поле — сразу);
/// - многострочное: ↑ — с первой строки, ↓ — с последней (строки — как
///   отрисованы, с переносами), ←/→ — как у однострочного.
///
/// В остальных случаях действие выключено (`isEnabled` = false), клавиша
/// идёт дальше вверх к `DefaultTextEditingShortcuts` — каретка ходит как
/// раньше. Во время IME-набора (composing) поле не трогаем. Вне поля слой
/// ничего не делает: стрелки обрабатываются как прежде.
///
/// Нативный редактор sora (`LxCodeEditor`, platform view) клавиши получает
/// в Android-View, сюда они не доходят.
class DpadTextFieldExit extends StatelessWidget {
  const DpadTextFieldExit({super.key, required this.child});

  final Widget child;

  static const _shortcuts = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.arrowUp):
        _FieldArrowIntent(TraversalDirection.up),
    SingleActivator(LogicalKeyboardKey.arrowDown):
        _FieldArrowIntent(TraversalDirection.down),
    SingleActivator(LogicalKeyboardKey.arrowLeft):
        _FieldArrowIntent(TraversalDirection.left),
    SingleActivator(LogicalKeyboardKey.arrowRight):
        _FieldArrowIntent(TraversalDirection.right),
  };

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      debugLabel: 'DpadTextFieldExit',
      shortcuts: _shortcuts,
      child: Actions(
        actions: <Type, Action<Intent>>{
          _FieldArrowIntent: _FieldArrowAction(),
        },
        child: child,
      ),
    );
  }

  /// Уйдёт ли фокус из поля [state] по стрелке [direction] (для тестов).
  @visibleForTesting
  static bool shouldExit(EditableTextState state, TraversalDirection direction) =>
      _shouldExit(state, direction);
}

class _FieldArrowIntent extends Intent {
  const _FieldArrowIntent(this.direction);

  final TraversalDirection direction;
}

class _FieldArrowAction extends Action<_FieldArrowIntent> {
  @override
  bool isEnabled(_FieldArrowIntent intent) {
    final state = _focusedEditable();
    return state != null && _shouldExit(state, intent.direction);
  }

  @override
  void invoke(_FieldArrowIntent intent) {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return;
    Actions.maybeInvoke(
      context,
      DirectionalFocusIntent(intent.direction, ignoreTextFields: false),
    );
  }
}

/// Поле, на котором сейчас первичный фокус, или null.
EditableTextState? _focusedEditable() {
  final node = FocusManager.instance.primaryFocus;
  final context = node?.context;
  if (node == null || context == null || !context.mounted) return null;
  final state = context.findAncestorStateOfType<EditableTextState>();
  if (state == null || !state.mounted || state.widget.focusNode != node) {
    return null;
  }
  return state;
}

bool _shouldExit(EditableTextState state, TraversalDirection direction) {
  final value = state.textEditingValue;
  // IME-набор: стрелки — дело клавиатуры.
  if (value.composing.isValid && !value.composing.isCollapsed) return false;
  final text = value.text;
  final sel = value.selection;
  if (!sel.isValid) return true;
  final singleLine = state.widget.maxLines == 1;
  switch (direction) {
    case TraversalDirection.left:
      return sel.isCollapsed && sel.extentOffset <= 0;
    case TraversalDirection.right:
      return sel.isCollapsed && sel.extentOffset >= text.length;
    case TraversalDirection.up:
    case TraversalDirection.down:
      if (singleLine) return true;
      if (!sel.isCollapsed) return false;
      if (text.isEmpty) return true;
      final line = state.renderEditable.getLineAtOffset(sel.extent);
      return direction == TraversalDirection.up
          ? line.start <= 0
          : line.end >= text.length;
  }
}
