import 'package:flutter/material.dart';

import '../../services/app_info_cache.dart';
import '../../services/traffic_profiler.dart';
import '../per_app_trace_tab/app_multi_picker.dart';
import 'profiler_filter.dart';

/// §044/new-profiler — фильтр-окно профайлера. Bottom-sheet, паттерн
/// `home/widgets/filter_panel.dart`: TabBar с amber-точкой на табе с активным
/// фильтром + контент таба.
///
/// Две вкладки (порядок по решению юзера):
/// 1. **Protocol** — чипы DNS / TCP / UDP (по семейству §177).
/// 2. **App** — галочки замеченных в трафике пакетов ([seenApps]) + «потеряшки»
///    (unattributed) + кнопка пикера (добавить app, которого ещё не было).
///
/// [showAppTab] — в App-вкладке (`per_app_trace`) target зафиксирован сессией,
/// App-таб скрыт. [seenApps] — пакеты, реально засветившиеся в текущих событиях.
Future<void> showProfilerFilterSheet(
  BuildContext context, {
  required ProfilerFilter filter,
  required bool showAppTab,
  required Set<String> seenApps,
  required bool hasUnattributed,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ProfilerFilterSheet(
      filter: filter,
      showAppTab: showAppTab,
      seenApps: seenApps,
      hasUnattributed: hasUnattributed,
    ),
  );
}

class _ProfilerFilterSheet extends StatefulWidget {
  const _ProfilerFilterSheet({
    required this.filter,
    required this.showAppTab,
    required this.seenApps,
    required this.hasUnattributed,
  });

  final ProfilerFilter filter;
  final bool showAppTab;
  final Set<String> seenApps;
  final bool hasUnattributed;

  @override
  State<_ProfilerFilterSheet> createState() => _ProfilerFilterSheetState();
}

class _ProfilerFilterSheetState extends State<_ProfilerFilterSheet>
    with TickerProviderStateMixin {
  late final TabController _tab;

  // Protocol-чипы: (label, представитель-семейство §177).
  static const _protocols = <(String, TrafficEventKind)>[
    ('DNS', TrafficEventKind.dnsResolve),
    ('TCP', TrafficEventKind.tcpOpen),
    ('UDP', TrafficEventKind.udpOpen),
  ];

  ProfilerFilter get f => widget.filter;

  // Пакеты, добавленные через пикер (которых не было в seenApps) — показываем
  // их в App-табе тоже, чтобы галочка была видна.
  final Set<String> _extraApps = {};

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: widget.showAppTab ? 2 : 1, vsync: this);
    // app'ы из фильтра, которых нет в seen, — изначально extra (например из
    // прошлого пикера).
    _extraApps.addAll(f.apps.where((p) => !widget.seenApps.contains(p)));
    f.addListener(_onChanged);
  }

  @override
  void dispose() {
    f.removeListener(_onChanged);
    _tab.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  String _appLabel(String pkg) {
    final name = AppInfoCache.of(pkg)?.appName;
    if (name != null && name.isNotEmpty) return name;
    final seg = pkg.split('.');
    return seg.isNotEmpty ? seg.last : pkg;
  }

  Widget _dotTab(String label, bool active) => Tab(
        height: 40,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label),
            if (active) ...[
              const SizedBox(width: 5),
              Container(
                width: 7,
                height: 7,
                decoration: const BoxDecoration(
                    color: Colors.amber, shape: BoxShape.circle),
              ),
            ],
          ],
        ),
      );

  // ── Protocol-таб ──
  Widget _protocolTab() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final (label, kind) in _protocols)
            FilterChip(
              label: Text(label),
              selected: f.hasKind(kind),
              onSelected: (v) => f.toggleKind(kind, v),
            ),
        ],
      ),
    );
  }

  // ── App-таб ──
  Widget _appTab() {
    // Замеченные + extra (из пикера), отсортированы: выбранные наверх.
    final all = <String>{...widget.seenApps, ..._extraApps}.toList();
    all.sort((a, b) {
      final sa = f.hasApp(a) ? 0 : 1;
      final sb = f.hasApp(b) ? 0 : 1;
      if (sa != sb) return sa - sb;
      return _appLabel(a).toLowerCase().compareTo(_appLabel(b).toLowerCase());
    });
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Кнопка пикера — В НАЧАЛЕ (просьба юзера): добавить app, которого ещё
        // не было в трафике, без скролла до конца списка.
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: OutlinedButton.icon(
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add app from full list'),
            onPressed: _openPicker,
          ),
        ),
        // «Потеряшки» — события без owner'а.
        if (widget.hasUnattributed || f.includeUnattributed)
          CheckboxListTile(
            value: f.includeUnattributed,
            onChanged: (v) => f.includeUnattributed = v ?? false,
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            secondary: Icon(Icons.help_outline,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            title: const Text('Unattributed (no owner)',
                style: TextStyle(fontSize: 13)),
            subtitle: const Text('«потеряшки» — события без приложения',
                style: TextStyle(fontSize: 10)),
          ),
        if (all.isEmpty && !widget.hasUnattributed)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text('No apps seen yet — traffic will populate this list.',
                style: TextStyle(fontSize: 12)),
          ),
        for (final pkg in all)
          CheckboxListTile(
            value: f.hasApp(pkg),
            onChanged: (v) => f.toggleApp(pkg, v ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            secondary: _appIcon(pkg),
            title: Text(_appLabel(pkg), style: const TextStyle(fontSize: 13)),
            subtitle: Text(pkg,
                style: const TextStyle(fontSize: 10, fontFamily: 'monospace')),
          ),
      ],
    );
  }

  Widget _appIcon(String pkg) {
    AppInfoCache.ensure(pkg);
    return AnimatedBuilder(
      animation: AppInfoCache.revision,
      builder: (_, _) {
        final info = AppInfoCache.of(pkg);
        if (info?.icon != null) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.memory(info!.icon!,
                width: 28, height: 28, gaplessPlayback: true),
          );
        }
        final cs = Theme.of(context).colorScheme;
        final label = _appLabel(pkg);
        return SizedBox(
          width: 28,
          height: 28,
          child: CircleAvatar(
            backgroundColor: cs.surfaceContainerHighest,
            child: Text(label.isEmpty ? '?' : label.characters.first.toUpperCase(),
                style: TextStyle(fontSize: 11, color: cs.onSurface)),
          ),
        );
      },
    );
  }

  Future<void> _openPicker() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _PickerSheet(filter: f, onPicked: (pkg) {
        // добавленный пакет показываем в App-табе даже если его не было в seen.
        setState(() => _extraApps.add(pkg));
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: mq.size.height * 0.8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text('Filter events',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600)),
                  ),
                  if (f.isActive)
                    TextButton(
                      onPressed: f.clearAll,
                      child: const Text('Reset all'),
                    ),
                ],
              ),
              TabBar(
                controller: _tab,
                tabs: [
                  _dotTab('Protocol', f.kinds.isNotEmpty),
                  if (widget.showAppTab) _dotTab('App', f.appAxisActive),
                ],
              ),
              const SizedBox(height: 4),
              Flexible(
                child: SingleChildScrollView(
                  child: AnimatedBuilder(
                    animation: _tab,
                    builder: (_, _) => _tab.index == 0 || !widget.showAppTab
                        ? _protocolTab()
                        : _appTab(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Полный пикер приложений (за кнопкой «Add app»). Мульти-select поверх
/// [AppMultiPicker]; выбор сразу пишется в [filter.apps] + дёргается [onPicked]
/// чтобы родитель показал пакет в App-табе.
class _PickerSheet extends StatefulWidget {
  const _PickerSheet({required this.filter, required this.onPicked});
  final ProfilerFilter filter;
  final void Function(String pkg) onPicked;

  @override
  State<_PickerSheet> createState() => _PickerSheetState();
}

class _PickerSheetState extends State<_PickerSheet> {
  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: mq.size.height * 0.85),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('Add app to filter',
                  style:
                      TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            Flexible(
              child: AppMultiPicker(
                selected: widget.filter.apps,
                onToggle: (pkg, on) {
                  widget.filter.toggleApp(pkg, on);
                  if (on) widget.onPicked(pkg);
                  setState(() {});
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
