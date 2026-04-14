import 'dart:async';

import 'package:flutter/material.dart';

class NodeRow extends StatelessWidget {
  const NodeRow({
    super.key,
    required this.tag,
    required this.active,
    required this.highlighted,
    required this.delay,
    required this.pingBusy,
    required this.tunnelUp,
    required this.busy,
    required this.onHighlight,
    required this.onActivate,
    required this.onPing,
  });

  final String tag;
  final bool active;
  final bool highlighted;
  final int? delay;
  final bool pingBusy;
  final bool tunnelUp;
  final bool busy;
  final VoidCallback onHighlight;
  final VoidCallback onActivate;
  final VoidCallback onPing;

  String get _subtitle {
    if (pingBusy) return 'PING…';
    if (active) {
      if (delay != null) {
        return delay! < 0 ? 'ACTIVE · ERR' : 'ACTIVE · ${delay}MS';
      }
      return 'ACTIVE';
    }
    if (delay != null) {
      return delay! < 0 ? 'ERR' : '${delay}MS';
    }
    return '';
  }

  Future<void> _openLongPressMenu(BuildContext context) async {
    final canPing = tunnelUp && !busy && !pingBusy;
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Navigator.of(context).overlay?.context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null || !box.hasSize) return;

    final a = box.localToGlobal(Offset.zero);
    final b = box.localToGlobal(box.size.bottomRight(Offset.zero));
    final position = RelativeRect.fromRect(
      Rect.fromPoints(a, b),
      Offset.zero & overlay.size,
    );
    final chosen = await showMenu<String>(
      context: context,
      position: position,
      items: [
        PopupMenuItem<String>(
          value: 'ping',
          enabled: canPing,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.speed_outlined,
              size: 22,
              color: canPing ? null : Theme.of(context).disabledColor,
            ),
            title: const Text('Ping latency'),
          ),
        ),
      ],
    );
    if (chosen == 'ping' && context.mounted) {
      onPing();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final canActivate = tunnelUp && !busy && !active;

    return Material(
      color: highlighted ? colorScheme.primaryContainer.withAlpha(55) : null,
      child: InkWell(
        onTap: onHighlight,
        onLongPress: () => unawaited(_openLongPressMenu(context)),
        child: SizedBox(
          height: 56,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: (active || highlighted) ? 3 : 0,
                color: (active || highlighted)
                    ? colorScheme.primary
                    : Colors.transparent,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tag,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                          ),
                    ),
                    if (_subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        _subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              letterSpacing: 0.6,
                              color: colorScheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 40),
                tooltip: active ? 'Active' : 'Use node',
                onPressed: canActivate ? onActivate : null,
                icon: Icon(
                  active ? Icons.check_circle : Icons.play_circle_outline,
                  size: 22,
                  color: active
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}
