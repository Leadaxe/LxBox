import 'package:flutter/material.dart';

import '../../models/app_info.dart';
import '../../services/app_info_cache.dart';
import '../../services/l10n/l10n.dart';

class SingleAppPickerScreen extends StatefulWidget {
  const SingleAppPickerScreen({super.key});

  @override
  State<SingleAppPickerScreen> createState() => _SingleAppPickerScreenState();
}

class _SingleAppPickerScreenState extends State<SingleAppPickerScreen> {
  List<AppInfo> _apps = [];
  bool _loading = true;
  bool _showSystem = false;
  String _search = '';

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 50), _load);
  }

  Future<void> _load() async {
    try {
      final apps = await AppInfoCache.loadAllApps();
      if (!mounted) return;
      setState(() {
        _apps = apps;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<AppInfo> get _filtered {
    var list = _apps.where((a) => _showSystem || !a.isSystem).toList();
    if (_search.isNotEmpty) {
      final q = _search.toLowerCase();
      list = list
          .where((a) =>
              a.appName.toLowerCase().contains(q) ||
              a.packageName.toLowerCase().contains(q))
          .toList();
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l.statsTracePickAppTitle),
        actions: [
          IconButton(
            tooltip: context.l.statsTraceShowSystemApps,
            icon: Icon(
              _showSystem ? Icons.visibility : Icons.visibility_off,
            ),
            onPressed: () => setState(() => _showSystem = !_showSystem),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              decoration: InputDecoration(
                hintText: context.l.statsTraceSearchApps,
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _search = v),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: _filtered.length,
                    itemBuilder: (_, i) {
                      final a = _filtered[i];
                      AppInfoCache.ensure(a.packageName);
                      return AnimatedBuilder(
                        animation: AppInfoCache.revision,
                        builder: (_, _) {
                          final info = AppInfoCache.of(a.packageName);
                          Widget leading;
                          if (info?.icon != null) {
                            leading = ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: Image.memory(info!.icon!,
                                  width: 32, height: 32, gaplessPlayback: true),
                            );
                          } else {
                            leading = SizedBox(
                              width: 32,
                              height: 32,
                              child: CircleAvatar(
                                backgroundColor: cs.surfaceContainerHighest,
                                child: Text(
                                  a.appName.isEmpty
                                      ? '?'
                                      : a.appName.characters.first
                                          .toUpperCase(),
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: cs.onSurface),
                                ),
                              ),
                            );
                          }
                          return ListTile(
                            leading: leading,
                            title: Text(a.appName,
                                style: const TextStyle(fontSize: 14)),
                            subtitle: Text(a.packageName,
                                style: const TextStyle(
                                    fontSize: 11, fontFamily: 'monospace')),
                            onTap: () =>
                                Navigator.pop(context, a.packageName),
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
