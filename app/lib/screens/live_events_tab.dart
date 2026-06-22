// §048 / §160 — Live system-wide tab.
//
// 4-й tab в `StatsScreen`. Показывает все TrafficEvent'ы со всех apps в
// real-time, без выбора target. Решает discovery-кейс: «не знаю какой app
// виноват, что вообще происходит на устройстве». Использует тот же
// `_globalRollingBuffer` что Per-app session backfill.
//
// §160 — тело (тогл Live/Aggregated + общий фильтр + детали + пауза)
// делегировано общему [TraceExplorer] (тот же движок, что в per-app trace,
// без дубля кода). Здесь остаётся только специфика system-wide:
//   - SSE-подписка на globalLiveStream → локальный snapshot `_events`;
//   - recording START/STOP (globalRecording);
//   - app multi-select pre-фильтр (по package, auto-collected из feed'а) —
//     уникален для system-wide (в per-app trace процесс один);
//   - unattributed banner.

import 'dart:async';

import 'package:flutter/material.dart';

import '../services/traffic_profiler.dart';
import '../widgets/core_logs_hint_banner.dart';
import 'live_events_tab/recording_header.dart';
import 'live_events_tab/unattributed_banner.dart';
import 'stats_screen/trace_explorer.dart';

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
  Timer? _ticker; // для refresh «Recording 02:34» каждую секунду

  // System-wide app pre-фильтр (мульти-выбор пакетов). TraceExplorer о нём
  // не знает — применяем здесь до передачи событий.
  final Set<String> _appFilter = {}; // empty = no filter
  final Set<String> _seenApps = {};

  @override
  void initState() {
    super.initState();
    // §048 — recording state управляется explicit через
    // [TrafficProfiler.I.startGlobalRecording] (юзер тапает ▶ START).
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
      // STOP — буфер заморожен, _events остаётся; START — clear.
      if (!TrafficProfiler.I.isGlobalRecording) return;
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
    final p =
        e.process?.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty);
    if (p != null) _seenApps.addAll(p);
  }

  void _onEvent(Map<String, Object?> msg) {
    if (msg['event'] != 'traffic_event') return;
    final data = msg['data'];
    if (data is! Map) return;
    // Через SSE приходит JSON; проще пересчитать snapshot из global buffer'а
    // на каждый tick (O(N), N ≤ 3000). Пауза отображения — в TraceExplorer.
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
    super.dispose();
  }

  /// События после system-wide app pre-фильтра.
  List<TrafficEvent> get _appFiltered {
    if (_appFilter.isEmpty) return _events;
    return _events.where((e) {
      final pkgs = e.process
              ?.split(',')
              .map((s) => s.trim())
              .toSet() ??
          const <String>{};
      return pkgs.any(_appFilter.contains);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        LiveRecordingHeader(
          eventCount: _events.length,
          onToggle: _toggleRecording,
        ),
        _appFilterBar(context),
        const Divider(height: 1),
        const CoreLogsHintBanner(),
        if (TrafficProfiler.I.unattributedBannerActive)
          const UnattributedBanner(),
        Expanded(
          child: TraceExplorer(
            // System-wide: unattributed события уже внутри globalRollingBuffer
            // как обычные строки (с confidence=unattributed). Отдельной
            // «no owner» секции (как в per-app) тут нет → unattributed=[].
            events: _appFiltered,
            unattributed: const [],
            recording: TrafficProfiler.I.isGlobalRecording,
          ),
        ),
      ],
    );
  }

  /// System-wide app multi-select (уникален для Live; в per-app процесс один).
  Widget _appFilterBar(BuildContext context) {
    if (_seenApps.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _showAppFilterSheet,
          icon: const Icon(Icons.android, size: 16),
          label: Text(
            _appFilter.isEmpty ? 'All apps' : '${_appFilter.length} app(s)',
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ),
    );
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
}
