import 'package:flutter/material.dart';

import '../dns_body_dialogs.dart';
import '../resolved_server.dart';
import 'dns_badge.dart';

/// §044: единый builder через typed `ResolvedServer`. Никаких Map['_kind'] —
/// classification через typed accessors на ResolvedServer.
///
/// - `kind: template` — badge `Template`, edit (copy-on-write) + switch
/// - `kind: preset`   — badge `Preset` (subtitle с preset-label), edit + switch
/// - `kind: inline` + `overrides != null` — badge `Overridden`, edit + reset (↺)
/// - `kind: inline` + `overrides == null` — badge `User`, edit + delete (🗑)
class MergedServerTile extends StatelessWidget {
  const MergedServerTile({
    super.key,
    required this.entry,
    required this.onToggleEnabled,
    required this.onEdit,
    required this.onReset,
    required this.onDelete,
  });

  final ResolvedServer entry;
  final void Function(String tag, bool value) onToggleEnabled;
  final void Function(String tag) onEdit;
  final void Function(String tag) onReset;
  final void Function(String tag) onDelete;

  @override
  Widget build(BuildContext context) {
    final type = entry.body['type']?.toString() ?? '';
    final addr = entry.body['server']?.toString() ?? '';
    final theme = Theme.of(context);

    // Короткие labels (§044).
    final (String badgeText, Color badgeColor) = switch (entry.kind) {
      ServerKind.template => ('Template', theme.colorScheme.tertiary),
      ServerKind.preset => ('Preset', theme.colorScheme.primary),
      ServerKind.inline => entry.isOverridden
          ? ('Overridden', theme.colorScheme.error.withValues(alpha: 0.9))
          : ('User', theme.colorScheme.secondary),
    };

    return Card(
      child: ListTile(
        onTap: () => showServerBodyDialog(context, entry),
        leading: SizedBox(
          width: 40,
          child: Switch(
            value: entry.enabled,
            onChanged: (v) => onToggleEnabled(entry.tag, v),
          ),
        ),
        title: Text(
          entry.description.isNotEmpty ? entry.description : entry.tag,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: entry.enabled ? null : theme.colorScheme.onSurfaceVariant,
          ),
        ),
        subtitle: Text(
          '${entry.tag} · $type${addr.isNotEmpty ? ' · $addr' : ''}'
          '${entry.presetLabel != null && entry.presetLabel!.isNotEmpty ? ' · ${entry.presetLabel}' : ''}',
          style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
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
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  tooltip: 'Edit',
                  onPressed: () => onEdit(entry.tag),
                  visualDensity: VisualDensity.compact,
                ),
                if (entry.isOverridden)
                  IconButton(
                    icon: const Icon(Icons.restart_alt, size: 18),
                    tooltip: 'Reset to default',
                    onPressed: () => onReset(entry.tag),
                    visualDensity: VisualDensity.compact,
                  )
                else if (entry.isUserOnly)
                  IconButton(
                    icon: Icon(Icons.delete_outline,
                        size: 18, color: theme.colorScheme.error),
                    tooltip: 'Delete',
                    onPressed: () => onDelete(entry.tag),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
