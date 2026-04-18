import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';

import '../controllers/subscription_controller.dart';
import '../models/parsed_node.dart';
import '../services/config_builder.dart';
import '../services/settings_storage.dart';
import '../services/source_loader.dart';
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
  List<ParsedNode>? _nodes;
  bool _loading = true;
  String? _error;
  bool _editing = false;
  late TextEditingController _nameCtrl;
  String _rawSource = '';

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 3, vsync: this);
    _nameCtrl = TextEditingController(text: widget.entry.source.name);
    unawaited(_loadNodes());
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadNodes({bool cacheOnly = true}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final tagCounts = <String, int>{};
      final nodes = await SourceLoader.loadNodesFromSource(
        widget.entry.source,
        tagCounts,
        cacheOnly: cacheOnly,
      );
      // Include jump servers as separate entries
      final expanded = <ParsedNode>[];
      for (final node in nodes) {
        expanded.add(node);
        if (node.detourServer != null) {
          expanded.add(ParsedNode(
            tag: node.detourServer!.tag,
            scheme: node.detourServer!.scheme,
            server: node.detourServer!.server,
            port: node.detourServer!.port,
            label: node.detourServer!.tag,
            outbound: node.detourServer!.outbound,
          ));
        }
      }
      // Load raw source from cache
      if (widget.entry.source.source.isNotEmpty) {
        try {
          final cacheKey = widget.entry.source.source.hashCode.toRadixString(16);
          final dir = await getApplicationSupportDirectory();
          final cached = File('${dir.path}/sub_cache/$cacheKey');
          if (cached.existsSync()) {
            final bytes = await cached.readAsBytes();
            _rawSource = utf8.decode(bytes, allowMalformed: true);
          }
        } catch (_) {}
      } else if (widget.entry.source.connections.isNotEmpty) {
        _rawSource = widget.entry.source.connections.join('\n');
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
    final hasDetour = (_nodes ?? const []).any((n) => n.detourServer != null);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (hasDetour) ...[
          Text('Display', style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.bold,
          )),
          const Divider(),
          SwitchListTile(
            title: const Text('Register detour servers'),
            subtitle: const Text('Add ⚙ servers to proxy groups (visible in node list)'),
            value: widget.entry.source.registerDetourServers,
            onChanged: (val) {
              setState(() => widget.entry.source.registerDetourServers = val);
              unawaited(widget.controller.persistSources());
            },
          ),
          SwitchListTile(
            title: const Text('Register detour in auto group'),
            subtitle: const Text('Include ⚙ servers in auto-proxy-out urltest'),
            value: widget.entry.source.registerDetourInAuto,
            onChanged: (val) {
              setState(() => widget.entry.source.registerDetourInAuto = val);
              unawaited(widget.controller.persistSources());
            },
          ),
          SwitchListTile(
            title: const Text('Use detour servers'),
            subtitle: Text(widget.entry.source.useDetourServers
                ? 'Nodes connect through detour servers'
                : 'Nodes connect directly (detour skipped)'),
            value: widget.entry.source.useDetourServers,
            onChanged: (val) {
              setState(() => widget.entry.source.useDetourServers = val);
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
          subtitle: Text(widget.entry.source.overrideDetour.isEmpty
              ? 'None (use original)'
              : widget.entry.source.overrideDetour),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _showOverrideDetourPicker(),
        ),
      ],
    );
  }

  Future<void> _showOverrideDetourPicker() async {
    // Load direct servers for picker
    final allSources = await SettingsStorage.getProxySources();
    final directSources = allSources
        .where((s) => s.source.isEmpty && s.connections.isNotEmpty)
        .toList();
    final directNodes = await ConfigBuilder.loadAndParseNodes(directSources, {});
    final tags = directNodes.map((n) => n.tag).toList();

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
    setState(() => widget.entry.source.overrideDetour = chosen);
    unawaited(widget.controller.persistSources());
  }

  Widget _buildSourceTab(ThemeData theme) {
    final source = widget.entry.source;
    final cs = theme.colorScheme;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // Headers section
        if (source.source.isNotEmpty) ...[
          Text('Headers', style: theme.textTheme.titleSmall?.copyWith(
            color: cs.primary, fontWeight: FontWeight.bold,
          )),
          const Divider(),
          if (source.name.isNotEmpty)
            _headerRow('profile-title', source.name, theme),
          if (source.supportUrl.isNotEmpty)
            _headerRow('support-url', source.supportUrl, theme),
          if (source.webPageUrl.isNotEmpty)
            _headerRow('profile-web-page-url', source.webPageUrl, theme),
          if (source.updateIntervalHours > 0)
            _headerRow('profile-update-interval', '${source.updateIntervalHours} hours', theme),
          if (source.totalBytes > 0)
            _headerRow('subscription-userinfo',
              'upload=${source.uploadBytes}; download=${source.downloadBytes}; total=${source.totalBytes}'
              '${source.expireTimestamp > 0 ? "; expire=${source.expireTimestamp}" : ""}',
              theme),
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
    final source = entry.source;
    final url = source.source.isNotEmpty
        ? source.source
        : source.connections.isNotEmpty
            ? source.connections.first
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
              if (source.lastUpdated != null) ...[
                Icon(Icons.schedule, size: 14, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 4),
                Text(
                  SubscriptionEntry.formatAgo(source.lastUpdated!),
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(width: 16),
              ],
              Icon(Icons.dns_outlined, size: 14, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Text(
                '${_nodes?.length ?? entry.nodeCount} nodes',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
          // Traffic quota
          if (source.totalBytes > 0) ...[
            const SizedBox(height: 8),
            _buildTrafficBar(source, theme),
          ],
          // Expire
          if (source.expireTimestamp > 0) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.event_outlined, size: 14, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 4),
                Text(
                  'Expires: ${_formatExpire(source.expireTimestamp)}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ],
          // Support & web page links
          if (source.supportUrl.isNotEmpty || source.webPageUrl.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                if (source.supportUrl.isNotEmpty)
                  ActionChip(
                    avatar: Icon(
                      source.supportUrl.contains('t.me') ? Icons.telegram : Icons.open_in_new,
                      size: 16,
                      color: source.supportUrl.contains('t.me')
                          ? const Color(0xFF2AABEE)
                          : null,
                    ),
                    label: const Text('Support'),
                    onPressed: () => unawaited(_openUrl(source.supportUrl)),
                  ),
                if (source.webPageUrl.isNotEmpty)
                  ActionChip(
                    avatar: const Icon(Icons.language, size: 16),
                    label: const Text('Web page'),
                    onPressed: () => unawaited(_openUrl(source.webPageUrl)),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTrafficBar(dynamic source, ThemeData theme) {
    final used = source.uploadBytes + source.downloadBytes;
    final total = source.totalBytes;
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

    final warningCount = nodes.where((n) => n.warning.isNotEmpty).length;
    return Column(
      children: [
        if (warningCount > 0)
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
                    '$warningCount ${warningCount == 1 ? "узел" : "узлов"} с предупреждениями (XHTTP fallback)',
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
          leading: _protocolIcon(node.scheme),
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
                '${node.scheme}  ${node.server}:${node.port}',
                style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
              ),
              if (node.warning.isNotEmpty)
                Row(
                  children: [
                    Icon(Icons.warning_amber, size: 12, color: Colors.orange),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        node.warning,
                        style: const TextStyle(fontSize: 10, color: Colors.orange),
                      ),
                    ),
                  ],
                ),
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

  void _showNodeMenu(ParsedNode node) {
    final info = node.sourceUri.isNotEmpty
        ? node.sourceUri
        : '${node.scheme}://${node.server}:${node.port}';
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
