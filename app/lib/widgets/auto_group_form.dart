import 'package:flutter/material.dart';

import '../models/auto_select.dart';
import '../models/direction.dart';
import '../models/node_link.dart';
import '../models/node_spec.dart';
import '../models/server_list.dart';
import '../services/contract/group_genus.dart';
import '../services/l10n/locale_controller.dart';
import '../services/node_identity.dart';
import '../services/parser/uri_utils.dart';
import '../services/safe_regex.dart';
import 'urltest_idle_hint.dart';

/// §322/§686 — кандидат в пул узла автовыбора: ссылка на члена папки
/// `{id папки, сырой тег}` (§439), имя и флаг «член включён в папке».
/// Выключенного сборка в группу не берёт; превью показывает его отдельно (⏻).
class AutoPoolCandidate {
  const AutoPoolCandidate({
    required this.key,
    required this.label,
    this.enabled = true,
  });

  final NodeLink key;
  final String label;
  final bool enabled;
}

/// Члены папки, которые могут попасть в пул: обычные узлы с адресом, без
/// групп (вложенность urltest в urltest бессмысленна) и без нечитаемых raw.
/// §686 — выключенные члены остаются кандидатами с `enabled: false`.
List<AutoPoolCandidate> autoPoolCandidates(FolderServers folder) {
  final out = <AutoPoolCandidate>[];
  for (final m in folder.members) {
    final n = m.node;
    if (n == null || n.isGroup || n.tag.isEmpty) continue;
    if (nodeIdentityKey(n) == null) continue;
    out.add(AutoPoolCandidate(
      key: NodeLink(folderId: folder.id, tag: n.tag),
      label: n.label.isEmpty ? n.tag : n.label,
      enabled: m.enabled,
    ));
  }
  return out;
}

enum _MembershipMode { all, rule, explicit }

/// §565 — выбор режима группы: три вида автовыбора (§612 — удержание до
/// отказа) и ручной род.
enum _Kind { fastest, balance, hold, manual }

/// §686 — форма узла автовыбора: Name, Servers in the pool (All / Rule / Pick)
/// с превью состава, Mode, Selected server, Sticky session, Advanced. Одна на
/// два экрана: создание (`AutoGroupEditScreen`) и Settings карточки узла
/// (`NodeSettingsScreen`, где форма правит текст Source).
///
/// [value] — группа, которую форма показывает. Новое значение, отличное от
/// того, что форма собрала бы сама ([AutoGroupFormState.snapshot]),
/// перезаливает поля: так правка Source руками доходит до формы. [onChanged]
/// получает группу после каждой правки поля.
class AutoGroupForm extends StatefulWidget {
  const AutoGroupForm({
    super.key,
    required this.value,
    required this.candidates,
    this.onChanged,
    this.enabled = true,
  });

  /// `null` — создание нового узла.
  final AutoSelectSpec? value;

  /// Кандидаты в пул — узлы того же контейнера (без самой группы).
  final List<AutoPoolCandidate> candidates;

  final ValueChanged<AutoSelectSpec>? onChanged;

  /// false — форма видна, но не правится (Source не разбирается).
  final bool enabled;

  @override
  State<AutoGroupForm> createState() => AutoGroupFormState();
}

class AutoGroupFormState extends State<AutoGroupForm> {
  final _labelCtrl = TextEditingController();
  final _includeCtrl = TextEditingController();
  final _excludeCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  final _intervalCtrl = TextEditingController();
  final _toleranceCtrl = TextEditingController();
  final _idleCtrl = TextEditingController();
  final _poolCtrl = TextEditingController();
  final _poolToleranceCtrl = TextEditingController();
  final _badgeCtrl = TextEditingController(); // §322 — UI-only значки

  _MembershipMode _mode = _MembershipMode.all;
  Set<NodeLink> _picked = {}; // ссылки для режима «список»
  UrltestMode _urlMode = kNewAutoMode;
  Set<StickyHashKey> _sticky = {};
  bool _interrupt = false; // §208 — рвать соединения при смене узла
  bool _manual = false; // §565 — род selector: член выбирается вручную
  String _default = ''; // §565 — сырой тег выбранного члена
  bool _advanced = false;

  /// Перезаливка полей из [AutoGroupForm.value]: слушатели полей молчат.
  bool _loading = false;

  /// `id` новой группы — один на всё время жизни формы.
  late final String _newId = newUuidV4();

  List<TextEditingController> get _ctrls => [
        _labelCtrl, _includeCtrl, _excludeCtrl, _urlCtrl, _intervalCtrl,
        _toleranceCtrl, _idleCtrl, _poolCtrl, _poolToleranceCtrl, _badgeCtrl,
      ];

  @override
  void initState() {
    super.initState();
    _loadFrom(widget.value);
    for (final c in _ctrls) {
      c.addListener(_onField);
    }
  }

  @override
  void didUpdateWidget(AutoGroupForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    final v = widget.value;
    if (v != null &&
        !identical(v, oldWidget.value) &&
        !_sameStored(snapshot(), v)) {
      _loadFrom(v);
    }
  }

  /// Значения равны в хранимой форме. У ручного рода параметров замера в
  /// записи нет: поля формы держат их до обратного переключения режима.
  static bool _sameStored(AutoSelectSpec a, AutoSelectSpec b) =>
      a.sameGroupAs(b) ||
      (a.isManual && b.isManual && a.copyWith(params: b.params).sameGroupAs(b));

  @override
  void dispose() {
    for (final c in _ctrls) {
      c.dispose();
    }
    super.dispose();
  }

  void _loadFrom(AutoSelectSpec? s) {
    _loading = true;
    final m = s?.membership ?? const RuleMembers();
    final p = s?.params ?? const AutoSelectParams();
    _labelCtrl.text = s?.label ?? '';
    _includeCtrl.text = m is RuleMembers ? m.include : '';
    _excludeCtrl.text = m is RuleMembers ? m.exclude : '';
    _urlCtrl.text = p.url;
    _intervalCtrl.text = p.interval;
    _toleranceCtrl.text = '${p.tolerance}';
    _idleCtrl.text = p.idleTimeout;
    _poolCtrl.text = '${p.pool}';
    _poolToleranceCtrl.text = '${p.poolTolerance}';
    _badgeCtrl.text = s?.poolBadge ?? kDefaultPoolBadge;
    _mode = switch (m) {
      ExplicitMembers() => _MembershipMode.explicit,
      RuleMembers(:final include, :final exclude)
          when include.isEmpty && exclude.isEmpty =>
        _MembershipMode.all,
      RuleMembers() => _MembershipMode.rule,
    };
    _picked = m is ExplicitMembers ? m.members.toSet() : <NodeLink>{};
    // §612 — новая группа предлагается в режиме failover.
    _urlMode = s == null ? kNewAutoMode : p.mode;
    _sticky = p.stickyHash.toSet();
    _interrupt = p.interruptExistConnections;
    _manual = s?.isManual ?? false;
    _default = s?.manualDefault ?? '';
    _loading = false;
  }

  void _onField() {
    if (_loading) return;
    _changed();
  }

  /// Правка формы: перерисовка и группа наружу.
  void _changed() {
    if (!mounted) return;
    setState(() {});
    widget.onChanged?.call(snapshot());
  }

  void _update(VoidCallback fn) {
    fn();
    _changed();
  }

  // ── Сборка результата ──

  AutoSelectMembership _membership() => switch (_mode) {
        _MembershipMode.all => const RuleMembers(),
        _MembershipMode.rule => RuleMembers(
            include: _includeCtrl.text.trim(),
            exclude: _excludeCtrl.text.trim(),
          ),
        // Порядок — как в списке папки, а не как кликали чекбоксы. §686 —
        // выбранный выключенный член хранится: заработает, когда включат.
        _MembershipMode.explicit => ExplicitMembers([
            for (final c in widget.candidates)
              if (_picked.contains(c.key)) c.key,
          ]),
      };

  /// Группа такой, какой её собрали поля формы.
  AutoSelectSpec snapshot() {
    final initial = widget.value;
    final label = _labelCtrl.text.trim().isEmpty
        ? getLocalText.s("Auto")
        : _labelCtrl.text.trim();
    const d = AutoSelectParams();
    return AutoSelectSpec(
      id: initial?.id ?? _newId,
      tag: tagFromLabel(label, 'urltest', 'auto', 0),
      label: label,
      membership: _membership(),
      params: AutoSelectParams(
        url: _urlCtrl.text.trim().isEmpty ? d.url : _urlCtrl.text.trim(),
        interval: _intervalValue,
        tolerance: int.tryParse(_toleranceCtrl.text.trim()) ?? d.tolerance,
        idleTimeout: _idleValue,
        mode: _urlMode,
        pool: int.tryParse(_poolCtrl.text.trim()) ?? d.pool,
        poolTolerance: clampPoolTolerance(
            int.tryParse(_poolToleranceCtrl.text.trim()) ?? d.poolTolerance),
        stickyHash: [
          for (final k in StickyHashKey.values)
            if (_sticky.contains(k)) k,
        ],
        interruptExistConnections: _interrupt,
      ),
      // Синонимы — производное от подписки; у папочной группы их нет, у
      // приехавшей из подписки сохраняем как есть (правка их не меняет).
      tagSynonyms: initial?.tagSynonyms ?? const {},
      poolBadge: _badgeCtrl.text.trim(),
      // §565 — род и выбранный член. У автовыбора `default` доживает
      // сквозным, как пришёл (контракт 1.1.50).
      genus: _manual ? GroupGenus.manual : GroupGenus.auto,
      manualDefault: _default,
    );
  }

  /// Interval и idle timeout ровно такими, какими они уйдут в хранение:
  /// пустое поле — умолчание [AutoSelectParams].
  String get _intervalValue {
    final v = _intervalCtrl.text.trim();
    return v.isEmpty ? const AutoSelectParams().interval : v;
  }

  String get _idleValue {
    final v = _idleCtrl.text.trim();
    return v.isEmpty ? const AutoSelectParams().idleTimeout : v;
  }

  // ── Превью состава ──

  /// Кандидат попадает в пул по настройке режима — без учёта выключения.
  /// Повторяет логику `resolveAutoSelectMembers`, но по именам: синонимов у
  /// папочной группы нет, а у приехавшей из подписки превью всё равно
  /// показывает имена.
  bool Function(AutoPoolCandidate) _accepts() {
    switch (_mode) {
      case _MembershipMode.all:
        return (_) => true;
      case _MembershipMode.explicit:
        return (c) => _picked.contains(c.key);
      case _MembershipMode.rule:
        final inc = tryCompileRegex(_includeCtrl.text.trim());
        final exc = tryCompileRegex(_excludeCtrl.text.trim());
        return (c) => ruleAccepts([c.label], inc, exc);
    }
  }

  /// Кандидаты, попавшие в пул при текущих настройках. §686 — выключенный
  /// член сборкой отбрасывается, в пул не входит.
  List<AutoPoolCandidate> _matched() {
    final accepts = _accepts();
    return [
      for (final c in widget.candidates)
        if (c.enabled && accepts(c)) c
    ];
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final matched = _matched();
    final enabledCount = widget.candidates.where((c) => c.enabled).length;
    final offCount = widget.candidates.length - enabledCount;
    final includeText = _includeCtrl.text.trim();
    final excludeText = _excludeCtrl.text.trim();
    final includeValid =
        includeText.isEmpty || tryCompileRegex(includeText) != null;
    final excludeValid =
        excludeText.isEmpty || tryCompileRegex(excludeText) != null;
    final count = getLocalText.s(
        "%s of %s servers", '${matched.length}', '$enabledCount');

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _labelCtrl,
          decoration: InputDecoration(
            labelText: getLocalText.s("Name"),
            hintText: getLocalText.s("Auto"),
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          style: const TextStyle(fontSize: 14),
        ),
        const Divider(height: 28),

        // ── Членство ──
        Text(getLocalText.s("Servers in the pool"),
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        const SizedBox(height: 6),
        SegmentedButton<_MembershipMode>(
          segments: [
            ButtonSegment(
              value: _MembershipMode.all,
              label: Text(getLocalText.s("All")),
              icon: const Icon(Icons.select_all, size: 16),
            ),
            ButtonSegment(
              value: _MembershipMode.rule,
              label: Text(getLocalText.s("Rule")),
              icon: const Icon(Icons.filter_alt_outlined, size: 16),
            ),
            ButtonSegment(
              value: _MembershipMode.explicit,
              label: Text(getLocalText.s("Pick")),
              icon: const Icon(Icons.checklist, size: 16),
            ),
          ],
          selected: {_mode},
          showSelectedIcon: false,
          style: const ButtonStyle(
            visualDensity: VisualDensity.compact,
            textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
          ),
          onSelectionChanged: (s) => _update(() {
            final next = s.first;
            // Переключение «правило → список» разворачивает текущий
            // результат в галочки: пользователь видит то же самое и может
            // подправить руками, а не начинает с нуля. §686 — выключенные
            // члены, которых принимает правило, отмечаются тоже.
            if (next == _MembershipMode.explicit &&
                _mode != _MembershipMode.explicit) {
              final accepts = _accepts();
              _picked = {
                for (final c in widget.candidates)
                  if (accepts(c)) c.key,
              };
            }
            _mode = next;
          }),
        ),
        const SizedBox(height: 10),

        if (_mode == _MembershipMode.rule) ...[
          TextField(
            controller: _includeCtrl,
            decoration: InputDecoration(
              labelText: getLocalText.s("Include (regex)"),
              hintText: getLocalText.s("empty = all servers"),
              border: const OutlineInputBorder(),
              isDense: true,
              errorText: includeValid ? null : 'Invalid regex',
              errorStyle: const TextStyle(fontSize: 10),
            ),
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _excludeCtrl,
            decoration: InputDecoration(
              labelText: getLocalText.s("Exclude (regex)"),
              hintText: getLocalText.s("applied after include"),
              border: const OutlineInputBorder(),
              isDense: true,
              errorText: excludeValid ? null : 'Invalid regex',
              errorStyle: const TextStyle(fontSize: 10),
            ),
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 8),
        ],

        // Превью состава — общее для всех режимов. §686 — выключенные члены
        // в счёт не входят, их число — хвостом «· K off».
        _previewLine(
          cs,
          offCount > 0
              ? '$count ${getLocalText.s("· %s off", '$offCount')}'
              : count,
          key: const ValueKey('auto-group-count'),
        ),
        // §675 — пустой состав сборка не эмитит: узел остаётся в папке,
        // но в конфиг не идёт. Пустую папку называет _memberList.
        if (matched.isEmpty && widget.candidates.isNotEmpty)
          _previewLine(
            cs,
            getLocalText.s(
                "No servers match, the auto node stays out of the config until one does"),
          ),
        const SizedBox(height: 6),
        _memberList(cs, matched),

        const Divider(height: 28),

        // ── Режим выбора ──
        Text(getLocalText.s("Mode"),
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        const SizedBox(height: 6),
        SegmentedButton<_Kind>(
          segments: [
            ButtonSegment(
              value: _Kind.fastest,
              label: Text(getLocalText.s("Fastest")),
              icon: const Icon(Icons.bolt, size: 16),
            ),
            ButtonSegment(
              value: _Kind.balance,
              label: Text(getLocalText.s("Load balance")),
              icon: const Icon(Icons.hub_outlined, size: 16),
            ),
            // §612 (контракт 1.1.111) — удержание узла до отказа.
            ButtonSegment(
              value: _Kind.hold,
              label: Text(getLocalText.s("Hold until failure")),
              icon: const Icon(Icons.push_pin_outlined, size: 16),
            ),
            ButtonSegment(
              value: _Kind.manual,
              label: Text(getLocalText.s("Manual")),
              icon: const Icon(Icons.touch_app_outlined, size: 16),
            ),
          ],
          selected: {_kind},
          showSelectedIcon: false,
          style: const ButtonStyle(
            visualDensity: VisualDensity.compact,
            textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
          ),
          onSelectionChanged: (s) => _update(() {
            switch (s.first) {
              case _Kind.manual:
                _manual = true;
              case _Kind.fastest:
                _manual = false;
                _urlMode = UrltestMode.leastTest;
              case _Kind.balance:
                _manual = false;
                _urlMode = UrltestMode.roundRobin;
              case _Kind.hold:
                _manual = false;
                _urlMode = UrltestMode.failover;
            }
          }),
        ),
        const SizedBox(height: 4),
        _previewLine(
          cs,
          switch (_kind) {
            _Kind.fastest => getLocalText.s("single best server by latency"),
            _Kind.balance =>
              getLocalText.s("spread connections across a pool of servers"),
            _Kind.hold =>
              getLocalText.s("keep the fastest server until it fails"),
            _Kind.manual =>
              getLocalText.s("you pick the server, no latency tests"),
          },
        ),

        if (_kind == _Kind.balance) ..._balancerControls(cs, enabledCount),
        if (_kind == _Kind.manual) ..._manualControls(cs, matched),

        const Divider(height: 28),

        // ── Advanced ──
        InkWell(
          onTap: () => setState(() => _advanced = !_advanced),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Icon(
                  _advanced ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: cs.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(getLocalText.s("Advanced"),
                    style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
              ],
            ),
          ),
        ),
        if (_advanced) ..._advancedControls(cs),
      ],
    );
    if (widget.enabled) return body;
    // Source не разбирается: форма видна прежней, но не правится.
    return IgnorePointer(
        key: const ValueKey('auto-group-form-off'),
        child: Opacity(opacity: .5, child: body));
  }

  _Kind get _kind => _manual
      ? _Kind.manual
      : switch (_urlMode) {
          UrltestMode.roundRobin => _Kind.balance,
          UrltestMode.failover => _Kind.hold,
          UrltestMode.leastTest => _Kind.fastest,
        };

  /// §565 — род selector: выбранный член пула. Отметка — текущий `default`;
  /// без него (или если член выпал из пула) ядро берёт первого.
  List<Widget> _manualControls(
      ColorScheme cs, List<AutoPoolCandidate> matched) {
    if (matched.isEmpty) return const [];
    final current = matched.any((c) => c.key.tag == _default)
        ? _default
        : matched.first.key.tag;
    return [
      const SizedBox(height: 10),
      Text(getLocalText.s("Selected server"),
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
      const SizedBox(height: 4),
      RadioGroup<String>(
        groupValue: current,
        onChanged: (v) => _update(() => _default = v ?? ''),
        child: Column(
          children: [
            for (final c in matched)
              RadioListTile<String>(
                key: ValueKey('auto-group-default-${c.key.tag}'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                value: c.key.tag,
                title: Text(c.label,
                    style: const TextStyle(fontSize: 13),
                    overflow: TextOverflow.ellipsis),
              ),
          ],
        ),
      ),
    ];
  }

  Widget _previewLine(ColorScheme cs, String text, {Key? key}) => Text(
        text,
        key: key,
        style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
      );

  /// Список кандидатов. В режиме «список» — с чекбоксами; иначе только
  /// показывает, кто попал (галочка) и кто нет (приглушённый). §686 —
  /// выключенный член приглушён и несёт ⏻: в All/Rule на месте ✓/⊖, в Pick
  /// справа от имени (его можно отметить).
  Widget _memberList(ColorScheme cs, List<AutoPoolCandidate> matched) {
    if (widget.candidates.isEmpty) {
      return _previewLine(cs, getLocalText.s("Folder has no servers yet"));
    }
    final hit = matched.map((c) => c.key).toSet();
    final dim = cs.onSurfaceVariant.withValues(alpha: .5);
    Widget offIcon(AutoPoolCandidate c) => Icon(
          Icons.power_settings_new,
          key: ValueKey('auto-group-off-${c.key.tag}'),
          size: 18,
          color: dim,
        );
    return Container(
      constraints: const BoxConstraints(maxHeight: 240),
      decoration: BoxDecoration(
        border: Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: widget.candidates.length,
        itemBuilder: (_, i) {
          final c = widget.candidates[i];
          final inPool = hit.contains(c.key);
          final title = Text(
            c.label,
            style: TextStyle(
              fontSize: 13,
              color: inPool || (_mode == _MembershipMode.explicit && c.enabled)
                  ? null
                  : dim,
            ),
            overflow: TextOverflow.ellipsis,
          );
          if (_mode == _MembershipMode.explicit) {
            return CheckboxListTile(
              key: ValueKey('auto-group-member-${c.key.tag}'),
              dense: true,
              visualDensity: VisualDensity.compact,
              controlAffinity: ListTileControlAffinity.leading,
              title: title,
              secondary: c.enabled ? null : offIcon(c),
              value: _picked.contains(c.key),
              onChanged: (v) => _update(() {
                if (v ?? false) {
                  _picked.add(c.key);
                } else {
                  _picked.remove(c.key);
                }
              }),
            );
          }
          return ListTile(
            key: ValueKey('auto-group-member-${c.key.tag}'),
            dense: true,
            visualDensity: VisualDensity.compact,
            leading: !c.enabled
                ? offIcon(c)
                : Icon(
                    inPool
                        ? Icons.check_circle_outline
                        : Icons.remove_circle_outline,
                    size: 18,
                    color: inPool ? cs.primary : dim,
                  ),
            title: title,
          );
        },
      ),
    );
  }

  /// §208 — pool size / tolerance + sticky-чипы. Только под Load balance.
  List<Widget> _balancerControls(ColorScheme cs, int n) {
    return [
      const SizedBox(height: 10),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _poolCtrl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: getLocalText.s("Pool size"),
                border: const OutlineInputBorder(),
                isDense: true,
                helperText:
                    n > 0 ? getLocalText.plural("of %d nodes", n) : null,
                helperStyle: const TextStyle(fontSize: 10),
              ),
              style: const TextStyle(fontSize: 13),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _poolToleranceCtrl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: getLocalText.s("Pool tolerance (ms)"),
                border: const OutlineInputBorder(),
                isDense: true,
                helperText: getLocalText.s("0 = keep pool full"),
                helperStyle: const TextStyle(fontSize: 10),
              ),
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
      Text(getLocalText.s("Sticky session by"),
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
      const SizedBox(height: 4),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final k in StickyHashKey.values)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: FilterChip(
                  label: Text(_stickyLabel(k),
                      style: const TextStyle(fontSize: 12)),
                  selected: _sticky.contains(k),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onSelected: (sel) => _update(() {
                    if (sel) {
                      _sticky.add(k);
                    } else {
                      _sticky.remove(k);
                    }
                  }),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 4),
      _previewLine(
        cs,
        _sticky.isEmpty
            ? getLocalText.s("no stickiness — every connection re-picks")
            : getLocalText.s("connections with the same key keep one server"),
      ),
    ];
  }

  List<Widget> _advancedControls(ColorScheme cs) => [
        // §565 — у ручного рода замеров нет: их поля не показываем.
        if (!_manual) ..._probeControls(),
        const SizedBox(height: 4),
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          visualDensity: VisualDensity.compact,
          title: Text(getLocalText.s("Interrupt connections on switch"),
              style: const TextStyle(fontSize: 14)),
          subtitle: Text(
              getLocalText.s(
                  "off: open connections finish on the old server"),
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
          value: _interrupt,
          onChanged: (v) => _update(() => _interrupt = v ?? false),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _badgeCtrl,
          decoration: InputDecoration(
            labelText: getLocalText.s("Badge in list (regex)"),
            border: const OutlineInputBorder(),
            isDense: true,
            helperText: getLocalText.s(
                "taken from member names; empty = no badges. Display only — not sent to the core"),
            helperMaxLines: 3,
            helperStyle: const TextStyle(fontSize: 10),
          ),
          style: const TextStyle(fontSize: 13),
        ),
        // §612 — у failover tolerance не действует и не эмитится: поле скрыто.
        if (!_manual && _urlMode != UrltestMode.failover) ...[
          const SizedBox(height: 10),
          TextField(
            controller: _toleranceCtrl,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: getLocalText.s("Switch tolerance (ms)"),
              border: const OutlineInputBorder(),
              isDense: true,
              helperText:
                  getLocalText.s("how much faster a rival must be to win"),
              helperStyle: const TextStyle(fontSize: 10),
            ),
            style: const TextStyle(fontSize: 13),
          ),
        ],
      ];

  /// Параметры замера автовыбора: адрес, период, простой.
  List<Widget> _probeControls() => [
        const SizedBox(height: 8),
        TextField(
          controller: _urlCtrl,
          decoration: InputDecoration(
            labelText: getLocalText.s("Test URL"),
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          style: const TextStyle(fontSize: 13),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _intervalCtrl,
                decoration: InputDecoration(
                  labelText: getLocalText.s("Interval"),
                  border: const OutlineInputBorder(),
                  isDense: true,
                  helperText: getLocalText.s("e.g. 15m"),
                  helperStyle: const TextStyle(fontSize: 10),
                ),
                style: const TextStyle(fontSize: 13),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _idleCtrl,
                decoration: InputDecoration(
                  labelText: getLocalText.s("Idle timeout"),
                  border: const OutlineInputBorder(),
                  isDense: true,
                  helperText: getLocalText.s("e.g. 30m"),
                  helperStyle: const TextStyle(fontSize: 10),
                ),
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
        // §442 — interval > idle_timeout: сохранить можно, санитайзер сборки
        // поднимет idle_timeout до interval. Условие — по значениям, которые
        // уйдут в хранение (пустое поле — умолчание AutoSelectParams).
        if (urltestIdleRaiseTarget(_intervalValue, _idleValue)
            case final target?) ...[
          const SizedBox(height: 4),
          UrltestIdleRaiseHint(
            key: const ValueKey('auto-group-idle-raise-hint'),
            target: target,
          ),
        ],
      ];

  // Названия ключей — как в §208-редакторе Направления: технические термины
  // config'а, не переводим (l10n-exempt по тому же основанию).
  String _stickyLabel(StickyHashKey k) => switch (k) {
        StickyHashKey.process => 'process',
        StickyHashKey.domain => 'domain',
        StickyHashKey.sourceIp => 'source ip',
        StickyHashKey.destIp => 'dest ip',
        StickyHashKey.destPort => 'dest port',
      };
}
