import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/subscription_controller.dart';
import '../models/node_spec.dart';
import '../models/node_warning.dart';
import '../models/server_list.dart';
import '../services/subscription/sources.dart';
import '../services/url_launcher.dart';

class SubscriptionDetailScreen extends StatefulWidget {
  const SubscriptionDetailScreen({
    super.key,
    required this.entry,
    required this.index,
    required this.controller,
  });

  final SubscriptionEntry entry;
  final int index;
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

  bool get _hasMoreHeaders =>
      _rawHeaders.entries
          .any((e) => !_importantHeaders.contains(e.key.toLowerCase()));

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
        _sourceError = e.toString();
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
        await widget.controller.updateAt(widget.index);
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
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete subscription?'),
        content: Text('Remove "${widget.entry.displayName}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Theme.of(ctx).colorScheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.controller.removeAt(widget.index);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _openUrl(String url) async {
    final opened = await UrlLauncher.open(url);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Copied: $url')),
      );
    }
  }

  void _toggleEdit() {
    if (_editing) {
      // Save
      final name = _nameCtrl.text.trim();
      unawaited(widget.controller.renameAt(widget.index, name));
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
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  hintText: 'Display name',
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
            tooltip: _editing ? 'Save' : 'Rename',
            icon: Icon(_editing ? Icons.check : Icons.edit_outlined),
            onPressed: _toggleEdit,
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : () => _loadNodes(cacheOnly: false),
          ),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline),
            onPressed: _delete,
          ),
        ],
        bottom: TabBar(
          controller: _tabCtrl,
          tabs: const [
            Tab(text: 'Nodes'),
            Tab(text: 'Settings'),
            Tab(text: 'Source'),
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
              _buildMeta(entry, theme),
              const Divider(height: 1),
              Expanded(child: _buildNodeList(theme)),
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
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Tag prefix', style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.bold,
        )),
        const SizedBox(height: 4),
        Text(
          'Prefix applied to every tag from this subscription '
          '(e.g. "BL:" → "BL: Frankfurt"). Used to distinguish servers '
          'from different subscriptions and resolve name collisions.',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: TextFormField(
            initialValue: widget.entry.tagPrefix,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Prefix',
              hintText: 'empty = no prefix',
              isDense: true,
            ),
            onChanged: (val) {
              widget.entry.tagPrefix = val.trim();
              unawaited(widget.controller.persistSources());
            },
          ),
        ),
        const SizedBox(height: 24),
        if (hasDetour) ...[
          Text('Display', style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.bold,
          )),
          const Divider(),
          SwitchListTile(
            title: const Text('Register detour servers'),
            subtitle: const Text('Add ⚙ servers to proxy groups (visible in node list)'),
            value: widget.entry.registerDetourServers,
            onChanged: (val) {
              setState(() => widget.entry.registerDetourServers = val);
              unawaited(widget.controller.persistSources());
            },
          ),
          SwitchListTile(
            title: const Text('Register detour in auto group'),
            subtitle: const Text('Include ⚙ servers in auto-proxy-out urltest'),
            value: widget.entry.registerDetourInAuto,
            onChanged: (val) {
              setState(() => widget.entry.registerDetourInAuto = val);
              unawaited(widget.controller.persistSources());
            },
          ),
          SwitchListTile(
            title: const Text('Use detour servers'),
            subtitle: Text(widget.entry.useDetourServers
                ? 'Nodes connect through detour servers'
                : 'Nodes connect directly (detour skipped)'),
            value: widget.entry.useDetourServers,
            onChanged: (val) {
              setState(() => widget.entry.useDetourServers = val);
              unawaited(widget.controller.persistSources());
            },
          ),
          const Divider(),
        ],
        Text('Override', style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.bold,
        )),
        const SizedBox(height: 4),
        Text(
          'Replace all detour servers with a different one',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        ListTile(
          title: const Text('Override detour'),
          subtitle: Text(widget.entry.overrideDetour.isEmpty
              ? 'None (use original)'
              : widget.entry.overrideDetour),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _showOverrideDetourPicker(),
        ),
        if (widget.entry.list is SubscriptionServers) ...[
          const SizedBox(height: 24),
          Text('Subscription', style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.bold,
          )),
          const Divider(),
          _buildSubscriptionInfo(theme),
        ],
      ],
    );
  }

  Widget _buildSubscriptionInfo(ThemeData theme) {
    final list = widget.entry.list as SubscriptionServers;
    final cs = theme.colorScheme;
    final statusLabel = _statusLabel(list);
    final statusColor = _statusColor(list, cs);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: const Icon(Icons.link, size: 20),
          title: const Text('URL'),
          subtitle: Text(list.url, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.content_copy, size: 18),
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: list.url));
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('URL copied'), duration: Duration(seconds: 1)),
            );
          },
        ),
        ListTile(
          leading: const Icon(Icons.sync, size: 20),
          title: const Text('Update interval'),
          subtitle: Text('${list.updateIntervalHours}h '
              '(auto-refresh every ${_intervalHuman(list.updateIntervalHours)})'),
          trailing: const Icon(Icons.edit, size: 18),
          onTap: _showIntervalPicker,
        ),
        ListTile(
          leading: Icon(_statusIcon(list), size: 20, color: statusColor),
          title: Text(statusLabel, style: TextStyle(color: statusColor)),
          subtitle: Text(_subscriptionStatusSubtitle(list)),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 8),
          child: OutlinedButton.icon(
            onPressed: _refreshNow,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Refresh now'),
          ),
        ),
      ],
    );
  }

  String _statusLabel(SubscriptionServers list) {
    switch (list.lastUpdateStatus) {
      case UpdateStatus.ok:
        return 'OK';
      case UpdateStatus.failed:
        final n = list.consecutiveFails;
        return n > 1 ? 'Failed ($n in a row)' : 'Failed';
      case UpdateStatus.inProgress:
        return 'Refreshing…';
      case UpdateStatus.never:
        return 'Never updated';
    }
  }

  Color _statusColor(SubscriptionServers list, ColorScheme cs) {
    switch (list.lastUpdateStatus) {
      case UpdateStatus.ok:
        return cs.primary;
      case UpdateStatus.failed:
        return cs.error;
      case UpdateStatus.inProgress:
        return cs.secondary;
      case UpdateStatus.never:
        return cs.onSurfaceVariant;
    }
  }

  IconData _statusIcon(SubscriptionServers list) {
    switch (list.lastUpdateStatus) {
      case UpdateStatus.ok:
        return Icons.check_circle_outline;
      case UpdateStatus.failed:
        return Icons.error_outline;
      case UpdateStatus.inProgress:
        return Icons.hourglass_empty;
      case UpdateStatus.never:
        return Icons.schedule;
    }
  }

  String _subscriptionStatusSubtitle(SubscriptionServers list) {
    final parts = <String>[];
    if (list.lastUpdated != null) {
      parts.add('Last success: ${SubscriptionEntry.formatAgo(list.lastUpdated!)}');
    }
    if (list.lastUpdateAttempt != null &&
        list.lastUpdateAttempt != list.lastUpdated) {
      parts.add('Last attempt: ${SubscriptionEntry.formatAgo(list.lastUpdateAttempt!)}');
    }
    if (list.lastNodeCount > 0) {
      parts.add('${list.lastNodeCount} nodes');
    }
    return parts.isEmpty ? '—' : parts.join(' · ');
  }

  String _intervalHuman(int hours) {
    if (hours < 24) return '${hours}h';
    final d = hours ~/ 24;
    final rem = hours % 24;
    if (rem == 0) return d == 1 ? 'day' : '$d days';
    return '${d}d ${rem}h';
  }

  Future<void> _showIntervalPicker() async {
    final list = widget.entry.list as SubscriptionServers;
    final presets = <int>[1, 3, 6, 12, 24, 48, 72, 168];
    final chosen = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Update interval'),
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
                  Text('${h}h (${_intervalHuman(h)})'),
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

  Future<void> _showOverrideDetourPicker() async {
    // Direct-server picker: все UserServer-узлы из других entries.
    final tags = <String>[];
    for (final e in widget.controller.entries) {
      if (e.list is! UserServer) continue;
      for (final n in e.list.nodes) {
        if (n.tag.isNotEmpty) tags.add(n.tag);
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
    setState(() => widget.entry.overrideDetour = chosen);
    unawaited(widget.controller.persistSources());
  }

  Widget _buildSourceTab(ThemeData theme) {
    final entry = widget.entry;
    final cs = theme.colorScheme;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // HTTP Response Headers — живой GET с сервера, без кеша.
        if (entry.url.isNotEmpty) ...[
          Row(
            children: [
              Text(
                _sourceLoading ? 'Fetching…' : 'Response headers',
                style: theme.textTheme.titleSmall?.copyWith(
                    color: cs.primary, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: 'Re-fetch live',
                visualDensity: VisualDensity.compact,
                onPressed:
                    _sourceLoading ? null : () => unawaited(_fetchSourceLive()),
              ),
              if (_rawHeaders.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.copy, size: 16),
                  tooltip: 'Copy headers',
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    final text = _rawHeaders.entries
                        .map((e) => '${e.key}: ${e.value}')
                        .join('\n');
                    Clipboard.setData(ClipboardData(text: text));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Headers copied')),
                    );
                  },
                ),
            ],
          ),
          const Divider(),
          if (_sourceError != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text('Fetch failed: $_sourceError',
                  style: TextStyle(fontSize: 12, color: cs.error)),
            )
          else if (_sourceLoading && _rawHeaders.isEmpty)
            const LinearProgressIndicator()
          else if (_rawHeaders.isEmpty)
            const Text('No data — tap refresh above',
                style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic))
          else ...[
            for (final h in _filteredHeaders(important: true))
              _headerRow(h.key, h.value, theme),
            if (_hasMoreHeaders) ...[
              const SizedBox(height: 4),
              TextButton.icon(
                onPressed: () =>
                    setState(() => _showAllHeaders = !_showAllHeaders),
                icon: Icon(
                    _showAllHeaders
                        ? Icons.expand_less
                        : Icons.expand_more,
                    size: 16),
                label: Text(_showAllHeaders
                    ? 'Hide others'
                    : 'Show all (${_rawHeaders.length - _filteredHeaders(important: true).length})'),
              ),
              if (_showAllHeaders)
                for (final h in _filteredHeaders(important: false))
                  _headerRow(h.key, h.value, theme),
            ],
          ],
          const SizedBox(height: 16),
        ],

        // Raw source
        Text('Raw response', style: theme.textTheme.titleSmall?.copyWith(
          color: cs.primary, fontWeight: FontWeight.bold,
        )),
        const Divider(),
        if (_rawSource.isEmpty)
          const Text('No cached source data')
        else
          Stack(
            children: [
              SelectableText(
                _rawSource,
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
              ),
              Positioned(
                top: 0,
                right: 0,
                child: IconButton(
                  icon: const Icon(Icons.copy, size: 16),
                  tooltip: 'Copy source',
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _rawSource));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Source copied')),
                    );
                  },
                ),
              ),
            ],
          ),
      ],
    );
  }

  Widget _headerRow(String name, String value, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(name, style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurfaceVariant,
            )),
          ),
          Expanded(
            child: SelectableText(value, style: const TextStyle(fontSize: 11)),
          ),
        ],
      ),
    );
  }

  Widget _buildMeta(SubscriptionEntry entry, ThemeData theme) {
    final url = entry.url.isNotEmpty
        ? entry.url
        : entry.connections.isNotEmpty
            ? entry.connections.first
            : '';

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (url.isNotEmpty) ...[
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    url,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 2,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy, size: 16),
                  tooltip: 'Copy URL',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: url));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('URL copied')),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              if (entry.lastUpdated != null) ...[
                Icon(Icons.schedule, size: 14, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 4),
                Text(
                  SubscriptionEntry.formatAgo(entry.lastUpdated!),
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(width: 16),
              ],
              Icon(Icons.dns_outlined, size: 14, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Text(
                entry.detourCount > 0
                    ? '${entry.nodeCount} +${entry.detourCount}⚙ nodes'
                    : '${entry.nodeCount} nodes',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
          // Traffic quota
          if (entry.totalBytes > 0) ...[
            const SizedBox(height: 8),
            _buildTrafficBar(entry, theme),
          ],
          // Expire
          if (entry.expireTimestamp > 0) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.event_outlined, size: 14, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 4),
                Text(
                  'Expires: ${_formatExpire(entry.expireTimestamp)}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ],
          // Support & web page links
          if (entry.supportUrl.isNotEmpty || entry.webPageUrl.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                if (entry.supportUrl.isNotEmpty)
                  ActionChip(
                    avatar: Icon(
                      entry.supportUrl.contains('t.me') ? Icons.telegram : Icons.open_in_new,
                      size: 16,
                      color: entry.supportUrl.contains('t.me')
                          ? const Color(0xFF2AABEE)
                          : null,
                    ),
                    label: const Text('Support'),
                    onPressed: () => unawaited(_openUrl(entry.supportUrl)),
                  ),
                if (entry.webPageUrl.isNotEmpty)
                  ActionChip(
                    avatar: const Icon(Icons.language, size: 16),
                    label: const Text('Web page'),
                    onPressed: () => unawaited(_openUrl(entry.webPageUrl)),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTrafficBar(SubscriptionEntry entry, ThemeData theme) {
    final used = entry.uploadBytes + entry.downloadBytes;
    final total = entry.totalBytes;
    final pct = total > 0 ? (used / total).clamp(0.0, 1.0) : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(value: pct),
        const SizedBox(height: 2),
        Text(
          '${_formatBytes(used)} / ${_formatBytes(total)} used',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes <= 0) return '0';
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  static String _formatExpire(int timestamp) {
    if (timestamp <= 0) return 'Unlimited';
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    final diff = dt.difference(DateTime.now());
    if (diff.isNegative) return 'Expired';
    if (diff.inDays > 0) return '${diff.inDays} days left';
    return '${diff.inHours} hours left';
  }

  Widget _buildNodeList(ThemeData theme) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ),
      );
    }

    final nodes = _nodes;
    if (nodes == null && !_loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Update subscription to see nodes'),
        ),
      );
    }

    if (nodes == null || nodes.isEmpty) {
      if (_loading) return const SizedBox.shrink();
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No nodes found'),
        ),
      );
    }

    // Считаем только actionable (warning/error). Info (TLS-insecure) тут
    // не учитываем — это часто намеренный выбор провайдера, чтобы не пугать.
    final actionableCount = nodes
        .where((n) => n.warnings
            .any((w) => w.severity != WarningSeverity.info))
        .length;
    return Column(
      children: [
        if (actionableCount > 0)
          Container(
            width: double.infinity,
            color: Colors.orange.withValues(alpha: 0.15),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.warning_amber, size: 16, color: Colors.orange),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '$actionableCount node${actionableCount == 1 ? "" : "s"} with warnings (XHTTP fallback etc.)',
                    style: const TextStyle(fontSize: 12, color: Colors.orange),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: nodes.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final node = nodes[i];
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: _protocolIcon(node.protocol),
          title: Text(
            node.label.isNotEmpty ? node.label : node.tag,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${node.protocol}  ${node.server}:${node.port}',
                style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
              ),
              if (node.warnings.isNotEmpty) _NodeWarningRow(node.warnings),
            ],
          ),
          dense: true,
          onLongPress: () => _showNodeMenu(node),
        );
      },
          ),
        ),
      ],
    );
  }

  void _showNodeMenu(NodeSpec node) {
    final info = node.rawUri.isNotEmpty
        ? node.rawUri
        : '${node.protocol}://${node.server}:${node.port}';
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy node info'),
              subtitle: Text(info, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
              onTap: () {
                Clipboard.setData(ClipboardData(text: info));
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Node info copied')),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.label_outline),
              title: const Text('Copy tag'),
              subtitle: Text(node.tag, style: const TextStyle(fontSize: 11)),
              onTap: () {
                Clipboard.setData(ClipboardData(text: node.tag));
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Tag copied')),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _protocolIcon(String scheme) {
    final icon = switch (scheme) {
      'vless' => Icons.security,
      'vmess' => Icons.vpn_key,
      'trojan' => Icons.shield_outlined,
      'ss' => Icons.lock_outline,
      'hysteria2' || 'hy2' => Icons.speed,
      'wireguard' => Icons.lan_outlined,
      _ => Icons.public,
    };
    return Icon(icon, size: 20);
  }
}

/// Inline warning-line под нодой. Сортируем по severity (error → warning →
/// info), показываем первый. Цвет: error=красный, warning=оранжевый,
/// info=серый (TLS-insecure часто намеренное → не должен орать).
class _NodeWarningRow extends StatelessWidget {
  const _NodeWarningRow(this.warnings);
  final List<NodeWarning> warnings;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sorted = [...warnings]
      ..sort((a, b) => b.severity.index.compareTo(a.severity.index));
    final w = sorted.first;
    final (color, icon) = switch (w.severity) {
      WarningSeverity.error => (cs.error, Icons.error_outline),
      WarningSeverity.warning => (Colors.orange, Icons.warning_amber),
      WarningSeverity.info => (cs.onSurfaceVariant, Icons.info_outline),
    };
    final more = warnings.length - 1;
    return Row(
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            more > 0 ? '${w.message} (+$more more)' : w.message,
            style: TextStyle(fontSize: 10, color: color),
          ),
        ),
      ],
    );
  }
}
