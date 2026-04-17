import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  late TextEditingController _jsonCtrl;
  String _originalTag = '';
  String _scheme = '';
  String _serverInfo = '';
  String _detour = '';
  List<String> _availableNodes = [];

  @override
  void initState() {
    super.initState();
    _tagCtrl = TextEditingController();
    _jsonCtrl = TextEditingController();
    unawaited(_load());
  }

  @override
  void dispose() {
    _tagCtrl.dispose();
    _jsonCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final connections = widget.entry.source.connections;
    if (connections.isEmpty) return;

    final first = connections.first;


    if (first.trimLeft().startsWith('{')) {
      // Already JSON
      try {
        final parsed = jsonDecode(first) as Map<String, dynamic>;
        _originalTag = parsed['tag']?.toString() ?? '';
        _scheme = parsed['type']?.toString() ?? '';
        final server = parsed['server']?.toString() ?? '';
        final port = parsed['server_port']?.toString() ?? '';
        _serverInfo = port.isNotEmpty ? '$server:$port' : server;
        _jsonCtrl.text = const JsonEncoder.withIndent('  ').convert(parsed);
      } catch (_) {
        _originalTag = first.length > 30 ? first.substring(0, 30) : first;
        _jsonCtrl.text = first;
      }
    } else {
      // URI-based node — parse to outbound JSON
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
      _jsonCtrl.text = const JsonEncoder.withIndent('  ').convert(node.outbound);
    }

    _tagCtrl.text = _originalTag;

    // Read detour from JSON
    try {
      final parsed = jsonDecode(_jsonCtrl.text);
      if (parsed is Map<String, dynamic>) {
        _detour = parsed['detour']?.toString() ?? '';
      }
    } catch (_) {}

    // Load available direct servers for detour dropdown
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

  void _saveJson() {
    try {
      final parsed = jsonDecode(_jsonCtrl.text);
      // Re-serialize as single connection
      final jsonStr = jsonEncode(parsed is List ? parsed.first : parsed);
      // Update the source via controller
      widget.subController.updateConnectionAt(widget.index, [jsonStr]);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('JSON saved')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Invalid JSON: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(_tagCtrl.text.isNotEmpty ? _tagCtrl.text : 'Node Settings'),
        actions: [
          IconButton(
            tooltip: 'Save',
            icon: const Icon(Icons.save),
            onPressed: _saveJson,
          ),
        ],
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

                // --- Detour section ---
                _sectionHeader('Detour', 'Route through another server first', theme),
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
                      // Update detour in JSON
                      try {
                        final parsed = jsonDecode(_jsonCtrl.text);
                        if (parsed is Map<String, dynamic>) {
                          if (_detour.isNotEmpty) {
                            parsed['detour'] = _detour;
                          } else {
                            parsed.remove('detour');
                          }
                          _jsonCtrl.text = const JsonEncoder.withIndent('  ').convert(parsed);
                        }
                      } catch (_) {}
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Text(
                    _detour.isEmpty
                        ? 'Traffic goes directly to this server.'
                        : 'Phone \u2192 $_detour \u2192 $_originalTag \u2192 Internet',
                    style: theme.textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ),
                const SizedBox(height: 16),

                // --- JSON editor ---
                _sectionHeader('Outbound JSON', 'Edit tag, detour, and all server parameters', theme),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Stack(
                      children: [
                        TextField(
                          controller: _jsonCtrl,
                          maxLines: null,
                          minLines: 8,
                          style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            isDense: true,
                            contentPadding: EdgeInsets.fromLTRB(12, 12, 40, 12),
                          ),
                        ),
                        Positioned(
                          top: 4,
                          right: 4,
                          child: IconButton(
                            icon: const Icon(Icons.copy, size: 16),
                            tooltip: 'Copy JSON',
                            visualDensity: VisualDensity.compact,
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: _jsonCtrl.text));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('JSON copied')),
                              );
                            },
                          ),
                        ),
                      ],
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
