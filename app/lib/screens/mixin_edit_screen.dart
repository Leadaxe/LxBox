import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../config/config_parse.dart';
import '../controllers/subscription_controller.dart';
import '../models/mixin.dart';
import '../services/l10n/locale_controller.dart';
import '../services/mixins/mixin_apply.dart';
import '../services/mixins/mixin_path.dart';
import '../services/mixins/mixin_preview.dart';
import '../services/mixins/mixin_suggest.dart';
import '../services/ui_helpers.dart';
import '../widgets/app_bottom_sheet.dart';
import '../widgets/lx_code_editor.dart';
import '../widgets/safe_bottom.dart';

/// Вид строки статуса поля Target.
enum MixinTargetStatusKind { ok, error, neutral }

/// Статус поля Target: текст и вид. Save разрешена при [ok] или при
/// [neutral] (конфиг в этой сессии ещё не собирали, синтаксис верный).
class MixinTargetStatus {
  final MixinTargetStatusKind kind;
  final String text;
  const MixinTargetStatus(this.kind, this.text);

  bool get allowsSave => kind != MixinTargetStatusKind.error;
}

/// §704 §5 — форма миксина: Name, Target с подсказками по курсору и живым
/// статусом, Action, Value (JSON5) и Preview — фрагмент результата. Save
/// возвращает миксин через `Navigator.pop`; запись и пересборку делает
/// вкладка Mixins.
class MixinEditScreen extends StatefulWidget {
  const MixinEditScreen({
    super.key,
    this.initial,
    required this.mixins,
    this.subController,
  });

  /// `null` — новый миксин (встаёт в конец списка).
  final Mixin? initial;

  /// Весь список: база предпросмотра = конфиг до миксинов + миксины выше.
  final List<Mixin> mixins;

  /// Источник базы (`lastConfigBeforeMixins`); `null` — базы нет.
  final SubscriptionController? subController;

  @override
  State<MixinEditScreen> createState() => _MixinEditScreenState();
}

class _MixinEditScreenState extends State<MixinEditScreen> {
  final _name = TextEditingController();
  final _target = TextEditingController();
  final _keys = TextEditingController();
  final _value = TextEditingController();
  final _targetFocus = FocusNode();

  MixinOp _op = MixinOp.append;
  bool _removeKeys = false;
  bool _edited = false;

  /// Конфиг, который миксин увидит при сборке; `null` — не собирали.
  Map<String, dynamic>? _base;

  @override
  void initState() {
    super.initState();
    final m = widget.initial;
    if (m != null) {
      _name.text = m.name;
      _target.text = m.target;
      _op = m.opKind ?? MixinOp.append;
      final v = m.value;
      if (_op == MixinOp.remove) {
        if (v is List) {
          _removeKeys = true;
          _keys.text = v.map((e) => '$e').join(', ');
        }
      } else {
        _value.text = const JsonEncoder.withIndent('  ').convert(v);
      }
    }
    final base = widget.subController?.lastConfigBeforeMixins;
    if (base != null) {
      _base = mixinPreviewBase(base, widget.mixins, beforeId: m?.id);
    }
    _target.addListener(_onTargetChanged);
    _targetFocus.addListener(_onTargetChanged);
  }

  @override
  void dispose() {
    _target.removeListener(_onTargetChanged);
    _targetFocus.removeListener(_onTargetChanged);
    _name.dispose();
    _target.dispose();
    _keys.dispose();
    _value.dispose();
    _targetFocus.dispose();
    super.dispose();
  }

  /// Текст или курсор Target сменились: статус и подсказки.
  void _onTargetChanged() {
    if (mounted) setState(() {});
  }

  void _markEdited() {
    _edited = true;
    setState(() {});
  }

  // ─── Value ───

  /// Разобранное значение: `(value, null)` или `(null, ошибка)`. Пустое
  /// поле — ошибка без текста (Save неактивна, подписи нет).
  (Object?, String?) _parseValue() {
    if (_op == MixinOp.remove) {
      if (!_removeKeys) return (true, null);
      final keys = [
        for (final k in _keys.text.split(','))
          if (k.trim().isNotEmpty) k.trim(),
      ];
      if (keys.isEmpty) return (null, '');
      return (keys, null);
    }
    final text = _value.text.trim();
    if (text.isEmpty) return (null, '');
    try {
      return (jsonDecode(canonicalJsonForSingbox(text)), null);
    } on FormatException catch (e) {
      return (null, e.message);
    }
  }

  // ─── Target ───

  MixinTargetStatus _status() {
    final parsed = parseMixinPath(_target.text);
    if (parsed is MixinPathError) {
      return MixinTargetStatus(
        MixinTargetStatusKind.error,
        getLocalText.s("✗ syntax: %s", parsed.message),
      );
    }
    final base = _base;
    if (base == null) {
      return MixinTargetStatus(
        MixinTargetStatusKind.neutral,
        getLocalText.s("No config built yet"),
      );
    }
    final matches = (parsed as MixinPath).resolve(base);
    final n = matches.length;
    if (n == 0) {
      return MixinTargetStatus(
        MixinTargetStatusKind.error,
        getLocalText.s("✗ no match"),
      );
    }
    if (_op == MixinOp.append || _op == MixinOp.prepend) {
      if (n != 1 || matches.single.value is! List) {
        return MixinTargetStatus(
          MixinTargetStatusKind.error,
          getLocalText.s("✗ needs a single list"),
        );
      }
    }
    if (_op == MixinOp.before || _op == MixinOp.after) {
      if (!matches.every((m) => m.isListElement)) {
        return MixinTargetStatus(
          MixinTargetStatusKind.error,
          getLocalText.s("✗ not a list element"),
        );
      }
    }
    final count = n == 1
        ? getLocalText.s("✓ 1 match")
        : getLocalText.plural("✓ %d matches", n);
    if (n > 1 && _op == MixinOp.before) {
      return MixinTargetStatus(
        MixinTargetStatusKind.ok,
        getLocalText.s("%s → before first", count),
      );
    }
    if (n > 1 && _op == MixinOp.after) {
      return MixinTargetStatus(
        MixinTargetStatusKind.ok,
        getLocalText.s("%s → after last", count),
      );
    }
    return MixinTargetStatus(MixinTargetStatusKind.ok, count);
  }

  MixinPathSuggestions _suggestions() {
    final base = _base;
    if (base == null || !_targetFocus.hasFocus) {
      return MixinPathSuggestions.none;
    }
    final sel = _target.selection;
    final cursor = sel.isValid ? sel.baseOffset : _target.text.length;
    return suggestMixinPathAt(_target.text, cursor, base);
  }

  void _applySuggestion(MixinPathSuggestions s, String item) {
    final sel = _target.selection;
    final cursor = sel.isValid ? sel.baseOffset : _target.text.length;
    final (text, at) = applyMixinPathSuggestion(_target.text, cursor, s, item);
    _edited = true;
    _target.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: at),
    );
  }

  // ─── Save / Back ───

  Mixin? _build() {
    final (value, error) = _parseValue();
    if (error != null) return null;
    final m = widget.initial;
    if (m == null) {
      return Mixin(
        name: _name.text.trim(),
        target: _target.text.trim(),
        op: _op.name,
        value: value,
      );
    }
    return m.copyWith(
      name: _name.text.trim(),
      target: _target.text.trim(),
      op: _op.name,
      value: value,
    );
  }

  bool _canSave() => _status().allowsSave && _parseValue().$2 == null;

  void _save() {
    if (!_canSave()) return;
    final m = _build();
    if (m == null) return;
    Navigator.pop(context, m);
  }

  Future<void> _handleBack() async {
    if (!_edited) {
      Navigator.pop(context);
      return;
    }
    final action = await showUnsavedChangesDialog(context); // §219
    if (!mounted) return;
    if (action == 'save') {
      if (_canSave()) {
        _save();
      }
    } else if (action == 'discard') {
      Navigator.pop(context);
    }
  }

  // ─── UI ───

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final status = _status();
    final (value, valueError) = _parseValue();
    final suggestions = _suggestions();
    final canSave = status.allowsSave && valueError == null;
    final statusColor = switch (status.kind) {
      MixinTargetStatusKind.ok => cs.primary,
      MixinTargetStatusKind.error => cs.error,
      MixinTargetStatusKind.neutral => cs.onSurfaceVariant,
    };

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_handleBack());
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(getLocalText.s("Mixin")),
          actions: [
            TextButton(
              onPressed: canSave ? _save : null,
              child: Text(getLocalText.s("Save")),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24)
              .withSafeBottom(context),
          children: [
            TextField(
              controller: _name,
              onChanged: (_) => _markEdited(),
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: getLocalText.s("Name"),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('mixin-target'),
              controller: _target,
              focusNode: _targetFocus,
              onChanged: (_) => _markEdited(),
              autocorrect: false,
              enableSuggestions: false,
              style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: getLocalText.s("Target"),
                // l10n-exempt: path example
                hintText: 'route.rules[action=hijack-dns]',
                isDense: true,
              ),
            ),
            if (suggestions.items.isNotEmpty)
              _SuggestionList(
                items: suggestions.items,
                onPick: (item) => _applySuggestion(suggestions, item),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4),
              child: Text(
                status.text,
                key: const ValueKey('mixin-target-status'),
                style: TextStyle(fontSize: 12, color: statusColor),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<MixinOp>(
              key: ValueKey('mixin-op-${_op.name}'),
              initialValue: _op,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: getLocalText.s("Action"),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                for (final op in MixinOp.values)
                  DropdownMenuItem(
                    value: op,
                    // l10n-exempt: verb name as stored
                    child: Text(op.name),
                  ),
              ],
              onChanged: (op) {
                if (op == null) return;
                _op = op;
                _markEdited();
              },
            ),
            const SizedBox(height: 12),
            if (_op == MixinOp.remove) ...[
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(
                    value: false,
                    label: Text(getLocalText.s("Whole node")),
                  ),
                  ButtonSegment(
                    value: true,
                    label: Text(getLocalText.s("Keys")),
                  ),
                ],
                selected: {_removeKeys},
                onSelectionChanged: (s) {
                  _removeKeys = s.first;
                  _markEdited();
                },
              ),
              if (_removeKeys) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _keys,
                  onChanged: (_) => _markEdited(),
                  autocorrect: false,
                  style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    labelText: getLocalText.s("Keys, comma-separated"),
                    // l10n-exempt: key list example
                    hintText: 'tcp_fast_open, tls.utls',
                    isDense: true,
                  ),
                ),
              ],
            ] else
              LxTextCodeField(
                controller: _value,
                onChanged: (_) => _markEdited(),
                minLines: 4,
                maxLines: 16,
                fontSize: 13,
                label: getLocalText.s("Value"),
                errorText: (valueError == null || valueError.isEmpty)
                    ? null
                    : valueError,
              ),
            const SizedBox(height: 16),
            if (_base != null &&
                status.kind == MixinTargetStatusKind.ok &&
                valueError == null)
              _PreviewSection(
                preview: previewMixin(
                  _base!,
                  Mixin(
                    target: _target.text.trim(),
                    op: _op.name,
                    value: value,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Подсказки Target под полем: тап подставляет и ставит курсор дальше.
class _SuggestionList extends StatelessWidget {
  const _SuggestionList({required this.items, required this.onPick});

  final List<String> items;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Тап по подсказке — «внутри» поля: фокус и клавиатура остаются.
    return TextFieldTapRegion(
      child: Container(
        constraints: const BoxConstraints(maxHeight: 200),
        margin: const EdgeInsets.only(top: 2),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
        ),
        child: ListView.builder(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          itemCount: items.length,
          itemBuilder: (_, i) => InkWell(
            onTap: () => onPick(items[i]),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text(
                items[i],
                style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Preview: родитель цели после применения, строка на элемент с маркером
/// в гаттере и подкраской; тап — полный JSON элемента.
class _PreviewSection extends StatelessWidget {
  const _PreviewSection({required this.preview});

  final MixinPreview preview;

  Color? _background(ColorScheme cs, String marker) => switch (marker) {
    '+' => cs.primaryContainer.withValues(alpha: 0.5),
    '~' => cs.tertiaryContainer.withValues(alpha: 0.5),
    '-' => cs.errorContainer.withValues(alpha: 0.5),
    _ => null,
  };

  void _showFull(BuildContext context, MixinPreviewRow row) {
    final text = const JsonEncoder.withIndent('  ').convert(row.value);
    unawaited(
      showAppBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (ctx) => Padding(
          padding: EdgeInsets.fromLTRB(
            12,
            0,
            12,
            MediaQuery.of(ctx).padding.bottom + 12,
          ),
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.6,
            child: LxJsonView(text: text, showLineNumbers: true),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final fragment = preview.fragment;
    final issue = preview.issue;
    final mono = TextStyle(
      fontSize: 12,
      fontFamily: 'monospace',
      color: cs.onSurface,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              getLocalText.s("Preview"),
              style: theme.textTheme.labelSmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 8),
            if (fragment != null)
              Expanded(
                child: Text(
                  fragment.parentPath.isEmpty
                      ? getLocalText.s("(root)")
                      : fragment.parentPath,
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: cs.onSurfaceVariant,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        if (issue != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '⚠ ${issue.reason}',
              style: TextStyle(fontSize: 12, color: cs.error),
            ),
          ),
        if (fragment != null)
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: cs.outlineVariant),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final row in fragment.rows)
                  InkWell(
                    onTap: () => _showFull(context, row),
                    child: Container(
                      color: _background(cs, row.marker),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 14,
                            child: Text(row.marker, style: mono),
                          ),
                          Expanded(
                            child: Text(
                              row.text,
                              style: mono,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
