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
    this.onCopy,
    this.urltestNow,
    this.hasDetour = false,
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
  /// Called with 'server', 'detour', or 'both'.
  final void Function(String mode)? onCopy;
  /// If this node is a URLTest group, shows which node it auto-selected.
  final String? urltestNow;
  final bool hasDetour;

  String get _subtitle {
    if (pingBusy) return 'PING…';
    if (urltestNow != null) {
      final base = '→ $urltestNow';
      if (delay != null) {
        return delay! < 0 ? '$base · ERR' : '$base · ${delay}MS';
      }
      return base;
    }
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

  Color? _delayColor(BuildContext context) {
    if (delay == null || pingBusy) return null;
    if (delay! < 0) return Theme.of(context).colorScheme.error;
    if (delay! < 200) return Colors.green;
    if (delay! < 500) return Colors.orange;
    return Theme.of(context).colorScheme.error;
  }

  bool get _isSpecial => tag == 'direct-out' || tag == 'auto-proxy-out';

  Future<void> _openLongPressMenu(BuildContext context) async {
    final canPing = tunnelUp && !busy && !pingBusy;
    final canActivate = tunnelUp && !busy && !active;
    final showCopy = !_isSpecial;
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
              size: 20,
              color: canPing ? null : Theme.of(context).disabledColor,
            ),
            title: const Text('Ping'),
          ),
        ),
        PopupMenuItem<String>(
          value: 'activate',
          enabled: canActivate,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.play_circle_outline,
              size: 20,
              color: canActivate ? null : Theme.of(context).disabledColor,
            ),
            title: const Text('Use this node'),
          ),
        ),
        if (showCopy) const PopupMenuDivider(),
        if (showCopy)
          PopupMenuItem<String>(
            value: 'copy_server',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.content_copy, size: 20),
              title: const Text('Copy server'),
            ),
          ),
        if (showCopy && hasDetour)
          PopupMenuItem<String>(
            value: 'copy_detour',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.alt_route, size: 20),
              title: const Text('Copy detour'),
            ),
          ),
        if (showCopy && hasDetour)
          PopupMenuItem<String>(
            value: 'copy_both',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.copy_all, size: 20),
              title: const Text('Copy server + detour'),
            ),
          ),
      ],
    );
    if (!context.mounted) return;
    switch (chosen) {
      case 'ping':
        onPing();
      case 'activate':
        onActivate();
      case 'copy_server':
        if (onCopy != null) onCopy!('server');
      case 'copy_detour':
        if (onCopy != null) onCopy!('detour');
      case 'copy_both':
        if (onCopy != null) onCopy!('both');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final canActivate = tunnelUp && !busy && !active;

    return Material(
      color: highlighted
          ? colorScheme.primaryContainer.withAlpha(55)
          : (_isSpecial ? colorScheme.secondaryContainer.withAlpha(40) : null),
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
                              color: _delayColor(context) ?? colorScheme.onSurfaceVariant,
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
