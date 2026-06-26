import 'package:flutter/material.dart';

import '../../services/app_info_cache.dart';
import '../../services/traffic_profiler.dart';
import '../per_app_trace_tab/app_multi_picker.dart';
import 'profiler_filter.dart';

/// §044/new-profiler — фильтр-окно профайлера. Bottom-sheet по паттерну
/// `home/widgets/filter_panel.dart` (эталон фильтра главного экрана):
/// TabBar с amber-точкой на табе с активным фильтром + сводка `InputChip`
/// (tap → таб, ✕ → снять) + контент активного таба.
///
/// Две независимые оси: **App** (мульти-пикер, «по процессу») и
/// **DNS/TCP/UDP** (чипы фаз, «по типу события»). Плюс кросс-осевой поиск над
/// табами и чип Unattributed.
///
/// [showAppTab] — в App-вкладке (`per_app_trace`) target зафиксирован сессией,
/// app-ось не нужна → таб App скрыт.
Future<void> showProfilerFilterSheet(
  BuildContext context, {
  required ProfilerFilter filter,
  required bool showAppTab,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ProfilerFilterSheet(filter: filter, showAppTab: showAppTab),
  );
}

class _ProfilerFilterSheet extends StatefulWidget {
  const _ProfilerFilterSheet({required this.filter, required this.showAppTab});

  final ProfilerFilter filter;
  final bool showAppTab;

  @override
  State<_ProfilerFilterSheet> createState() => _ProfilerFilterSheetState();
}

class _ProfilerFilterSheetState extends State<_ProfilerFilterSheet>
    with TickerProviderStateMixin {
  late final TabController _tab;
  late final TextEditingController _searchCtrl;

  // Описание табов-типов: (label, представитель-семейство §177).
  static const _kindTabs = <(String, TrafficEventKind)>[
    ('DNS', TrafficEventKind.dnsResolve),
    ('TCP', TrafficEventKind.tcpOpen),
    ('UDP', TrafficEventKind.udpOpen),
  ];

  ProfilerFilter get f => widget.filter;

  /// Индексы: [App?] DNS TCP UDP. App присутствует только если showAppTab.
  int get _tabCount => (widget.showAppTab ? 1 : 0) + _kindTabs.length;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: _tabCount, vsync: this);
    _searchCtrl = TextEditingController(text: f.search);
    f.addListener(_onFilterChanged);
  }

  @override
  void dispose() {
    f.removeListener(_onFilterChanged);
    _tab.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onFilterChanged() {
    if (mounted) setState(() {});
  }

  String _appLabel(String pkg) {
    final name = AppInfoCache.of(pkg)?.appName;
    if (name != null && name.isNotEmpty) return name;
    // package короче имени — режем по последнему сегменту.
    final seg = pkg.split('.');
    return seg.isNotEmpty ? seg.last : pkg;
  }

  /// Сводка активных фильтров чипами (tap → таб, ✕ → снять).
  List<Widget> _summaryChips() {
    final chips = <Widget>[];
    if (widget.showAppTab) {
      for (final pkg in f.apps) {
        chips.add(InputChip(
          avatar: const Icon(Icons.android, size: 16),
          label: Text(_appLabel(pkg), style: const TextStyle(fontSize: 12)),
          onPressed: () => _tab.animateTo(0),
          onDeleted: () => f.toggleApp(pkg, false),
        ));
      }
    }
    for (final (label, kind) in _kindTabs) {
      if (f.hasKind(kind)) {
        chips.add(InputChip(
          label: Text(label, style: const TextStyle(fontSize: 12)),
          onPressed: () => _tab.animateTo(_kindTabIndex(kind)),
          onDeleted: () => f.toggleKind(kind, false),
        ));
      }
    }
    if (f.onlyUnattributed) {
      chips.add(InputChip(
        label: const Text('Unattributed', style: TextStyle(fontSize: 12)),
        onDeleted: () => f.onlyUnattributed = false,
      ));
    }
    return chips;
  }

  int _kindTabIndex(TrafficEventKind kind) {
    final base = widget.showAppTab ? 1 : 0;
    final i = _kindTabs.indexWhere((t) => t.$2 == kind);
    return base + (i < 0 ? 0 : i);
  }

  Widget _dotTab(String label, bool active) {
    return Tab(
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
                color: Colors.amber,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _tabs() {
    return [
      if (widget.showAppTab) _dotTab('App', f.apps.isNotEmpty),
      for (final (label, kind) in _kindTabs) _dotTab(label, f.hasKind(kind)),
    ];
  }

  Widget _tabContent(int index) {
    final base = widget.showAppTab ? 1 : 0;
    if (widget.showAppTab && index == 0) {
      return AppMultiPicker(
        selected: f.apps,
        onToggle: f.toggleApp,
      );
    }
    final kindIndex = index - base;
    final (_, kind) = _kindTabs[kindIndex];
    return _kindContent(kind);
  }

  /// Контент таба-типа: чипы фаз семейства. DNS=resolve+fail, TCP=open+close,
  /// UDP=udp. Чип фазы тоглит конкретный вид, но фильтр всё равно матчит по
  /// семейству (см. `ProfilerFilter.kindFamily`) — поэтому здесь тоглим
  /// представителя семейства одним чипом (паритет со старым поведением §177).
  Widget _kindContent(TrafficEventKind family) {
    final label = switch (family) {
      TrafficEventKind.dnsResolve => 'DNS queries (resolve + fail)',
      TrafficEventKind.tcpOpen => 'TCP connections (open + close)',
      TrafficEventKind.udpOpen => 'UDP connections',
      _ => 'Events',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: FilterChip(
          label: Text(label, style: const TextStyle(fontSize: 13)),
          selected: f.hasKind(family),
          onSelected: (v) => f.toggleKind(family, v),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final summary = _summaryChips();
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
                      onPressed: () {
                        f.clearAll();
                        _searchCtrl.clear();
                      },
                      child: const Text('Reset all'),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              // Кросс-осевой поиск (domain / ip / process) — над табами.
              TextField(
                controller: _searchCtrl,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Search domain / IP / app…',
                  prefixIcon: const Icon(Icons.search, size: 18),
                  suffixIcon: f.search.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () {
                            _searchCtrl.clear();
                            f.search = '';
                          },
                        ),
                  isDense: true,
                  border: const OutlineInputBorder(),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                onChanged: (v) => f.search = v,
              ),
              const SizedBox(height: 8),
              TabBar(
                controller: _tab,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                labelPadding: const EdgeInsets.symmetric(horizontal: 14),
                tabs: _tabs(),
              ),
              if (summary.isNotEmpty) ...[
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (var i = 0; i < summary.length; i++) ...[
                        if (i > 0) const SizedBox(width: 6),
                        summary[i],
                      ],
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Flexible(
                child: AnimatedBuilder(
                  animation: _tab,
                  builder: (_, _) =>
                      SingleChildScrollView(child: _tabContent(_tab.index)),
                ),
              ),
              const SizedBox(height: 4),
              // Unattributed — кросс-осевой чип под табами.
              Align(
                alignment: Alignment.centerLeft,
                child: FilterChip(
                  label: const Text('Unattributed only',
                      style: TextStyle(fontSize: 12)),
                  selected: f.onlyUnattributed,
                  onSelected: (v) => f.onlyUnattributed = v,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
