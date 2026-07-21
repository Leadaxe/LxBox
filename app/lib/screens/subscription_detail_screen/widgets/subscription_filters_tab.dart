import 'dart:async';

import 'package:flutter/material.dart';

import '../../../controllers/subscription_controller.dart';
import '../../../models/import_rule.dart';
import '../../../models/server_list.dart';
import '../../../services/l10n/locale_controller.dart';

/// §302 — «Filters» tab: per-subscription import-rules (REPLACE + DISABLE),
/// применяемые к телу подписки на импорте/обновлении. CRUD + drag-reorder +
/// общий тумблер набора. Правила вступают в силу на следующем refresh —
/// вкладка подсказывает это баннером.
///
/// Самодостаточна (как Source-tab): читает правила из `entry.list`, мутирует
/// через `entry.updateImportRules` / `entry.importRulesEnabled` и persist'ит
/// через `controller.persistSources()`. Слушает `entry` (ChangeNotifier),
/// чтобы фоновый refresh/rename не рассинхронил список.
class SubscriptionFiltersTab extends StatefulWidget {
  const SubscriptionFiltersTab({
    super.key,
    required this.entry,
    required this.controller,
  });

  final SubscriptionEntry entry;
  final SubscriptionController controller;

  @override
  State<SubscriptionFiltersTab> createState() => _SubscriptionFiltersTabState();
}

class _SubscriptionFiltersTabState extends State<SubscriptionFiltersTab> {
  SubscriptionServers? get _sub {
    final l = widget.entry.list;
    return l is SubscriptionServers ? l : null;
  }

  List<ImportRule> get _rules => _sub?.importRules ?? const [];
  bool get _setEnabled => _sub?.importRulesEnabled ?? true;

  void _persist() => unawaited(widget.controller.persistSources());

  Future<void> _addRule() async {
    final rule = await _editRuleDialog(context, null);
    if (rule == null) return;
    widget.entry.updateImportRules([..._rules, rule]);
    _persist();
    setState(() {});
  }

  Future<void> _editRuleAt(int i) async {
    if (i < 0 || i >= _rules.length) return;
    final rule = await _editRuleDialog(context, _rules[i]);
    if (rule == null) return;
    final next = [..._rules]..[i] = rule;
    widget.entry.updateImportRules(next);
    _persist();
    setState(() {});
  }

  void _deleteRuleAt(int i) {
    if (i < 0 || i >= _rules.length) return;
    final next = [..._rules]..removeAt(i);
    widget.entry.updateImportRules(next);
    _persist();
    setState(() {});
  }

  void _toggleRuleAt(int i, bool enabled) {
    if (i < 0 || i >= _rules.length) return;
    final next = [..._rules]..[i] = _rules[i].copyWith(enabled: enabled);
    widget.entry.updateImportRules(next);
    _persist();
    setState(() {});
  }

  void _reorder(int oldIndex, int newIndex) {
    final next = [..._rules];
    if (newIndex > oldIndex) newIndex -= 1;
    final moved = next.removeAt(oldIndex);
    next.insert(newIndex, moved);
    widget.entry.updateImportRules(next);
    _persist();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_sub == null) {
      return Center(child: Text(getLocalText.s("No nodes found")));
    }
    final rules = _rules;
    return Stack(
      children: [
        _body(context, rules, theme),
        Positioned(
          right: 16,
          bottom: MediaQuery.of(context).padding.bottom + 16,
          child: FloatingActionButton.extended(
            onPressed: _addRule,
            icon: const Icon(Icons.add),
            label: Text(getLocalText.s("Add rule")),
          ),
        ),
      ],
    );
  }

  Widget _body(BuildContext context, List<ImportRule> rules, ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Общий тумблер набора.
        SwitchListTile(
          value: _setEnabled,
          onChanged: (v) {
            widget.entry.importRulesEnabled = v;
            _persist();
            setState(() {});
          },
          title: Text(getLocalText.s("Enable import rules")),
          subtitle: Text(getLocalText.s(
              "Rewrite or disable nodes when the subscription is imported")),
        ),
        const Divider(height: 1),
        // Правила применяются на импорте — существующие ноды не меняются
        // задним числом. Подсказываем, что нужно обновить.
        Container(
          width: double.infinity,
          color: theme.colorScheme.surfaceContainerHighest,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            getLocalText.s("Rules apply on the next update. Refresh to see the effect."),
            style: TextStyle(
                fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: rules.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      getLocalText.s("No rules yet. Add one to fix broken params or hide nodes."),
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                )
              : ReorderableListView.builder(
                  padding: EdgeInsets.fromLTRB(
                      0, 0, 0, MediaQuery.of(context).padding.bottom + 80),
                  itemCount: rules.length,
                  onReorder: _reorder,
                  itemBuilder: (context, i) =>
                      _ruleTile(context, rules[i], i, key: ValueKey('rule-$i')),
                ),
        ),
      ],
    );
  }

  Widget _ruleTile(BuildContext context, ImportRule rule, int i,
      {required Key key}) {
    final theme = Theme.of(context);
    final invalid = rule.enabled && rule.pattern.isNotEmpty && !rule.isUsable;
    final isReplace = rule.action == ImportRuleAction.replace;
    return ListTile(
      key: key,
      leading: Switch(
        value: rule.enabled,
        onChanged: (v) => _toggleRuleAt(i, v),
      ),
      title: Row(
        children: [
          // Бейдж действия.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: (isReplace ? Colors.blue : Colors.orange)
                  .withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              isReplace
                  ? getLocalText.s("Replace")
                  : getLocalText.s("Disable"),
              style: TextStyle(
                fontSize: 10,
                color: isReplace ? Colors.blue : Colors.orange,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              rule.pattern.isEmpty ? getLocalText.s("(empty)") : rule.pattern,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
          ),
        ],
      ),
      subtitle: Text(
        [
          if (isReplace)
            '→ ${rule.replacement.isEmpty ? getLocalText.s("(remove)") : rule.replacement}',
          if (rule.isRegex) getLocalText.s("regex"),
          if (rule.caseSensitive) getLocalText.s("case-sensitive"),
          if (invalid) getLocalText.s("invalid pattern — skipped"),
        ].join('  ·  '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          color: invalid
              ? theme.colorScheme.error
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20),
            tooltip: getLocalText.s("Delete"),
            onPressed: () => _deleteRuleAt(i),
          ),
          ReorderableDragStartListener(
            index: i,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Icon(Icons.drag_handle, size: 20),
            ),
          ),
        ],
      ),
      onTap: () => _editRuleAt(i),
    );
  }
}

/// §302 — редактор одного правила (add/edit). Возвращает `ImportRule` или
/// `null` (отмена). Regex валидируется вживую (как node-фильтр §301): при
/// `isRegex` пробуем компиляцию, ошибку показываем под полем и блокируем Save.
Future<ImportRule?> _editRuleDialog(
    BuildContext context, ImportRule? initial) {
  return showDialog<ImportRule>(
    context: context,
    builder: (ctx) => _RuleEditor(initial: initial),
  );
}

class _RuleEditor extends StatefulWidget {
  const _RuleEditor({this.initial});
  final ImportRule? initial;

  @override
  State<_RuleEditor> createState() => _RuleEditorState();
}

class _RuleEditorState extends State<_RuleEditor> {
  late ImportRuleAction _action;
  late TextEditingController _pattern;
  late TextEditingController _replacement;
  late bool _isRegex;
  late bool _caseSensitive;

  @override
  void initState() {
    super.initState();
    final r = widget.initial;
    _action = r?.action ?? ImportRuleAction.replace;
    _pattern = TextEditingController(text: r?.pattern ?? '');
    _replacement = TextEditingController(text: r?.replacement ?? '');
    _isRegex = r?.isRegex ?? false;
    _caseSensitive = r?.caseSensitive ?? false;
    _pattern.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _pattern.dispose();
    _replacement.dispose();
    super.dispose();
  }

  /// null = валиден; иначе текст ошибки под полем паттерна.
  String? get _patternError {
    if (_pattern.text.isEmpty) return getLocalText.s("Pattern is required");
    if (!_isRegex) return null;
    try {
      RegExp(_pattern.text);
      return null;
    } catch (_) {
      return getLocalText.s("Invalid regular expression");
    }
  }

  @override
  Widget build(BuildContext context) {
    final isReplace = _action == ImportRuleAction.replace;
    final err = _patternError;
    return AlertDialog(
      title: Text(widget.initial == null
          ? getLocalText.s("Add rule")
          : getLocalText.s("Edit rule")),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Выбор действия.
            SegmentedButton<ImportRuleAction>(
              segments: [
                ButtonSegment(
                  value: ImportRuleAction.replace,
                  label: Text(getLocalText.s("Replace")),
                  icon: const Icon(Icons.find_replace, size: 18),
                ),
                ButtonSegment(
                  value: ImportRuleAction.disable,
                  label: Text(getLocalText.s("Disable")),
                  icon: const Icon(Icons.block, size: 18),
                ),
              ],
              selected: {_action},
              onSelectionChanged: (s) => setState(() => _action = s.first),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _pattern,
              autofocus: true,
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: InputDecoration(
                labelText: getLocalText.s("Pattern"),
                hintText: isReplace ? 'hellochrome_120' : r'.*Netherlands.*',
                errorText: err,
                border: const OutlineInputBorder(),
              ),
            ),
            if (isReplace) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _replacement,
                style: const TextStyle(fontFamily: 'monospace'),
                decoration: InputDecoration(
                  labelText: getLocalText.s("Replacement"),
                  hintText: 'chrome',
                  helperText: getLocalText.s("Empty removes the matched text"),
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _isRegex,
              onChanged: (v) => setState(() => _isRegex = v),
              title: Text(getLocalText.s("Regular expression")),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _caseSensitive,
              onChanged: (v) => setState(() => _caseSensitive = v),
              title: Text(getLocalText.s("Case-sensitive")),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(getLocalText.s("Cancel")),
        ),
        TextButton(
          onPressed: err != null
              ? null
              : () => Navigator.pop(
                    context,
                    ImportRule(
                      action: _action,
                      pattern: _pattern.text,
                      replacement:
                          isReplace ? _replacement.text : '',
                      isRegex: _isRegex,
                      caseSensitive: _caseSensitive,
                      enabled: widget.initial?.enabled ?? true,
                    ),
                  ),
          child: Text(getLocalText.s("Save")),
        ),
      ],
    );
  }
}
