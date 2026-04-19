import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../controllers/home_controller.dart';
import '../controllers/subscription_controller.dart';
import '../services/template_loader.dart';
import '../services/settings_storage.dart';

class DnsSettingsScreen extends StatefulWidget {
  const DnsSettingsScreen({
    super.key,
    required this.subController,
    required this.homeController,
  });

  final SubscriptionController subController;
  final HomeController homeController;

  @override
  State<DnsSettingsScreen> createState() => _DnsSettingsScreenState();
}

class _DnsSettingsScreenState extends State<DnsSettingsScreen> {
  /// Merged server list: template defaults + user overrides.
  List<Map<String, dynamic>> _servers = [];
  late TextEditingController _rulesCtrl;
  bool _loading = true;
  Timer? _saveTimer;

  String _strategy = '';
  bool _independentCache = false;
  String _dnsFinal = '';
  String _defaultResolver = '';

  @override
  void initState() {
    super.initState();
    _rulesCtrl = TextEditingController();
    unawaited(_load());
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _rulesCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final template = await TemplateLoader.load();
    final userServers = await SettingsStorage.getDnsServers();
    final rulesJson = await SettingsStorage.getDnsRules();
    final vars = await SettingsStorage.getAllVars();

    // Parse dns_options from template
    final templateDns = template.dnsOptions;
    final templateServers = (templateDns['servers'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map((s) => Map<String, dynamic>.from(s))
        .toList();
    final templateRules = templateDns['rules'] as List<dynamic>? ?? [];

    // Merge: if user has saved servers, use those; otherwise use template defaults
    final servers = userServers.isNotEmpty ? userServers : templateServers;

    // Rules: user override or template default
    final rules = rulesJson.isNotEmpty
        ? rulesJson
        : (templateRules.isNotEmpty ? const JsonEncoder.withIndent('  ').convert(templateRules) : '');

    if (mounted) {
      setState(() {
        _servers = servers;
        _rulesCtrl.text = rules;
        _strategy = vars['dns_strategy'] ?? 'prefer_ipv4';
        _independentCache = vars['dns_independent_cache'] == 'true';
        _dnsFinal = vars['dns_final'] ?? '';
        _defaultResolver = vars['dns_default_domain_resolver'] ?? '';
        _loading = false;
      });
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () => unawaited(_save()));
  }

  Future<void> _save() async {
    await SettingsStorage.saveDnsServers(_servers);
    await SettingsStorage.saveDnsRules(_rulesCtrl.text);
    await SettingsStorage.setVar('dns_strategy', _strategy);
    await SettingsStorage.setVar('dns_independent_cache', _independentCache.toString());
    await SettingsStorage.setVar('dns_final', _dnsFinal);
    await SettingsStorage.setVar('dns_default_domain_resolver', _defaultResolver);

    if (!mounted) return;
    final config = await widget.subController.generateConfig();
    if (config != null && mounted) {
      await widget.homeController.saveParsedConfig(config);
    }
  }

  List<String> get _enabledServerTags {
    return _servers
        .where((s) => s['enabled'] != false)
        .map((s) => s['tag']?.toString() ?? '')
        .where((t) => t.isNotEmpty)
        .toList();
  }

  void _addServer() {
    // Load available presets from template that aren't already added
    _showJsonEditor(-1);
  }

  void _showJsonEditor(int index) {
    final isNew = index < 0;
    final json = isNew
        ? '{\n  "type": "udp",\n  "tag": "dns_new",\n  "server": "1.1.1.1",\n  "server_port": 53,\n  "description": "My DNS",\n  "enabled": true\n}'
        : const JsonEncoder.withIndent('  ').convert(_servers[index]);
    final ctrl = TextEditingController(text: json);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(isNew ? 'Add DNS Server' : 'Edit DNS Server', style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: 12),
            SizedBox(
              height: 200,
              child: TextField(
                controller: ctrl,
                maxLines: null,
                expands: true,
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () {
                try {
                  final obj = jsonDecode(ctrl.text) as Map<String, dynamic>;
                  if ((obj['tag']?.toString() ?? '').isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Tag is required')));
                    return;
                  }
                  Navigator.pop(ctx);
                  setState(() {
                    if (isNew) {
                      _servers.add(obj);
                    } else {
                      _servers[index] = obj;
                    }
                    _scheduleSave();
                  });
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Invalid JSON: $e')));
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    ).then((_) => ctrl.dispose());
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('DNS Settings')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final theme = Theme.of(context);
    final serverTags = _enabledServerTags;

    return Scaffold(
      appBar: AppBar(title: const Text('DNS Settings')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(12, 12, 12, MediaQuery.of(context).padding.bottom + 24),
        children: [
          // --- Servers ---
          Row(
            children: [
              Text('DNS Servers', style: theme.textTheme.titleMedium),
              const Spacer(),
              IconButton(icon: const Icon(Icons.add), onPressed: _addServer),
            ],
          ),
          const SizedBox(height: 4),
          ...List.generate(_servers.length, _buildServerTile),

          const Divider(height: 32),

          // --- Strategy ---
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Strategy'),
            trailing: DropdownButton<String>(
              value: ['prefer_ipv4', 'prefer_ipv6', 'ipv4_only', 'ipv6_only'].contains(_strategy)
                  ? _strategy : 'prefer_ipv4',
              items: const [
                DropdownMenuItem(value: 'prefer_ipv4', child: Text('prefer_ipv4')),
                DropdownMenuItem(value: 'prefer_ipv6', child: Text('prefer_ipv6')),
                DropdownMenuItem(value: 'ipv4_only', child: Text('ipv4_only')),
                DropdownMenuItem(value: 'ipv6_only', child: Text('ipv6_only')),
              ],
              onChanged: (v) { if (v != null) setState(() { _strategy = v; _scheduleSave(); }); },
            ),
          ),

          // --- Independent Cache ---
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Independent Cache'),
            subtitle: const Text('Separate cache per DNS server', style: TextStyle(fontSize: 12)),
            value: _independentCache,
            onChanged: (v) => setState(() { _independentCache = v; _scheduleSave(); }),
          ),

          const Divider(height: 32),

          // --- DNS Rules ---
          Text('DNS Rules', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          SizedBox(
            height: 150,
            child: TextField(
              controller: _rulesCtrl,
              maxLines: null,
              expands: true,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '[\n  {"server": "yandex_doh", "rule_set": "ru-domains"}\n]',
                isDense: true,
              ),
              onChanged: (_) => _scheduleSave(),
            ),
          ),

          const Divider(height: 32),

          // --- Final ---
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('DNS Final'),
            subtitle: const Text('Fallback DNS server', style: TextStyle(fontSize: 12)),
            trailing: DropdownButton<String>(
              value: serverTags.contains(_dnsFinal) ? _dnsFinal : null,
              hint: const Text('select'),
              items: serverTags.map((t) => DropdownMenuItem(value: t, child: Text(t, style: const TextStyle(fontSize: 13)))).toList(),
              onChanged: (v) { if (v != null) setState(() { _dnsFinal = v; _scheduleSave(); }); },
            ),
          ),

          // --- Default Resolver ---
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Default Domain Resolver'),
            subtitle: const Text('Resolves domains in DNS server addresses', style: TextStyle(fontSize: 12)),
            trailing: DropdownButton<String>(
              value: serverTags.contains(_defaultResolver) ? _defaultResolver : null,
              hint: const Text('select'),
              items: serverTags.map((t) => DropdownMenuItem(value: t, child: Text(t, style: const TextStyle(fontSize: 13)))).toList(),
              onChanged: (v) { if (v != null) setState(() { _defaultResolver = v; _scheduleSave(); }); },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildServerTile(int index) {
    final server = _servers[index];
    final tag = server['tag']?.toString() ?? '';
    final type = server['type']?.toString() ?? '';
    final addr = server['server']?.toString() ?? '';
    final desc = server['description']?.toString() ?? '';
    final enabled = server['enabled'] != false;

    return Card(
      child: ListTile(
        leading: SizedBox(
          width: 40,
          child: Switch(
            value: enabled,
            onChanged: (v) {
              setState(() {
                _servers[index] = Map<String, dynamic>.from(server)..['enabled'] = v;
                _scheduleSave();
              });
            },
          ),
        ),
        title: Text(
          desc.isNotEmpty ? desc : tag,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: enabled ? null : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        subtitle: Text(
          '$tag · $type${addr.isNotEmpty ? ' · $addr' : ''}',
          style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 18),
              onPressed: () => _showJsonEditor(index),
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              icon: Icon(Icons.delete_outline, size: 18, color: Theme.of(context).colorScheme.error),
              onPressed: () {
                setState(() { _servers.removeAt(index); _scheduleSave(); });
              },
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }
}
