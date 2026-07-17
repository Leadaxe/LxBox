import 'package:flutter/material.dart';

import '../../../services/l10n/l10n.dart';
import '../resolved_server.dart';
import 'dns_badge.dart';

/// §044: единый builder через typed `ResolvedServer`. Никаких Map['_kind'] —
/// classification через typed accessors на ResolvedServer.
///
/// §117 задача 4 (locked decision №8): тайл ужат до switch (enabled) +
/// title/subtitle + badge; **тап → полноэкранный редактор**
/// (`openDnsServerEditor`). Инлайн-тюнер и иконки edit/reset/delete
/// переехали в редактор (Params/JSON + AppBar-actions).
///
/// §117 lifecycle (locked №7): `locked` (сервер реферится активным пресетом
/// ИЛИ routing-правилом с DNS-опцией) — enabled-switch заблокирован и
/// показывается включённым (build force-include), в subtitle
/// «used by <пресет/правило>» с замком.
class MergedServerTile extends StatelessWidget {
  const MergedServerTile({
    super.key,
    required this.entry,
    required this.onToggleEnabled,
    required this.onTap,
  });

  final ResolvedServer entry;
  final void Function(String tag, bool value) onToggleEnabled;

  /// Тап по тайлу — открыть редактор сервера.
  final void Function(String tag) onTap;

  @override
  Widget build(BuildContext context) {
    final type = entry.body['type']?.toString() ?? '';
    final addr = entry.body['server']?.toString() ?? '';
    final theme = Theme.of(context);
    final locked = entry.locked;

    // Короткие labels (§044).
    final (String badgeText, Color badgeColor) = switch (entry.kind) {
      ServerKind.template => (
          context.l.dnsBadgeTemplate,
          theme.colorScheme.tertiary
        ),
      ServerKind.preset => (context.l.dnsBadgePreset, theme.colorScheme.primary),
      ServerKind.inline => entry.isOverridden
          ? (
              context.l.dnsBadgeOverridden,
              theme.colorScheme.error.withValues(alpha: 0.9)
            )
          : (context.l.dnsBadgeUser, theme.colorScheme.secondary),
    };

    final subtitleLine =
        '${entry.tag} · $type${addr.isNotEmpty ? ' · $addr' : ''}'
        '${entry.presetLabel != null && entry.presetLabel!.isNotEmpty ? ' · ${entry.presetLabel}' : ''}';

    return Card(
      child: ListTile(
        onTap: () => onTap(entry.tag),
        leading: SizedBox(
          width: 40,
          child: Switch(
            // §117: locked-сервер build force-include'ит — показываем ON.
            value: entry.enabled || locked,
            onChanged:
                locked ? null : (v) => onToggleEnabled(entry.tag, v),
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
                    context.l.dnsUsedBy(entry.lockedByLabel),
                    style: TextStyle(
                        fontSize: 11, color: theme.colorScheme.primary),
                  ),
                ],
              ),
          ],
        ),
        trailing: DnsBadge(badgeText, badgeColor),
      ),
    );
  }
}
