import 'package:flutter/material.dart';

import '../../models/custom_rule.dart';
import '../../services/format_utils.dart' show formatDateTime;
import '../../services/l10n/locale_controller.dart';
import '../../services/rule_transfer.dart';

/// §396 — диалоги экспорта/импорта правил. Чистая презентация (стиль
/// `routing_screen_menus.dart` / `import_preview_dialog.dart` бэкапа):
/// показывают диалог и возвращают выбор, state-мутации остаются в экране.

/// Экран выбора правил на экспорт. [displayNames] позиционно выровнен с
/// [rules] (live-label'ы пресетов — `ruleDisplayNames` §279). Полноэкранный
/// (решение владельца: попап для списка правил тесен), по умолчанию НИЧЕГО
/// не выбрано, над списком тумблер Select all / Deselect all. Возвращает
/// выбранные правила или null (закрыт без экспорта).
Future<List<CustomRule>?> showRuleExportPicker(
  BuildContext context, {
  required List<CustomRule> rules,
  required List<String> displayNames,
}) {
  return Navigator.of(context).push<List<CustomRule>>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) =>
          _RuleExportScreen(rules: rules, displayNames: displayNames),
    ),
  );
}

class _RuleExportScreen extends StatefulWidget {
  const _RuleExportScreen({required this.rules, required this.displayNames});

  final List<CustomRule> rules;
  final List<String> displayNames;

  @override
  State<_RuleExportScreen> createState() => _RuleExportScreenState();
}

class _RuleExportScreenState extends State<_RuleExportScreen> {
  // Решение владельца: стартуем с пустого выбора — экспорт осознанный,
  // «отдать всё» это один тап по Select all.
  final _selected = <String>{};

  bool get _allSelected =>
      widget.rules.isNotEmpty && _selected.length == widget.rules.length;

  void _toggleAll() {
    setState(() {
      if (_allSelected) {
        _selected.clear();
      } else {
        _selected.addAll(widget.rules.map((r) => r.id));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(getLocalText.s("Export rules"))),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: TextButton.icon(
              onPressed: _toggleAll,
              icon: Icon(
                _allSelected ? Icons.deselect : Icons.select_all,
                size: 18,
              ),
              label: Text(_allSelected
                  ? getLocalText.s("Deselect all")
                  : getLocalText.s("Select all")),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: widget.rules.length,
              itemBuilder: (_, i) {
                final rule = widget.rules[i];
                final summary = rule.summary();
                return CheckboxListTile(
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _selected.contains(rule.id),
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      _selected.add(rule.id);
                    } else {
                      _selected.remove(rule.id);
                    }
                  }),
                  title: Text(widget.displayNames[i]),
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
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: FilledButton(
            onPressed: _selected.isEmpty
                ? null
                : () => Navigator.pop(context, [
                      for (final r in widget.rules)
                        if (_selected.contains(r.id)) r
                    ]),
            child: Text(getLocalText.s("Export (%d)", _selected.length)),
          ),
        ),
      ),
    );
  }
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
