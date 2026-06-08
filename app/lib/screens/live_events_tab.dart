// §048 Принцип 7 — Live system-wide tab.
//
// 4-й tab в `StatsScreen`. Показывает все TrafficEvent'ы со всех apps в
// real-time, без выбора target. Решает discovery-кейс: «не знаю какой app
// виноват, что вообще происходит на устройстве». Использует тот же
// `_globalRollingBuffer` что Per-app session backfill (§048 Принцип 4) —
// без дополнительной memory cost.
//
// Фильтры (chips):
//   - app multi-select  — фильтр по package name (auto-collected из feed'а)
//   - event type        — DNS / TCP / UDP / Failed / Unattributed
//   - search            — substring match по domain / IP / process
//   - Live / Frozen     — pause/resume для статичного просмотра (юзер
//                         хочет внимательно прочитать что происходит)
//
// Tap row → option «Open in Per-app session» — старт session с этим
// package как target. Quick-discovery flow.

import 'dart:async';

import 'package:flutter/material.dart';

import '../services/traffic_profiler.dart';
import '../widgets/core_logs_hint_banner.dart';
import 'live_events_tab/event_tile.dart';
import 'live_events_tab/recording_header.dart';
import 'live_events_tab/unattributed_banner.dart';

class LiveEventsTab extends StatefulWidget {
  const LiveEventsTab({super.key});

  @override
  State<LiveEventsTab> createState() => _LiveEventsTabState();
}

class _LiveEventsTabState extends State<LiveEventsTab> {
  StreamSubscription<Map<String, Object?>>? _sub;
  // Локальный snapshot — приходит из global rolling buffer'а на init,
  // потом обновляется через SSE feed. Live-снимок == _events newest-last.
  final List<TrafficEvent> _events = [];
  bool _paused = false;
  Timer? _ticker; // для refresh «Recording 02:34» каждую секунду

  // Filter state.
  final TextEditingController _searchCtrl = TextEditingController();
  String _search = '';
  final Set<String> _appFilter = {}; // empty = no filter
  final Set<TrafficEventKind> _kindFilter = {}; // empty = no filter
  bool _onlyUnattributed = false;

  // Cache of seen apps для chip selection.
  final Set<String> _seenApps = {};

  @override
  void initState() {
    super.initState();
    // §048 — recording state управляется explicit через [TrafficProfiler.I.startGlobalRecording]
    // (юзер тапает ▶ START в Live tab). Tab subscribes к stream, но это
    // не запускает recording — listener attached только если recording active.
    final snapshot = TrafficProfiler.I.globalSnapshot(seconds: 60);
    _events.addAll(snapshot);
    for (final e in snapshot) {
      _trackApp(e);
    }
    _sub = TrafficProfiler.I.globalLiveStream().listen(_onEvent);
    TrafficProfiler.I.addListener(_onProfilerChanged);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && TrafficProfiler.I.isGlobalRecording) setState(() {});
    });
  }

  void _onProfilerChanged() {
    if (!mounted) return;
    setState(() {
      // На STOP recording'а — фиксируем последний snapshot из buffer'а
      // (он уже не растёт), на START — clear (TrafficProfiler уже это
      // сделал в startGlobalRecording).
      if (!TrafficProfiler.I.isGlobalRecording) {
        // Buffer заморожен. _events остаётся как есть.
        return;
      }
      _events.clear();
      _seenApps.clear();
    });
  }

  void _toggleRecording() {
    if (TrafficProfiler.I.isGlobalRecording) {
      TrafficProfiler.I.stopGlobalRecording();
    } else {
      TrafficProfiler.I.startGlobalRecording();
    }
  }

  void _trackApp(TrafficEvent e) {
    final p = e.process?.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty);
    if (p != null) _seenApps.addAll(p);
  }

  void _onEvent(Map<String, Object?> msg) {
    if (_paused) return;
    if (msg['event'] != 'traffic_event') return;
    final data = msg['data'];
    if (data is! Map) return;
    // Emitted event — нам нужен сам TrafficEvent объект, но через SSE
    // приходит JSON. Проще пересчитывать snapshot из global buffer'а
    // на каждый tick: это O(N) и N <= 3000.
    setState(() {
      final fresh = TrafficProfiler.I.globalRollingBuffer;
      _events
        ..clear()
        ..addAll(fresh);
      for (final e in fresh) {
        _trackApp(e);
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    TrafficProfiler.I.removeListener(_onProfilerChanged);
    _ticker?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  List<TrafficEvent> get _filtered {
    var list = _events;
    if (_appFilter.isNotEmpty) {
      list = list.where((e) {
        final pkgs = e.process
                ?.split(',')
                .map((s) => s.trim())
                .toSet() ??
            const <String>{};
        return pkgs.any(_appFilter.contains);
      }).toList();
    }
    if (_kindFilter.isNotEmpty) {
      list = list.where((e) => _kindFilter.contains(e.kind)).toList();
    }
    if (_onlyUnattributed) {
      list = list
          .where((e) => e.confidence == ConfidenceLevel.unattributed)
          .toList();
    }
    if (_search.isNotEmpty) {
      final lq = _search.toLowerCase();
      list = list.where((e) {
        return (e.domain?.toLowerCase().contains(lq) ?? false) ||
            (e.ip?.contains(_search) ?? false) ||
            (e.process?.toLowerCase().contains(lq) ?? false);
      }).toList();
    }
    return list.reversed.toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final filtered = _filtered;
    return Column(
      children: [
        LiveRecordingHeader(
          eventCount: _events.length,
          onToggle: _toggleRecording,
        ),
        _filterBar(context),
        const Divider(height: 1),
        const CoreLogsHintBanner(),
        if (TrafficProfiler.I.unattributedBannerActive)
          const UnattributedBanner(),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _events.isEmpty
                          ? (TrafficProfiler.I.isGlobalRecording
                              ? 'Waiting for events… '
                                  '(events appear when traffic flows)'
                              : 'Tap ▶ START above to begin capture.')
                          : 'No matches.',
                      style: TextStyle(color: cs.onSurfaceVariant),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (_, i) => LiveEventTile(
                    event: filtered[i],
                    onSearchKey: _applySearchKey,
                  ),
                ),
        ),
      ],
    );
  }

  Widget _filterBar(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
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
              const SizedBox(width: 8),
              IconButton(
                tooltip: _paused ? 'Resume' : 'Pause',
                icon: Icon(
                    _paused ? Icons.play_arrow : Icons.pause, size: 22),
                onPressed: () => setState(() => _paused = !_paused),
                color: _paused ? cs.error : cs.primary,
              ),
            ],
          ),
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
                  onSelected: (v) =>
                      setState(() => _onlyUnattributed = v),
                ),
                const SizedBox(width: 8),
                if (_seenApps.isNotEmpty)
                  TextButton.icon(
                    onPressed: _showAppFilterSheet,
                    icon: const Icon(Icons.android, size: 16),
                    label: Text(
                      _appFilter.isEmpty
                          ? 'All apps'
                          : '${_appFilter.length} app(s)',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _kindChips() {
    Widget chip(String label, TrafficEventKind kind) {
      final selected = _kindFilter.contains(kind);
      return Padding(
        padding: const EdgeInsets.only(right: 4),
        child: FilterChip(
          label: Text(label, style: const TextStyle(fontSize: 11)),
          selected: selected,
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
    }

    return [
      chip('DNS', TrafficEventKind.dnsResolve),
      chip('DNS×', TrafficEventKind.dnsFail),
      chip('TCP', TrafficEventKind.tcpOpen),
      chip('TCP·', TrafficEventKind.tcpClose),
      chip('UDP', TrafficEventKind.udpOpen),
    ];
  }

  void _showAppFilterSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        final apps = _seenApps.toList()..sort();
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return SafeArea(
              child: ListView(
                shrinkWrap: true,
                children: [
                  ListTile(
                    title: const Text('Filter by app'),
                    trailing: TextButton(
                      onPressed: () => setSheetState(() {
                        _appFilter.clear();
                        setState(() {});
                      }),
                      child: const Text('Clear'),
                    ),
                  ),
                  for (final a in apps)
                    CheckboxListTile(
                      dense: true,
                      title: Text(a, style: const TextStyle(fontSize: 13)),
                      value: _appFilter.contains(a),
                      onChanged: (v) {
                        setSheetState(() {
                          if (v ?? false) {
                            _appFilter.add(a);
                          } else {
                            _appFilter.remove(a);
                          }
                          setState(() {});
                        });
                      },
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// Кладём `key` в существующий search field, фильтруя список по нему.
  /// Повторный tap на том же значении (уже выставленном) — clear (escape
  /// hatch без отдельной кнопки).
  void _applySearchKey(String key) {
    final clean = key.trim();
    if (clean.isEmpty) return;
    if (_search == clean) {
      _searchCtrl.clear();
      setState(() => _search = '');
      return;
    }
    _searchCtrl.text = clean;
    _searchCtrl.selection =
        TextSelection.collapsed(offset: clean.length);
    setState(() => _search = clean);
  }
}
