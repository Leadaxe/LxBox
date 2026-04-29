import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../models/debug_entry.dart';
import '../services/app_log.dart';
import '../services/dump_builder.dart';
import '../services/stderr_reader.dart';

class DebugScreen extends StatefulWidget {
  const DebugScreen({super.key});

  @override
  State<DebugScreen> createState() => _DebugScreenState();
}

enum _DebugAction { clear, copy }

class _DebugScreenState extends State<DebugScreen> {
  DebugFilter _sourceFilter = DebugFilter.all;
  final Set<DebugLevel> _levels = {...DebugLevel.values};
  bool _buildingDump = false;
  // Text search — case-insensitive substring match по message (night T6-3).
  String _searchQuery = '';
  final _searchController = TextEditingController();

  /// §038 MVP1 — содержимое `filesDir/stderr.log`. Грузится async в
  /// initState; null означает «файл отсутствует/пуст» — в этом случае
  /// TabBar не показываем (никакого следа от Go panic — нечего смотреть).
  String? _stderrText;
  bool _stderrLoading = true;

  @override
  void initState() {
    super.initState();
    _loadStderr();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadStderr() async {
    final text = await StderrReader.read();
    if (!mounted) return;
    setState(() {
      _stderrText = text;
      _stderrLoading = false;
    });
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

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _copyAll(List<DebugEntry> entries) {
    Clipboard.setData(ClipboardData(text: _entriesToText(entries)));
    _snack('${entries.length} entries copied');
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
      _snack('Share failed: $e');
    } finally {
      if (mounted) setState(() => _buildingDump = false);
    }
  }

  /// §038 — поделиться файлом stderr.log напрямую (без обёртки в
  /// Dump-pack). Stderr содержит Go panic-stacktrace и иногда имена
  /// outbound'ов / host'ов, но не пароли.
  Future<void> _shareStderr() async {
    final p = await StderrReader.path();
    if (p == null) {
      _snack('stderr is empty');
      return;
    }
    try {
      final ts = DateTime.now().toIso8601String();
      // ignore: deprecated_member_use
      await Share.shareXFiles(
        [XFile(p, name: p.split('/').last, mimeType: 'text/plain')],
        subject: 'L×Box stderr — $ts',
      );
    } catch (e) {
      _snack('Share failed: $e');
    }
  }

  Color _levelColor(DebugLevel l) => switch (l) {
        DebugLevel.debug => Colors.grey,
        DebugLevel.info => Colors.blue,
        DebugLevel.warning => Colors.orange,
        DebugLevel.error => Colors.red,
      };

  @override
  Widget build(BuildContext context) {
    final showStderrTab =
        !_stderrLoading && _stderrText != null && _stderrText!.isNotEmpty;
    final scaffold = AnimatedBuilder(
      animation: AppLog.I,
      builder: (context, _) {
        final filtered = _filteredEntries();
        return Scaffold(
          appBar: AppBar(
            title: const Text('Debug'),
            actions: _buildAppBarActions(filtered),
            bottom: showStderrTab
                ? const TabBar(tabs: [Tab(text: 'Log'), Tab(text: 'stderr')])
                : null,
          ),
          body: showStderrTab
              ? TabBarView(children: [_buildLogTab(filtered), _buildStderrTab()])
              : _buildLogTab(filtered),
        );
      },
    );
    return showStderrTab
        ? DefaultTabController(length: 2, child: scaffold)
        : scaffold;
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
        tooltip: 'Отправить дамп (config + vars + subs + log)',
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
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: _DebugAction.copy,
            enabled: filtered.isNotEmpty,
            child: const ListTile(
              leading: Icon(Icons.copy_outlined),
              title: Text('Copy log'),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
          PopupMenuItem(
            value: _DebugAction.clear,
            enabled: AppLog.I.entries.isNotEmpty,
            child: const ListTile(
              leading: Icon(Icons.delete_sweep_outlined),
              title: Text('Clear'),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    ];
  }

  Widget _buildLogTab(List<DebugEntry> filtered) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<DebugFilter>(
            segments: const [
              ButtonSegment(value: DebugFilter.all, label: Text('All')),
              ButtonSegment(value: DebugFilter.core, label: Text('Core')),
              ButtonSegment(value: DebugFilter.app, label: Text('App')),
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
              hintText: 'Filter by text…',
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
                        ? 'No matches for "$_searchQuery"'
                        : 'No events yet'))
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

  /// §038 stderr-tab. Plain SelectableText в monospace + кнопки Refresh
  /// (перечитывает) и Share (отдаёт файлы напрямую через share_plus).
  Widget _buildStderrTab() {
    final text = _stderrText ?? '';
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Go runtime stderr from libbox / sing-box. '
                  'Survives SIGABRT — useful for diagnosing native crashes.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 20),
                tooltip: 'Re-read stderr.log',
                onPressed: () async {
                  setState(() => _stderrLoading = true);
                  await _loadStderr();
                },
              ),
              IconButton(
                icon: const Icon(Icons.ios_share, size: 20),
                tooltip: 'Share stderr.log files',
                onPressed: _shareStderr,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              text,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                height: 1.3,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

