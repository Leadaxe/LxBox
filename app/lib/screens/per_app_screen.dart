import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/settings_storage.dart';
import '../vpn/box_vpn_client.dart';

class PerAppScreen extends StatefulWidget {
  const PerAppScreen({super.key});

  @override
  State<PerAppScreen> createState() => _PerAppScreenState();
}

enum _Mode { off, include, exclude }

class _AppInfo {
  _AppInfo({required this.packageName, required this.appName, required this.isSystem});
  final String packageName;
  final String appName;
  final bool isSystem;
}

class _PerAppScreenState extends State<PerAppScreen> {
  final _vpn = BoxVpnClient();
  List<_AppInfo> _allApps = [];
  final _selected = <String>{};
  _Mode _mode = _Mode.off;
  bool _loading = true;
  bool _showSystem = false;
  bool _dirty = false;
  String _search = '';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final modeStr = await SettingsStorage.getPerAppMode();
    final list = await SettingsStorage.getPerAppList();
    final apps = await _vpn.getInstalledApps();

    final parsed = apps.map((m) => _AppInfo(
          packageName: m['packageName'] as String? ?? '',
          appName: m['appName'] as String? ?? '',
          isSystem: m['isSystemApp'] as bool? ?? false,
        )).toList()
      ..sort((a, b) => a.appName.toLowerCase().compareTo(b.appName.toLowerCase()));

    if (mounted) {
      setState(() {
        _allApps = parsed;
        _selected.addAll(list);
        _mode = switch (modeStr) {
          'include' => _Mode.include,
          'exclude' => _Mode.exclude,
          _ => _Mode.off,
        };
        _loading = false;
      });
    }
  }

  Future<void> _apply() async {
    final modeStr = switch (_mode) {
      _Mode.include => 'include',
      _Mode.exclude => 'exclude',
      _Mode.off => 'off',
    };
    await SettingsStorage.savePerApp(modeStr, _selected.toList());
    await _vpn.setPerAppProxy(modeStr, _selected.toList());
    _dirty = false;
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Per-app proxy saved. Restart VPN to apply.')),
      );
    }
  }

  List<_AppInfo> get _filtered {
    var list = _allApps.where((a) => _showSystem || !a.isSystem).toList();
    if (_search.isNotEmpty) {
      final q = _search.toLowerCase();
      list = list.where((a) =>
          a.appName.toLowerCase().contains(q) ||
          a.packageName.toLowerCase().contains(q)).toList();
    }
    // Selected first
    list.sort((a, b) {
      final sa = _selected.contains(a.packageName) ? 0 : 1;
      final sb = _selected.contains(b.packageName) ? 0 : 1;
      if (sa != sb) return sa.compareTo(sb);
      return a.appName.toLowerCase().compareTo(b.appName.toLowerCase());
    });
    return list;
  }

  void _selectAll() {
    setState(() {
      for (final a in _filtered) {
        _selected.add(a.packageName);
      }
      _dirty = true;
    });
  }

  void _deselectAll() {
    setState(() {
      _selected.clear();
      _dirty = true;
    });
  }

  void _invert() {
    setState(() {
      final visible = _filtered.map((a) => a.packageName).toSet();
      final newSelected = visible.difference(_selected);
      _selected.removeAll(visible);
      _selected.addAll(newSelected);
      _dirty = true;
    });
  }

  Future<void> _exportToClipboard() async {
    final text = _selected.join('\n');
    await Clipboard.setData(ClipboardData(text: text));
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
    final packages = text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
    final known = _allApps.map((a) => a.packageName).toSet();
    final added = packages.intersection(known);
    setState(() {
      _selected.addAll(added);
      _dirty = true;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${added.length} packages imported')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Per-App Proxy')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final apps = _filtered;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Per-App Proxy'),
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
          // Mode selector
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: SegmentedButton<_Mode>(
              segments: const [
                ButtonSegment(value: _Mode.off, label: Text('Off')),
                ButtonSegment(value: _Mode.include, label: Text('Include')),
                ButtonSegment(value: _Mode.exclude, label: Text('Exclude')),
              ],
              selected: {_mode},
              onSelectionChanged: (s) {
                setState(() {
                  _mode = s.first;
                  _dirty = true;
                });
              },
            ),
          ),
          if (_mode != _Mode.off) ...[
            // Hint
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                _mode == _Mode.include
                    ? 'Only checked apps will use VPN'
                    : 'All apps except checked will use VPN',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
            // Search
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
            // Count
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                '${_selected.length} selected · ${apps.length} shown',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
            // App list
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
                        _dirty = true;
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
          ] else
            const Expanded(
              child: Center(
                child: Text('Per-app proxy is off.\nAll apps use VPN.'),
              ),
            ),
          // Apply button
          if (_dirty)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => unawaited(_apply()),
                    child: const Text('Apply'),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
