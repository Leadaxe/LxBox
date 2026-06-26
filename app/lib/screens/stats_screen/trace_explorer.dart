import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../services/traffic_profiler.dart';
import '../per_app_trace_tab/session_json.dart';
import '../per_app_trace_tab/widgets/aggregate_axis.dart';
import '../per_app_trace_tab/widgets/aggregated_view.dart';
import '../per_app_trace_tab/widgets/live_view.dart';
import 'aggregate_detail_sheet.dart';
import 'profiler_filter.dart';
import 'profiler_filter_sheet.dart';
import 'traffic_event_detail_sheet.dart';

/// §044/new-profiler — режим записи: persistent (пишем всегда, в фоне тоже) vs
/// tab-scoped (пишем только пока вкладка открыта). Управляет родитель —
/// explorer лишь рисует кнопку и зовёт колбэк.
enum RecordingScope { persistent, tabScoped }

/// §160 / §044-new-profiler — общий explorer трафика. Единый движок Profiler
/// (Stats→Live) и per-app trace, без дубля кода.
///
/// **§044/new-profiler:** управление свёрнуто в ОДНУ control-строку (Live/pause
/// · Record-scope · Aggregate-меню · Filter-окно · Export); фильтр вынесен в
/// `ProfilerFilterSheet`. Фильтр-state — общий `ProfilerFilter` (от родителя).
///
/// Агрегаты (`byDomain`/`byIp`) считаются здесь из [events] общим
/// `computeTraceAggregates`. [events] — полный таймлайн (любой порядок;
/// explorer сам разворачивает для показа). [unattributed] — system-wide
/// «no owner» события (Live-секция внизу). [recording] — идёт ли запись
/// (для empty-state текста).
///
/// Record-управление опционально (Profiler даёт, App-вкладка — нет, там запись
/// через START/STOP сессии). Если [onToggleRecording] == null — кнопка Record
/// не рисуется.
class TraceExplorer extends StatefulWidget {
  const TraceExplorer({
    super.key,
    required this.events,
    required this.unattributed,
    required this.recording,
    required this.filter,
    this.showAppTab = true,
    this.includeAppsFilter = true,
    this.recordScope,
    this.onToggleRecordScope,
    this.isRecording,
    this.onToggleRecording,
  });

  final List<TrafficEvent> events;
  final List<TrafficEvent> unattributed;
  final bool recording;

  /// Общая фильтр-модель (редактируется фильтр-окном, применяется здесь).
  final ProfilerFilter filter;

  /// Показывать ли App-таб в фильтр-окне (App-вкладка: target фиксирован → нет).
  final bool showAppTab;

  /// Применять ли app-ось к списку (App-вкладка: target фиксирован → нет).
  final bool includeAppsFilter;

  // ── Record-управление (опционально; Profiler даёт, App-вкладка — нет) ──
  final RecordingScope? recordScope;
  final void Function(RecordingScope)? onToggleRecordScope;
  final bool? isRecording;
  final VoidCallback? onToggleRecording;

  @override
  State<TraceExplorer> createState() => _TraceExplorerState();
}

enum _Mode { live, aggregated }

class _TraceExplorerState extends State<TraceExplorer> {
  _Mode _mode = _Mode.live;
  AggAxis _aggAxis = AggAxis.domain;

  // Пауза только для отображения Live: запись продолжается, список замирает
  // на снимке. Снимок фиксируется в момент паузы.
  bool _paused = false;
  List<TrafficEvent>? _frozenEvents;
  List<TrafficEvent>? _frozenUnattributed;

  ProfilerFilter get _filter => widget.filter;

  @override
  void initState() {
    super.initState();
    _filter.addListener(_onFilterChanged);
    // §044/new-profiler — подтянуть выбранное окно хранения Live (для Profiler;
    // в App-вкладке record-управления нет, но загрузка безвредна).
    TrafficProfiler.I.loadRetention().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(TraceExplorer old) {
    super.didUpdateWidget(old);
    if (old.filter != widget.filter) {
      old.filter.removeListener(_onFilterChanged);
      _filter.addListener(_onFilterChanged);
    }
  }

  @override
  void dispose() {
    _filter.removeListener(_onFilterChanged);
    super.dispose();
  }

  void _onFilterChanged() {
    if (mounted) setState(() {});
  }

  /// Ключ из детального sheet → общий поиск. Повторный тот же ключ — clear.
  /// `switchToAggregated` — для «View in Aggregated» из sheet'а агрегата.
  void _applySearchKey(String key, {bool switchToAggregated = false}) {
    final clean = key.trim();
    if (clean.isEmpty) return;
    setState(() {
      _filter.search = _filter.search == clean ? '' : clean;
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

  Future<void> _export(List<TrafficEvent> visible) async {
    final json = const JsonEncoder.withIndent('  ').convert(
      eventsToJson(visible),
    );
    if (!mounted) return;
    // Лист: Share / Copy. Делаем просто — Share с fallback на clipboard.
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.share),
              title: Text('Share ${visible.length} events (JSON)'),
              onTap: () {
                Navigator.pop(sheetCtx);
                Share.share(json, subject: 'LxBox profiler export');
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy JSON to clipboard'),
              onTap: () async {
                Navigator.pop(sheetCtx);
                await Clipboard.setData(ClipboardData(text: json));
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Export JSON copied')),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Источник: на паузе — снимок, иначе живые списки родителя.
    final srcEvents = _paused ? (_frozenEvents ?? const []) : widget.events;
    final srcUnattr =
        _paused ? (_frozenUnattributed ?? const []) : widget.unattributed;

    return Column(
      children: [
        _controlBar(context, srcEvents),
        Expanded(child: _body(context, srcEvents, srcUnattr)),
      ],
    );
  }

  /// §044/new-profiler — одна строка управления (5 affordance).
  Widget _controlBar(BuildContext context, List<TrafficEvent> srcEvents) {
    final cs = Theme.of(context).colorScheme;
    final visible = _applyFilter(srcEvents).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Row(
        children: [
          // 1 — Live / pause (только в Live-режиме).
          if (_mode == _Mode.live)
            IconButton(
              tooltip: _paused ? 'Resume' : 'Pause',
              icon: Icon(_paused ? Icons.play_arrow : Icons.pause, size: 22),
              color: _paused ? cs.error : cs.primary,
              onPressed: _togglePause,
            ),
          // 2 — Record scope (опционально).
          if (widget.onToggleRecording != null) _recordButton(context),
          // 2b — Retention (окно хранения Live) — только в Profiler.
          if (widget.onToggleRecording != null) _retentionButton(context),
          // 3 — Aggregate-меню.
          _aggregateButton(context),
          const Spacer(),
          // 4 — Filter-окно (+ бейдж активных).
          _filterButton(context),
          // 5 — Export видимого списка.
          IconButton(
            tooltip: 'Export visible events',
            icon: const Icon(Icons.download, size: 22),
            onPressed:
                visible.isEmpty ? null : () => _export(visible.toList()),
          ),
        ],
      ),
    );
  }

  /// Retention — окно хранения Live-журнала. Меню 1m / 10m / 1h.
  Widget _retentionButton(BuildContext context) {
    const opts = <(String, int)>[
      ('1m', 60),
      ('10m', 600),
      ('1h', 3600),
    ];
    final curSec = TrafficProfiler.I.retention.inSeconds;
    String curLabel() {
      for (final (l, s) in opts) {
        if (s == curSec) return l;
      }
      return '${(curSec / 60).round()}m';
    }

    return PopupMenuButton<int>(
      tooltip: 'Live retention window',
      onSelected: (sec) async {
        await TrafficProfiler.I.setRetention(Duration(seconds: sec));
        if (mounted) setState(() {});
      },
      itemBuilder: (_) => [
        for (final (label, sec) in opts)
          PopupMenuItem(
            value: sec,
            child: Row(
              children: [
                Icon(
                  sec == curSec
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Text('Keep $label'),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.history, size: 18),
            const SizedBox(width: 2),
            Text(curLabel(), style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }

  /// Record: tap = старт/стоп записи; long-press = тогл scope persistent↔tab.
  Widget _recordButton(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final on = widget.isRecording ?? false;
    final scope = widget.recordScope ?? RecordingScope.persistent;
    final persistent = scope == RecordingScope.persistent;
    return IconButton(
      tooltip: on
          ? 'Recording (${persistent ? "persistent" : "tab-scoped"}) — tap to stop, long-press: scope'
          : 'Start recording (${persistent ? "persistent" : "tab-scoped"}) — long-press: scope',
      icon: Icon(
        on ? Icons.fiber_manual_record : Icons.radio_button_unchecked,
        size: 22,
        color: on
            ? cs.error
            : (persistent ? cs.onSurfaceVariant : cs.outline),
      ),
      onPressed: widget.onToggleRecording,
      onLongPress: widget.onToggleRecordScope == null
          ? null
          : () {
              widget.onToggleRecordScope!(
                persistent
                    ? RecordingScope.tabScoped
                    : RecordingScope.persistent,
              );
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  duration: const Duration(seconds: 2),
                  content: Text(persistent
                      ? 'Recording scope: tab-scoped (stops when you leave)'
                      : 'Recording scope: persistent (keeps recording in background)'),
                ),
              );
            },
    );
  }

  /// Aggregate — кнопка-меню: Поток / by Domain / by IP.
  Widget _aggregateButton(BuildContext context) {
    final isLive = _mode == _Mode.live;
    final IconData icon;
    final String label;
    if (isLive) {
      icon = Icons.stream;
      label = 'Stream';
    } else {
      icon = Icons.summarize;
      label = _aggAxis == AggAxis.domain ? 'by Domain' : 'by IP';
    }
    return PopupMenuButton<String>(
      tooltip: 'Grouping',
      onSelected: (v) => setState(() {
        switch (v) {
          case 'stream':
            _mode = _Mode.live;
          case 'domain':
            _mode = _Mode.aggregated;
            _aggAxis = AggAxis.domain;
          case 'ip':
            _mode = _Mode.aggregated;
            _aggAxis = AggAxis.ip;
        }
        if (_mode != _Mode.live) {
          _paused = false;
          _frozenEvents = null;
          _frozenUnattributed = null;
        }
      }),
      itemBuilder: (_) => [
        _aggMenuItem('stream', Icons.stream, 'Event stream', isLive),
        _aggMenuItem('domain', Icons.summarize, 'Group by Domain',
            !isLive && _aggAxis == AggAxis.domain),
        _aggMenuItem('ip', Icons.summarize, 'Group by IP',
            !isLive && _aggAxis == AggAxis.ip),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18),
            const SizedBox(width: 4),
            Text(label, style: const TextStyle(fontSize: 12)),
            const Icon(Icons.arrow_drop_down, size: 18),
          ],
        ),
      ),
    );
  }

  PopupMenuItem<String> _aggMenuItem(
      String value, IconData icon, String label, bool selected) {
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(
            selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
            size: 18,
          ),
          const SizedBox(width: 8),
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Text(label),
        ],
      ),
    );
  }

  /// Собрать список замеченных пакетов + есть ли потеряшки — для App-таба
  /// фильтр-окна. Источник = текущие события (Live-буфер / события сессии).
  ({Set<String> apps, bool hasUnattr}) _collectSeen() {
    final apps = <String>{};
    var hasUnattr = false;
    for (final e in widget.events) {
      if (e.confidence == ConfidenceLevel.unattributed || e.process == null) {
        hasUnattr = true;
      }
      final p = e.process;
      if (p != null && p.isNotEmpty) {
        // process может быть «a,b» (secondary packages) — раскладываем.
        for (final seg in p.split(',')) {
          final t = seg.trim();
          if (t.isNotEmpty) apps.add(t);
        }
      }
    }
    for (final e in widget.unattributed) {
      if (e.confidence == ConfidenceLevel.unattributed || e.process == null) {
        hasUnattr = true;
      }
    }
    return (apps: apps, hasUnattr: hasUnattr);
  }

  void _openFilterSheet(BuildContext context) {
    final seen = _collectSeen();
    showProfilerFilterSheet(
      context,
      filter: _filter,
      showAppTab: widget.showAppTab,
      seenApps: seen.apps,
      hasUnattributed: seen.hasUnattr,
    );
  }

  /// Filter — открывает фильтр-окно, бейдж активных фильтров.
  Widget _filterButton(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // App-вкладка app-ось не применяет → не считаем её в бейдж.
    final n = widget.includeAppsFilter
        ? _filter.activeCount
        : _filter.activeCountNoApps;
    final active = n > 0;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        TextButton.icon(
          icon: Icon(Icons.filter_list,
              size: 20, color: active ? cs.primary : null),
          label: Text(active ? 'Filter ($n)' : 'Filter',
              style: TextStyle(
                  fontSize: 12, color: active ? cs.primary : null)),
          onPressed: () => _openFilterSheet(context),
        ),
        if (active)
          Positioned(
            right: 4,
            top: 2,
            child: Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: cs.primary,
                shape: BoxShape.circle,
              ),
            ),
          ),
      ],
    );
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
      search: _filter.search,
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

  Iterable<TrafficEvent> _applyFilter(Iterable<TrafficEvent> src) =>
      _filter.apply(src, includeApps: widget.includeAppsFilter);
}
