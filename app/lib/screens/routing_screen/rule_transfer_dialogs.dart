import 'package:flutter/material.dart';

import '../../models/custom_rule.dart';
import '../../services/format_utils.dart' show formatDateTime;
import '../../services/l10n/locale_controller.dart';
import '../../services/rule_transfer.dart';

/// §396 — диалоги экспорта/импорта правил. Чистая презентация (стиль
/// `routing_screen_menus.dart` / `import_preview_dialog.dart` бэкапа):
/// показывают диалог и возвращают выбор, state-мутации остаются в экране.

/// Итог экспорт-флоу: выбранные правила + DNS-сущности второго экрана.
class RuleExportSelection {
  const RuleExportSelection({
    required this.rules,
    this.dnsServers = const [],
    this.dnsRules = const [],
  });

  final List<CustomRule> rules;
  final List<Map<String, dynamic>> dnsServers;
  final List<Map<String, dynamic>> dnsRules;
}

/// Экран выбора правил на экспорт (шаг 1) → экран DNS (шаг 2, §4.2 п.2
/// спеки §396). [displayNames] позиционно выровнен с [rules] (live-label'ы
/// пресетов — `ruleDisplayNames` §279). Полноэкранный (решение владельца:
/// попап для списка правил тесен), по умолчанию НИЧЕГО не выбрано, над
/// списком тумблер Select all / Deselect all.
///
/// [dnsServers] — `dns_options.servers` без `kind: preset`; [dnsRules] —
/// `dns_options.rules` только inline/srs (фильтрует вызывающий).
/// [templateServerTags] — для предотметки на шаге 2 (referenced-теги,
/// которых нет в шаблоне). Возвращает составной выбор или null (отмена).
Future<RuleExportSelection?> showRuleExportPicker(
  BuildContext context, {
  required List<CustomRule> rules,
  required List<String> displayNames,
  required List<Map<String, dynamic>> dnsServers,
  required List<Map<String, dynamic>> dnsRules,
  required Set<String> templateServerTags,
}) {
  return Navigator.of(context).push<RuleExportSelection>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _RuleExportScreen(
        rules: rules,
        displayNames: displayNames,
        dnsServers: dnsServers,
        dnsRules: dnsRules,
        templateServerTags: templateServerTags,
      ),
    ),
  );
}

class _RuleExportScreen extends StatefulWidget {
  const _RuleExportScreen({
    required this.rules,
    required this.displayNames,
    required this.dnsServers,
    required this.dnsRules,
    required this.templateServerTags,
  });

  final List<CustomRule> rules;
  final List<String> displayNames;
  final List<Map<String, dynamic>> dnsServers;
  final List<Map<String, dynamic>> dnsRules;
  final Set<String> templateServerTags;

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

  Future<void> _next() async {
    final picked = [
      for (final r in widget.rules)
        if (_selected.contains(r.id)) r
    ];
    // Нечего показывать на шаге 2 → сразу отдаём выбор правил.
    if (widget.dnsServers.isEmpty && widget.dnsRules.isEmpty) {
      Navigator.pop(context, RuleExportSelection(rules: picked));
      return;
    }
    // Предотметка: серверы, на которые ссылаются выбранные правила и
    // которых нет в шаблоне получателя (шаблонные у него есть всегда).
    final referenced = referencedDnsServerTags(picked)
        .difference(widget.templateServerTags);
    final dns = await Navigator.of(context).push<(List<int>, List<int>)>(
      MaterialPageRoute(
        builder: (_) => _DnsExportScreen(
          servers: widget.dnsServers,
          rules: widget.dnsRules,
          preselectedServerTags: referenced,
        ),
      ),
    );
    if (dns == null || !mounted) return; // back — остаёмся на шаге 1
    final (serverIdx, ruleIdx) = dns;
    Navigator.pop(
      context,
      RuleExportSelection(
        rules: picked,
        dnsServers: [for (final i in serverIdx) widget.dnsServers[i]],
        dnsRules: [for (final i in ruleIdx) widget.dnsRules[i]],
      ),
    );
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
            onPressed: _selected.isEmpty ? null : _next,
            child: Text(getLocalText.s("Continue")),
          ),
        ),
      ),
    );
  }
}

/// Шаг 2 экспорта — DNS-сущности в файл. Возвращает (индексы серверов,
/// индексы правил) или null (back — вернуться к выбору правил).
class _DnsExportScreen extends StatefulWidget {
  const _DnsExportScreen({
    required this.servers,
    required this.rules,
    required this.preselectedServerTags,
  });

  final List<Map<String, dynamic>> servers;
  final List<Map<String, dynamic>> rules;
  final Set<String> preselectedServerTags;

  @override
  State<_DnsExportScreen> createState() => _DnsExportScreenState();
}

class _DnsExportScreenState extends State<_DnsExportScreen> {
  final _servers = <int>{};
  final _rules = <int>{};

  @override
  void initState() {
    super.initState();
    for (var i = 0; i < widget.servers.length; i++) {
      final tag = widget.servers[i]['tag']?.toString() ?? '';
      if (widget.preselectedServerTags.contains(tag)) _servers.add(i);
    }
  }

  String _serverLabel(Map<String, dynamic> s) {
    final tag = s['tag']?.toString() ?? '';
    final desc = s['description']?.toString() ?? '';
    return desc.isNotEmpty ? '$desc ($tag)' : tag;
  }

  Widget _header(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w600)),
      );

  @override
  Widget build(BuildContext context) {
    final total = _servers.length + _rules.length;
    return Scaffold(
      appBar: AppBar(title: Text(getLocalText.s("Include DNS"))),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              getLocalText.s(
                  "Optionally bundle DNS servers and DNS rules the recipient may be missing. Servers referenced by the selected rules are pre-checked."),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          if (widget.servers.isNotEmpty) ...[
            _header(getLocalText.s("DNS Servers")),
            for (var i = 0; i < widget.servers.length; i++)
              CheckboxListTile(
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                value: _servers.contains(i),
                onChanged: (v) => setState(() {
                  if (v == true) {
                    _servers.add(i);
                  } else {
                    _servers.remove(i);
                  }
                }),
                title: Text(_serverLabel(widget.servers[i])),
              ),
          ],
          if (widget.rules.isNotEmpty) ...[
            _header(getLocalText.s("DNS Rules")),
            for (var i = 0; i < widget.rules.length; i++)
              CheckboxListTile(
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                value: _rules.contains(i),
                onChanged: (v) => setState(() {
                  if (v == true) {
                    _rules.add(i);
                  } else {
                    _rules.remove(i);
                  }
                }),
                title: Text(widget.rules[i]['name']?.toString() ?? ''),
              ),
          ],
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: FilledButton(
            onPressed: () =>
                Navigator.pop(context, (_servers.toList()..sort(), _rules.toList()..sort())),
            child: Text(total > 0
                ? getLocalText.s("Export (+%d DNS)", total)
                : getLocalText.s("Export without DNS")),
          ),
        ),
      ),
    );
  }
}

/// Итог превью импорта: выбранные правила + выбранные DNS-сущности.
class RuleImportSelection {
  const RuleImportSelection({
    required this.rules,
    this.dnsServers = const [],
    this.dnsRules = const [],
  });

  final List<SanitizedImportRule> rules;
  final List<Map<String, dynamic>> dnsServers;
  final List<Map<String, dynamic>> dnsRules;
}

/// Превью импорта: шапка (когда/чем создан) + чекбокс на правило с итогом
/// санации + DNS-секции файла (если есть). Неимпортируемые (§5.3/§5.3a
/// спеки) — disabled с причиной. Возвращает выбор или null (отмена).
Future<RuleImportSelection?> showRuleImportPreview(
  BuildContext context, {
  required List<SanitizedImportRule> items,
  List<SanitizedImportDnsItem> dnsServers = const [],
  List<SanitizedImportDnsItem> dnsRules = const [],
  DateTime? createdAt,
  String? sourceAppVersion,
}) {
  final selected = <int>{
    for (var i = 0; i < items.length; i++)
      if (items[i].importable) i,
  };
  final selServers = <int>{
    for (var i = 0; i < dnsServers.length; i++)
      if (dnsServers[i].importable) i,
  };
  final selRules = <int>{
    for (var i = 0; i < dnsRules.length; i++)
      if (dnsRules[i].importable) i,
  };
  return showDialog<RuleImportSelection>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) {
        final cs = Theme.of(ctx).colorScheme;
        final total = selected.length + selServers.length + selRules.length;
        Widget dnsSection(String title, List<SanitizedImportDnsItem> list,
            Set<int> sel) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 2),
                child: Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w500)),
              ),
              for (var i = 0; i < list.length; i++)
                _importDnsRow(ctx, cs, list[i],
                    checked: sel.contains(i),
                    onChanged: list[i].importable
                        ? (v) => set(() {
                              if (v == true) {
                                sel.add(i);
                              } else {
                                sel.remove(i);
                              }
                            })
                        : null),
            ],
          );
        }

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
                  if (dnsServers.isNotEmpty)
                    dnsSection(getLocalText.s("DNS Servers"), dnsServers,
                        selServers),
                  if (dnsRules.isNotEmpty)
                    dnsSection(
                        getLocalText.s("DNS Rules"), dnsRules, selRules),
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
              onPressed: total == 0
                  ? null
                  : () => Navigator.pop(
                        ctx,
                        RuleImportSelection(
                          rules: [
                            for (var i = 0; i < items.length; i++)
                              if (selected.contains(i)) items[i]
                          ],
                          dnsServers: [
                            for (var i = 0; i < dnsServers.length; i++)
                              if (selServers.contains(i)) dnsServers[i].item!
                          ],
                          dnsRules: [
                            for (var i = 0; i < dnsRules.length; i++)
                              if (selRules.contains(i)) dnsRules[i].item!
                          ],
                        ),
                      ),
              child: Text(getLocalText.s("Import (%d)", total)),
            ),
          ],
        );
      },
    ),
  );
}

Widget _importDnsRow(
  BuildContext ctx,
  ColorScheme cs,
  SanitizedImportDnsItem item, {
  required bool checked,
  required ValueChanged<bool?>? onChanged,
}) {
  final title = item.label.isNotEmpty
      ? item.label
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
    subtitle: item.skipReason == null
        ? null
        : Text(
            _dnsSkipText(item.skipReason!),
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
  );
}

String _dnsSkipText(ImportDnsSkipReason r) => switch (r) {
      ImportDnsSkipReason.unsupportedEntry =>
        getLocalText.s("Unsupported entry — skipped"),
      ImportDnsSkipReason.alreadyExists =>
        getLocalText.s("Already on this device"),
      ImportDnsSkipReason.notAvailable =>
        getLocalText.s("Not available in this app version"),
      ImportDnsSkipReason.managedByPresets =>
        getLocalText.s("Managed by presets automatically"),
    };

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
