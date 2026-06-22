import 'package:flutter/material.dart';

import '../../services/traffic_profiler.dart';
import '../per_app_trace_tab/widgets/aggregate_axis.dart';
import '../per_app_trace_tab/widgets/aggregated_view.dart';
import '../per_app_trace_tab/widgets/live_view.dart';
import 'aggregate_detail_sheet.dart';
import 'traffic_event_detail_sheet.dart';

/// §160 — общий explorer трафика: тогл **Live / Aggregated** + общий фильтр
/// (поиск + чипы типа события) + drill-down детали + пауза Live.
///
/// Единый движок для двух экранов (без дубля кода):
/// - **Per-app trace** (`PerAppTraceTab`) — `events` = `session.events`.
/// - **Stats→Live** (`LiveEventsTab`) — `events` = `globalRollingBuffer`.
///
/// Агрегаты (`byDomain`/`byIp`) считаются **здесь** из [events] общим
/// `computeTraceAggregates` — не завязываясь на `Session`, поэтому работает
/// и там где сессии нет (Live). [events] — полный таймлайн (newest-last
/// или любой порядок; explorer сам разворачивает для показа). [unattributed]
/// — system-wide «no owner» события (Live-секция внизу). [recording] —
/// идёт ли запись (для empty-state текста).
class TraceExplorer extends StatefulWidget {
  const TraceExplorer({
    super.key,
    required this.events,
    required this.unattributed,
    required this.recording,
  });

  final List<TrafficEvent> events;
  final List<TrafficEvent> unattributed;
  final bool recording;

  @override
  State<TraceExplorer> createState() => _TraceExplorerState();
}

enum _Mode { live, aggregated }

class _TraceExplorerState extends State<TraceExplorer> {
  _Mode _mode = _Mode.live;
  AggAxis _aggAxis = AggAxis.domain;
  final TextEditingController _searchCtrl = TextEditingController();
  String _search = '';
  final Set<TrafficEventKind> _kindFilter = <TrafficEventKind>{};
  bool _onlyUnattributed = false;

  // Пауза только для отображения Live: запись продолжается, список замирает
  // на снимке. Снимок фиксируется в момент паузы.
  bool _paused = false;
  List<TrafficEvent>? _frozenEvents;
  List<TrafficEvent>? _frozenUnattributed;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Ключ из детального sheet → общий поиск. Повторный тот же ключ — clear.
  /// `switchToAggregated` — для «View in Aggregated» из sheet'а агрегата.
  void _applySearchKey(String key, {bool switchToAggregated = false}) {
    final clean = key.trim();
    if (clean.isEmpty) return;
    setState(() {
      if (_search == clean) {
        _searchCtrl.clear();
        _search = '';
      } else {
        _searchCtrl.text = clean;
        _searchCtrl.selection =
            TextSelection.collapsed(offset: clean.length);
        _search = clean;
      }
      if (switchToAggregated) {
        _mode = _Mode.aggregated;
        _aggAxis = AggAxis.domain;
      }
    });
  }

  void _togglePause() {
    setState(() {
      _paused = !_paused;
      if (_paused) {
        _frozenEvents = List.of(widget.events);
        _frozenUnattributed = List.of(widget.unattributed);
      } else {
        _frozenEvents = null;
        _frozenUnattributed = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Источник: на паузе — снимок, иначе живые списки родителя.
    final srcEvents = _paused ? (_frozenEvents ?? const []) : widget.events;
    final srcUnattr =
        _paused ? (_frozenUnattributed ?? const []) : widget.unattributed;

    return Column(
      children: [
        _modeToggle(context),
        _filterBar(context),
        Expanded(child: _body(context, srcEvents, srcUnattr)),
      ],
    );
  }

  /// Тогл Live / Aggregated (+ ось by Domain / by IP только в Aggregated).
  Widget _modeToggle(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Expanded(
            child: SegmentedButton<_Mode>(
              segments: [
                const ButtonSegment(
                    value: _Mode.live,
                    label: Text('Live'),
                    icon: Icon(Icons.stream, size: 16)),
                ButtonSegment(
                    value: _Mode.aggregated,
                    // Сокращаем до «Agg» когда выбран: справа появляется ось.
                    label: Text(_mode == _Mode.aggregated ? 'Agg' : 'Aggregated'),
                    icon: const Icon(Icons.summarize, size: 16)),
              ],
              selected: {_mode},
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
              ),
              onSelectionChanged: (s) => setState(() {
                _mode = s.first;
                if (_mode != _Mode.live) {
                  _paused = false;
                  _frozenEvents = null;
                  _frozenUnattributed = null;
                }
              }),
            ),
          ),
          if (_mode == _Mode.aggregated) ...[
            const SizedBox(width: 8),
            SegmentedButton<AggAxis>(
              segments: const [
                ButtonSegment(value: AggAxis.domain, label: Text('Domain')),
                ButtonSegment(value: AggAxis.ip, label: Text('IP')),
              ],
              selected: {_aggAxis},
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
              ),
              onSelectionChanged: (s) => setState(() => _aggAxis = s.first),
            ),
          ],
        ],
      ),
    );
  }

  /// Общий фильтр на оба режима. Чипы типа / Unattributed / Pause — только
  /// в Live (в Aggregated событий-строк нет).
  Widget _filterBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Search domain / IP / app…',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    suffixIcon: _search.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() => _search = '');
                            },
                          ),
                    isDense: true,
                    border: const OutlineInputBorder(),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                  ),
                  onChanged: (v) => setState(() => _search = v),
                ),
              ),
              if (_mode == _Mode.live) ...[
                const SizedBox(width: 8),
                IconButton(
                  tooltip: _paused ? 'Resume' : 'Pause',
                  icon: Icon(_paused ? Icons.play_arrow : Icons.pause, size: 22),
                  color: _paused
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.primary,
                  onPressed: _togglePause,
                ),
              ],
            ],
          ),
          if (_mode == _Mode.live) ...[
            const SizedBox(height: 4),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ..._kindChips(),
                  const SizedBox(width: 8),
                  FilterChip(
                    label: const Text('Unattributed only',
                        style: TextStyle(fontSize: 11)),
                    selected: _onlyUnattributed,
                    visualDensity: VisualDensity.compact,
                    onSelected: (v) => setState(() => _onlyUnattributed = v),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _kindChips() {
    Widget chip(String label, TrafficEventKind kind) => Padding(
          padding: const EdgeInsets.only(right: 4),
          child: FilterChip(
            label: Text(label, style: const TextStyle(fontSize: 11)),
            selected: _kindFilter.contains(kind),
            visualDensity: VisualDensity.compact,
            onSelected: (v) => setState(() {
              if (v) {
                _kindFilter.add(kind);
              } else {
                _kindFilter.remove(kind);
              }
            }),
          ),
        );
    return [
      chip('DNS', TrafficEventKind.dnsResolve),
      chip('DNS×', TrafficEventKind.dnsFail),
      chip('TCP', TrafficEventKind.tcpOpen),
      chip('TCP·', TrafficEventKind.tcpClose),
      chip('UDP', TrafficEventKind.udpOpen),
    ];
  }

  Widget _body(BuildContext context, List<TrafficEvent> srcEvents,
      List<TrafficEvent> srcUnattr) {
    if (_mode == _Mode.live) {
      return LiveView(
        recording: widget.recording,
        events: _applyFilter(srcEvents).toList().reversed.toList(),
        unattributed: _applyFilter(srcUnattr).toList().reversed.toList(),
        onOpenDetail: (e) => showTrafficEventDetailSheet(context, e,
            onSearchKey: _applySearchKey),
      );
    }
    // Aggregated — агрегаты считаем из полного (нефильтрованного) набора,
    // фильтр применяется к строкам внутри AggregatedView по search.
    final agg = computeTraceAggregates(srcEvents);
    return AggregatedView(
      events: srcEvents,
      byDomain: agg.byDomain,
      byIp: agg.byIp,
      axis: _aggAxis,
      search: _search,
      onOpenAggregate: (key) => showAggregateDetailSheet(
        context,
        events: srcEvents,
        byDomain: agg.byDomain,
        byIp: agg.byIp,
        axis: _aggAxis,
        key: key,
        onSearchKey: (k) => _applySearchKey(k, switchToAggregated: true),
      ),
    );
  }

  Iterable<TrafficEvent> _applyFilter(Iterable<TrafficEvent> src) {
    var list = src;
    if (_kindFilter.isNotEmpty) {
      list = list.where((e) => _kindFilter.contains(e.kind));
    }
    if (_onlyUnattributed) {
      list =
          list.where((e) => e.confidence == ConfidenceLevel.unattributed);
    }
    if (_search.isNotEmpty) {
      final lq = _search.toLowerCase();
      list = list.where((e) =>
          (e.domain?.toLowerCase().contains(lq) ?? false) ||
          (e.ip?.contains(_search) ?? false) ||
          (e.process?.toLowerCase().contains(lq) ?? false));
    }
    return list;
  }
}
