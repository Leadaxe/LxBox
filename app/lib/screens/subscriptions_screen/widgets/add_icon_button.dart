import 'package:flutter/material.dart';

/// §074 — custom «+» button с поддержкой onTap + onLongPress (без
/// встроенного Tooltip widget'а, который перехватывал бы long-press).
/// Визуально match'ит `IconButton.filled` — primary background, circle,
/// 40dp tap-target.
class AddIconButton extends StatelessWidget {
  const AddIconButton({
    super.key,
    required this.busy,
    required this.onTap,
    required this.onLongPress,
  });

  final bool busy;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: busy ? cs.surfaceContainerHighest : cs.primary,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: busy ? null : onTap,
        onLongPress: busy ? null : onLongPress,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Center(
            child: Icon(
              Icons.add,
              size: 20,
              color: busy ? cs.onSurfaceVariant : cs.onPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
