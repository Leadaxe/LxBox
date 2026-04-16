import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/home_controller.dart';
import '../controllers/subscription_controller.dart';
import '../models/parsed_node.dart';
import '../services/settings_storage.dart';
import '../services/source_loader.dart';

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
  List<ParsedNode> _allNodes = [];
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
    final sources = await SettingsStorage.getProxySources();
    final excluded = await SettingsStorage.getExcludedNodes();

    final tagCounts = <String, int>{};
    final nodes = <ParsedNode>[];
    for (var i = 0; i < sources.length; i++) {
      try {
        final result = await SourceLoader.loadNodesFromSource(
          sources[i],
          tagCounts,
          sourceIndex: i,
          totalSources: sources.length,
        );
        nodes.addAll(result);
      } catch (_) {}
    }

    if (mounted) {
      setState(() {
        _allNodes = nodes;
        _excluded.addAll(excluded);
        _loading = false;
      });
    }
  }

  List<ParsedNode> get _filtered {
    if (_search.isEmpty) return _allNodes;
    final q = _search.toLowerCase();
    return _allNodes.where((n) {
      final label = n.label.isNotEmpty ? n.label : n.tag;
      return label.toLowerCase().contains(q) ||
          n.tag.toLowerCase().contains(q) ||
          n.server.toLowerCase().contains(q);
    }).toList();
  }

  int get _includedCount => _allNodes.length - _excluded.length;

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
        title: const Text('Node Filter'),
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
          // Search
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

          // Counter
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Included: $_includedCount / ${_allNodes.length} nodes',
              style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 4),

          // Node list
          if (_loading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else
            Expanded(
              child: ListView.builder(
                itemCount: nodes.length,
                itemBuilder: (context, i) {
                  final node = nodes[i];
                  final label = node.label.isNotEmpty ? node.label : node.tag;
                  final included = !_excluded.contains(node.tag);

                  return CheckboxListTile(
                    value: included,
                    dense: true,
                    title: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: included ? null : cs.onSurfaceVariant,
                      ),
                    ),
                    subtitle: Text(
                      '${node.scheme} · ${node.server}:${node.port}',
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

          // Apply button
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
