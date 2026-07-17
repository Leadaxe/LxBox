import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/subscription_controller.dart';
import '../models/channel.dart';
import '../models/node_spec.dart';
import '../models/server_list.dart';
import '../services/error_humanize.dart';
import '../services/l10n/l10n.dart';
import '../services/settings_storage.dart';
import '../services/subscription/sources.dart';
import '../widgets/detour_target_picker.dart';
import '../services/url_launcher.dart';
import 'subscriptions_screen/entry_context_menu.dart' show showEditSourceDialog;
import 'subscription_detail_screen/detour_mode.dart';
import 'subscription_detail_screen/subscription_detail_format.dart';
import 'subscription_detail_screen/widgets/subscription_meta.dart';
import 'subscription_detail_screen/widgets/subscription_node_list.dart';
import 'subscription_detail_screen/widgets/subscription_settings_tab.dart';
import 'subscription_detail_screen/widgets/subscription_source_tab.dart';

class SubscriptionDetailScreen extends StatefulWidget {
  const SubscriptionDetailScreen({
    super.key,
    required this.entry,
    required this.controller,
  });

  final SubscriptionEntry entry;
  final SubscriptionController controller;

  @override
  State<SubscriptionDetailScreen> createState() =>
      _SubscriptionDetailScreenState();
}

class _SubscriptionDetailScreenState extends State<SubscriptionDetailScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabCtrl;
  List<NodeSpec>? _nodes;
  bool _loading = true;
  String? _error;
  bool _editing = false;
  late TextEditingController _nameCtrl;
  String _rawSource = '';
  Map<String, String> _rawHeaders = const {};
  bool _sourceLoaded = false;
  bool _sourceLoading = false;
  String? _sourceError;
  bool _showAllHeaders = false;

  // §248 — каналы: секция Channels в detour-пикере + подпись «⚙ <label>»
  // канальной override-цели в Settings-вкладке.
  List<Channel> _channels = const [];

  /// Headers, которые нам реально нужны — подписочные метаданные.
  /// Остальное (server, date, cookies, content-length, ddos-guard, etc.) —
  /// под раскрывашкой.
  static const _importantHeaders = {
    'profile-title',
    'profile-update-interval',
    'profile-web-page-url',
    'support-url',
    'subscription-userinfo',
    'content-type',
  };

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 3, vsync: this);
    _nameCtrl = TextEditingController(text: widget.entry.name);
    unawaited(_loadNodes());
    unawaited(_loadChannels());
    // При первом заходе на Source — живой GET.
    _tabCtrl.addListener(() {
      if (_tabCtrl.index == 2 && !_sourceLoaded && !_sourceLoading) {
        unawaited(_fetchSourceLive());
      }
    });
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  List<MapEntry<String, String>> _filteredHeaders({required bool important}) {
    final entries = _rawHeaders.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return entries
        .where((e) => _importantHeaders.contains(e.key.toLowerCase()) == important)
        .toList();
  }

  Future<void> _fetchSourceLive() async {
    if (widget.entry.url.isEmpty) return;
    setState(() {
      _sourceLoading = true;
      _sourceError = null;
    });
    try {
      final r = await fetchRaw(UrlSource(widget.entry.url));
      if (!mounted) return;
      setState(() {
        _rawSource = r.body;
        _rawHeaders = r.headers;
        _sourceLoaded = true;
        _sourceLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sourceError = humanizeError(e);
        _sourceLoading = false;
      });
    }
  }

  Future<void> _loadNodes({bool cacheOnly = true}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (!cacheOnly) {
        // §219 — index по ссылке (список мог сместиться от reorder).
        final idx = widget.controller.entries.indexOf(widget.entry);
        if (idx >= 0) await widget.controller.updateAt(idx);
      }
      // v2: узлы уже распарсены в entry.list.nodes. Детоур-узлы показываем
      // отдельной строкой под родителем.
      final expanded = <NodeSpec>[];
      for (final node in widget.entry.list.nodes) {
        expanded.add(node);
        if (node.chained != null) expanded.add(node.chained!);
      }
      // Source-вкладка теперь подтягивается живым GET при переключении туда.
      // Для UserServer (connections) показываем сразу что есть.
      if (widget.entry.connections.isNotEmpty) {
        _rawSource = widget.entry.connections.join('\n');
        _sourceLoaded = true;
      }
      if (mounted) setState(() { _nodes = expanded; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = humanizeError(e); _loading = false; });
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l.subDeleteSubscriptionTitle),
        content: Text(ctx.l.subDeleteRemoveBody(widget.entry.displayName)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.l.commonCancel)),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Theme.of(ctx).colorScheme.error),
            child: Text(ctx.l.commonDelete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    // §219 — index по ссылке: список мог переупорядочиться (drag-reorder) пока
    // открыт экран → removeAt снёс бы не ту подписку.
    final idx = widget.controller.entries.indexOf(widget.entry);
    if (idx < 0) {
      if (mounted) Navigator.pop(context);
      return;
    }
    await widget.controller.removeAt(idx);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _openUrl(String url) async {
    final opened = await UrlLauncher.open(url);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l.subCopiedUrl(url))),
      );
    }
  }

  void _toggleEdit() {
    if (_editing) {
      // Save
      final name = _nameCtrl.text.trim();
      // §219 — index по ссылке (список мог сместиться от reorder).
      final idx = widget.controller.entries.indexOf(widget.entry);
      if (idx >= 0) unawaited(widget.controller.renameAt(idx, name));
    }
    setState(() => _editing = !_editing);
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: _editing
            ? TextField(
                controller: _nameCtrl,
                autofocus: true,
                style: theme.textTheme.titleLarge,
                decoration: InputDecoration(
                  border: InputBorder.none,
                  hintText: context.l.subDisplayNameHint,
                ),
                onSubmitted: (_) => _toggleEdit(),
              )
            : Text(
                entry.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
        actions: [
          IconButton(
            tooltip: _editing ? context.l.commonSave : context.l.commonRename,
            icon: Icon(_editing ? Icons.check : Icons.edit_outlined),
            onPressed: _toggleEdit,
          ),
          IconButton(
            tooltip: context.l.commonRefresh,
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : () => _loadNodes(cacheOnly: false),
          ),
          IconButton(
            tooltip: context.l.commonDelete,
            icon: const Icon(Icons.delete_outline),
            onPressed: _delete,
          ),
        ],
        bottom: TabBar(
          controller: _tabCtrl,
          tabs: [
            Tab(text: context.l.homeNodesTitle),
            Tab(text: context.l.subTabSettings),
            Tab(text: context.l.subTabSource),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabCtrl,
        children: [
          // Tab 1: Nodes
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_loading) const LinearProgressIndicator(),
              SubscriptionMeta(entry: entry, onOpenUrl: _openUrl),
              const Divider(height: 1),
              Expanded(
                child: SubscriptionNodeList(
                  nodes: _nodes,
                  loading: _loading,
                  error: _error,
                ),
              ),
            ],
          ),
          // Tab 2: Settings
          _buildSettingsTab(theme),
          // Tab 3: Source
          _buildSourceTab(theme),
        ],
      ),
    );
  }

  Widget _buildSettingsTab(ThemeData theme) {
    final hasDetour = (_nodes ?? const []).any((n) => n.chained != null);
    return SubscriptionSettingsTab(
      entry: widget.entry,
      channels: _channels, // §248 — подпись канальной override-цели
      // §252 — разворот цели в цепочку «как пакет пойдёт» для превью.
      detourPathHopsOf: (stored) => detourPathHops(stored,
          controller: widget.controller, channels: _channels),
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
      onCopyUrl: () async {
        final list = widget.entry.list as SubscriptionServers;
        await Clipboard.setData(ClipboardData(text: list.url));
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(context.l.subUrlCopied),
              duration: const Duration(seconds: 1)),
        );
      },
      onShowIntervalPicker: _showIntervalPicker,
      onRefreshNow: _refreshNow,
      onEditSource: _editSource, // §129
    );
  }

  /// §129 — сменить источник подписки (online↔file). Переиспользует общий
  /// диалог; index берём по ссылке (мог сместиться от reorder/delete).
  Future<void> _editSource() async {
    final idx = widget.controller.entries.indexOf(widget.entry);
    if (idx < 0) return;
    await showEditSourceDialog(context, idx, widget.entry, widget.controller);
    if (mounted) setState(() {}); // подхватить смену url/имени
  }

  Future<void> _showIntervalPicker() async {
    final list = widget.entry.list as SubscriptionServers;
    // §129 — -1 = «Don't auto-update» (никогда, игнор серверного интервала);
    //          0 = «Never (respect server)» (сами нет, но сервер может задать).
    final presets = <int>[-1, 0, 1, 3, 6, 12, 24, 48, 72, 168];
    final chosen = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(ctx.l.subUpdateIntervalTitle),
        children: [
          for (final h in presets)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, h),
              child: Row(
                children: [
                  if (h == list.updateIntervalHours)
                    const Icon(Icons.check, size: 18)
                  else
                    const SizedBox(width: 18),
                  const SizedBox(width: 8),
                  Text(switch (h) {
                    < 0 => ctx.l.subIntervalDontAuto,
                    0 => ctx.l.subIntervalNeverRespect,
                    _ => '${h}h (${intervalHuman(h)})',
                  }),
                ],
              ),
            ),
        ],
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() {
      widget.entry.updateIntervalHours = chosen;
    });
    await widget.controller.persistSources();
  }

  Future<void> _refreshNow() async {
    final idx = widget.controller.entries.indexOf(widget.entry);
    if (idx < 0) return;
    await widget.controller.updateAt(idx);
    if (!mounted) return;
    setState(() {});
  }

  /// §248 — загрузка каналов (initState + refresh перед пикером).
  Future<void> _loadChannels() async {
    final channels = await SettingsStorage.getChannels();
    if (!mounted) return;
    setState(() => _channels = channels);
  }

  Future<void> _showOverrideDetourPicker() async {
    // §239 — единый пикер; для подписки кандидаты = только «свободные»
    // одиночки (члены папок живут под политикой своей папки — чужим нельзя).
    // §248 — свежие каналы (могли измениться, пока экран открыт).
    await _loadChannels();
    if (!mounted) return;
    final chosen = await showDetourTargetPicker(
      context,
      controller: widget.controller,
      channels: _channels,
    );
    if (chosen == null || !mounted) return;
    setState(() {
      widget.entry.overrideDetour = chosen.storeValue;
      // §111: leftover useDetourServers=false (mode был None) молча гасит
      // override в builder'е. Для полного UI идемпотентно.
      if (chosen.storeValue.isNotEmpty) widget.entry.useDetourServers = true;
    });
    unawaited(widget.controller.persistSources());
  }

  Widget _buildSourceTab(ThemeData theme) {
    final entry = widget.entry;
    return SubscriptionSourceTab(
      hasUrl: entry.url.isNotEmpty,
      sourceLoading: _sourceLoading,
      sourceError: _sourceError,
      rawHeaders: _rawHeaders,
      rawSource: _rawSource,
      showAllHeaders: _showAllHeaders,
      importantHeaders: _filteredHeaders(important: true),
      moreHeaders: _filteredHeaders(important: false),
      onRefetch: () => unawaited(_fetchSourceLive()),
      onToggleShowAll: () =>
          setState(() => _showAllHeaders = !_showAllHeaders),
    );
  }

  // ─── Detour mode (тернарный radio over {useDetourServers, overrideDetour})
  // Mapping см. в comment у RadioListTile блока в _buildSettingsTab.

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
          // overrideDetour сохраняем — может уже выбран ранее. Если пусто —
          // открываем picker сразу (юзер хочет Override, надо его сконфигурить).
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
}
