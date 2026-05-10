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
import 'app_settings_screen.dart';
import 'stats_screen.dart';

class LiveEventsTab extends StatefulWidget {
  const LiveEventsTab({super.key, this.onJumpToPerApp});

  /// Optional callback — когда юзер делает «Open in Per-app session»,
  /// родитель решает как переключить tab (DefaultTabController.animateTo
  /// + start session).
  final ValueChanged<String>? onJumpToPerApp;

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
        _recordingHeader(context),
        _filterBar(context),
        const Divider(height: 1),
        if (TrafficProfiler.I.unattributedBannerActive)
          Container(
            width: double.infinity,
            color: cs.errorContainer,
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.warning_amber,
                    size: 16, color: cs.onErrorContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${TrafficProfiler.I.recentUnattributedCount} unattributed events / 30s — '
                    'sing-box не смог детектить owner package для части DNS/TCP traffic\'а',
                    style: TextStyle(
                        fontSize: 12, color: cs.onErrorContainer),
                  ),
                ),
              ],
            ),
          ),
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
                  itemBuilder: (_, i) =>
                      _eventTile(context, filtered[i]),
                ),
        ),
      ],
    );
  }

  /// §048 — header с recording control. ▶ START / ⏹ STOP + duration badge.
  /// Аналогичен Per-app trace header'у, но без target picker'а — Live это
  /// system-wide recording, фокусируется через filter chips.
  Widget _recordingHeader(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isRec = TrafficProfiler.I.isGlobalRecording;
    final startedAt = TrafficProfiler.I.globalRecordingStartedAt;
    final duration = startedAt == null
        ? Duration.zero
        : DateTime.now().difference(startedAt);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Row(
        children: [
          Icon(
            isRec ? Icons.fiber_manual_record : Icons.podcasts,
            size: 16,
            color: isRec ? cs.error : cs.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isRec ? 'Recording system-wide events' : 'Not recording',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: isRec ? cs.error : cs.onSurface),
                ),
                Text(
                  isRec
                      ? '${_fmtDur(duration)} · ${_events.length} events'
                      : 'Tap START to begin capture. Recording continues '
                          'when you leave this tab.',
                  style: TextStyle(
                      fontSize: 11, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _toggleRecording,
            icon: Icon(isRec ? Icons.stop : Icons.fiber_manual_record,
                size: 18),
            label: Text(isRec ? 'STOP' : 'START'),
            style: FilledButton.styleFrom(
              backgroundColor: isRec ? cs.error : cs.primary,
              foregroundColor: isRec ? cs.onError : cs.onPrimary,
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            icon: const Icon(Icons.more_vert),
            onSelected: (v) {
              if (v == 'diagnostics') _openDiagnosticsSettings();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'diagnostics',
                child: ListTile(
                  leading: Icon(Icons.tune),
                  title: Text('Diagnostics settings'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Deep-link → App Settings → Diagnostics. Live recording require'ит
  /// `core_logs_enabled=true` (toggle "Forward sing-box logs") чтобы DNS
  /// и connection events приходили из core. Юзер видит «0 events» и
  /// открывает diagnostics для toggle'а.
  ///
  /// initialTab=1 — Diagnostics после §052 Phase 2 (TabBar 3→2).
  void _openDiagnosticsSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const AppSettingsScreen(initialTab: 1),
      ),
    );
  }

  static String _fmtDur(Duration d) {
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
    if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds % 60}s';
    return '${d.inSeconds}s';
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

  Widget _eventTile(BuildContext context, TrafficEvent e) {
    final cs = Theme.of(context).colorScheme;
    final ts = '${e.ts.hour.toString().padLeft(2, '0')}:'
        '${e.ts.minute.toString().padLeft(2, '0')}:'
        '${e.ts.second.toString().padLeft(2, '0')}';
    Color kindColor;
    String kindLabel;
    switch (e.kind) {
      case TrafficEventKind.dnsResolve:
        kindColor = cs.tertiary;
        kindLabel = 'DNS';
      case TrafficEventKind.dnsFail:
        kindColor = cs.error;
        kindLabel = 'DNS×';
      case TrafficEventKind.tcpOpen:
        kindColor = cs.primary;
        kindLabel = 'TCP';
      case TrafficEventKind.tcpClose:
        kindColor = cs.outline;
        kindLabel = 'TCP·';
      case TrafficEventKind.udpOpen:
        kindColor = cs.secondary;
        kindLabel = 'UDP';
    }

    final summary = _eventSummary(e);
    final process = e.process ?? '?';

    return InkWell(
      onLongPress: () => _showEventActions(e),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(ts,
                    style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: cs.onSurfaceVariant)),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: kindColor.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(kindLabel,
                      style: TextStyle(
                          fontSize: 10,
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.bold,
                          color: kindColor)),
                ),
                const SizedBox(width: 6),
                _confidenceBadge(context, e),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(summary,
                      style: const TextStyle(fontSize: 12),
                      overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 60, top: 1),
              child: Text(process,
                  style: TextStyle(
                      fontSize: 10,
                      fontFamily: 'monospace',
                      color: e.confidence == ConfidenceLevel.unattributed
                          ? cs.error
                          : cs.primary),
                  overflow: TextOverflow.ellipsis),
            ),
            if (e.dnsRecordType != null)
              Padding(
                padding: const EdgeInsets.only(left: 60, top: 1),
                child: Text('record: ${e.dnsRecordType}',
                    style: TextStyle(
                        fontSize: 10, color: cs.onSurfaceVariant)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _confidenceBadge(BuildContext context, TrafficEvent e) {
    final cs = Theme.of(context).colorScheme;
    Color color;
    String label;
    switch (e.confidence) {
      case ConfidenceLevel.verified:
        return const SizedBox.shrink();
      case ConfidenceLevel.secondary:
        color = cs.tertiary;
        label = 'sec';
      case ConfidenceLevel.inferred:
        color = cs.secondary;
        label = '〽';
      case ConfidenceLevel.unattributed:
        color = cs.error;
        label = '?';
    }
    return Tooltip(
      message: 'confidence: ${e.confidence.name}'
          '${e.matchedVia != null ? "\nmatched via: ${e.matchedVia}" : ""}'
          '${e.shownBecause != null ? "\nshown because: ${e.shownBecause}" : ""}',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 10,
                fontFamily: 'monospace',
                color: color)),
      ),
    );
  }

  String _eventSummary(TrafficEvent e) {
    switch (e.kind) {
      case TrafficEventKind.dnsResolve:
        return e.ip != null
            ? '${e.domain ?? "?"} → ${e.ip}'
            : (e.domain ?? '?');
      case TrafficEventKind.dnsFail:
        return 'DNS× ${e.domain ?? "?"}';
      case TrafficEventKind.tcpOpen:
      case TrafficEventKind.udpOpen:
        return '${e.domain ?? e.ip ?? "?"}:${e.port ?? "?"}';
      case TrafficEventKind.tcpClose:
        final bytes =
            '↑${_fmtBytes(e.upBytes ?? 0)} ↓${_fmtBytes(e.downBytes ?? 0)}';
        return '${e.domain ?? e.ip ?? "?"}:${e.port ?? "?"} closed · $bytes';
    }
  }

  void _showEventActions(TrafficEvent e) {
    final pkgs = e.process
            ?.split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList() ??
        const <String>[];
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(_eventSummary(e)),
              subtitle: Text(
                  'confidence: ${e.confidence.name}${e.matchedVia != null ? "  ·  ${e.matchedVia}" : ""}'),
            ),
            const Divider(height: 1),
            for (final pkg in pkgs)
              ListTile(
                leading: const Icon(Icons.android),
                title: Text(pkg),
                subtitle: const Text('Open in Per-app session'),
                onTap: () {
                  Navigator.pop(ctx);
                  if (widget.onJumpToPerApp != null) {
                    widget.onJumpToPerApp!(pkg);
                  } else {
                    StatsScreen.requestPerAppSession(context, pkg);
                  }
                },
              ),
            if (pkgs.isEmpty)
              const ListTile(
                leading: Icon(Icons.help_outline),
                title: Text(
                    'No process detected — cannot start Per-app session.'),
              ),
          ],
        ),
      ),
    );
  }
}

String _fmtBytes(int b) {
  if (b < 1024) return '${b}B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)}KB';
  if (b < 1024 * 1024 * 1024) {
    return '${(b / 1024 / 1024).toStringAsFixed(1)}MB';
  }
  return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)}GB';
}
