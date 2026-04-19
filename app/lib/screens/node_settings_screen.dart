import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../controllers/subscription_controller.dart';
import '../models/server_list.dart';
import '../models/template_vars.dart';

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
    // v2: узел уже распарсен в entry.list.nodes.first.
    final nodes = widget.entry.list.nodes;
    if (nodes.isEmpty) return;
    final node = nodes.first;

    _originalTag = node.tag;
    _scheme = node.protocol;
    _serverInfo = '${node.server}:${node.port}';
    _jsonCtrl.text = const JsonEncoder.withIndent('  ')
        .convert(node.emit(TemplateVars.empty).map);
    _tagCtrl.text = _originalTag;

    // Detour хранится в `entry.detourPolicy.overrideDetour` (применяется
    // builder'ом в server_list_build). Раньше писали в JSON node.detour,
    // но parseSingboxEntry это поле не восстанавливает — терялось при save.
    _detour = widget.entry.overrideDetour;

    // Доступные detour-теги: все узлы всех `UserServer` кроме себя.
    final tags = <String>[];
    for (final e in widget.subController.entries) {
      if (e.list is! UserServer) continue;
      for (final n in e.list.nodes) {
        if (n.tag.isNotEmpty && n.tag != _originalTag) tags.add(n.tag);
      }
    }
    _availableNodes = tags;

    if (mounted) setState(() {});
  }

  /// Префикс для нод которые юзер маркает как detour-сервера. Внутри
  /// конфига это просто часть `tag`'а — никаких отдельных флагов. Префикс
  /// `⚙ ` удобно сортировать/фильтровать в UI и понятно что это детур.
  static const String _detourPrefix = '⚙ ';
  bool get _isMarkedDetour => _tagCtrl.text.startsWith(_detourPrefix);

  void _toggleDetourMark(bool on) {
    setState(() {
      if (on && !_isMarkedDetour) {
        _tagCtrl.text = '$_detourPrefix${_tagCtrl.text}';
      } else if (!on && _isMarkedDetour) {
        _tagCtrl.text = _tagCtrl.text.substring(_detourPrefix.length);
      }
    });
  }

  void _saveJson() {
    try {
      final parsed = jsonDecode(_jsonCtrl.text);
      final map = parsed is List ? parsed.first : parsed;
      // Подмешиваем edited tag из отдельного поля (юзер мог менять
      // только tag и забыть про JSON-редактор).
      if (map is Map<String, dynamic>) {
        final newTag = _tagCtrl.text.trim();
        if (newTag.isNotEmpty) map['tag'] = newTag;
      }
      final jsonStr = jsonEncode(map);
      widget.subController.updateConnectionAt(widget.index, [jsonStr]);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved')),
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
              padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(context).padding.bottom + 24),
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
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: TextField(
                    controller: _tagCtrl,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'Tag',
                      hintText: 'Display name in node list',
                      isDense: true,
                      prefixIcon: Icon(Icons.label_outline, size: 18),
                    ),
                  ),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.alt_route, size: 20),
                  title: const Text('Mark as detour server'),
                  subtitle: const Text(
                      'Adds ⚙ prefix — use when this node serves as the first '
                      'hop for other nodes (Override detour in subscription)'),
                  value: _isMarkedDetour,
                  onChanged: _toggleDetourMark,
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
                      // Persist через ServerList.detourPolicy.overrideDetour —
                      // builder подхватит и перезапишет main.map['detour'].
                      // Не трогаем JSON ноды, иначе после save через
                      // parseSingboxEntry поле снова потеряется.
                      widget.entry.overrideDetour = _detour;
                      unawaited(widget.subController.persistSources());
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
