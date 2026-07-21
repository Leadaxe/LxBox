import 'dart:async';

import 'package:flutter/material.dart';

import '../../../controllers/subscription_controller.dart';
import '../../../models/import_rule.dart';
import '../../../models/node_spec.dart';
import '../../../models/server_list.dart';
import '../../../services/l10n/locale_controller.dart';

/// §302 — «Filters» tab: per-subscription import-rules (REPLACE + DISABLE),
/// применяемые к телу подписки на импорте/обновлении. CRUD + drag-reorder +
/// общий тумблер набора. Правила вступают в силу на следующем refresh —
/// после каждой правки показываем snackbar с кнопкой Refresh, а редактор
/// правила даёт живой предпросмотр эффекта на тестовой строке.
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

  /// Пример строки для предпросмотра в редакторе — сырой URI первой ноды
  /// подписки (то, на чём правило реально сработает). Пусто → редактор
  /// покажет плейсхолдер, юзер введёт строку сам.
  String get _sampleLine {
    final nodes = _sub?.nodes ?? const <NodeSpec>[];
    if (nodes.isEmpty) return '';
    // originLine = дозаменная строка (если правило уже её меняло); иначе
    // rawUri = то, что распарсилось. Для предпросмотра нужен «вход» —
    // берём originLine, когда есть, чтобы не показывать уже-заменённое.
    return nodes.first.originLine ?? nodes.first.rawUri;
  }

  void _persist() => unawaited(widget.controller.persistSources());

  /// Правила меняются — существующие ноды не переразбираются задним числом.
  /// Показываем это snackbar'ом с кнопкой Refresh (тот же путь, что кнопка
  /// обновления в AppBar) — чтобы «когда сработает» было очевидно и в один тап.
  void _notifyChanged() {
    if (!mounted || !_setEnabled) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text(getLocalText.s(
            "Rules changed. Refresh the subscription to apply them.")),
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: getLocalText.s("Refresh"),
          onPressed: () {
            final idx = widget.controller.entries.indexOf(widget.entry);
            if (idx >= 0) unawaited(widget.controller.updateAt(idx));
          },
        ),
      ),
    );
  }

  Future<void> _addRule() async {
    final rule = await _openRuleEditor(null);
    if (rule == null) return;
    widget.entry.updateImportRules([..._rules, rule]);
    _persist();
    setState(() {});
    _notifyChanged();
  }

  Future<void> _editRuleAt(int i) async {
    if (i < 0 || i >= _rules.length) return;
    final rule = await _openRuleEditor(_rules[i]);
    if (rule == null) return;
    final next = [..._rules]..[i] = rule;
    widget.entry.updateImportRules(next);
    _persist();
    setState(() {});
    _notifyChanged();
  }

  void _deleteRuleAt(int i) {
    if (i < 0 || i >= _rules.length) return;
    final next = [..._rules]..removeAt(i);
    widget.entry.updateImportRules(next);
    _persist();
    setState(() {});
    _notifyChanged();
  }

  void _toggleRuleAt(int i, bool enabled) {
    if (i < 0 || i >= _rules.length) return;
    final next = [..._rules]..[i] = _rules[i].copyWith(enabled: enabled);
    widget.entry.updateImportRules(next);
    _persist();
    setState(() {});
    _notifyChanged();
  }

  void _reorder(int oldIndex, int newIndex) {
    final next = [..._rules];
    if (newIndex > oldIndex) newIndex -= 1;
    final moved = next.removeAt(oldIndex);
    next.insert(newIndex, moved);
    widget.entry.updateImportRules(next);
    _persist();
    setState(() {});
    _notifyChanged();
  }

  /// Открывает полноэкранный редактор правила (add/edit). Возвращает
  /// `ImportRule` или `null` (отмена/системный back).
  Future<ImportRule?> _openRuleEditor(ImportRule? initial) {
    return Navigator.of(context).push<ImportRule>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _RuleEditorScreen(
          initial: initial,
          sampleLine: _sampleLine,
        ),
      ),
    );
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
            _notifyChanged();
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
          child: Row(
            children: [
              Icon(Icons.info_outline,
                  size: 16, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  getLocalText.s(
                      "Rules apply on the next update. Refresh to see the effect."),
                  style: TextStyle(
                      fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: rules.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      getLocalText.s(
                          "No rules yet. Add one to fix broken params or hide nodes."),
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

/// §302 — полноэкранный редактор одного правила (add/edit). Возвращает
/// `ImportRule` через `Navigator.pop` или `null` (Cancel/системный back).
/// Regex валидируется вживую (как node-фильтр §301): при `isRegex` пробуем
/// компиляцию, ошибку показываем под полем и блокируем Save. Секция Preview
/// прогоняет текущее правило по тестовой строке в реальном времени — это
/// отвечает на вопрос «что именно и когда правило делает».
class _RuleEditorScreen extends StatefulWidget {
  const _RuleEditorScreen({this.initial, this.sampleLine = ''});

  final ImportRule? initial;

  /// Префилл тестовой строки предпросмотра (сырой URI первой ноды подписки).
  final String sampleLine;

  @override
  State<_RuleEditorScreen> createState() => _RuleEditorScreenState();
}

class _RuleEditorScreenState extends State<_RuleEditorScreen> {
  late ImportRuleAction _action;
  late TextEditingController _pattern;
  late TextEditingController _replacement;
  late TextEditingController _testLine;
  late bool _isRegex;
  late bool _caseSensitive;

  @override
  void initState() {
    super.initState();
    final r = widget.initial;
    _action = r?.action ?? ImportRuleAction.replace;
    _pattern = TextEditingController(text: r?.pattern ?? '');
    _replacement = TextEditingController(text: r?.replacement ?? '');
    _testLine = TextEditingController(text: widget.sampleLine);
    _isRegex = r?.isRegex ?? false;
    _caseSensitive = r?.caseSensitive ?? false;
    // Живой предпросмотр — перерисовываемся на любой ввод.
    _pattern.addListener(_onChanged);
    _replacement.addListener(_onChanged);
    _testLine.addListener(_onChanged);
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _pattern.dispose();
    _replacement.dispose();
    _testLine.dispose();
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

  /// Компилированный матчер текущего правила (или null — пуст/битый паттерн).
  /// Через `ImportRule.compiledPattern`, чтобы preview использовал ровно ту же
  /// семантику (escape/флаг caseSensitive), что и применение на этапе A.
  RegExp? get _matcher => _current().compiledPattern;

  ImportRule _current() => ImportRule(
        action: _action,
        pattern: _pattern.text,
        replacement:
            _action == ImportRuleAction.replace ? _replacement.text : '',
        isRegex: _isRegex,
        caseSensitive: _caseSensitive,
        enabled: widget.initial?.enabled ?? true,
      );

  void _save() {
    if (_patternError != null) return;
    Navigator.of(context).pop(_current());
  }

  @override
  Widget build(BuildContext context) {
    final isReplace = _action == ImportRuleAction.replace;
    final err = _patternError;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: getLocalText.s("Cancel"),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(widget.initial == null
            ? getLocalText.s("Add rule")
            : getLocalText.s("Edit rule")),
        actions: [
          TextButton(
            onPressed: err != null ? null : _save,
            child: Text(getLocalText.s("Save")),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
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
          const SizedBox(height: 8),
          Text(
            isReplace
                ? getLocalText.s(
                    "Rewrites matching text in every node line (e.g. fix a broken fingerprint).")
                : getLocalText.s(
                    "Hides matching nodes from routing. They stay visible, struck through."),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _pattern,
            autofocus: widget.initial == null,
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
          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 8),
          _previewSection(context, isReplace),
        ],
      ),
    );
  }

  Widget _previewSection(BuildContext context, bool isReplace) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          getLocalText.s("Preview"),
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        Text(
          getLocalText.s(
              "Test the rule against a node line to see what it does."),
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _testLine,
          maxLines: null,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          decoration: InputDecoration(
            labelText: getLocalText.s("Test line"),
            hintText: 'vless://…',
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 12),
        _previewResult(context, isReplace),
      ],
    );
  }

  Widget _previewResult(BuildContext context, bool isReplace) {
    final theme = Theme.of(context);
    final line = _testLine.text;
    final matcher = _matcher;

    if (line.isEmpty) {
      return _previewHint(
          theme, getLocalText.s("Enter a test line above to preview."));
    }
    if (matcher == null) {
      return _previewHint(
          theme, getLocalText.s("Enter a valid pattern to preview."));
    }

    final matches = matcher.hasMatch(line);

    if (!isReplace) {
      // DISABLE — совпало / нет.
      return _statusChip(
        theme,
        matched: matches,
        matchedLabel: getLocalText.s("This node would be disabled"),
        unmatchedLabel: getLocalText.s("No match — node kept"),
      );
    }

    // REPLACE — показываем after (и сравнение с before, если изменилось).
    final after = line.replaceAll(matcher, _replacement.text);
    final changed = after != line;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _statusChip(
          theme,
          matched: changed,
          matchedLabel: getLocalText.s("Match — text rewritten"),
          unmatchedLabel: getLocalText.s("No match — line unchanged"),
        ),
        if (changed) ...[
          const SizedBox(height: 8),
          _diffRow(theme, getLocalText.s("Before"), line,
              theme.colorScheme.error),
          const SizedBox(height: 4),
          _diffRow(theme, getLocalText.s("After"), after,
              theme.colorScheme.primary),
        ],
      ],
    );
  }

  Widget _previewHint(ThemeData theme, String text) => Text(
        text,
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      );

  Widget _statusChip(
    ThemeData theme, {
    required bool matched,
    required String matchedLabel,
    required String unmatchedLabel,
  }) {
    final color = matched ? theme.colorScheme.primary : theme.colorScheme.outline;
    return Row(
      children: [
        Icon(matched ? Icons.check_circle_outline : Icons.remove_circle_outline,
            size: 18, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            matched ? matchedLabel : unmatchedLabel,
            style: theme.textTheme.bodyMedium?.copyWith(color: color),
          ),
        ),
      ],
    );
  }

  Widget _diffRow(ThemeData theme, String label, String value, Color color) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(color: color),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ],
      ),
    );
  }
}
