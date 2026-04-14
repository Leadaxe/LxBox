import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/subscription_controller.dart';
import '../models/parsed_node.dart';
import '../services/source_loader.dart';

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

class _SubscriptionDetailScreenState extends State<SubscriptionDetailScreen> {
  List<ParsedNode>? _nodes;
  bool _loading = true;
  String? _error;
  bool _editing = false;
  late TextEditingController _nameCtrl;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.entry.source.name);
    unawaited(_loadNodes());
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadNodes() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final tagCounts = <String, int>{};
      final nodes = await SourceLoader.loadNodesFromSource(
        widget.entry.source,
        tagCounts,
      );
      if (mounted) setState(() { _nodes = nodes; _loading = false; });
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
            onPressed: _loading ? null : _loadNodes,
          ),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline),
            onPressed: _delete,
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_loading) const LinearProgressIndicator(),
          _buildMeta(entry, theme),
          const Divider(height: 1),
          Expanded(child: _buildNodeList(theme)),
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
        ],
      ),
    );
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

    return ListView.separated(
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
          subtitle: Text(
            '${node.scheme}  ${node.server}:${node.port}',
            style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
          ),
          dense: true,
        );
      },
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
