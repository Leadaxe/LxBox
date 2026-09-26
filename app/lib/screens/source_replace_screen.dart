/// Фича 565 фаза B (контракт 1.1.78 §74) — редактор свёртки папки или
/// подписки в группу: галочка, режим (Manual / Auto / Both), имя группы и
/// параметры автовыбора — те же поля и умолчания, что у автовыбора
/// Направления (`direction_edit_screen.dart`).
library;

import 'package:flutter/material.dart';

import '../models/direction.dart';
import '../models/server_list.dart';
import '../models/source_replace.dart';
import '../services/tag_resolver.dart';
import '../services/l10n/locale_controller.dart';
import '../widgets/safe_bottom.dart';
import '../widgets/urltest_idle_hint.dart';

/// Итог редактора: `null` у [replace] — свёртка снята.
typedef SourceReplaceResult = ({SourceReplace? replace});

/// §568 / задача 570 — кто уже носит имя, которое вводят группе свёртки.
enum ReplaceTagOwner { node, fold, direction }

/// §568 / задача 570 — занятые имена для предупреждения редактора свёртки:
/// теги узлов других источников (с их префиксом), имена других свёрток и
/// теги Направлений. Свой источник [selfId] не считается: его узлы свёртка
/// и заменяет. При совпадении побеждает первый вид в порядке Направление →
/// свёртка → узел.
Map<String, ReplaceTagOwner> replaceTagOwnersOf({
  required Iterable<ServerList> sources,
  required String selfId,
  List<Direction> directions = const [],
}) {
  final out = <String, ReplaceTagOwner>{};
  for (final l in sources) {
    if (l.id == selfId) continue;
    for (final n in l.nodes) {
      out[TagResolver.displayTag(l.tagPrefix, n.tag)] = ReplaceTagOwner.node;
    }
  }
  for (final l in sources) {
    final r = l.replace;
    if (l.id == selfId || r == null || r.tag.trim().isEmpty) continue;
    out[r.tag] = ReplaceTagOwner.fold;
  }
  for (final d in directions) {
    out[d.tag] = ReplaceTagOwner.direction;
  }
  return out;
}

/// Открывает редактор. `null` — ушли без сохранения.
Future<SourceReplaceResult?> openSourceReplaceEditor(
  BuildContext context, {
  required SourceReplace? initial,
  required String defaultTag,
  Map<String, ReplaceTagOwner> takenTags = const {},
}) =>
    Navigator.push<SourceReplaceResult>(
      context,
      MaterialPageRoute(
        builder: (_) => SourceReplaceScreen(
            initial: initial, defaultTag: defaultTag, takenTags: takenTags),
      ),
    );

class SourceReplaceScreen extends StatefulWidget {
  const SourceReplaceScreen({
    super.key,
    required this.initial,
    required this.defaultTag,
    this.takenTags = const {},
  });

  final SourceReplace? initial;

  /// §568 / задача 570 — занятые имена ([replaceTagOwnersOf]): редактор
  /// предупреждает, но сохранять не мешает.
  final Map<String, ReplaceTagOwner> takenTags;

  /// Имя группы по умолчанию — имя источника.
  final String defaultTag;

  @override
  State<SourceReplaceScreen> createState() => _SourceReplaceScreenState();
}

class _SourceReplaceScreenState extends State<SourceReplaceScreen> {
  late bool _on;
  late ReplaceMode _mode;
  late final TextEditingController _tagCtrl;
  late final TextEditingController _urlCtrl;
  late final TextEditingController _intervalCtrl;
  late final TextEditingController _toleranceCtrl;
  late final TextEditingController _idleCtrl;
  late final TextEditingController _poolCtrl;
  late final TextEditingController _poolToleranceCtrl;
  late UrltestMode _autoMode;
  late bool _interrupt;
  late Set<StickyHashKey> _sticky;

  @override
  void initState() {
    super.initState();
    final r = widget.initial;
    _on = r != null;
    _mode = r?.mode ?? ReplaceMode.both;
    _tagCtrl = TextEditingController(
        text: r == null || r.tag.isEmpty ? widget.defaultTag : r.tag);
    final a = r?.auto ?? const DirectionAuto();
    _urlCtrl = TextEditingController(text: a.url);
    _intervalCtrl = TextEditingController(text: a.interval);
    _toleranceCtrl = TextEditingController(text: '${a.tolerance}');
    _idleCtrl = TextEditingController(text: a.idleTimeout);
    _poolCtrl = TextEditingController(text: '${a.pool}');
    _poolToleranceCtrl = TextEditingController(text: '${a.poolTolerance}');
    _autoMode = a.mode;
    _interrupt = a.interruptExistConnections;
    _sticky = a.stickyHash.toSet();
    for (final c in _ctrls) {
      c.addListener(_changed);
    }
  }

  List<TextEditingController> get _ctrls => [
        _tagCtrl,
        _urlCtrl,
        _intervalCtrl,
        _toleranceCtrl,
        _idleCtrl,
        _poolCtrl,
        _poolToleranceCtrl,
      ];

  void _changed() => setState(() {});

  @override
  void dispose() {
    for (final c in _ctrls) {
      c.dispose();
    }
    super.dispose();
  }

  String _orDefault(TextEditingController c, String fallback) {
    final v = c.text.trim();
    return v.isEmpty ? fallback : v;
  }

  /// §568 / задача 570 — предупреждение о занятом имени (не запрет):
  /// узел-тёзка получит суффикс, две свёртки с одним именем дадут две
  /// группы с одним тегом, Направление-тёзка спорит с группой за ссылки.
  String? _tagClash() {
    final tag = _orDefault(_tagCtrl, widget.defaultTag.trim());
    return switch (widget.takenTags[tag]) {
      ReplaceTagOwner.node => getLocalText.s(
          "A server already has this name — it will get a numeric suffix."),
      ReplaceTagOwner.fold =>
        getLocalText.s("Another replace group already has this name."),
      ReplaceTagOwner.direction =>
        getLocalText.s("A direction already has this name."),
      null => null,
    };
  }

  SourceReplace? _snapshot() {
    if (!_on) return null;
    final tag = _orDefault(_tagCtrl, widget.defaultTag.trim());
    if (_mode == ReplaceMode.manual) {
      return SourceReplace(mode: _mode, tag: tag);
    }
    return SourceReplace(
      mode: _mode,
      tag: tag,
      auto: DirectionAuto(
        url: _orDefault(_urlCtrl, const DirectionAuto().url),
        interval: _orDefault(_intervalCtrl, '15m'),
        tolerance: clampDirectionTolerance(
            int.tryParse(_toleranceCtrl.text.trim()) ?? 50),
        idleTimeout: _orDefault(_idleCtrl, '30m'),
        interruptExistConnections: _interrupt,
        mode: _autoMode,
        pool: clampDirectionPool(int.tryParse(_poolCtrl.text.trim()) ?? 3),
        poolTolerance: clampDirectionTolerance(
            int.tryParse(_poolToleranceCtrl.text.trim()) ?? 0),
        stickyHash: StickyHashKey.values.where(_sticky.contains).toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final snap = _snapshot();
    final dirty = snap != widget.initial;
    return Scaffold(
      appBar: AppBar(
        title: Text(getLocalText.s("Replace with a group")),
        actions: [
          IconButton(
            key: const ValueKey('source-replace-save'),
            tooltip: getLocalText.s("Save"),
            icon: const Icon(Icons.check),
            onPressed: dirty
                ? () => Navigator.pop<SourceReplaceResult>(
                    context, (replace: snap))
                : null,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16).withSafeBottom(context),
        children: [
          SwitchListTile(
            key: const ValueKey('source-replace-toggle'),
            contentPadding: EdgeInsets.zero,
            title: Text(getLocalText.s("Replace with a group")),
            subtitle: Text(getLocalText.s(
                "Directions and rules see one group instead of every server")),
            value: _on,
            onChanged: (v) => setState(() => _on = v),
          ),
          if (_on) ...[
            const SizedBox(height: 8),
            TextField(
              controller: _tagCtrl,
              decoration: InputDecoration(
                labelText: getLocalText.s("Group name"),
                hintText: widget.defaultTag,
                border: const OutlineInputBorder(),
                isDense: true,
                helperText: _tagClash(),
                helperMaxLines: 3,
                helperStyle: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
            const SizedBox(height: 12),
            SegmentedButton<ReplaceMode>(
              segments: [
                ButtonSegment(
                    value: ReplaceMode.manual,
                    label: Text(getLocalText.s("Manual"))),
                ButtonSegment(
                    value: ReplaceMode.auto,
                    label: Text(getLocalText.s("Auto"))),
                ButtonSegment(
                    value: ReplaceMode.both,
                    label: Text(getLocalText.s("Both"))),
              ],
              selected: {_mode},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
            const SizedBox(height: 4),
            Text(
              switch (_mode) {
                ReplaceMode.manual =>
                  getLocalText.s("You pick the server in the group"),
                ReplaceMode.auto =>
                  getLocalText.s("The group picks a server by latency"),
                ReplaceMode.both => getLocalText.s(
                    "You pick the server; the first option picks by latency"),
              },
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
            if (_mode != ReplaceMode.manual) ..._autoFields(cs),
          ],
        ],
      ),
    );
  }

  List<Widget> _autoFields(ColorScheme cs) {
    InputDecoration deco(String label, {String? hint, String? helper}) =>
        InputDecoration(
          labelText: label,
          hintText: hint,
          helperText: helper,
          border: const OutlineInputBorder(),
          isDense: true,
        );
    final interval = _orDefault(_intervalCtrl, '15m');
    final idle = _orDefault(_idleCtrl, '30m');
    return [
      const SizedBox(height: 16),
      TextField(controller: _urlCtrl, decoration: deco(getLocalText.s("Test URL"))),
      const SizedBox(height: 8),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              controller: _intervalCtrl,
              // l10n-exempt: duration literal, locale-independent
              decoration: deco(getLocalText.s("Interval"),
                  hint: '15m',
                  helper: getLocalText.s("Larger values save battery")),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _toleranceCtrl,
              keyboardType: TextInputType.number,
              enabled: _autoMode == UrltestMode.leastTest,
              decoration: deco(getLocalText.s("Tolerance (ms)")),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _idleCtrl,
        // l10n-exempt: duration literal, locale-independent
        decoration: deco(getLocalText.s("Idle timeout"), hint: '30m'),
      ),
      if (urltestIdleRaiseTarget(interval, idle) case final target?) ...[
        const SizedBox(height: 4),
        UrltestIdleRaiseHint(target: target),
      ],
      const SizedBox(height: 12),
      Text(getLocalText.s("Mode"),
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
      const SizedBox(height: 6),
      SegmentedButton<UrltestMode>(
        segments: [
          ButtonSegment(
              value: UrltestMode.leastTest,
              label: Text(getLocalText.s("Fastest")),
              icon: const Icon(Icons.bolt, size: 16)),
          ButtonSegment(
              value: UrltestMode.roundRobin,
              label: Text(getLocalText.s("Load balance")),
              icon: const Icon(Icons.hub_outlined, size: 16)),
        ],
        selected: {_autoMode},
        showSelectedIcon: false,
        onSelectionChanged: (s) => setState(() => _autoMode = s.first),
      ),
      if (_autoMode == UrltestMode.roundRobin) ...[
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _poolCtrl,
                keyboardType: TextInputType.number,
                decoration: deco(getLocalText.s("Pool size")),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _poolToleranceCtrl,
                keyboardType: TextInputType.number,
                decoration: deco(getLocalText.s("Pool tolerance (ms)"),
                    helper: getLocalText.s("0 = keep pool full")),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(getLocalText.s("Sticky session by"),
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          children: [
            for (final k in StickyHashKey.values)
              FilterChip(
                // l10n-exempt: core key names
                label: Text(k.wire.replaceAll('_', ' '),
                    style: const TextStyle(fontSize: 12)),
                selected: _sticky.contains(k),
                onSelected: (sel) => setState(
                    () => sel ? _sticky.add(k) : _sticky.remove(k)),
              ),
          ],
        ),
      ],
      CheckboxListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(getLocalText.s("Interrupt connections on switch"),
            style: const TextStyle(fontSize: 14)),
        value: _interrupt,
        onChanged: (v) => setState(() => _interrupt = v ?? false),
      ),
    ];
  }
}
