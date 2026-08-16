import 'package:flutter/material.dart';

import '../../models/custom_rule.dart';
import '../../services/format_utils.dart' show formatDateTime;
import '../../services/l10n/locale_controller.dart';
import '../../services/rule_transfer.dart';

/// §396 — диалоги экспорта/импорта правил. Чистая презентация (стиль
/// `routing_screen_menus.dart` / `import_preview_dialog.dart` бэкапа):
/// показывают диалог и возвращают выбор, state-мутации остаются в экране.

/// Диалог выбора правил на экспорт. [displayNames] позиционно выровнен с
/// [rules] (live-label'ы пресетов — `ruleDisplayNames` §279). Все правила
/// отмечены по умолчанию. Возвращает выбранные правила или null (отмена).
Future<List<CustomRule>?> showRuleExportPicker(
  BuildContext context, {
  required List<CustomRule> rules,
  required List<String> displayNames,
}) {
  final selected = <String>{for (final r in rules) r.id};
  return showDialog<List<CustomRule>>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        title: Text(getLocalText.s("Export rules")),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: rules.length,
            itemBuilder: (_, i) {
              final rule = rules[i];
              final summary = rule.summary();
              return CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: selected.contains(rule.id),
                onChanged: (v) => set(() {
                  if (v == true) {
                    selected.add(rule.id);
                  } else {
                    selected.remove(rule.id);
                  }
                }),
                title: Text(displayNames[i]),
                subtitle: summary.isEmpty
                    ? null
                    : Text(summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11)),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(getLocalText.s("Cancel")),
          ),
          FilledButton(
            onPressed: selected.isEmpty
                ? null
                : () => Navigator.pop(ctx,
                    [for (final r in rules) if (selected.contains(r.id)) r]),
            child: Text(getLocalText.s("Export (%d)", selected.length)),
          ),
        ],
      ),
    ),
  );
}

/// Превью импорта: шапка (когда/чем создан) + чекбокс на правило с итогом
/// санации. Неимпортируемые (§5.3 спеки) — disabled с причиной. Возвращает
/// выбранные элементы или null (отмена).
Future<List<SanitizedImportRule>?> showRuleImportPreview(
  BuildContext context, {
  required List<SanitizedImportRule> items,
  DateTime? createdAt,
  String? sourceAppVersion,
}) {
  final selected = <int>{
    for (var i = 0; i < items.length; i++)
      if (items[i].importable) i,
  };
  return showDialog<List<SanitizedImportRule>>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) {
        final cs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: Text(getLocalText.s("Import rules")),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (createdAt != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        getLocalText.s(
                            "Created: %s", formatDateTime(createdAt.toLocal())),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  if (sourceAppVersion != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        getLocalText.s("App version: %s", sourceAppVersion),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  for (var i = 0; i < items.length; i++)
                    _importRow(ctx, cs, items[i],
                        checked: selected.contains(i),
                        onChanged: items[i].importable
                            ? (v) => set(() {
                                  if (v == true) {
                                    selected.add(i);
                                  } else {
                                    selected.remove(i);
                                  }
                                })
                            : null),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(getLocalText.s("Cancel")),
            ),
            FilledButton(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.pop(ctx, [
                        for (var i = 0; i < items.length; i++)
                          if (selected.contains(i)) items[i]
                      ]),
              child: Text(getLocalText.s("Import (%d)", selected.length)),
            ),
          ],
        );
      },
    ),
  );
}

Widget _importRow(
  BuildContext ctx,
  ColorScheme cs,
  SanitizedImportRule item, {
  required bool checked,
  required ValueChanged<bool?>? onChanged,
}) {
  final notes = <String>[
    for (final w in item.warnings) _warningText(w),
    if (item.rejectReason != null) _rejectText(item.rejectReason!),
  ];
  final title = item.displayLabel.isNotEmpty
      ? item.displayLabel
      : getLocalText.s("Unsupported entry");
  return CheckboxListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    controlAffinity: ListTileControlAffinity.leading,
    value: checked,
    onChanged: onChanged,
    title: Text(
      title,
      style: item.importable ? null : TextStyle(color: cs.onSurfaceVariant),
    ),
    subtitle: notes.isEmpty
        ? null
        : Text(
            notes.join('\n'),
            style: TextStyle(
              fontSize: 11,
              color: item.importable ? cs.error : cs.onSurfaceVariant,
            ),
          ),
  );
}

String _warningText(ImportRuleWarning w) => switch (w.kind) {
      ImportRuleWarningKind.outboundMissing => getLocalText.s(
          "Channel \"%s\" not found — set to %s, rule disabled",
          w.missingTag,
          kImportOutboundFallback),
      ImportRuleWarningKind.dnsServerMissing => getLocalText.s(
          "DNS server \"%s\" not found — DNS option disabled", w.missingTag),
      ImportRuleWarningKind.resolveServerMissing => getLocalText.s(
          "DNS server \"%s\" not found — resolver set to auto", w.missingTag),
    };

String _rejectText(ImportRuleRejectReason r) => switch (r) {
      ImportRuleRejectReason.unsupportedEntry =>
        getLocalText.s("Unsupported entry — skipped"),
      ImportRuleRejectReason.unknownPreset =>
        getLocalText.s("Unknown preset (newer app version?)"),
    };
