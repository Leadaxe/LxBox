import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// §736 — однострочное поле (поиск над списком) отпускает фокус по ↑/↓.
///
/// Во Flutter стрелки в `TextField` забирает `DefaultTextEditingShortcuts`
/// (каретка к началу/концу строки), а `DirectionalFocusIntent` по умолчанию
/// (`ignoreTextFields: true`) поле глушит своим
/// `DirectionalFocusAction.forTextField()`. На TV пульт доходил до поля
/// поиска и дальше «вниз» не шёл (issue #220). Здесь ↑/↓ без модификаторов
/// — переход фокуса к соседнему виджету; ←/→ остаются за кареткой.
///
/// Только для однострочных полей: в многострочном ↑/↓ — переход по строкам.
class DpadFieldExit extends StatelessWidget {
  const DpadFieldExit({super.key, required this.child});

  final Widget child;

  static const shortcuts = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(
      TraversalDirection.up,
      ignoreTextFields: false,
    ),
    SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(
      TraversalDirection.down,
      ignoreTextFields: false,
    ),
  };

  @override
  Widget build(BuildContext context) =>
      Shortcuts(shortcuts: shortcuts, child: child);
}
