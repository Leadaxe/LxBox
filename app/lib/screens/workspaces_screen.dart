import 'package:flutter/material.dart';

import '../services/format_utils.dart';
import '../services/l10n/locale_controller.dart';
import '../services/relative_time.dart';
import '../services/workspaces/workspace_controller.dart';
import '../services/workspaces/workspace_store.dart';
import 'home/widgets/workspace_menu.dart';

/// §417 — управление слотами: переименовать, удалить, размер на диске.
/// Загрузка и Save as — в попапе на главном экране, здесь их нет:
/// экран открывается поверх Home, а загрузка пересоздаёт Home.
class WorkspacesScreen extends StatefulWidget {
  const WorkspacesScreen({super.key});

  @override
  State<WorkspacesScreen> createState() => _WorkspacesScreenState();
}

class _WorkspacesScreenState extends State<WorkspacesScreen> {
  final _ws = WorkspaceController.I;
  Map<String, int> _sizes = const {};

  @override
  void initState() {
    super.initState();
    _ws.addListener(_onChanged);
    _reload();
  }

  @override
  void dispose() {
    _ws.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _reload() async {
    await _ws.refresh();
    final sizes = <String, int>{};
    for (final s in _ws.slots) {
      sizes[s.name] = await WorkspaceStore.I.slotSizeBytes(s.name);
    }
    if (mounted) setState(() => _sizes = sizes);
  }

  Future<void> _rename(String name) async {
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => WorkspaceNameDialog(
        initial: name,
        title: getLocalText.s("Rename"),
      ),
    );
    if (newName == null || newName == name || !mounted) return;
    try {
      await _ws.rename(name, newName);
    } on WorkspaceError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(workspaceErrorText(e))));
    }
    await _reload();
  }

  Future<void> _delete(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(getLocalText.s(
            "Delete workspace “%s”?", workspaceDisplayName(name))),
        content: Text(getLocalText.s(
            "Its saved state will be removed. This cannot be undone.")),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(getLocalText.s("Cancel")),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(getLocalText.s("Delete")),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _ws.delete(name);
    } on WorkspaceError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(workspaceErrorText(e))));
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final slots = [..._ws.slots]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return Scaffold(
      appBar: AppBar(title: Text(getLocalText.s("Workspaces"))),
      body: slots.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  getLocalText.s("No workspaces saved yet"),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge,
                ),
              ),
            )
          : ListView.builder(
              itemCount: slots.length,
              itemBuilder: (context, i) {
                final s = slots[i];
                final isCurrent = s.name == _ws.current;
                final size = _sizes[s.name];
                final parts = [
                  relativeTime(now, s.savedAt),
                  if (size != null) formatBytes(size, spaced: true),
                  if (isCurrent) getLocalText.s("Current"),
                ];
                return ListTile(
                  leading: Icon(
                    isCurrent
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: isCurrent ? theme.colorScheme.primary : null,
                  ),
                  title: Text(workspaceDisplayName(s.name)),
                  subtitle: Text(parts.join(' · ')),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) => switch (v) {
                      'rename' => _rename(s.name),
                      'delete' => _delete(s.name),
                      _ => null,
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'rename',
                        child: Text(getLocalText.s("Rename")),
                      ),
                      // current — адрес автосохранения, удалить нельзя.
                      PopupMenuItem(
                        value: 'delete',
                        enabled: !isCurrent,
                        child: Text(getLocalText.s("Delete")),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
