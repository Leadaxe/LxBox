import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../models/debug_entry.dart';
import '../services/app_log.dart';
import '../services/dump_builder.dart';
import '../services/error_format.dart';
import '../services/ui_helpers.dart';
import 'app_settings_screen.dart';
import 'crash_reports_screen.dart';
import 'oom_reports_screen.dart';
import 'debug/profiling_tab.dart';
import '../services/l10n/locale_controller.dart';

class DebugScreen extends StatefulWidget {
  const DebugScreen({super.key, this.initialTab = 0});

  /// §357 — стартовая вкладка (0 Log · 1 Crashes · 2 OOM · 3 Profiling),
  /// паттерн `AppSettingsScreen.initialTab`. Используется lxbox-навигацией
  /// support-ленты (`route:debug/<tab>`, `route:profiler`).
  final int initialTab;

  @override
  State<DebugScreen> createState() => _DebugScreenState();
}

enum _DebugAction { clear, copy, diagnosticsSettings }

class _DebugScreenState extends State<DebugScreen> with SnackHelper {
  DebugFilter _sourceFilter = DebugFilter.all;
  final Set<DebugLevel> _levels = {...DebugLevel.values};
  bool _buildingDump = false;
  // Text search — case-insensitive substring match по message (night T6-3).
  String _searchQuery = '';
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  static String _entriesToText(List<DebugEntry> entries) {
    final buf = StringBuffer();
    for (final e in entries) {
      final src = e.source == DebugSource.core ? 'CORE' : 'APP ';
      final prev = e.fromPreviousSession ? ' [PREV]' : '';
      buf.writeln(
          '[${e.time.toIso8601String()}] ${e.level.name.toUpperCase().padRight(7)} $src$prev  ${e.message}');
    }
    return buf.toString();
  }

  // §219 — _snack вынесен в SnackHelper.showSnack (services/ui_helpers.dart).

  void _copyAll(List<DebugEntry> entries) {
    Clipboard.setData(ClipboardData(text: _entriesToText(entries)));
    showSnack(getLocalText.plural("%d entries copied", entries.length));
  }

  /// Собирает единый dump (config + vars + server_lists + debug-log)
  /// и открывает системный share-диалог.
  Future<void> _shareDump() async {
    if (_buildingDump) return;
    setState(() => _buildingDump = true);
    try {
      final path = await DumpBuilder.build();
      final name = path.split('/').last;
      // ignore: deprecated_member_use
      await Share.shareXFiles(
        [XFile(path, name: name, mimeType: 'application/json')],
        text: 'LxBox diagnostic dump',
        subject: name,
      );
    } catch (e) {
      if (!mounted) return;
      showSnack(getLocalText.s("Share failed: %s", formatUserError(e).render()));
    } finally {
      if (mounted) setState(() => _buildingDump = false);
    }
  }

  Color _levelColor(DebugLevel l) => switch (l) {
        DebugLevel.debug => Colors.grey,
        DebugLevel.info => Colors.blue,
        DebugLevel.warning => Colors.orange,
        DebugLevel.error => Colors.red,
      };

  /// §316 — ПОСТОЯННЫЕ вкладки. Раньше вкладка stderr появлялась только
  /// при непустом файле: пока канал был сломан, интерфейс просто молчал, и
  /// понять «крашей нет или не читается» было нельзя. Теперь «Crashes» на
  /// месте всегда и сама говорит, что крашей не было.
  ///
  /// §318 — «OOM» отдельной вкладкой рядом: снимки памяти от oom-killer'а
  /// ядра. В «Crashes» их не сливаем — паника и давление памяти это разные
  /// события, в общем списке сигнал теряется.
  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      initialIndex: widget.initialTab.clamp(0, 3),
      child: AnimatedBuilder(
        animation: AppLog.I,
        builder: (context, _) {
          final filtered = _filteredEntries();
          return Scaffold(
            appBar: AppBar(
              title: Text(getLocalText.s("Debug")),
              actions: _buildAppBarActions(filtered),
              // §318/§158 — четыре вкладки: `isScrollable` вместо равных
              // долей, иначе на узких экранах «Profiling» обрезается.
              bottom: TabBar(isScrollable: true, tabs: [
                Tab(text: getLocalText.s("Log")),
                Tab(text: getLocalText.s("Crashes")),
                Tab(text: getLocalText.s("OOM")),
                Tab(text: getLocalText.s("Profiling")),
              ]),
            ),
            body: TabBarView(children: [
              _buildLogTab(filtered),
              const CrashReportsTab(),
              const OomReportsTab(),
              const ProfilingTab(),
            ]),
          );
        },
      ),
    );
  }

  List<DebugEntry> _filteredEntries() {
    final q = _searchQuery.trim().toLowerCase();
    return AppLog.I.entries.where((e) {
      if (!_levels.contains(e.level)) return false;
      final bySource = switch (_sourceFilter) {
        DebugFilter.all => true,
        DebugFilter.core => e.source == DebugSource.core,
        DebugFilter.app => e.source == DebugSource.app,
      };
      if (!bySource) return false;
      if (q.isEmpty) return true;
      return e.message.toLowerCase().contains(q);
    }).toList();
  }

  List<Widget> _buildAppBarActions(List<DebugEntry> filtered) {
    return [
      IconButton(
        icon: _buildingDump
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.ios_share),
        tooltip: getLocalText.s("Share dump (config + vars + subs + log)"),
        onPressed: _buildingDump ? null : _shareDump,
      ),
      PopupMenuButton<_DebugAction>(
        icon: const Icon(Icons.more_vert),
        onSelected: (a) {
          switch (a) {
            case _DebugAction.clear:
              AppLog.I.clear();
            case _DebugAction.copy:
              _copyAll(filtered);
            case _DebugAction.diagnosticsSettings:
              _openDiagnosticsSettings();
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: _DebugAction.copy,
            enabled: filtered.isNotEmpty,
            child: ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: Text(getLocalText.s("Copy log")),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
          PopupMenuItem(
            value: _DebugAction.clear,
            enabled: AppLog.I.entries.isNotEmpty,
            child: ListTile(
              leading: const Icon(Icons.delete_sweep_outlined),
              title: Text(getLocalText.s("Clear")),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
          // §043/§207: shortcut в Diagnostics tab App Settings'ов — там toggle
          // "Forward sing-box logs" + Debug API + раздел Profiling (полный
          // набор pprof-кнопок: goroutine/CPU/heap/allocs).
          const PopupMenuDivider(),
          PopupMenuItem(
            value: _DebugAction.diagnosticsSettings,
            child: ListTile(
              leading: const Icon(Icons.tune),
              title: Text(getLocalText.s("Diagnostics settings")),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    ];
  }

  void _openDiagnosticsSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const AppSettingsScreen(initialTab: 2),
      ),
    );
  }

  Widget _buildLogTab(List<DebugEntry> filtered) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<DebugFilter>(
            segments: [
              ButtonSegment(
                  value: DebugFilter.all, label: Text(getLocalText.s("All"))),
              ButtonSegment(
                  value: DebugFilter.core,
                  label: Text(getLocalText.s("Core"))),
              ButtonSegment(
                  value: DebugFilter.app, label: Text(getLocalText.s("App"))),
            ],
            selected: {_sourceFilter},
            onSelectionChanged: (s) =>
                setState(() => _sourceFilter = s.first),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            children: DebugLevel.values.map((l) {
              final on = _levels.contains(l);
              return FilterChip(
                label: Text(l.name),
                selected: on,
                selectedColor: _levelColor(l).withValues(alpha: 0.2),
                onSelected: (v) => setState(() {
                  if (v) {
                    _levels.add(l);
                  } else {
                    _levels.remove(l);
                  }
                }),
              );
            }).toList(),
          ),
          const SizedBox(height: 8),
          // Search field (night T6-3). Case-insensitive substring
          // match by message. Empty = no filter.
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search, size: 18),
              hintText: getLocalText.s("Filter by text…"),
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: _searchQuery.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                    ),
            ),
            onChanged: (v) => setState(() => _searchQuery = v),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Text(_searchQuery.isNotEmpty
                        ? getLocalText.s("No matches for \"%s\"", _searchQuery)
                        : getLocalText.s("No events yet")))
                : ListView.separated(
                    itemCount: filtered.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final entry = filtered[i];
                      final src = entry.source == DebugSource.core
                          ? 'core'
                          : 'app';
                      // §038: prev-session entries (warning+error с диска)
                      // отделяем тегом «↑ prev session» + курсивом.
                      final prevTag = entry.fromPreviousSession
                          ? ' · ↑ prev session'
                          : '';
                      return ListTile(
                        dense: true,
                        leading: Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: _levelColor(entry.level),
                            shape: BoxShape.circle,
                          ),
                        ),
                        title: Text(
                          entry.message,
                          style: TextStyle(
                            fontSize: 12,
                            fontFamily: 'monospace',
                            fontStyle: entry.fromPreviousSession
                                ? FontStyle.italic
                                : FontStyle.normal,
                          ),
                        ),
                        subtitle: Text(
                          '${entry.time.toIso8601String()} · ${entry.level.name} · $src$prevTag',
                          style: const TextStyle(fontSize: 11),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

}
