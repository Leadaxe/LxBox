import 'package:flutter/material.dart';

import '../../../widgets/reorder_grab_strip.dart';
import '../dns_body_dialogs.dart';
import '../dns_format.dart';
import 'dns_badge.dart';

/// §033: builds a tile for a single `dns_options.rules[i]` entry.
///
/// Lookup maps
/// (`templateRulesByName`/`presetRulesByPresetId`/`presetLabelByPresetId`) и
/// mutating-actions переданы из state.
class DnsRuleTile extends StatelessWidget {
  const DnsRuleTile({
    required super.key,
    required this.index,
    required this.entry,
    required this.templateRulesByName,
    required this.presetRulesByPresetId,
    required this.presetLabelByPresetId,
    required this.onToggleEnabled,
    required this.onEdit,
    required this.onDelete,
    this.dragIndex,
  });

  /// Индекс записи в **storage**-списке (`_rules`) — для mutating-callbacks.
  final int index;

  /// §117: индекс в **display**-списке ReorderableListView — для grab-strip.
  /// null = строка не draggable (preset-записи внутри атомарной
  /// mirror-группы, решение №6).
  final int? dragIndex;

  final Map<String, dynamic> entry;
  final Map<String, Map<String, dynamic>> templateRulesByName;
  final Map<String, Map<String, dynamic>> presetRulesByPresetId;
  final Map<String, String> presetLabelByPresetId;
  final void Function(int index, bool value) onToggleEnabled;
  final void Function(int index) onEdit;
  final void Function(int index) onDelete;

  @override
  Widget build(BuildContext context) {
    final kind = entry['kind'] as String? ?? 'inline';
    final enabled = entry['enabled'] == true;
    final theme = Theme.of(context);

    // §033: title для kind=preset рендерится динамически из текущего шаблона
    // (storage хранит presetId), для остальных — берётся из entry.name.
    final String displayTitle;
    Map<String, dynamic>? body;
    if (kind == 'inline') {
      displayTitle = entry['name'] as String? ?? '';
      final r = entry['rule'];
      if (r is Map<String, dynamic>) body = r;
    } else if (kind == 'template') {
      displayTitle = entry['name'] as String? ?? '';
      body = templateRulesByName[displayTitle];
    } else if (kind == 'preset') {
      final pid = entry['presetId'] as String? ?? '';
      displayTitle = presetLabelByPresetId[pid] ?? pid;
      body = presetRulesByPresetId[pid];
    } else if (kind == 'srs') {
      displayTitle = entry['name'] as String? ?? '';
      // body: показываем сам entry как preview (срz config'а здесь нет — body
      // строится builder'ом при emit'е). Достаточно для UI.
      body = {
        'srsUrl': entry['srsUrl'],
        'server': entry['server'],
      };
    } else {
      displayTitle = entry['name'] as String? ?? '';
    }

    final preview = formatRulePreview(body, kind: kind);

    final badgeText = switch (kind) {
      'template' => 'template',
      'preset' => 'preset',
      'srs' => 'srs',
      _ => 'inline',
    };
    final badgeColor = switch (kind) {
      'template' => theme.colorScheme.tertiary,
      'preset' => theme.colorScheme.primary,
      'srs' => theme.colorScheme.outline,
      _ => theme.colorScheme.secondary,
    };

    // §098 — grab-strip слева (как в routing rules). §117-fix: полоса через
    // Stack+Positioned, БЕЗ IntrinsicHeight. `ListTile` под IntrinsicHeight
    // занижает intrinsic-высоту при переносе заголовка на 2 строки и режет
    // низ контента (overflow). Stack даёт тайлу натуральную высоту, полоса
    // тянется Positioned(top:0,bottom:0).
    final tile = Card(
      child: ListTile(
        onTap: () => showRuleBodyDialog(context, displayTitle, kind, body),
        leading: Switch(
          value: enabled,
          onChanged: (v) => onToggleEnabled(index, v),
        ),
        title: Text(
          displayTitle,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: enabled ? null : theme.colorScheme.onSurfaceVariant,
          ),
        ),
        subtitle: Text(
          preview,
          style: TextStyle(
            fontSize: 11,
            color: theme.colorScheme.onSurfaceVariant,
            fontFamily: 'monospace',
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        // Badge над action-кнопками. У kind:inline — edit/delete; у
        // template/preset/srs — только badge (не редактируются).
        trailing: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            DnsBadge(badgeText, badgeColor),
            if (kind == 'inline') ...[
              const SizedBox(height: 2),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    onPressed: () => onEdit(index),
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    icon: Icon(Icons.delete_outline,
                        size: 18, color: theme.colorScheme.error),
                    onPressed: () => onDelete(index),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );

    if (dragIndex == null) return tile;
    // Полоса 18px + горизонтальные margin 6+6 = 30px gutter слева.
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 30),
          child: tile,
        ),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          child: ReorderGrabStrip(index: dragIndex!),
        ),
      ],
    );
  }
}
