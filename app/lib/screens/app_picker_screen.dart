import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../vpn/box_vpn_client.dart';

/// Cached app list — loaded once, reused across screen opens.
List<_AppInfo>? _cachedApps;
bool _cacheLoading = false;

Future<List<_AppInfo>> _loadApps() async {
  if (_cachedApps != null) return _cachedApps!;
  if (_cacheLoading) {
    // Another call is already loading — wait for it
    while (_cacheLoading) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    return _cachedApps ?? [];
  }
  _cacheLoading = true;
  try {
    final vpn = BoxVpnClient();
    final apps = await vpn.getInstalledApps();
    _cachedApps = apps.map((m) {
      final iconStr = m['icon'] as String? ?? '';
      Uint8List? iconBytes;
      if (iconStr.isNotEmpty) {
        try { iconBytes = base64Decode(iconStr); } catch (_) {}
      }
      return _AppInfo(
        packageName: m['packageName'] as String? ?? '',
        appName: m['appName'] as String? ?? '',
        isSystem: m['isSystemApp'] as bool? ?? false,
        iconBytes: iconBytes,
      );
    }).toList()
      ..sort((a, b) => a.appName.toLowerCase().compareTo(b.appName.toLowerCase()));
    return _cachedApps!;
  } finally {
    _cacheLoading = false;
  }
}

/// Screen for selecting apps to include in an App Rule.
/// Returns the updated list of package names on pop.
class AppPickerResult {
  AppPickerResult({required this.packages, required this.name});
  final List<String> packages;
  final String name;
}

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
  _AppInfo({required this.packageName, required this.appName, required this.isSystem, this.iconBytes});
  final String packageName;
  final String appName;
  final bool isSystem;
  final Uint8List? iconBytes;
}

class _AppPickerScreenState extends State<AppPickerScreen> {
  List<_AppInfo> _allApps = [];
  late final Set<String> _selected;
  late final TextEditingController _nameCtrl;
  bool _loading = true;
  bool _showSystem = false;
  bool _editingName = false;
  String _search = '';

  @override
  void initState() {
    super.initState();
    _selected = Set<String>.from(widget.selected);
    _nameCtrl = TextEditingController(text: widget.ruleName);
    // Don't load here — let build() render the preloader first
    Future.delayed(const Duration(milliseconds: 100), _load);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final apps = await _loadApps();
    if (mounted) setState(() { _allApps = apps; _loading = false; });
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
    final apps = _loading ? <_AppInfo>[] : _filtered;

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {},
      child: Scaffold(
        appBar: AppBar(
          title: _editingName
              ? TextField(
                  controller: _nameCtrl,
                  autofocus: true,
                  style: Theme.of(context).textTheme.titleLarge,
                  decoration: const InputDecoration(border: InputBorder.none, hintText: 'Group name'),
                  onSubmitted: (_) => setState(() => _editingName = false),
                )
              : GestureDetector(
                  onTap: () => setState(() => _editingName = true),
                  child: Text(_nameCtrl.text),
                ),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(context, AppPickerResult(
              packages: _selected.toList(),
              name: _nameCtrl.text.trim(),
            )),
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
            if (_loading) const LinearProgressIndicator(),
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
                _loading
                    ? 'Loading apps...'
                    : '${_selected.length} selected \u00b7 ${apps.length} shown',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
            Expanded(
              child: _loading
                  ? const SizedBox.shrink()
                  : ListView.builder(
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
                          secondary: app.iconBytes != null
                              ? Image.memory(app.iconBytes!, width: 36, height: 36, gaplessPlayback: true)
                              : const Icon(Icons.android, size: 36),
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
