import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/subscription_controller.dart';
import '../services/config_builder.dart';
import '../services/settings_storage.dart';

class NodeSettingsScreen extends StatefulWidget {
  const NodeSettingsScreen({
    super.key,
    required this.entry,
    required this.index,
    required this.subController,
  });

  final SubscriptionEntry entry;
  final int index;
  final SubscriptionController subController;

  @override
  State<NodeSettingsScreen> createState() => _NodeSettingsScreenState();
}

class _NodeSettingsScreenState extends State<NodeSettingsScreen> {
  late TextEditingController _tagCtrl;
  String _detour = '';
  List<String> _availableNodes = [];
  String _originalTag = '';
  String _scheme = '';
  String _serverInfo = '';
  Timer? _saveTimer;

  @override
  void initState() {
    super.initState();
    _tagCtrl = TextEditingController();
    unawaited(_load());
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _tagCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // Parse the node to get info
    final connections = widget.entry.source.connections;
    if (connections.isEmpty) return;

    final tagCounts = <String, int>{};
    final nodes = await ConfigBuilder.loadAndParseNodes(
      [widget.entry.source],
      tagCounts,
    );

    if (nodes.isEmpty) return;
    final node = nodes.first;
    _originalTag = node.tag;
    _scheme = node.scheme;
    _serverInfo = '${node.server}:${node.port}';

    // Load existing overrides
    final overrides = await SettingsStorage.getNodeOverrides();
    final ov = overrides[_originalTag] ?? {};
    _tagCtrl.text = ov['custom_tag'] ?? _originalTag;
    _detour = ov['detour'] ?? '';

    // Load only direct servers for detour dropdown (not subscriptions — they change)
    final allSources = await SettingsStorage.getProxySources();
    final directSources = allSources
        .where((s) => s.source.isEmpty && s.connections.isNotEmpty)
        .toList();
    final directNodes = await ConfigBuilder.loadAndParseNodes(directSources, {});
    _availableNodes = directNodes
        .map((n) => n.tag)
        .where((t) => t != _originalTag)
        .toList();

    if (mounted) setState(() {});
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () => unawaited(_save()));
  }

  Future<void> _save() async {
    final customTag = _tagCtrl.text.trim();
    await SettingsStorage.saveNodeOverride(
      _originalTag,
      customTag: customTag == _originalTag ? '' : customTag,
      detour: _detour,
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Settings saved, regenerate config to apply')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(_tagCtrl.text.isNotEmpty ? _tagCtrl.text : 'Node Settings'),
      ),
      body: _originalTag.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // --- Info section ---
                _sectionHeader('Info', 'Protocol and server details', theme),
                ListTile(
                  leading: const Icon(Icons.security, size: 20),
                  title: const Text('Protocol'),
                  trailing: Text(_scheme, style: theme.textTheme.bodyMedium),
                ),
                ListTile(
                  leading: const Icon(Icons.dns, size: 20),
                  title: const Text('Server'),
                  trailing: Text(_serverInfo, style: theme.textTheme.bodyMedium),
                ),
                const SizedBox(height: 16),

                // --- Tag section ---
                _sectionHeader('Display Name', 'How this node appears in lists and statistics', theme),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: TextField(
                    controller: _tagCtrl,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'Node name',
                      isDense: true,
                    ),
                    onChanged: (_) => _scheduleSave(),
                  ),
                ),
                const SizedBox(height: 16),

                // --- Detour section ---
                _sectionHeader('Detour', 'Route through another server', theme),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: DropdownButtonFormField<String>(
                    initialValue: _detour.isEmpty ? '' : (_availableNodes.contains(_detour) ? _detour : ''),
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'Detour server',
                      isDense: true,
                    ),
                    items: [
                      const DropdownMenuItem(value: '', child: Text('None (direct)')),
                      ..._availableNodes.map((tag) =>
                          DropdownMenuItem(value: tag, child: Text(tag, overflow: TextOverflow.ellipsis))),
                    ],
                    onChanged: (v) {
                      setState(() => _detour = v ?? '');
                      _scheduleSave();
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Text(
                    _detour.isEmpty
                        ? 'Traffic goes directly to this server.'
                        : 'Phone \u2192 $_detour \u2192 ${_tagCtrl.text} \u2192 Internet',
                    style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Text(
                    'Useful for bypassing blocks or adding an extra hop for privacy.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _sectionHeader(String title, String description, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            description,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const Divider(),
        ],
      ),
    );
  }
}
