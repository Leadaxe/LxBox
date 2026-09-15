import 'package:flutter/material.dart';

import '../../../models/dns_ref.dart';
import '../../../widgets/reorder_grab_strip.dart';
import '../dns_body_dialogs.dart';
import '../dns_format.dart';
import 'dns_badge.dart';

/// §033: builds a tile for a single DNS rule entry ([DnsRuleRef]).
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

  final DnsRuleRef entry;
  final Map<String, Map<String, dynamic>> templateRulesByName;
  final Map<String, List<Map<String, dynamic>>> presetRulesByPresetId;
  final Map<String, String> presetLabelByPresetId;
  final void Function(int index, bool value) onToggleEnabled;
  final void Function(int index) onEdit;
  final void Function(int index) onDelete;

  @override
  Widget build(BuildContext context) {
    final kind = entry.kind;
    final enabled = entry.enabled;
    final theme = Theme.of(context);

    // §033: title для kind=preset рендерится динамически из текущего шаблона
    // (storage хранит presetId), для остальных — берётся из entry.name.
    final String displayTitle;
    Map<String, dynamic>? body;
    // §253: preset может нести несколько DNS-правил — превью/диалог по списку.
    List<Map<String, dynamic>>? bodies;
    switch (entry) {
      case DnsRuleInline(:final name, :final rule):
        displayTitle = name;
        body = rule;
      case DnsRuleTemplate(:final name):
        displayTitle = name;
        body = templateRulesByName[displayTitle];
      case DnsRulePreset(:final presetId):
        displayTitle = presetLabelByPresetId[presetId] ?? presetId;
        bodies = presetRulesByPresetId[presetId];
      case DnsRuleSrs(:final name, :final srsUrl, :final server):
        displayTitle = name;
        // body: показываем сам entry как preview (срz config'а здесь нет — body
        // строится builder'ом при emit'е). Достаточно для UI.
        body = {
          'srsUrl': srsUrl,
          'server': server,
        };
    }

    final preview = bodies != null
        ? formatRulesPreview(bodies, kind: kind)
        : formatRulePreview(body, kind: kind);

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
        onTap: () => showRuleBodyDialog(
            context, displayTitle, kind, bodies ?? body),
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
          // §253: по 2 строки на правило у многоправильного пресета.
          maxLines: (bodies != null && bodies.length > 1)
              ? 2 * bodies.length
              : 2,
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
