import 'dart:async';

import 'package:flutter/material.dart';

import '../screens/home/special_node_display.dart';
import 'node_view_item.dart';

/// One row в node list на главной screen'е. Read-only widget от
/// [NodeViewItem] data + callbacks.
///
/// Specs:
/// - §068 — extract view-model class (item-based constructor вместо 14
///   explicit args)
/// - §048 — `item.matches == false` → render с opacity 0.4 (single source
///   of opacity, magic 0.4 не утекает в caller)
class NodeRow extends StatelessWidget {
  const NodeRow({
    super.key,
    required this.item,
    required this.onHighlight,
    required this.onActivate,
    required this.onPing,
    this.onCopyUri,
    this.onViewJson,
    this.onRunUrltest,
    this.onSelectServer,
    this.onViewPool,
  });

  final NodeViewItem item;
  final VoidCallback onHighlight;
  final VoidCallback onActivate;
  final VoidCallback onPing;

  /// Called when user wants the original URI (vless://, wireguard://, …).
  final VoidCallback? onCopyUri;
  final VoidCallback? onViewJson;

  /// Non-null only for URLTest group tags — triggers `/group/<tag>/delay`
  /// которое forces sing-box re-test всех members и update `now`.
  final VoidCallback? onRunUrltest;

  /// §203 — non-null только для auto/urltest-ноды с текущим выбором
  /// (`urltestNow`): «Select server» в меню → подсветка + scroll к выбранному
  /// сервером тегу. Иначе null → пункт меню скрыт.
  final VoidCallback? onSelectServer;

  /// §208 — non-null только для auto-ноды round_robin-канала: «View pool» в меню
  /// → попап с текущим составом пула (getPool). Иначе null → пункт скрыт.
  final VoidCallback? onViewPool;

  /// Right-side delay label (или PING… / ERR), цвет по latency.
  String get _delayLabel {
    if (item.pingBusy) return 'PING…';
    final delay = item.delay;
    if (delay == null) return '';
    return delay < 0 ? 'ERR' : '${delay}MS';
  }

  Color? _delayColor(BuildContext context) {
    final delay = item.delay;
    if (delay == null || item.pingBusy) return null;
    if (delay < 0) return Theme.of(context).colorScheme.error;
    if (delay < 200) return Colors.green;
    if (delay < 500) return Colors.orange;
    return Theme.of(context).colorScheme.error;
  }

  /// `[ACTIVE] [protocol]              [50MS]` — left part flex, ping right-aligned.
  Widget _buildSubtitleRow(BuildContext context, ColorScheme cs) {
    final hasActive = item.active;
    final hasArrow = item.urltestNow != null && item.urltestNow!.isNotEmpty;
    final hasProto =
        item.protocolLabel != null && item.protocolLabel!.isNotEmpty;
    // §201 — у block нет осмысленного delay (всегда ERR): бейдж не рисуем.
    final dl = _isBlock ? '' : _delayLabel;

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
            '→ ${item.urltestNow}',
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
            item.protocolLabel!,
            // §199 — транспорт уступает серверу: обрезается ellipsis'ом, не
            // переполняет (внутри Flexible).
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
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

    // Пинг (`right`) ВСЕГДА прижат к правому краю строки. Вся левая часть
    // (active / arrow / proto) живёт в одном Expanded, который съедает остаток
    // ширины и толкает пинг вправо — без конкуренции flex-ов между proto и
    // Spacer'ом (из-за неё пинг раньше всплывал в середину строки).
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                if (activePill != null) ...[
                  activePill,
                  const SizedBox(width: 6),
                ],
                // §199 — в строке auto/urltest ВАЖЕН выбранный сервер
                // (`→ <node>`): он держит место (flex:3), транспорт (proto)
                // уступает по остаточному принципу (flex:1) — обрезается/
                // исчезает первым при нехватке ширины.
                if (arrow != null)
                  Flexible(
                    flex: 3,
                    fit: FlexFit.loose,
                    child: Padding(
                      padding: EdgeInsets.only(right: proto != null ? 6 : 0),
                      child: arrow,
                    ),
                  ),
                if (proto != null)
                  Flexible(
                    flex: 1,
                    fit: FlexFit.loose,
                    child: proto,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          right,
        ],
      ),
    );
  }

  // §125 — служебная нода (direct/auto): по типу из конфига, не по маске имени.
  bool get _isSpecial => specialNodeDisplayForType(item.outboundType) != null;

  // §201 — block: дропает трафик, urltest всегда ERR. Не пингуем и не
  // показываем delay-бейдж (был бы всегда «ERR»).
  bool get _isBlock => item.outboundType == 'block';

  Future<void> _openLongPressMenu(BuildContext context) async {
    // §201 — block не пингуется (всегда ERR): пункт Ping disabled.
    final canPing = item.tunnelUp && !item.busy && !item.pingBusy && !_isBlock;
    final canActivate = item.tunnelUp && !item.busy && !item.active;
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
            enabled: item.tunnelUp && !item.busy,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.auto_awesome,
                size: 20,
                color: (item.tunnelUp && !item.busy)
                    ? null
                    : Theme.of(context).disabledColor,
              ),
              title: const Text('Run URLTest'),
            ),
          ),
        // §203 — «Select server»: только для auto/urltest-ноды с текущим
        // выбором (onSelectServer != null). Подсвечивает и скроллит к серверу,
        // который urltest выбрал быстрейшим.
        if (onSelectServer != null)
          PopupMenuItem<String>(
            value: 'select_server',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.my_location, size: 20),
              title: const Text('Select server'),
            ),
          ),
        // §208 — «View pool»: только для auto-ноды round_robin-канала
        // (onViewPool != null). Попап со слотами пула (getPool).
        if (onViewPool != null)
          PopupMenuItem<String>(
            value: 'view_pool',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.hub_outlined, size: 20),
              title: const Text('View pool'),
            ),
          ),
        if (onViewJson != null) const PopupMenuDivider(),
        if (onViewJson != null)
          // §258 — экран стал Overview/JSON, пункт переименован в View
          // details (внутреннее значение 'view_json' не трогаем).
          PopupMenuItem<String>(
            value: 'view_json',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.info_outline, size: 20),
              title: const Text('View details'),
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
        // §099 — Copy JSON / detour / server+detour перенесены в View JSON.
      ],
    );
    if (!context.mounted) return;
    switch (chosen) {
      case 'ping':
        onPing();
      case 'select_server':
        onSelectServer?.call();
      case 'view_pool':
        onViewPool?.call();
      case 'activate':
        onActivate();
      case 'run_urltest':
        if (onRunUrltest != null) onRunUrltest!();
      case 'copy_uri':
        if (onCopyUri != null) onCopyUri!();
      case 'view_json':
        if (onViewJson != null) onViewJson!();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final canActivate = item.tunnelUp && !item.busy && !item.active;

    final content = Material(
      color: item.highlighted
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
                width: (item.active || item.highlighted) ? 3 : 0,
                color: (item.active || item.highlighted)
                    ? colorScheme.primary
                    : Colors.transparent,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Builder(builder: (context) {
                      // §125 — служебные ноды (direct/auto) показываем
                      // подменённым label'ом + иконкой; тип берём ТОЧНО из
                      // конфига (item.outboundType), не по маске имени.
                      final special =
                          specialNodeDisplayForType(item.outboundType);
                      final displayText = special?.label ?? item.tag;
                      return Row(
                        children: [
                          if (special != null) ...[
                            Icon(special.icon,
                                size: 18, color: colorScheme.primary),
                            const SizedBox(width: 6),
                          ],
                          Flexible(
                            child: Text(
                              displayText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyLarge
                                  ?.copyWith(
                                    fontWeight: item.active
                                        ? FontWeight.w600
                                        : FontWeight.w500,
                                  ),
                            ),
                          ),
                        ],
                      );
                    }),
                    _buildSubtitleRow(context, colorScheme),
                  ],
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 40),
                tooltip: item.active ? 'Active' : 'Use node',
                onPressed: canActivate ? onActivate : null,
                icon: Icon(
                  item.active ? Icons.check_circle : Icons.play_circle_outline,
                  size: 22,
                  color: item.active
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

    // §048 — single source of opacity. Caller передаёт `matches` через
    // `NodeViewItem`, widget сам решает как render себя в matching/non-matching
    // состоянии. Magic 0.4 не утекает в caller.
    return Opacity(
      opacity: item.matches ? 1.0 : 0.4,
      child: content,
    );
  }
}
