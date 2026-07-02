// §044 / §160 — Per-app trace tab. Третий tab в `StatsScreen`. Показывает
// recording state, target picker, тогл Live / Aggregated + общий фильтр,
// overflow menu (verbose toggle / wipe / share / help), in-tab banner для
// verbose-active state.
//
// §160 дизайн-решения (свернули 4 саб-таба → 2 режима):
// - **Тогл `Live / Aggregated`** (SegmentedButton) вместо TabBar(4).
//   Connections удалён — его роль = Live + чип TCP/UDP + детали по тапу.
//   Domains+IPs слиты в Aggregated с вторичной осью by Domain / by IP.
// - **Общий фильтр** сверху (поиск + чипы типа события) — один на оба
//   режима; чипы типа активны только в Live (в Aggregated событий нет).
// - **Drill-down по тапу**: Live строка → детали события; Aggregated
//   строка → свод + список соединений → conn → детали события. Sheet'ы
//   общие (`stats_screen/{traffic_event,aggregate}_detail_sheet.dart`),
//   рассчитаны на переиспользование в Stats→Live (будущий шаг).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../services/traffic_profiler.dart';
import '../services/format_utils.dart';
import '../widgets/core_logs_hint_banner.dart';
import 'app_picker_screen.dart';
import 'stats_screen/profiler_filter.dart';
import 'stats_screen/trace_explorer.dart';
import 'per_app_trace_tab/session_json.dart';
import 'per_app_trace_tab/single_app_picker_screen.dart';
import 'per_app_trace_tab/trace_dialogs.dart';
import 'per_app_trace_tab/trace_sections.dart';

class PerAppTraceTab extends StatefulWidget {
  const PerAppTraceTab({super.key});

  @override
  State<PerAppTraceTab> createState() => _PerAppTraceTabState();
}

class _PerAppTraceTabState extends State<PerAppTraceTab> {
  String? _pendingTarget; // выбран но ещё не started
  bool _verbose = false;
  bool _verboseActiveInSession = false;
  // §048 Принцип 3 — secondary packages (WebView etc) для будущей session'и.
  // На время active session — Live setter через TrafficProfiler.updateSecondaryPackages.
  final Set<String> _pendingSecondaryPackages = <String>{};
  Timer? _ticker; // для refresh «Recording 02:34» каждую секунду

  // §044/new-profiler — фильтр (типы + поиск); app-ось скрыта (target фиксирован
  // сессией). Общая модель, редактируется фильтр-окном через TraceExplorer.
  final ProfilerFilter _filter = ProfilerFilter();

  @override
  void initState() {
    super.initState();
    TrafficProfiler.I.addListener(_onProfilerChanged);
    // §219 — профайлер питается push-стримом CcChannel.connections (§168/§176),
    // подключённым в HomeScreen; здесь только слушаем его агрегат. Поллинга нет
    // (старый Runtime fetcher / clashClient удалены в §122).
    _onProfilerChanged();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && TrafficProfiler.I.isRecording) setState(() {});
    });
  }

  void _onProfilerChanged() {
    if (!mounted) return;
    setState(() {
      final s = TrafficProfiler.I.active;
      if (s != null) {
        _verboseActiveInSession = s.wasVerbose;
        _pendingTarget = s.targetPackage;
      }
    });
  }

  @override
  void dispose() {
    TrafficProfiler.I.removeListener(_onProfilerChanged);
    _ticker?.cancel();
    _filter.dispose();
    super.dispose();
  }

  Future<void> _pickApp() async {
    final pkg = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const SingleAppPickerScreen()),
    );
    if (pkg == null || !mounted) return;
    setState(() => _pendingTarget = pkg);
  }

  Future<void> _toggleRecording() async {
    final profiler = TrafficProfiler.I;
    if (profiler.isRecording) {
      await profiler.stop();
    } else {
      final target = _pendingTarget;
      if (target == null) return;
      await profiler.start(
        target,
        verbose: _verbose,
        secondaryPackages: _pendingSecondaryPackages.isEmpty
            ? null
            : Set<String>.of(_pendingSecondaryPackages),
      );
    }
    if (!mounted) return;
    setState(() {});
  }

  /// §048 Принцип 3 — multi-select picker для secondary packages
  /// (WebView/system-process subprocess'ы). Открывает существующий
  /// AppPickerScreen с pre-checked текущим выбором, target package
  /// исключается из selectable списка (нельзя добавить его в secondary).
  Future<void> _pickSecondaryPackages() async {
    final result = await Navigator.of(context).push<AppPickerResult>(
      MaterialPageRoute(
        builder: (_) => AppPickerScreen(
          selected: Set<String>.of(_pendingSecondaryPackages),
        ),
      ),
    );
    if (result == null || !mounted) return;
    final newSet = result.packages.toSet()..remove(_pendingTarget);
    setState(() {
      _pendingSecondaryPackages
        ..clear()
        ..addAll(newSet);
    });
    // Если идёт recording — применяем live.
    if (TrafficProfiler.I.isRecording) {
      TrafficProfiler.I.updateSecondaryPackages(newSet);
    }
  }

  Future<void> _toggleVerbose(bool value) async {
    setState(() => _verbose = value);
    // Если сейчас active session — изменить уже nothing нельзя без reload,
    // показываем snackbar.
    if (TrafficProfiler.I.isRecording) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Verbose toggle takes effect on next session — stop and restart.'),
        ),
      );
    }
  }

  Future<void> _shareSession(Session s) async {
    final json = const JsonEncoder.withIndent('  ').convert(sessionToJson(s));
    await Share.share(json, subject: 'LxBox session ${s.targetPackage}');
  }

  Future<void> _copySession(Session s) async {
    final json = const JsonEncoder.withIndent('  ').convert(sessionToJson(s));
    await Clipboard.setData(ClipboardData(text: json));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Session JSON copied to clipboard')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profiler = TrafficProfiler.I;
    final session = profiler.active;
    return Column(
      children: [
        if (_verboseActiveInSession && session != null)
          verboseBanner(context),
        if (session != null && profiler.unattributedBannerActive)
          unattributedBanner(context),
        _header(context, session),
        if (session != null) _statsRow(context, session),
        if (session != null) _secondaryPackagesRow(context, session),
        const SizedBox(height: 4),
        const CoreLogsHintBanner(),
        // §160 — общий движок Live/Aggregated+фильтр+детали. Источник —
        // события активной сессии (per-app trace).
        Expanded(
          child: TraceExplorer(
            events: session?.events ?? const [],
            unattributed: session == null
                ? const []
                : TrafficProfiler.I.globalUnattributedEvents
                    .where((e) => !e.ts.isBefore(session.startedAt))
                    .toList(),
            recording: profiler.isRecording,
            filter: _filter,
            // App-вкладка: target зафиксирован сессией → app-таб/ось не нужны;
            // запись через START/STOP сессии в хедере (не record-кнопкой).
            showAppTab: false,
            includeAppsFilter: false,
          ),
        ),
        if (session == null && profiler.completed.isNotEmpty)
          savedSessions(context, onShare: _shareSession),
      ],
    );
  }

  Widget _header(BuildContext context, Session? active) {
    final cs = Theme.of(context).colorScheme;
    final target = active?.targetPackage ?? _pendingTarget;
    final canRecord = target != null;
    final isRecording = active != null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: isRecording ? null : _pickApp,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: cs.outlineVariant),
                  color: cs.surface,
                ),
                child: Row(
                  children: [
                    Icon(Icons.android, size: 18, color: cs.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        target ?? 'Pick an app to trace…',
                        style: TextStyle(
                          fontSize: 14,
                          color: target == null ? cs.onSurfaceVariant : null,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (!isRecording)
                      Icon(Icons.arrow_drop_down,
                          color: cs.onSurfaceVariant, size: 20),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: canRecord ? _toggleRecording : null,
            icon: Icon(isRecording ? Icons.stop : Icons.play_arrow,
                size: 18),
            label: Text(isRecording ? 'STOP' : 'START'),
            style: FilledButton.styleFrom(
              backgroundColor:
                  isRecording ? cs.error : cs.primary,
              foregroundColor: isRecording ? cs.onError : cs.onPrimary,
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              switch (v) {
                case 'verbose-on':
                  await _toggleVerbose(true);
                case 'verbose-off':
                  await _toggleVerbose(false);
                case 'share':
                  if (active != null) await _shareSession(active);
                case 'copy':
                  if (active != null) await _copySession(active);
                case 'wipe':
                  showWipeAllDialog(context);
                case 'help':
                  showHelpDialog(context);
              }
            },
            itemBuilder: (_) => [
              CheckedPopupMenuItem(
                value: _verbose ? 'verbose-off' : 'verbose-on',
                checked: _verbose,
                child: const Text('Verbose core logs (debug)'),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'copy',
                enabled: active != null,
                child: const ListTile(
                  leading: Icon(Icons.copy),
                  title: Text('Copy session JSON'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'share',
                enabled: active != null,
                child: const ListTile(
                  leading: Icon(Icons.share),
                  title: Text('Share session'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'wipe',
                child: ListTile(
                  leading: Icon(Icons.delete_outline),
                  title: Text('Clear all sessions'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'help',
                child: ListTile(
                  leading: Icon(Icons.help_outline),
                  title: Text('Help'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statsRow(BuildContext context, Session s) {
    final cs = Theme.of(context).colorScheme;
    final dur = (s.finishedAt ?? DateTime.now()).difference(s.startedAt);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Row(
        children: [
          Icon(Icons.fiber_manual_record, size: 12, color: cs.error),
          const SizedBox(width: 6),
          Text(
            s.finishedAt == null ? 'Recording' : 'Stopped',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          const SizedBox(width: 8),
          Text(formatDuration(dur),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          const SizedBox(width: 16),
          Text('${s.byDomain.length} doms · ${s.byIp.length} ips · ${s.events.length} ev',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          if (s.eventsDropped > 0) ...[
            const SizedBox(width: 8),
            Text('· ${s.eventsDropped} dropped',
                style: TextStyle(fontSize: 12, color: cs.error)),
          ],
        ],
      ),
    );
  }

  /// §048 Принцип 3 — chip-row для secondary packages (WebView etc).
  /// Tap → multi-select picker. Показывается под header'ом session'и.
  Widget _secondaryPackagesRow(BuildContext context, Session s) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Row(
        children: [
          Icon(Icons.link, size: 14, color: cs.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Wrap(
              spacing: 4,
              runSpacing: 2,
              children: [
                if (s.secondaryPackages.isEmpty)
                  Text('No secondary packages',
                      style: TextStyle(
                          fontSize: 11, color: cs.onSurfaceVariant)),
                for (final pkg in s.secondaryPackages)
                  Chip(
                    label: Text(pkg, style: const TextStyle(fontSize: 11)),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: _pickSecondaryPackages,
            icon: const Icon(Icons.add, size: 14),
            label: const Text('Edit secondary',
                style: TextStyle(fontSize: 11)),
            style: TextButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }

}
