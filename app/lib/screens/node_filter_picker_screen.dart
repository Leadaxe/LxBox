import 'package:flutter/material.dart';

import '../services/l10n/locale_controller.dart';
import '../services/ui_helpers.dart';
import '../widgets/safe_bottom.dart';
import 'home/filter_widgets.dart' show RegexFilterField;
import 'home/node_filter.dart';

/// §702 — результат пикера: паттерн и инверсия для поля Node filter.
class NodeFilterPick {
  const NodeFilterPick(this.pattern, this.invert);
  final String pattern;
  final bool invert;
}

/// §702 — полноэкранный пикер фильтра узлов Направления (образец — Emoji
/// picker лаунчера): regex + `!`, сетка эмодзи пула со счётчиками (тап —
/// toggle в OR-паттерне, как чипы home §048), список всего пула с ✓/✗.
/// Совпадение — как превью редактора: регистронезависимо (§301), пустой
/// паттерн = все узлы, инверсия выбирает не совпавшие (§197).
///
/// ✓ в AppBar возвращает [NodeFilterPick]; назад с изменениями — диалог
/// Save/Keep/Discard (§219).
class NodeFilterPickerScreen extends StatefulWidget {
  const NodeFilterPickerScreen({
    super.key,
    required this.pattern,
    required this.invert,
    required this.pool,
  });

  final String pattern;
  final bool invert;

  /// Пул кандидатов Направления (§674), уже посчитанный редактором.
  final List<String> pool;

  @override
  State<NodeFilterPickerScreen> createState() => _NodeFilterPickerScreenState();
}

class _NodeFilterPickerScreenState extends State<NodeFilterPickerScreen> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.pattern);
  late bool _invert = widget.invert;
  late final List<MapEntry<String, int>> _emojis =
      NodeFilter.emojiCounts(widget.pool);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  String get _pattern => _ctrl.text.trim();

  bool get _dirty => _pattern != widget.pattern.trim() || _invert != widget.invert;

  Set<String> get _selected =>
      _ctrl.text.split('|').where((p) => p.isNotEmpty).toSet();

  void _toggleEmoji(String emoji) {
    final parts = _ctrl.text.split('|').where((p) => p.isNotEmpty).toList();
    if (!parts.remove(emoji)) parts.add(emoji);
    final next = parts.join('|');
    _ctrl.text = next;
    _ctrl.selection = TextSelection.collapsed(offset: next.length);
    setState(() {});
  }

  void _apply() => Navigator.pop(context, NodeFilterPick(_pattern, _invert));

  Future<void> _handleBack() async {
    if (!_dirty) {
      Navigator.pop(context);
      return;
    }
    final action = await showUnsavedChangesDialog(context);
    if (!mounted) return;
    if (action == 'save') {
      _apply();
    } else if (action == 'discard') {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pattern = _pattern;
    RegExp? re;
    if (pattern.isNotEmpty) {
      try {
        re = RegExp(pattern, caseSensitive: false);
      } catch (_) {}
    }
    final valid = pattern.isEmpty || re != null;
    final matched = <String>[];
    final rest = <String>[];
    for (final t in widget.pool) {
      final hit = re == null || re.hasMatch(t) != _invert;
      (hit ? matched : rest).add(t);
    }
    final selected = _selected;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(getLocalText.s("Node filter")),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _handleBack,
          ),
          actions: [
            IconButton(
              tooltip: getLocalText.s("Apply"),
              icon: Icon(Icons.check,
                  color: _dirty ? cs.primary : cs.onSurfaceVariant),
              onPressed: valid ? _apply : null,
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              RegexFilterField(
                controller: _ctrl,
                onChanged: (_) => setState(() {}),
                valid: valid,
                invert: _invert,
                onInvertToggle: () => setState(() => _invert = !_invert),
                onClear: () => setState(_ctrl.clear),
              ),
              if (_emojis.isNotEmpty) ...[
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.3,
                  ),
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final e in _emojis)
                          FilterChip(
                            label: Text.rich(TextSpan(children: [
                              TextSpan(
                                  text: e.key,
                                  style: const TextStyle(fontSize: 15)),
                              TextSpan(
                                text: ' ${e.value}',
                                style: TextStyle(
                                    fontSize: 11, color: cs.onSurfaceVariant),
                              ),
                            ])),
                            selected: selected.contains(e.key),
                            showCheckmark: false,
                            onSelected: (_) => _toggleEmoji(e.key),
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              if (valid)
                Text(
                  getLocalText.s("%1\$s / %2\$s match",
                      '${matched.length}', '${widget.pool.length}'),
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              const Divider(height: 12),
              Expanded(
                child: !valid
                    ? const SizedBox.shrink()
                    : ListView(
                        padding: EdgeInsets.zero.withSafeBottom(context),
                        children: [
                          for (final t in matched) _row(cs, t, true),
                          for (final t in rest) _row(cs, t, false),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(ColorScheme cs, String tag, bool hit) {
    final color = hit ? Colors.green.shade600 : cs.onSurfaceVariant.withAlpha(150);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 20,
            child: Text(hit ? '✓' : '✗',
                style: TextStyle(fontSize: 13, color: hit ? color : cs.error)),
          ),
          Expanded(
            child: Text(tag,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: color)),
          ),
        ],
      ),
    );
  }
}
