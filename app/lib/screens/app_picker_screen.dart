import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/app_info.dart';
import '../services/app_info_cache.dart';

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

class _AppPickerScreenState extends State<AppPickerScreen> {
  List<AppInfo> _allApps = [];
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
    final apps = await AppInfoCache.loadAllApps();
    if (!mounted) return;
    setState(() {
      _allApps = apps;
      _loading = false;
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

  /// Рендер иконки для tile'а через общий [AppInfoCache]. На первом проходе
  /// AppInfo обычно уже есть (loadAllApps populate'ит cache), но если pkg
  /// ещё не подъехал — kick fire-and-forget fetch и letter-placeholder.
  Widget _iconFor(AppInfo app) {
    final pkg = app.packageName;
    AppInfoCache.ensure(pkg);
    final info = AppInfoCache.of(pkg) ?? app;
    if (info.icon != null) {
      return Image.memory(info.icon!,
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

  List<AppInfo> get _filtered {
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
    final apps = _loading ? <AppInfo>[] : _filtered;

    return PopScope(
      canPop: false,
      // §108: системный back/жест обязан возвращать выбор так же, как
      // стрелка в AppBar. С пустым handler'ом (canPop=true по умолчанию)
      // роут попался с result=null — caller (`_pickApps`) молча выкидывал
      // селекцию.
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _safePop();
      },
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
                          secondary: AnimatedBuilder(
                            animation: AppInfoCache.revision,
                            builder: (_, _) => _iconFor(app),
                          ),
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
