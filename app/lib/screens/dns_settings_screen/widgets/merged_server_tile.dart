import 'package:flutter/material.dart';

import '../../../widgets/outbound_picker.dart';
import '../../../widgets/template_var_list.dart';
import '../dns_body_dialogs.dart';
import '../resolved_server.dart';
import 'dns_badge.dart';

/// §044: единый builder через typed `ResolvedServer`. Никаких Map['_kind'] —
/// classification через typed accessors на ResolvedServer.
///
/// - `kind: template` — badge `Template`, edit (copy-on-write) + switch;
///   §117: при наличии vars — разворачиваемая секция параметров
///   ([TemplateVarListView]: outbound-канал, IP-профиль, domain resolver)
/// - `kind: preset`   — badge `Preset` (subtitle с preset-label), edit + switch
/// - `kind: inline` + `overrides != null` — badge `Overridden`, edit + reset (↺)
/// - `kind: inline` + `overrides == null` — badge `User`, edit + delete (🗑)
///
/// §117 lifecycle: `lockedByPreset` (сервер реферится активным пресетом) —
/// enabled-switch заблокирован и показывается включённым (build force-include),
/// в subtitle «used by <пресет>» с замком.
class MergedServerTile extends StatefulWidget {
  const MergedServerTile({
    super.key,
    required this.entry,
    required this.onToggleEnabled,
    required this.onEdit,
    required this.onReset,
    required this.onDelete,
    this.onVarChanged,
    this.outboundOptions = const [],
    this.dnsServerTags = const [],
  });

  final ResolvedServer entry;
  final void Function(String tag, bool value) onToggleEnabled;
  final void Function(String tag) onEdit;
  final void Function(String tag) onReset;
  final void Function(String tag) onDelete;

  /// §117: изменение var-значения (parent персистит в ref.varValues).
  final void Function(String tag, String name, String value)? onVarChanged;

  /// §117: каналы для `type: outbound` vars (Direct + активные каналы).
  final List<OutboundOption> outboundOptions;

  /// §117: теги DNS-серверов для `type: dns_servers` vars (без самого себя).
  final List<String> dnsServerTags;

  @override
  State<MergedServerTile> createState() => _MergedServerTileState();
}

class _MergedServerTileState extends State<MergedServerTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final type = entry.body['type']?.toString() ?? '';
    final addr = entry.body['server']?.toString() ?? '';
    final theme = Theme.of(context);
    final locked = entry.lockedByPreset;
    final hasVars = entry.vars.isNotEmpty && widget.onVarChanged != null;

    // Короткие labels (§044).
    final (String badgeText, Color badgeColor) = switch (entry.kind) {
      ServerKind.template => ('Template', theme.colorScheme.tertiary),
      ServerKind.preset => ('Preset', theme.colorScheme.primary),
      ServerKind.inline => entry.isOverridden
          ? ('Overridden', theme.colorScheme.error.withValues(alpha: 0.9))
          : ('User', theme.colorScheme.secondary),
    };

    final subtitleLine =
        '${entry.tag} · $type${addr.isNotEmpty ? ' · $addr' : ''}'
        '${entry.presetLabel != null && entry.presetLabel!.isNotEmpty ? ' · ${entry.presetLabel}' : ''}';

    return Card(
      child: Column(
        children: [
          ListTile(
            onTap: () => showServerBodyDialog(context, entry),
            leading: SizedBox(
              width: 40,
              child: Switch(
                // §117: locked-сервер build force-include'ит — показываем ON.
                value: entry.enabled || locked,
                onChanged: locked
                    ? null
                    : (v) => widget.onToggleEnabled(entry.tag, v),
              ),
            ),
            title: Text(
              entry.description.isNotEmpty ? entry.description : entry.tag,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: entry.enabled || locked
                    ? null
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  subtitleLine,
                  style: TextStyle(
                      fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
                ),
                if (locked)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.lock_outline,
                          size: 12, color: theme.colorScheme.primary),
                      const SizedBox(width: 4),
                      Text(
                        'used by ${entry.presetLabel ?? 'preset'}',
                        style: TextStyle(
                            fontSize: 11, color: theme.colorScheme.primary),
                      ),
                    ],
                  ),
              ],
            ),
            trailing: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                DnsBadge(badgeText, badgeColor),
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (hasVars)
                      IconButton(
                        icon: Icon(
                          _expanded ? Icons.expand_less : Icons.tune,
                          size: 18,
                        ),
                        tooltip: 'Parameters',
                        onPressed: () =>
                            setState(() => _expanded = !_expanded),
                        visualDensity: VisualDensity.compact,
                      ),
                    IconButton(
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      tooltip: 'Edit',
                      onPressed: () => widget.onEdit(entry.tag),
                      visualDensity: VisualDensity.compact,
                    ),
                    if (entry.isOverridden)
                      IconButton(
                        icon: const Icon(Icons.restart_alt, size: 18),
                        tooltip: 'Reset to default',
                        onPressed: () => widget.onReset(entry.tag),
                        visualDensity: VisualDensity.compact,
                      )
                    else if (entry.isUserOnly)
                      IconButton(
                        icon: Icon(Icons.delete_outline,
                            size: 18, color: theme.colorScheme.error),
                        tooltip: 'Delete',
                        onPressed: () => widget.onDelete(entry.tag),
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (hasVars && _expanded) ...[
            const Divider(height: 1),
            TemplateVarListView(
              key: ValueKey('dns-vars-${entry.tag}'),
              vars: entry.vars,
              initialValues: entry.varValues,
              showSectionHeaders: false,
              outboundOptions: widget.outboundOptions,
              dnsServerTags: widget.dnsServerTags,
              onChanged: (name, value) =>
                  widget.onVarChanged!(entry.tag, name, value),
            ),
          ],
        ],
      ),
    );
  }
}
