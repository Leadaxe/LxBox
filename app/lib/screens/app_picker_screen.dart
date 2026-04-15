import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../vpn/box_vpn_client.dart';

/// Screen for selecting apps to include in an App Rule.
/// Returns the updated list of package names on pop.
class AppPickerScreen extends StatefulWidget {
  const AppPickerScreen({
    super.key,
    required this.ruleName,
    required this.selected,
  });

  final String ruleName;
  final Set<String> selected;

  @override
  State<AppPickerScreen> createState() => _AppPickerScreenState();
}

class _AppInfo {
  _AppInfo({required this.packageName, required this.appName, required this.isSystem});
  final String packageName;
  final String appName;
  final bool isSystem;
}

class _AppPickerScreenState extends State<AppPickerScreen> {
  final _vpn = BoxVpnClient();
  List<_AppInfo> _allApps = [];
  late final Set<String> _selected;
  bool _loading = true;
  bool _showSystem = false;
  String _search = '';

  @override
  void initState() {
    super.initState();
    _selected = Set<String>.from(widget.selected);
    unawaited(_load());
  }

  Future<void> _load() async {
    final apps = await _vpn.getInstalledApps();
    final parsed = apps.map((m) => _AppInfo(
          packageName: m['packageName'] as String? ?? '',
          appName: m['appName'] as String? ?? '',
          isSystem: m['isSystemApp'] as bool? ?? false,
        )).toList()
      ..sort((a, b) => a.appName.toLowerCase().compareTo(b.appName.toLowerCase()));

    if (mounted) setState(() { _allApps = parsed; _loading = false; });
  }

  List<_AppInfo> get _filtered {
    var list = _allApps.where((a) => _showSystem || !a.isSystem).toList();
    if (_search.isNotEmpty) {
      final q = _search.toLowerCase();
      list = list.where((a) =>
          a.appName.toLowerCase().contains(q) ||
          a.packageName.toLowerCase().contains(q)).toList();
    }
    list.sort((a, b) {
      final sa = _selected.contains(a.packageName) ? 0 : 1;
      final sb = _selected.contains(b.packageName) ? 0 : 1;
      if (sa != sb) return sa.compareTo(sb);
      return a.appName.toLowerCase().compareTo(b.appName.toLowerCase());
    });
    return list;
  }

  void _selectAll() => setState(() {
    for (final a in _filtered) { _selected.add(a.packageName); }
  });

  void _deselectAll() => setState(() => _selected.clear());

  void _invert() => setState(() {
    final visible = _filtered.map((a) => a.packageName).toSet();
    final newSel = visible.difference(_selected);
    _selected.removeAll(visible);
    _selected.addAll(newSel);
  });

  Future<void> _exportToClipboard() async {
    await Clipboard.setData(ClipboardData(text: _selected.join('\n')));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${_selected.length} packages copied')),
      );
    }
  }

  Future<void> _importFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.isEmpty) return;
    final pkgs = text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
    final known = _allApps.map((a) => a.packageName).toSet();
    setState(() => _selected.addAll(pkgs.intersection(known)));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${pkgs.intersection(known).length} packages imported')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.ruleName)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final apps = _filtered;

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        // Return selected on pop regardless
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.ruleName),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(context, _selected.toList()),
          ),
          actions: [
            PopupMenuButton<String>(
              onSelected: (v) {
                switch (v) {
                  case 'select_all': _selectAll();
                  case 'deselect_all': _deselectAll();
                  case 'invert': _invert();
                  case 'export': unawaited(_exportToClipboard());
                  case 'import': unawaited(_importFromClipboard());
                  case 'system': setState(() => _showSystem = !_showSystem);
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'select_all', child: Text('Select all')),
                const PopupMenuItem(value: 'deselect_all', child: Text('Deselect all')),
                const PopupMenuItem(value: 'invert', child: Text('Invert')),
                const PopupMenuDivider(),
                const PopupMenuItem(value: 'import', child: Text('Import from clipboard')),
                const PopupMenuItem(value: 'export', child: Text('Export to clipboard')),
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: 'system',
                  child: Text(_showSystem ? 'Hide system apps' : 'Show system apps'),
                ),
              ],
            ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: TextField(
                decoration: const InputDecoration(
                  hintText: 'Search apps...',
                  prefixIcon: Icon(Icons.search, size: 20),
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
                style: const TextStyle(fontSize: 14),
                onChanged: (v) => setState(() => _search = v),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                '${_selected.length} selected · ${apps.length} shown',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: apps.length,
                itemBuilder: (context, i) {
                  final app = apps[i];
                  final checked = _selected.contains(app.packageName);
                  return CheckboxListTile(
                    value: checked,
                    onChanged: (v) {
                      setState(() {
                        if (v == true) {
                          _selected.add(app.packageName);
                        } else {
                          _selected.remove(app.packageName);
                        }
                      });
                    },
                    title: Text(
                      app.appName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14),
                    ),
                    subtitle: Text(
                      app.packageName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11),
                    ),
                    dense: true,
                    controlAffinity: ListTileControlAffinity.trailing,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
