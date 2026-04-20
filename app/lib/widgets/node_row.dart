import 'dart:async';

import 'package:flutter/material.dart';

import '../config/consts.dart';

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
    this.onCopyUri,
    this.onViewJson,
    this.urltestNow,
    this.onRunUrltest,
    this.hasDetour = false,
    this.protocolLabel,
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
  /// Called when user wants the original URI (vless://, wireguard://, …).
  final VoidCallback? onCopyUri;
  final VoidCallback? onViewJson;
  /// If this node is a URLTest group, shows which node it auto-selected.
  final String? urltestNow;
  /// Non-null only for URLTest group tags — triggers `/group/<tag>/delay`
  /// which forces sing-box to re-test all members and update `now`.
  final VoidCallback? onRunUrltest;
  final bool hasDetour;
  /// Compact protocol label (e.g. "Hy2 + TLS", "VLESS + TLS", "WG").
  /// Shown справа от имени ноды, ниже delay'я не лезет, серый цвет.
  final String? protocolLabel;

  /// Right-side delay label (или PING… / ERR), цвет по latency.
  String get _delayLabel {
    if (pingBusy) return 'PING…';
    if (delay == null) return '';
    return delay! < 0 ? 'ERR' : '${delay}MS';
  }

  Color? _delayColor(BuildContext context) {
    if (delay == null || pingBusy) return null;
    if (delay! < 0) return Theme.of(context).colorScheme.error;
    if (delay! < 200) return Colors.green;
    if (delay! < 500) return Colors.orange;
    return Theme.of(context).colorScheme.error;
  }

  /// `[ACTIVE] [protocol]              [50MS]` — left part flex, ping right-aligned.
  Widget _buildSubtitleRow(BuildContext context, ColorScheme cs) {
    final hasActive = active;
    final hasArrow = urltestNow != null && urltestNow!.isNotEmpty;
    final hasProto = protocolLabel != null && protocolLabel!.isNotEmpty;
    final dl = _delayLabel;

    if (!hasActive && !hasArrow && !hasProto && dl.isEmpty) {
      return const SizedBox.shrink();
    }

    final Widget? activePill = hasActive
        ? Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              'ACTIVE',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                color: Colors.green.shade700,
                letterSpacing: 0.5,
              ),
            ),
          )
        : null;

    final Widget? arrow = hasArrow
        ? Text(
            '→ $urltestNow',
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10,
              fontStyle: FontStyle.italic,
              color: cs.onSurfaceVariant,
            ),
          )
        : null;

    final Widget? proto = hasProto
        ? Text(
            protocolLabel!,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: cs.onSurfaceVariant,
              letterSpacing: 0.3,
            ),
          )
        : null;

    final right = dl.isEmpty
        ? const SizedBox.shrink()
        : Text(
            dl,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
              color: _delayColor(context) ?? cs.onSurfaceVariant,
            ),
          );

    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        children: [
          if (activePill != null) ...[activePill, const SizedBox(width: 6)],
          // Стрелка → <node>: занимает сколько есть места, но при нехватке
          // ellipsis'ом обрезается, НЕ переносит на новую строку.
          // protocol-label фикс. ширины идёт после — стрелка уступает ему.
          if (arrow != null)
            Flexible(
              fit: FlexFit.loose,
              child: Padding(
                padding: EdgeInsets.only(right: proto != null ? 6 : 0),
                child: arrow,
              ),
            ),
          ?proto,
          const Spacer(),
          right,
        ],
      ),
    );
  }

  bool get _isSpecial => tag == 'direct-out' || tag == kAutoOutboundTag;

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
        if (onRunUrltest != null)
          PopupMenuItem<String>(
            value: 'run_urltest',
            enabled: tunnelUp && !busy,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.auto_awesome,
                size: 20,
                color: (tunnelUp && !busy)
                    ? null
                    : Theme.of(context).disabledColor,
              ),
              title: const Text('Run URLTest'),
            ),
          ),
        if (onViewJson != null) const PopupMenuDivider(),
        if (onViewJson != null)
          PopupMenuItem<String>(
            value: 'view_json',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.code, size: 20),
              title: const Text('View JSON'),
            ),
          ),
        if (showCopy) const PopupMenuDivider(),
        if (showCopy && onCopyUri != null)
          PopupMenuItem<String>(
            value: 'copy_uri',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.link, size: 20),
              title: const Text('Copy URI'),
            ),
          ),
        if (showCopy)
          PopupMenuItem<String>(
            value: 'copy_server',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.content_copy, size: 20),
              title: const Text('Copy server (JSON)'),
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
      case 'run_urltest':
        if (onRunUrltest != null) onRunUrltest!();
      case 'copy_uri':
        if (onCopyUri != null) onCopyUri!();
      case 'copy_server':
        if (onCopy != null) onCopy!('server');
      case 'copy_detour':
        if (onCopy != null) onCopy!('detour');
      case 'copy_both':
        if (onCopy != null) onCopy!('both');
      case 'view_json':
        if (onViewJson != null) onViewJson!();
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
                    Row(
                      children: [
                        if (tag == kAutoOutboundTag) ...[
                          Icon(Icons.speed,
                              size: 18, color: colorScheme.primary),
                          const SizedBox(width: 6),
                        ],
                        Flexible(
                          child: Text(
                            tag,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                Theme.of(context).textTheme.bodyLarge?.copyWith(
                                      fontWeight: active
                                          ? FontWeight.w600
                                          : FontWeight.w500,
                                    ),
                          ),
                        ),
                      ],
                    ),
                    _buildSubtitleRow(context, colorScheme),
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
