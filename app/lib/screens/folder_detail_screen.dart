import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/subscription_controller.dart';
import '../models/server_list.dart';
import '../services/error_format.dart';
import '../services/subscription/input_helpers.dart';
import '../services/tag_resolver.dart';
import 'subscription_detail_screen/detour_mode.dart';
import 'subscription_detail_screen/widgets/subscription_settings_tab.dart';
import 'subscriptions_screen/folder_picker.dart';
import '../widgets/reorder_grab_strip.dart';

/// §234 — экран папки серверов. Зеркалит SubscriptionDetailScreen: вкладка
/// членов (per-member toggle, drag-reorder, long-press меню) + Settings
/// (общий SubscriptionSettingsTab: tag prefix / detour на всю папку).
class FolderDetailScreen extends StatefulWidget {
  const FolderDetailScreen({
    super.key,
    required this.entry,
    required this.controller,
  });

  final SubscriptionEntry entry;
  final SubscriptionController controller;

  @override
  State<FolderDetailScreen> createState() => _FolderDetailScreenState();
}

class _FolderDetailScreenState extends State<FolderDetailScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabCtrl;
  bool _editing = false;
  late TextEditingController _nameCtrl;

  FolderServers get _folder => widget.entry.list as FolderServers;

  /// Индекс entry по ссылке — список мог сместиться (reorder/delete).
  int get _index => widget.controller.entries.indexOf(widget.entry);

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    _nameCtrl = TextEditingController(text: widget.entry.name);
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  void _toggleEdit() {
    if (_editing) {
      final name = _nameCtrl.text.trim();
      final idx = _index;
      if (idx >= 0 && name.isNotEmpty) {
        unawaited(widget.controller.renameAt(idx, name));
      }
    }
    setState(() => _editing = !_editing);
  }

  Future<void> _delete() async {
    // Три исхода: cancel / вынести серверы одиночными / удалить всё.
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete folder?'),
        content: Text(_folder.members.isEmpty
            ? 'Remove "${widget.entry.displayName}"?'
            : 'Folder "${widget.entry.displayName}" contains '
                '${_folder.members.length} server(s).'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          if (_folder.members.isNotEmpty)
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'keep'),
              child: const Text('Keep servers'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'all'),
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.error),
            child: Text(_folder.members.isEmpty
                ? 'Delete'
                : 'Delete folder & servers'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    final idx = _index;
    if (idx < 0) {
      if (mounted) Navigator.pop(context);
      return;
    }
    await widget.controller
        .deleteFolderAt(idx, keepServers: choice == 'keep');
    if (mounted) Navigator.pop(context);
  }

  // ─────────────────────────── Add flows ───────────────────────────

  Future<void> _showError(String err) async {
    if (err.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
  }

  Future<void> _addFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      await _showError('Clipboard is empty');
      return;
    }
    final idx = _index;
    if (idx < 0) return;
    final err = await widget.controller.addMembersToFolder(idx, text);
    await _showError(err);
    if (err.isEmpty) setState(() {});
  }

  Future<void> _addFromFiles() async {
    try {
      final result =
          await FilePicker.pickFiles(withData: true, allowMultiple: true);
      if (result == null || result.files.isEmpty) return;
      var added = 0;
      final errors = <String>[];
      for (final file in result.files) {
        String text;
        if (file.bytes != null && file.bytes!.isNotEmpty) {
          text = String.fromCharCodes(file.bytes!);
        } else if (file.path != null) {
          text = await File(file.path!).readAsString();
        } else {
          continue;
        }
        text = text.trim();
        if (text.isEmpty) continue;
        final idx = _index;
        if (idx < 0) return;
        final err = await widget.controller.addMembersToFolder(
          idx,
          text,
          nameFallback: SubscriptionController.fileBaseName(file.name),
        );
        if (err.isEmpty) {
          added++;
        } else {
          errors.add('${file.name}: $err');
        }
      }
      if (!mounted) return;
      if (errors.isNotEmpty) {
        await _showError(errors.join('\n'));
      } else if (added == 0) {
        await _showError('No servers found in selected files');
      }
      setState(() {});
    } catch (e) {
      await _showError('Error: ${formatUserError(e)}');
    }
  }

  Future<void> _addFromUrl() async {
    final ctl = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add servers by URL'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'URL',
                hintText: 'https://…',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
              autocorrect: false,
            ),
            const SizedBox(height: 8),
            Text(
              'Fetched once — servers are added as a snapshot and '
              'won\'t auto-update. For live updates add a subscription instead.',
              style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
            child: const Text('Fetch'),
          ),
        ],
      ),
    );
    ctl.dispose();
    if (url == null || url.isEmpty || !mounted) return;
    if (!isSubscriptionUrl(url)) {
      await _showError('Enter a valid http(s):// URL');
      return;
    }
    final idx = _index;
    if (idx < 0) return;
    final err = await widget.controller.addUrlSnapshotToFolder(idx, url);
    await _showError(err);
    if (err.isEmpty) setState(() {});
  }

  // ───────────────────────── Member actions ─────────────────────────

  Future<void> _editMember(int memberIndex) async {
    final member = _folder.members[memberIndex];
    final ctl = TextEditingController(text: member.raw);
    final newRaw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit server'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLines: 8,
          minLines: 3,
          style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: 'Proxy link, WireGuard config or outbound JSON',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctl.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    ctl.dispose();
    if (newRaw == null || !mounted) return;
    final idx = _index;
    if (idx < 0) return;
    final err = await widget.controller.updateMemberAt(idx, memberIndex, newRaw);
    await _showError(err);
    if (err.isEmpty) setState(() {});
  }

  Future<void> _moveMember(int memberIndex) async {
    final toIndex = await showFolderPicker(context, widget.controller,
        excludeId: widget.entry.id);
    if (toIndex == null || !mounted) return;
    final idx = _index;
    if (idx < 0) return;
    final err =
        await widget.controller.moveMemberToFolder(idx, memberIndex, toIndex);
    await _showError(err);
    if (err.isEmpty) setState(() {});
  }

  Future<void> _ungroupMember(int memberIndex) async {
    final idx = _index;
    if (idx < 0) return;
    await widget.controller.ungroupMemberAt(idx, memberIndex);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Moved out of folder')),
    );
    setState(() {});
  }

  Future<void> _deleteMember(int memberIndex) async {
    final member = _folder.members[memberIndex];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete server?'),
        content: Text('Remove "${_memberTitle(member)}" from this folder?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final idx = _index;
    if (idx < 0) return;
    await widget.controller.removeMemberAt(idx, memberIndex);
    setState(() {});
  }

  void _showMemberMenu(int memberIndex) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit…'),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_editMember(memberIndex));
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_move_outline),
              title: const Text('Move to folder…'),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_moveMember(memberIndex));
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_off_outlined),
              title: const Text('Move out of folder'),
              subtitle: const Text('Becomes a standalone server'),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_ungroupMember(memberIndex));
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: Theme.of(ctx).colorScheme.error),
              title: Text('Delete',
                  style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_deleteMember(memberIndex));
              },
            ),
          ],
        ),
      ),
    );
  }

  static String _memberTitle(FolderMember m) {
    final node = m.node;
    if (node == null) {
      final line = m.raw.split('\n').first.trim();
      return line.length > 40 ? '${line.substring(0, 40)}…' : line;
    }
    return node.label.isNotEmpty ? node.label : node.tag;
  }

  // ───────────────────────────── build ─────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: widget.entry,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: _editing
              ? TextField(
                  controller: _nameCtrl,
                  autofocus: true,
                  style: theme.textTheme.titleLarge,
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    hintText: 'Folder name',
                  ),
                  onSubmitted: (_) => _toggleEdit(),
                )
              : Row(
                  children: [
                    const Icon(Icons.folder_outlined, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.entry.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
          actions: [
            IconButton(
              tooltip: _editing ? 'Save' : 'Rename',
              icon: Icon(_editing ? Icons.check : Icons.edit_outlined),
              onPressed: _toggleEdit,
            ),
            PopupMenuButton<String>(
              tooltip: 'Add servers',
              icon: const Icon(Icons.add),
              onSelected: (v) {
                if (v == 'paste') unawaited(_addFromClipboard());
                if (v == 'file') unawaited(_addFromFiles());
                if (v == 'url') unawaited(_addFromUrl());
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                    value: 'paste', child: Text('Paste from clipboard')),
                PopupMenuItem(value: 'file', child: Text('Import from files…')),
                PopupMenuItem(value: 'url', child: Text('Add by URL…')),
              ],
            ),
            IconButton(
              tooltip: 'Delete folder',
              icon: const Icon(Icons.delete_outline),
              onPressed: _delete,
            ),
          ],
          bottom: TabBar(
            controller: _tabCtrl,
            tabs: const [
              Tab(text: 'Servers'),
              Tab(text: 'Settings'),
            ],
          ),
        ),
        body: TabBarView(
          controller: _tabCtrl,
          children: [
            _buildMembersTab(theme),
            _buildSettingsTab(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildMembersTab(ThemeData theme) {
    final members = _folder.members;
    if (members.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.folder_open,
                  size: 48, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text('Folder is empty', style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                'Add servers with the + button above, or long-press a '
                'standalone server on the Servers screen and choose '
                '"Move to folder…".',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }
    return ReorderableListView.builder(
      padding: EdgeInsets.fromLTRB(
          12, 4, 12, MediaQuery.of(context).padding.bottom + 24),
      buildDefaultDragHandles: false,
      itemCount: members.length,
      onReorder: (oldIndex, newIndex) {
        if (newIndex > oldIndex) newIndex -= 1;
        final idx = _index;
        if (idx < 0) return;
        unawaited(widget.controller.reorderMember(idx, oldIndex, newIndex));
      },
      itemBuilder: (context, i) {
        final m = members[i];
        return _MemberTile(
          key: ValueKey('member-$i-${m.raw.hashCode}'),
          member: m,
          dragIndex: i,
          folderEnabled: widget.entry.enabled,
          onToggle: () {
            final idx = _index;
            if (idx < 0) return;
            unawaited(widget.controller
                .toggleMemberAt(idx, i)
                .then((_) => mounted ? setState(() {}) : null));
          },
          onLongPress: () => _showMemberMenu(i),
          onTap: () => _showMemberMenu(i),
        );
      },
    );
  }

  Widget _buildSettingsTab(ThemeData theme) {
    final hasDetour = _folder.nodes.any((n) => n.chained != null);
    return SubscriptionSettingsTab(
      entry: widget.entry,
      hasDetour: hasDetour,
      detourMode: _detourMode,
      onTagPrefixChanged: (val) {
        widget.entry.tagPrefix = val.trim();
        unawaited(widget.controller.persistSources());
      },
      onSetDetourMode: _setDetourMode,
      onRegisterDetourServersChanged: (val) {
        setState(() => widget.entry.registerDetourServers = val);
        unawaited(widget.controller.persistSources());
      },
      onRegisterDetourInAutoChanged: (val) {
        setState(() => widget.entry.registerDetourInAuto = val);
        unawaited(widget.controller.persistSources());
      },
      onShowOverrideDetourPicker: () => _showOverrideDetourPicker(),
      onReplaceDetourChainChanged: (val) {
        setState(() => widget.entry.replaceDetourChain = val);
        unawaited(widget.controller.persistSources());
      },
      // Subscription-only колбэки — для папки блок скрыт
      // (`entry.list is SubscriptionServers` false), no-op заглушки.
      onCopyUrl: () {},
      onShowIntervalPicker: () {},
      onRefreshNow: () {},
      onEditSource: () {},
    );
  }

  DetourMode get _detourMode {
    if (!widget.entry.useDetourServers) return DetourMode.none;
    if (widget.entry.overrideDetour.isNotEmpty) return DetourMode.override;
    return DetourMode.use;
  }

  void _setDetourMode(DetourMode mode) {
    setState(() {
      switch (mode) {
        case DetourMode.use:
          widget.entry.useDetourServers = true;
          widget.entry.overrideDetour = '';
        case DetourMode.override:
          widget.entry.useDetourServers = true;
          if (widget.entry.overrideDetour.isEmpty) {
            unawaited(_showOverrideDetourPicker());
          }
        case DetourMode.none:
          widget.entry.useDetourServers = false;
          widget.entry.overrideDetour = '';
      }
    });
    unawaited(widget.controller.persistSources());
  }

  Future<void> _showOverrideDetourPicker() async {
    // Кандидаты: ноды одиночных UserServer и ДРУГИХ папок (enabled). Свои
    // ноды исключены — detour в собственную ноду = цикл. Display-form тег
    // (§080 — как в subscription detail).
    final tags = <String>[];
    for (final e in widget.controller.entries) {
      final list = e.list;
      if (!list.enabled) continue;
      if (list is UserServer ||
          (list is FolderServers && list.id != widget.entry.id)) {
        for (final n in list.nodes) {
          if (n.tag.isEmpty) continue;
          tags.add(TagResolver.displayTag(list.tagPrefix, n.tag));
        }
      }
    }

    if (!mounted) return;
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Override detour'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, ''),
            child: const Text('None (use original)'),
          ),
          ...tags.map((tag) => SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, tag),
                child: Text(tag),
              )),
        ],
      ),
    );
    if (chosen == null) return;
    setState(() {
      widget.entry.overrideDetour = chosen;
      if (chosen.isNotEmpty) widget.entry.useDetourServers = true;
    });
    unawaited(widget.controller.persistSources());
  }
}

/// Строка члена папки: toggle + имя ноды + протокол/адрес. Grab-strip слева
/// для drag-reorder (§098-паттерн).
class _MemberTile extends StatelessWidget {
  const _MemberTile({
    super.key,
    required this.member,
    required this.dragIndex,
    required this.folderEnabled,
    required this.onToggle,
    required this.onLongPress,
    required this.onTap,
  });

  final FolderMember member;
  final int dragIndex;
  final bool folderEnabled;
  final VoidCallback onToggle;
  final VoidCallback onLongPress;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final node = member.node;
    final active = member.enabled && folderEnabled;
    final muted = theme.colorScheme.onSurfaceVariant;
    final title = node == null
        ? 'Unreadable entry'
        : (node.label.isNotEmpty ? node.label : node.tag);
    final subtitle = node == null
        ? 'Tap to edit or delete'
        : '${node.protocol.toUpperCase()} · ${node.server}:${node.port}';

    final tile = ListTile(
      contentPadding: EdgeInsets.zero,
      leading: SizedBox(
        width: 40,
        child: Switch(
          value: member.enabled,
          onChanged: (_) => onToggle(),
        ),
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: active ? null : muted,
          fontStyle: node == null ? FontStyle.italic : null,
        ),
      ),
      subtitle: Text(subtitle,
          style: TextStyle(fontSize: 12, color: muted),
          maxLines: 1,
          overflow: TextOverflow.ellipsis),
      onLongPress: onLongPress,
      onTap: onTap,
    );
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ReorderGrabStrip(index: dragIndex),
          Expanded(
            child: Column(
              children: [
                tile,
                const Divider(height: 1),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
