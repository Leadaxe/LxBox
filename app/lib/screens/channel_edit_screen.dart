import 'package:flutter/material.dart';

import '../models/channel.dart';
import 'home/filter_widgets.dart' show NegateToggle;

/// §125 — полноэкранный редактор канала роутинга. Идиома проекта
/// ([custom_rule_edit_screen.dart], [dns_server_edit_screen.dart]):
/// Navigator.push + PopScope back-guard (Save/Keep/Discard) + AppBar
/// delete/save. tag read-only (системный), label — единственное «имя».
///
/// Live-превью regex: [allNodeTags] — снимок тегов нод подписки (из ccGroups).
/// Пусто (туннель не поднят) → превью показывает «no node snapshot».
class ChannelEditScreen extends StatefulWidget {
  const ChannelEditScreen({
    super.key,
    required this.initial,
    required this.canDelete,
    required this.allNodeTags,
  });

  final Channel initial;

  /// vpn-1 неудаляем → false. Прочие → true.
  final bool canDelete;

  /// Снимок тегов нод подписки для live-превью фильтров.
  final List<String> allNodeTags;

  @override
  State<ChannelEditScreen> createState() => _ChannelEditScreenState();
}

class _ChannelEditScreenState extends State<ChannelEditScreen> {
  late final TextEditingController _labelCtrl;
  late final TextEditingController _nodeFilterCtrl;
  late final TextEditingController _defaultFilterCtrl;
  late final TextEditingController _autoUrlCtrl;
  late final TextEditingController _autoIntervalCtrl;
  late final TextEditingController _autoToleranceCtrl;
  late final TextEditingController _autoIdleCtrl;

  late bool _includeDirect;
  late bool _interrupt;
  late bool _nodeFilterInvert;
  late bool _autoEnabled;
  late bool _autoInterrupt;

  @override
  void initState() {
    super.initState();
    final c = widget.initial;
    _labelCtrl = TextEditingController(text: c.label);
    _nodeFilterCtrl = TextEditingController(text: c.nodeFilter);
    _defaultFilterCtrl = TextEditingController(text: c.defaultFilter);
    _includeDirect = c.includeDirect;
    _interrupt = c.interruptExistConnections;
    _nodeFilterInvert = c.nodeFilterInvert;
    _autoEnabled = c.auto != null;

    final a = c.auto ?? const ChannelAuto();
    _autoUrlCtrl = TextEditingController(text: a.url);
    _autoIntervalCtrl = TextEditingController(text: a.interval);
    _autoToleranceCtrl = TextEditingController(text: a.tolerance.toString());
    _autoIdleCtrl = TextEditingController(text: a.idleTimeout);
    _autoInterrupt = a.interruptExistConnections;

    for (final ctrl in [
      _labelCtrl,
      _nodeFilterCtrl,
      _defaultFilterCtrl,
      _autoUrlCtrl,
      _autoIntervalCtrl,
      _autoToleranceCtrl,
      _autoIdleCtrl,
    ]) {
      ctrl.addListener(_onAnyChange);
    }
  }

  @override
  void dispose() {
    for (final ctrl in [
      _labelCtrl,
      _nodeFilterCtrl,
      _defaultFilterCtrl,
      _autoUrlCtrl,
      _autoIntervalCtrl,
      _autoToleranceCtrl,
      _autoIdleCtrl,
    ]) {
      ctrl.dispose();
    }
    super.dispose();
  }

  void _onAnyChange() => setState(() {}); // live-превью + dirty-индикатор

  /// Собирает редактируемое состояние в [Channel] (tag/enabled immutable —
  /// берутся из initial).
  Channel _snapshot() {
    final c = widget.initial;
    return c.copyWith(
      label: _labelCtrl.text.trim().isEmpty
          ? c.tag
          : _labelCtrl.text.trim(),
      includeDirect: _includeDirect,
      nodeFilter: _nodeFilterCtrl.text.trim(),
      nodeFilterInvert: _nodeFilterInvert,
      defaultFilter: _defaultFilterCtrl.text.trim(),
      interruptExistConnections: _interrupt,
      clearAuto: !_autoEnabled,
      auto: _autoEnabled
          ? ChannelAuto(
              url: _autoUrlCtrl.text.trim(),
              interval: _autoIntervalCtrl.text.trim().isEmpty
                  ? '5m'
                  : _autoIntervalCtrl.text.trim(),
              tolerance: int.tryParse(_autoToleranceCtrl.text.trim()) ?? 50,
              idleTimeout: _autoIdleCtrl.text.trim().isEmpty
                  ? '30m'
                  : _autoIdleCtrl.text.trim(),
              interruptExistConnections: _autoInterrupt,
            )
          : null,
    );
  }

  bool _isDirty() {
    final s = _snapshot();
    final i = widget.initial;
    return s.label != i.label ||
        s.includeDirect != i.includeDirect ||
        s.nodeFilter != i.nodeFilter ||
        s.nodeFilterInvert != i.nodeFilterInvert ||
        s.defaultFilter != i.defaultFilter ||
        s.interruptExistConnections != i.interruptExistConnections ||
        (s.auto == null) != (i.auto == null) ||
        (s.auto != null &&
            i.auto != null &&
            (s.auto!.url != i.auto!.url ||
                s.auto!.interval != i.auto!.interval ||
                s.auto!.tolerance != i.auto!.tolerance ||
                s.auto!.idleTimeout != i.auto!.idleTimeout ||
                s.auto!.interruptExistConnections !=
                    i.auto!.interruptExistConnections));
  }

  Future<void> _handleBack() async {
    if (!_isDirty()) {
      Navigator.pop(context);
      return;
    }
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: const Text('Unsaved changes'),
          content: const Text('You have unsaved changes. Save before leaving?'),
          actionsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'discard'),
              style: TextButton.styleFrom(foregroundColor: cs.error),
              child: const Text('Discard'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'keep'),
              child: const Text('Keep'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'save'),
              style: TextButton.styleFrom(
                foregroundColor: cs.primary,
                textStyle: const TextStyle(fontWeight: FontWeight.w600),
              ),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    if (!mounted) return;
    if (action == 'save') {
      _save();
    } else if (action == 'discard') {
      Navigator.pop(context);
    }
  }

  void _save() {
    Navigator.pop(context, ChannelEditResult.saved(_snapshot()));
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete channel?'),
        content: Text(
            'Remove "${widget.initial.label}" (${widget.initial.tag})? '
            'References to it fall back to vpn-1.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      Navigator.pop(context, ChannelEditResult.deleted());
    }
  }

  // ── live-превью regex ──

  /// Компиляция regex, null при невалидном.
  RegExp? _compile(String pattern) {
    if (pattern.isEmpty) return null;
    try {
      return RegExp(pattern);
    } catch (_) {
      return null;
    }
  }

  bool _isValidRegex(String pattern) {
    if (pattern.isEmpty) return true;
    try {
      RegExp(pattern);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = widget.initial;
    final dirty = _isDirty();

    final nodeFilterText = _nodeFilterCtrl.text.trim();
    final nodeFilterValid = _isValidRegex(nodeFilterText);
    final re = _compile(nodeFilterText);
    // §197 — превью учитывает инверсию (как билдер): invert → ноды НЕ матчащие.
    final matchedNodes = nodeFilterText.isEmpty
        ? widget.allNodeTags
        : (re == null
            ? widget.allNodeTags
            : widget.allNodeTags
                .where((t) => re.hasMatch(t) != _nodeFilterInvert)
                .toList());

    final defaultText = _defaultFilterCtrl.text.trim();
    final defaultValid = _isValidRegex(defaultText);
    final defaultRe = _compile(defaultText);
    final defaultPick = (defaultText.isEmpty || defaultRe == null)
        ? null
        : _firstMatch(matchedNodes, defaultRe);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('Edit channel · ${c.tag}'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _handleBack,
          ),
          actions: [
            if (widget.canDelete)
              IconButton(
                tooltip: 'Delete channel',
                icon: Icon(Icons.delete_outline, color: cs.error),
                onPressed: _delete,
              ),
            IconButton(
              tooltip: 'Save',
              icon: Icon(Icons.check,
                  color: dirty ? cs.primary : cs.onSurfaceVariant),
              onPressed: _save,
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            // системный tag (read-only)
            Text(c.tag,
                style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: cs.onSurfaceVariant)),
            const SizedBox(height: 8),
            TextField(
              controller: _labelCtrl,
              decoration: const InputDecoration(
                labelText: 'Title',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 8),

            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              visualDensity: VisualDensity.compact,
              title: const Text('Include direct-out',
                  style: TextStyle(fontSize: 14)),
              value: _includeDirect,
              onChanged: (v) => setState(() => _includeDirect = v ?? false),
            ),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              visualDensity: VisualDensity.compact,
              title: const Text('Interrupt connections on switch',
                  style: TextStyle(fontSize: 14)),
              value: _interrupt,
              onChanged: (v) => setState(() => _interrupt = v ?? false),
            ),
            const Divider(height: 24),

            // node-filter regex + live-превью. §197 — `!`-тогл слева
            // (NegateToggle, как §048): инвертирует фильтр (ноды НЕ матчащие).
            Text('Node filter (regex)',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: NegateToggle(
                    active: _nodeFilterInvert,
                    onToggle: () => setState(
                        () => _nodeFilterInvert = !_nodeFilterInvert),
                    tooltip: 'Exclude matching (invert)',
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: TextField(
                    controller: _nodeFilterCtrl,
                    decoration: InputDecoration(
                      hintText: 'e.g. 🇩🇪|🇳🇱 — empty = all nodes',
                      border: const OutlineInputBorder(),
                      isDense: true,
                      errorText: nodeFilterValid ? null : 'Invalid regex',
                      errorStyle: const TextStyle(fontSize: 10),
                    ),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            _previewLine(
              cs,
              widget.allNodeTags.isEmpty
                  ? 'No node snapshot (connect to preview)'
                  : '${_nodeFilterInvert ? "excluded → " : ""}matched: '
                      '${matchedNodes.length} / ${widget.allNodeTags.length} nodes',
            ),
            const SizedBox(height: 16),

            // default-filter regex + live-превью
            Text('Default (regex)',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            const SizedBox(height: 4),
            TextField(
              controller: _defaultFilterCtrl,
              decoration: InputDecoration(
                hintText: 'first matching node becomes default',
                border: const OutlineInputBorder(),
                isDense: true,
                errorText: defaultValid ? null : 'Invalid regex',
                errorStyle: const TextStyle(fontSize: 10),
              ),
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 4),
            if (defaultText.isNotEmpty)
              _previewLine(
                cs,
                defaultPick == null
                    ? 'no match → first option used'
                    : '→ "$defaultPick"',
              ),
            const Divider(height: 24),

            // auto-двойник (urltest)
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              visualDensity: VisualDensity.compact,
              title: const Text('Include auto (urltest)',
                  style: TextStyle(fontSize: 14)),
              subtitle: const Text('latency-tested twin of this channel',
                  style: TextStyle(fontSize: 11)),
              value: _autoEnabled,
              onChanged: (v) => setState(() => _autoEnabled = v ?? false),
            ),
            if (_autoEnabled) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _autoUrlCtrl,
                decoration: const InputDecoration(
                  labelText: 'Test URL',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _autoIntervalCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Interval',
                        hintText: '5m',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _autoToleranceCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Tolerance (ms)',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _autoIdleCtrl,
                decoration: const InputDecoration(
                  labelText: 'Idle timeout',
                  hintText: '30m',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                style: const TextStyle(fontSize: 13),
              ),
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                visualDensity: VisualDensity.compact,
                title: const Text('Interrupt connections on switch',
                    style: TextStyle(fontSize: 14)),
                value: _autoInterrupt,
                onChanged: (v) => setState(() => _autoInterrupt = v ?? false),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _previewLine(ColorScheme cs, String text) => Text(
        text,
        style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
      );

  static String? _firstMatch(List<String> tags, RegExp re) {
    for (final t in tags) {
      if (re.hasMatch(t)) return t;
    }
    return null;
  }
}

/// Результат редактора: saved (с обновлённым каналом) или deleted.
class ChannelEditResult {
  const ChannelEditResult._({this.saved, this.wasDeleted = false});
  final Channel? saved;
  final bool wasDeleted;

  factory ChannelEditResult.saved(Channel channel) =>
      ChannelEditResult._(saved: channel);
  factory ChannelEditResult.deleted() =>
      const ChannelEditResult._(wasDeleted: true);
}

/// Открывает редактор канала. Возвращает null если юзер ушёл без изменений.
Future<ChannelEditResult?> openChannelEditor(
  BuildContext context, {
  required Channel initial,
  required bool canDelete,
  required List<String> allNodeTags,
}) =>
    Navigator.push<ChannelEditResult>(
      context,
      MaterialPageRoute(
        builder: (_) => ChannelEditScreen(
          initial: initial,
          canDelete: canDelete,
          allNodeTags: allNodeTags,
        ),
      ),
    );
