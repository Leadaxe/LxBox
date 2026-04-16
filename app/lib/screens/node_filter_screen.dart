import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../controllers/home_controller.dart';
import '../controllers/subscription_controller.dart';
import '../services/settings_storage.dart';

/// A lightweight node representation parsed from the config JSON.
class _NodeInfo {
  _NodeInfo({required this.tag, required this.type, this.server = '', this.port = 0});
  final String tag;
  final String type;
  final String server;
  final int port;
}

class NodeFilterScreen extends StatefulWidget {
  const NodeFilterScreen({
    super.key,
    required this.subController,
    required this.homeController,
  });

  final SubscriptionController subController;
  final HomeController homeController;

  @override
  State<NodeFilterScreen> createState() => _NodeFilterScreenState();
}

class _NodeFilterScreenState extends State<NodeFilterScreen> {
  List<_NodeInfo> _allNodes = [];
  final _excluded = <String>{};
  bool _loading = true;
  String _search = '';
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final excluded = await SettingsStorage.getExcludedNodes();
    final nodes = _parseNodesFromConfig(widget.homeController.state.configRaw);

    if (mounted) {
      setState(() {
        _allNodes = nodes;
        _excluded.addAll(excluded);
        _loading = false;
      });
    }
  }

  /// Extract nodes that belong to auto-proxy-out from the saved config JSON.
  /// Only shows nodes listed in the auto-proxy-out group outbounds —
  /// jump servers are never in that list (they're only referenced via detour).
  List<_NodeInfo> _parseNodesFromConfig(String configRaw) {
    if (configRaw.isEmpty) return [];
    try {
      final config = jsonDecode(configRaw) as Map<String, dynamic>;
      final outbounds = config['outbounds'] as List<dynamic>? ?? [];

      // Find auto-proxy-out group and its member tags
      final autoProxyTags = <String>{};
      for (final ob in outbounds) {
        if (ob is! Map<String, dynamic>) continue;
        final tag = ob['tag']?.toString() ?? '';
        if (tag == 'auto-proxy-out') {
          final members = ob['outbounds'] as List<dynamic>? ?? [];
          for (final m in members) {
            autoProxyTags.add(m.toString());
          }
          break;
        }
      }

      if (autoProxyTags.isEmpty) return [];

      // Build list: only nodes that are members of auto-proxy-out
      final nodes = <_NodeInfo>[];
      for (final ob in outbounds) {
        if (ob is! Map<String, dynamic>) continue;
        final tag = ob['tag']?.toString() ?? '';
        if (!autoProxyTags.contains(tag)) continue;
        nodes.add(_NodeInfo(
          tag: tag,
          type: ob['type']?.toString() ?? '',
          server: ob['server']?.toString() ?? '',
          port: ob['server_port'] as int? ?? 0,
        ));
      }
      return nodes;
    } catch (_) {
      return [];
    }
  }

  List<_NodeInfo> get _filtered {
    if (_search.isEmpty) return _allNodes;
    final q = _search.toLowerCase();
    return _allNodes.where((n) {
      return n.tag.toLowerCase().contains(q) ||
          n.server.toLowerCase().contains(q);
    }).toList();
  }

  int get _includedCount => _allNodes.where((n) => !_excluded.contains(n.tag)).length;

  void _selectAll() => setState(() {
        _excluded.clear();
        _dirty = true;
      });

  void _deselectAll() => setState(() {
        for (final n in _allNodes) {
          _excluded.add(n.tag);
        }
        _dirty = true;
      });

  Future<void> _apply() async {
    await SettingsStorage.saveExcludedNodes(_excluded);

    if (!mounted) return;

    final config = await widget.subController.generateConfig();
    if (config != null && mounted) {
      final ok = await widget.homeController.saveParsedConfig(config);
      if (ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Config regenerated with $_includedCount/${_allNodes.length} nodes'),
          ),
        );
        if (widget.homeController.state.tunnelUp) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Restart VPN to apply changes')),
          );
        }
      }
    }

    _dirty = false;
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final nodes = _filtered;

    return Scaffold(
      appBar: AppBar(
        title: const Text('auto-proxy-out'),
        actions: [
          TextButton(
            onPressed: _selectAll,
            child: const Text('All'),
          ),
          TextButton(
            onPressed: _deselectAll,
            child: const Text('None'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Search nodes...',
                prefixIcon: Icon(Icons.search, size: 20),
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              style: const TextStyle(fontSize: 13),
              onChanged: (v) => setState(() => _search = v),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Included: $_includedCount / ${_allNodes.length} nodes',
              style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 4),
          if (_loading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (_allNodes.isEmpty)
            const Expanded(child: Center(child: Text('No config loaded. Generate config first.')))
          else
            Expanded(
              child: ListView.builder(
                itemCount: nodes.length,
                itemBuilder: (context, i) {
                  final node = nodes[i];
                  final included = !_excluded.contains(node.tag);

                  return CheckboxListTile(
                    value: included,
                    dense: true,
                    title: Text(
                      node.tag,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: included ? null : cs.onSurfaceVariant,
                      ),
                    ),
                    subtitle: Text(
                      '${node.type} · ${node.server}:${node.port}',
                      style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                    ),
                    onChanged: (val) {
                      setState(() {
                        if (val == true) {
                          _excluded.remove(node.tag);
                        } else {
                          _excluded.add(node.tag);
                        }
                        _dirty = true;
                      });
                    },
                  );
                },
              ),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _dirty ? () => unawaited(_apply()) : null,
                  icon: const Icon(Icons.check),
                  label: Text('Apply ($_includedCount/${_allNodes.length})'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
