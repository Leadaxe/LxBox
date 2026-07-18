import 'package:flutter/material.dart';

import '../../models/app_info.dart';
import '../../services/app_info_cache.dart';
import '../../services/l10n/locale_controller.dart';

/// §044/new-profiler — **встраиваемый** мульти-select пикер приложений для
/// фильтр-окна профайлера (App-таб). В отличие от
/// [SingleAppPickerScreen] (полноэкранный, `Navigator.pop(package)` по тапу),
/// этот — виджет внутри таба: чекбоксы + накопление в [selected], без навигации.
///
/// Источник списка и icon-cache те же (`AppInfoCache.loadAllApps` + `ensure`),
/// чтобы не грузить иконки дважды.
class AppMultiPicker extends StatefulWidget {
  const AppMultiPicker({
    super.key,
    required this.selected,
    required this.onToggle,
  });

  /// Текущий набор выбранных пакетов (пустой = фильтра нет). Управляется
  /// родителем (фильтр-окно) — пикер только тоглит через [onToggle].
  final Set<String> selected;
  final void Function(String packageName, bool selected) onToggle;

  @override
  State<AppMultiPicker> createState() => _AppMultiPickerState();
}

class _AppMultiPickerState extends State<AppMultiPicker> {
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
    // Выбранные — наверх (чтобы видеть активный фильтр без скролла).
    list.sort((a, b) {
      final sa = widget.selected.contains(a.packageName) ? 0 : 1;
      final sb = widget.selected.contains(b.packageName) ? 0 : 1;
      if (sa != sb) return sa - sb;
      return a.appName.toLowerCase().compareTo(b.appName.toLowerCase());
    });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                decoration: InputDecoration(
                  hintText: getLocalText.s("Search by name or package"),
                  prefixIcon: const Icon(Icons.search, size: 18),
                  border: const OutlineInputBorder(),
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                style: const TextStyle(fontSize: 13),
                onChanged: (v) => setState(() => _search = v),
              ),
            ),
            IconButton(
              tooltip: getLocalText.s(1, "Show system apps"),
              visualDensity: VisualDensity.compact,
              icon: Icon(
                _showSystem ? Icons.visibility : Icons.visibility_off,
                size: 20,
              ),
              onPressed: () => setState(() => _showSystem = !_showSystem),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Flexible(
          child: _loading
              // Грузим весь список установленных приложений (loadAllApps) — на
              // устройстве с 200+ apps это пара секунд. Текст вместо голого
              // спиннера, чтобы не выглядело зависшим. Иконки догрузятся лениво.
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 12),
                        Text(getLocalText.s("Loading installed apps…"),
                            style: const TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                )
              : _filtered.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(getLocalText.s("No apps match"),
                            style: const TextStyle(fontSize: 12)),
                      ),
                    )
                  : ListView.builder(
                  itemCount: _filtered.length,
                  itemBuilder: (_, i) {
                    final a = _filtered[i];
                    AppInfoCache.ensure(a.packageName);
                    final checked = widget.selected.contains(a.packageName);
                    return AnimatedBuilder(
                      animation: AppInfoCache.revision,
                      builder: (_, _) {
                        final info = AppInfoCache.of(a.packageName);
                        Widget leading;
                        if (info?.icon != null) {
                          leading = ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: Image.memory(info!.icon!,
                                width: 28, height: 28, gaplessPlayback: true),
                          );
                        } else {
                          leading = SizedBox(
                            width: 28,
                            height: 28,
                            child: CircleAvatar(
                              backgroundColor: cs.surfaceContainerHighest,
                              child: Text(
                                a.appName.isEmpty
                                    ? '?'
                                    : a.appName.characters.first.toUpperCase(),
                                style:
                                    TextStyle(fontSize: 11, color: cs.onSurface),
                              ),
                            ),
                          );
                        }
                        return CheckboxListTile(
                          value: checked,
                          onChanged: (v) =>
                              widget.onToggle(a.packageName, v ?? false),
                          controlAffinity: ListTileControlAffinity.leading,
                          dense: true,
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 4),
                          secondary: leading,
                          title: Text(a.appName,
                              style: const TextStyle(fontSize: 13)),
                          subtitle: Text(a.packageName,
                              style: const TextStyle(
                                  fontSize: 10, fontFamily: 'monospace')),
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}
