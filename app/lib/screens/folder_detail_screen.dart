import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/subscription_controller.dart';
import '../models/server_list.dart';
import '../services/error_format.dart';
import '../services/probe/probe_runner.dart';
import '../services/settings_storage.dart';
import '../services/subscription/input_helpers.dart';
import '../services/tag_resolver.dart';
import 'home/filter_widgets.dart';
import 'home/node_list_presenter.dart' show protoLabel;
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

  // §236 — состояние Test servers. Результаты эфемерны (не персистятся).
  final Map<int, ProbeResult> _probe = {};
  FolderProbeRunner? _runner;
  bool _testing = false;
  ProbeThresholds _thresholds = const ProbeThresholds();

  // §236 UI-rework — локальный фильтр членов (как на главном: regex +
  // протоколы). Тоже эфемерный (осознанно не сохраняется, ср. §048).
  final _filterRegexCtl = TextEditingController();
  bool _filterExpanded = false;
  bool _regexInvert = false;
  final Set<String> _selectedProtocols = {};
  bool _protocolsInvert = false;

  FolderServers get _folder => widget.entry.list as FolderServers;

  /// Индекс entry по ссылке — список мог сместиться (reorder/delete).
  int get _index => widget.controller.entries.indexOf(widget.entry);

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    _nameCtrl = TextEditingController(text: widget.entry.name);
    unawaited(_loadThresholds());
  }

  @override
  void dispose() {
    // Отмена доводит run() до finally → probeStop (сессия не повисает).
    _runner?.cancel();
    _tabCtrl.dispose();
    _nameCtrl.dispose();
    _filterRegexCtl.dispose();
    super.dispose();
  }

  Future<void> _loadThresholds() async {
    final g = int.tryParse(await SettingsStorage.getVar('probe_ms_green', ''));
    final y = int.tryParse(await SettingsStorage.getVar('probe_ms_yellow', ''));
    final o = int.tryParse(await SettingsStorage.getVar('probe_ms_orange', ''));
    if (!mounted) return;
    setState(() {
      _thresholds = ProbeThresholds(
        greenMs: g ?? 250,
        yellowMs: y ?? 500,
        orangeMs: o ?? 700,
      );
    });
  }

  // ─────────────────────── §236 — Test servers ───────────────────────

  Future<void> _toggleTest() async {
    if (_testing) {
      _runner?.cancel();
      setState(() => _testing = false);
      return;
    }
    if (_folder.members.isEmpty) return;
    final ping = await SettingsStorage.getPingOptions();
    final url = (ping['url'] as String?)?.trim() ?? '';
    final timeoutMs = (ping['timeout_ms'] as num?)?.toInt() ?? 3000;
    if (!mounted) return;
    setState(() {
      _testing = true;
      _probe
        ..clear()
        ..addEntries([
          for (var i = 0; i < _folder.members.length; i++)
            MapEntry(i, const ProbeResult(ProbeStatus.pending)),
        ]);
    });
    final runner = FolderProbeRunner();
    _runner = runner;
    final err = await runner.run(
      _folder,
      url: url,
      timeoutMs: timeoutMs,
      onResult: (i, r) {
        if (!mounted) return;
        setState(() => _probe[i] = r);
      },
    );
    if (!mounted) return;
    setState(() => _testing = false);
    if (err.isNotEmpty) {
      await _showError(err);
      return;
    }
    // §236 UI-rework — при живом VPN выключенные члены не в конфиге →
    // не тестировались. Говорим явно попапом, а не только бейджами.
    final skipped = _probeSummary().skipped;
    if (skipped > 0 && mounted) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('VPN is running'),
          content: Text(
              '$skipped disabled server(s) were not tested — they are not '
              'part of the running config. Stop VPN and run the test again '
              'to test every server in this folder.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  /// §236 UI-rework — настройки теста (long-press на кнопке, как на главном):
  /// цель пинга (глобальные ping_options) + пороги цветовой шкалы.
  void _showTestSettings() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('Ping URL & timeout…'),
              subtitle: const Text('Shared with the home screen ping'),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_editPingTarget());
              },
            ),
            ListTile(
              leading: const Icon(Icons.palette_outlined),
              title: const Text('Ping color thresholds…'),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_editThresholds());
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editPingTarget() async {
    final ping = await SettingsStorage.getPingOptions();
    if (!mounted) return;
    final urlCtl =
        TextEditingController(text: (ping['url'] as String?) ?? '');
    final timeoutCtl = TextEditingController(
        text: '${(ping['timeout_ms'] as num?)?.toInt() ?? 3000}');
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ping target'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: urlCtl,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Test URL',
                hintText: 'empty = core default',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: timeoutCtl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Timeout, ms',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save')),
        ],
      ),
    );
    final url = urlCtl.text.trim();
    final timeout = int.tryParse(timeoutCtl.text.trim());
    urlCtl.dispose();
    timeoutCtl.dispose();
    if (saved != true || !mounted) return;
    await SettingsStorage.setGlobalPingUrl(url);
    if (timeout != null && timeout > 0) {
      await SettingsStorage.setGlobalPingTimeout(timeout);
    }
  }

  /// Число завершённых тестов (для строки-сводки).
  ({int ok, int dead, int broken, int skipped}) _probeSummary() {
    var ok = 0, dead = 0, broken = 0, skipped = 0;
    for (final r in _probe.values) {
      switch (r.status) {
        case ProbeStatus.ok:
          ok++;
        case ProbeStatus.failed:
          dead++;
        case ProbeStatus.broken:
        case ProbeStatus.invalid:
          broken++;
        case ProbeStatus.notInConfig:
          skipped++;
        case ProbeStatus.pending:
          break;
      }
    }
    return (ok: ok, dead: dead, broken: broken, skipped: skipped);
  }

  Future<void> _disableSlowerThan() async {
    final ctl = TextEditingController(text: '${_thresholds.orangeMs}');
    final ms = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Disable slow servers'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Slower than, ms',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, int.tryParse(ctl.text.trim())),
            child: const Text('Disable'),
          ),
        ],
      ),
    );
    ctl.dispose();
    if (ms == null || !mounted) return;
    final slow = <int>{
      for (final e in _probe.entries)
        if (e.value.status == ProbeStatus.ok && e.value.delayMs > ms) e.key,
    };
    if (slow.isEmpty) {
      await _showError('No tested servers slower than $ms ms');
      return;
    }
    final idx = _index;
    if (idx < 0) return;
    await widget.controller.setMembersEnabled(idx, slow, false);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Disabled ${slow.length} server(s) > $ms ms')),
    );
    setState(() {});
  }

  Future<void> _deleteUnreachable() async {
    final dead = <int>{
      for (final e in _probe.entries)
        if (e.value.status == ProbeStatus.failed ||
            e.value.status == ProbeStatus.broken ||
            e.value.status == ProbeStatus.invalid)
          e.key,
    };
    if (dead.isEmpty) {
      await _showError('No unreachable or broken servers in last test');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete unreachable?'),
        content: Text('Remove ${dead.length} server(s) that failed the test '
            '(unreachable or broken)?'),
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
    await widget.controller.removeMembersAt(idx, dead);
    if (!mounted) return;
    // Индексы съехали — результаты по оставшимся неатрибутируемы. Сброс.
    setState(() => _probe.clear());
  }

  Future<void> _sortByPing() async {
    final idx = _index;
    if (idx < 0) return;
    final n = _folder.members.length;
    int rank(int i) {
      final r = _probe[i];
      if (r == null) return 1 << 30;
      return switch (r.status) {
        ProbeStatus.ok => r.delayMs,
        ProbeStatus.pending || ProbeStatus.notInConfig => 1 << 30,
        // err/broken — в конец, ниже нетестированных.
        ProbeStatus.failed ||
        ProbeStatus.broken ||
        ProbeStatus.invalid =>
          (1 << 30) + 1,
      };
    }

    final order = [for (var i = 0; i < n; i++) i]
      ..sort((a, b) {
        final byRank = rank(a).compareTo(rank(b));
        return byRank != 0 ? byRank : a.compareTo(b); // stable
      });
    await widget.controller.applyMembersOrder(idx, order);
    if (!mounted) return;
    // Перепривязка результатов к новым индексам.
    final remapped = <int, ProbeResult>{};
    for (var newI = 0; newI < order.length; newI++) {
      final r = _probe[order[newI]];
      if (r != null) remapped[newI] = r;
    }
    setState(() {
      _probe
        ..clear()
        ..addAll(remapped);
    });
  }

  Future<void> _editThresholds() async {
    final g = TextEditingController(text: '${_thresholds.greenMs}');
    final y = TextEditingController(text: '${_thresholds.yellowMs}');
    final o = TextEditingController(text: '${_thresholds.orangeMs}');
    Widget field(TextEditingController c, String label) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: TextField(
            controller: c,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: label,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
        );
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ping color thresholds'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            field(g, 'Green up to, ms'),
            field(y, 'Yellow up to, ms'),
            field(o, 'Orange up to, ms'),
            Text(
              'Anything above is red.',
              style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save')),
        ],
      ),
    );
    final gv = int.tryParse(g.text.trim());
    final yv = int.tryParse(y.text.trim());
    final ov = int.tryParse(o.text.trim());
    g.dispose();
    y.dispose();
    o.dispose();
    if (saved != true || !mounted) return;
    final next = ProbeThresholds(
      greenMs: (gv == null || gv <= 0) ? 250 : gv,
      yellowMs: (yv == null || yv <= 0) ? 500 : yv,
      orangeMs: (ov == null || ov <= 0) ? 700 : ov,
    );
    await SettingsStorage.setVar('probe_ms_green', '${next.greenMs}');
    await SettingsStorage.setVar('probe_ms_yellow', '${next.yellowMs}');
    await SettingsStorage.setVar('probe_ms_orange', '${next.orangeMs}');
    if (!mounted) return;
    setState(() => _thresholds = next);
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
    final visible = _visibleMembers();
    final Widget list;
    if (_filterActive) {
      // §236 UI-rework — при активном фильтре drag-reorder выключен (индексы
      // отфильтрованного вида не соответствуют составу папки).
      list = ListView.builder(
        padding: EdgeInsets.fromLTRB(
            12, 4, 12, MediaQuery.of(context).padding.bottom + 24),
        itemCount: visible.length,
        itemBuilder: (context, vi) {
          final (i, m) = visible[vi];
          return _memberTile(i, m, reorderable: false);
        },
      );
    } else {
      list = ReorderableListView.builder(
        padding: EdgeInsets.fromLTRB(
            12, 4, 12, MediaQuery.of(context).padding.bottom + 24),
        buildDefaultDragHandles: false,
        itemCount: members.length,
        onReorder: (oldIndex, newIndex) {
          if (newIndex > oldIndex) newIndex -= 1;
          final idx = _index;
          if (idx < 0) return;
          unawaited(widget.controller.reorderMember(idx, oldIndex, newIndex));
          // §236 — ручной drag во время/после теста: результаты по индексам,
          // перепривязываем как в _sortByPing (иначе бейджи съедут).
          if (_probe.isNotEmpty) {
            final r = _probe.remove(oldIndex);
            final shifted = <int, ProbeResult>{};
            _probe.forEach((k, v) {
              var nk = k;
              if (k > oldIndex) nk--;
              if (nk >= newIndex) nk++;
              shifted[nk] = v;
            });
            if (r != null) shifted[newIndex] = r;
            setState(() {
              _probe
                ..clear()
                ..addAll(shifted);
            });
          }
        },
        itemBuilder: (context, i) =>
            _memberTile(i, members[i], reorderable: true),
      );
    }
    return Column(
      children: [
        _buildControlBar(theme),
        if (_filterExpanded) _buildFilterPanel(theme),
        const Divider(height: 1),
        Expanded(child: list),
      ],
    );
  }

  Widget _memberTile(int i, FolderMember m, {required bool reorderable}) {
    return _MemberTile(
      key: ValueKey('member-$i-${m.raw.hashCode}'),
      member: m,
      dragIndex: i,
      reorderable: reorderable,
      folderEnabled: widget.entry.enabled,
      probe: _probe[i],
      thresholds: _thresholds,
      onToggle: () {
        final idx = _index;
        if (idx < 0) return;
        unawaited(widget.controller
            .toggleMemberAt(idx, i)
            .then((_) => mounted ? setState(() {}) : null));
      },
      onLongPress: () => _showMemberMenu(i),
      onTap: () => _showMemberMenu(i),
      onProbeBadgeTap: () {
        final r = _probe[i];
        if (r == null || r.message.isEmpty) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(r.message)),
        );
      },
    );
  }

  // ─── §236 UI-rework — полоса: инфо · действия · тест · фильтр ──────────

  /// Полоса над списком (паттерн главного экрана): слева инфо/сводка теста,
  /// справа — actions (при результатах), кнопка теста (`Icons.speed`, тап =
  /// старт/отмена, long-press = настройки) и toggle фильтра (`filter_list`).
  Widget _buildControlBar(ThemeData theme) {
    final muted = theme.colorScheme.onSurfaceVariant;
    final s = _probeSummary();
    final String info;
    if (_testing) {
      info = 'Testing… ${s.ok + s.dead} done';
    } else if (_probe.isNotEmpty) {
      info = '${s.ok} ok · ${s.dead} err'
          '${s.broken > 0 ? ' · ${s.broken} broken' : ''}'
          '${s.skipped > 0 ? ' · ${s.skipped} not tested' : ''}';
    } else {
      final total = _folder.members.length;
      final off = _folder.disabledCount;
      info =
          '$total server${total == 1 ? '' : 's'}${off > 0 ? ' · $off off' : ''}';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(info, style: TextStyle(fontSize: 12, color: muted)),
          ),
          // Кнопка теста — как mass-ping на главном (Icons.speed / stop),
          // long-press = настройки теста (URL/timeout + пороги шкалы).
          GestureDetector(
            onTap: _folder.members.isEmpty
                ? null
                : () => unawaited(_toggleTest()),
            onLongPress: _showTestSettings,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(
                _testing ? Icons.stop_circle_outlined : Icons.speed,
                size: 22,
                color: _folder.members.isEmpty
                    ? Theme.of(context).disabledColor
                    : null,
              ),
            ),
          ),
          // Toggle фильтра — как на главном (§048): primary + точка при
          // активных фильтрах.
          IconButton(
            tooltip: _filterExpanded ? 'Hide filters' : 'Show filters',
            visualDensity: VisualDensity.compact,
            onPressed: () =>
                setState(() => _filterExpanded = !_filterExpanded),
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(
                  Icons.filter_list,
                  size: 20,
                  color: _filterActive ? theme.colorScheme.primary : null,
                ),
                if (_filterActive)
                  Positioned(
                    right: -2,
                    top: -2,
                    child: IgnorePointer(
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Colors.amber,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (_probe.isNotEmpty && !_testing)
            PopupMenuButton<String>(
              tooltip: 'Test actions',
              icon: const Icon(Icons.more_vert, size: 20),
              onSelected: (v) {
                if (v == 'disable_slow') unawaited(_disableSlowerThan());
                if (v == 'delete_dead') unawaited(_deleteUnreachable());
                if (v == 'sort') unawaited(_sortByPing());
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                    value: 'disable_slow',
                    child: Text('Disable slower than…')),
                PopupMenuItem(
                    value: 'delete_dead', child: Text('Delete unreachable')),
                PopupMenuItem(value: 'sort', child: Text('Sort by ping')),
              ],
            ),
        ],
      ),
    );
  }

  bool get _filterActive =>
      _filterRegexCtl.text.trim().isNotEmpty || _selectedProtocols.isNotEmpty;

  bool get _regexValid {
    final t = _filterRegexCtl.text.trim();
    if (t.isEmpty) return true;
    try {
      RegExp(t);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Члены, проходящие фильтр, парами (оригинальный индекс, член) — probe и
  /// bulk-операции работают по оригинальным индексам состава.
  List<(int, FolderMember)> _visibleMembers() {
    RegExp? re;
    final pattern = _filterRegexCtl.text.trim();
    if (pattern.isNotEmpty) {
      try {
        re = RegExp(pattern, caseSensitive: false);
      } catch (_) {
        re = null; // битый regex = фильтр не применяем (поле подсветится)
      }
    }
    final out = <(int, FolderMember)>[];
    for (var i = 0; i < _folder.members.length; i++) {
      final m = _folder.members[i];
      final node = m.node;
      if (re != null) {
        final hay = node == null ? m.raw : '${node.tag} ${node.label}';
        if (re.hasMatch(hay) == _regexInvert) continue;
      }
      if (_selectedProtocols.isNotEmpty) {
        final match = _selectedProtocols.contains(node?.protocol ?? '');
        if (match == _protocolsInvert) continue;
      }
      out.add((i, m));
    }
    return out;
  }

  /// §236 UI-rework — панель фильтра: regex + протокол-чипы (виджеты главного
  /// экрана, §048/§095).
  Widget _buildFilterPanel(ThemeData theme) {
    final protocols = <String>{
      for (final m in _folder.members)
        if (m.node != null) m.node!.protocol,
    }.toList()
      ..sort();
    return Container(
      color: theme.colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RegexFilterField(
            controller: _filterRegexCtl,
            onChanged: (_) => setState(() {}),
            valid: _regexValid,
            invert: _regexInvert,
            onInvertToggle: () => setState(() => _regexInvert = !_regexInvert),
            onClear: () {
              _filterRegexCtl.clear();
              setState(() {});
            },
          ),
          if (protocols.isNotEmpty) ...[
            const SizedBox(height: 4),
            MultiSelectChipsRow(
              options: [for (final p in protocols) (p, protoLabel(p))],
              enabled: _selectedProtocols,
              onToggle: (id) => setState(() {
                if (!_selectedProtocols.add(id)) _selectedProtocols.remove(id);
              }),
              invert: _protocolsInvert,
              onInvertToggle: () =>
                  setState(() => _protocolsInvert = !_protocolsInvert),
            ),
          ],
        ],
      ),
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
    this.reorderable = true,
    this.onProbeBadgeTap,
    this.probe,
    this.thresholds = const ProbeThresholds(),
  });

  final FolderMember member;
  final int dragIndex;

  /// §236 UI-rework — false при активном фильтре: grab-strip скрыта (drag по
  /// индексам отфильтрованного вида ломал бы состав).
  final bool reorderable;
  final bool folderEnabled;
  final VoidCallback onToggle;
  final VoidCallback onLongPress;
  final VoidCallback onTap;

  /// Тап по бейджу результата — показать текст ошибки (диагностика err).
  final VoidCallback? onProbeBadgeTap;

  /// §236 — результат последнего Test servers (null = не тестировался).
  final ProbeResult? probe;
  final ProbeThresholds thresholds;

  /// §236 — бейдж результата теста. Цвет задержки — по порогам шкалы.
  Widget? _probeBadge(ThemeData theme) {
    final r = probe;
    if (r == null) return null;
    final muted = theme.colorScheme.onSurfaceVariant;
    final (String text, Color color) = switch (r.status) {
      ProbeStatus.pending => ('…', muted),
      ProbeStatus.ok => (
          '${r.delayMs} ms',
          switch (thresholds.bandOf(r.delayMs)) {
            0 => Colors.green,
            1 => Colors.amber.shade800,
            2 => Colors.orange.shade800,
            _ => theme.colorScheme.error,
          }
        ),
      ProbeStatus.failed => ('err', theme.colorScheme.error),
      ProbeStatus.broken => ('broken', theme.colorScheme.error),
      ProbeStatus.invalid => ('invalid', theme.colorScheme.error),
      // НЕ «недоступен»: член выключен → его нет в конфиге работающего
      // ядра → не тестировался вовсе. Подсказка «как протестировать» — в
      // сводке (_buildTestBar): выключить VPN, probe-сессия меряет всех.
      ProbeStatus.notInConfig => ('not tested (off)', muted),
    };
    return GestureDetector(
      onTap: onProbeBadgeTap,
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }

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
      trailing: _probeBadge(theme),
      onLongPress: onLongPress,
      onTap: onTap,
    );
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (reorderable) ReorderGrabStrip(index: dragIndex),
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
