import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../vpn/box_vpn_client.dart';

/// Cached app metadata list — loaded once, reused across screen opens.
/// Иконки **не** тут, они lazy-cache'атся в `_iconCache` при scroll'е tile'а.
List<_AppInfo>? _cachedApps;
bool _cacheLoading = false;

/// Session-level icon cache: package → decoded PNG bytes (или null если
/// native вернул пусто). Персистит между открытиями picker'а — на повторном
/// открытии иконки мгновенные. Сброс только при перезапуске app'а.
final Map<String, Uint8List?> _iconCache = {};

/// Package'и, для которых уже запущен fetch (дедуп fire-and-forget).
final Set<String> _iconInFlight = {};

Future<List<_AppInfo>> _loadApps() async {
  if (_cachedApps != null) return _cachedApps!;
  if (_cacheLoading) {
    while (_cacheLoading) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    return _cachedApps ?? [];
  }
  _cacheLoading = true;
  try {
    final vpn = BoxVpnClient();
    final apps = await vpn.getInstalledApps();
    _cachedApps = apps
        .map((m) => _AppInfo(
              packageName: m['packageName'] as String? ?? '',
              appName: m['appName'] as String? ?? '',
              isSystem: m['isSystemApp'] as bool? ?? false,
            ))
        .toList()
      ..sort((a, b) =>
          a.appName.toLowerCase().compareTo(b.appName.toLowerCase()));
    return _cachedApps!;
  } finally {
    _cacheLoading = false;
  }
}

/// Screen for selecting apps. Returns updated list of package names on pop.
class AppPickerResult {
  AppPickerResult({required this.packages});
  final List<String> packages;
}

class AppPickerScreen extends StatefulWidget {
  const AppPickerScreen({super.key, required this.selected});

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
  List<_AppInfo> _allApps = [];
  late final Set<String> _selected;
  bool _loading = true;
  bool _showSystem = false;
  bool _popped = false; // guard от двойного Navigator.pop
  String _search = '';

  @override
  void initState() {
    super.initState();
    _selected = Set<String>.from(widget.selected);
    // Let build() render the preloader first.
    Future.delayed(const Duration(milliseconds: 300), _load);
  }

  Future<void> _load() async {
    final apps = await _loadApps();
    if (!mounted) return;
    setState(() {
      _allApps = apps;
      _loading = false;
    });
  }

  /// Lazy-fetch иконки для одного пакета. Fire-and-forget: вызывается из
  /// itemBuilder'а tile'а, дедупится через `_iconInFlight`. Когда ответ
  /// пришёл — setState чтобы tile перерисовался.
  void _ensureIcon(String pkg) {
    if (_iconCache.containsKey(pkg) || _iconInFlight.contains(pkg)) return;
    _iconInFlight.add(pkg);
    BoxVpnClient().getAppIcon(pkg).then((b64) {
      _iconInFlight.remove(pkg);
      Uint8List? bytes;
      if (b64.isNotEmpty) {
        try {
          bytes = base64Decode(b64);
        } catch (_) {}
      }
      _iconCache[pkg] = bytes;
      if (mounted) setState(() {});
    });
  }

  void _safePop() {
    if (_popped) return;
    _popped = true;
    Navigator.pop(
      context,
      AppPickerResult(packages: _selected.toList()),
    );
  }

  /// Рендер иконки для tile'а: если в cache — Image, если нет — letter-avatar
  /// плюс kick fire-and-forget fetch (ленивая подгрузка по мере scroll'а).
  Widget _iconFor(_AppInfo app) {
    final pkg = app.packageName;
    if (!_iconCache.containsKey(pkg)) _ensureIcon(pkg);
    final bytes = _iconCache[pkg];
    if (bytes != null) {
      return Image.memory(bytes,
          width: 36, height: 36, gaplessPlayback: true);
    }
    // Placeholder: первая буква имени в circle avatar.
    final letter = app.appName.isNotEmpty
        ? app.appName.characters.first.toUpperCase()
        : '?';
    return SizedBox(
      width: 36,
      height: 36,
      child: CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Text(letter,
            style: TextStyle(
              fontSize: 14,
              color: Theme.of(context).colorScheme.onSurface,
            )),
      ),
    );
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
    if (!mounted) return;
    final text = data?.text ?? '';
    if (text.isEmpty) return;
    final pkgs = text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet();
    final known = _allApps.map((a) => a.packageName).toSet();
    final added = pkgs.intersection(known);
    setState(() => _selected.addAll(added));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${added.length} packages imported')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final apps = _loading ? <_AppInfo>[] : _filtered;

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {},
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Select apps'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _safePop,
          ),
          actions: [
            PopupMenuButton<String>(
              onSelected: (v) {
                // Bulk-actions бессмысленны пока список не загрузился.
                if (_loading && v != 'system') return;
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
                PopupMenuItem(
                    value: 'select_all',
                    enabled: !_loading,
                    child: const Text('Select all')),
                PopupMenuItem(
                    value: 'deselect_all',
                    enabled: !_loading,
                    child: const Text('Deselect all')),
                PopupMenuItem(
                    value: 'invert',
                    enabled: !_loading,
                    child: const Text('Invert')),
                const PopupMenuDivider(),
                PopupMenuItem(
                    value: 'import',
                    enabled: !_loading,
                    child: const Text('Import from clipboard')),
                const PopupMenuItem(
                    value: 'export', child: Text('Export to clipboard')),
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
                          secondary: _iconFor(app),
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
