import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/home_controller.dart';
import '../controllers/subscription_controller.dart';
import '../models/parser_config.dart';
import '../services/config_builder.dart';
import '../services/rule_set_downloader.dart';
import '../services/settings_storage.dart';
import 'app_picker_screen.dart';

class RoutingScreen extends StatefulWidget {
  const RoutingScreen({
    super.key,
    required this.subController,
    required this.homeController,
  });

  final SubscriptionController subController;
  final HomeController homeController;

  @override
  State<RoutingScreen> createState() => _RoutingScreenState();
}

class _RoutingScreenState extends State<RoutingScreen> {
  WizardTemplate? _template;
  final _enabledRules = <String>{};
  final _enabledGroups = <String>{};
  final _ruleOutbounds = <String, String>{};
  String _routeFinal = '';
  final _appRules = <AppRule>[];
  bool _loading = true;
  bool _dirty = false;
  final _downloadingRules = <String>{}; // labels of rules currently downloading SRS

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final template = await ConfigBuilder.loadTemplate();
    final storedRules = await SettingsStorage.getEnabledRules();
    final storedGroups = await SettingsStorage.getEnabledGroups();
    final storedOutbounds = await SettingsStorage.getRuleOutbounds();
    final storedFinal = await SettingsStorage.getRouteFinal();
    final storedAppRules = await SettingsStorage.getAppRules();

    if (storedRules.isEmpty) {
      for (final r in template.selectableRules) {
        if (r.defaultEnabled) _enabledRules.add(r.label);
      }
    } else {
      _enabledRules.addAll(storedRules);
    }

    if (storedGroups.isEmpty) {
      for (final g in template.presetGroups) {
        if (g.defaultEnabled) _enabledGroups.add(g.tag);
      }
    } else {
      _enabledGroups.addAll(storedGroups);
    }

    _ruleOutbounds.addAll(storedOutbounds);
    _routeFinal = storedFinal.isNotEmpty ? storedFinal : 'proxy-out';
    _appRules.addAll(storedAppRules);

    setState(() {
      _template = template;
      _loading = false;
    });
  }

  Future<void> _apply() async {
    await SettingsStorage.saveEnabledRules(_enabledRules);
    await SettingsStorage.saveEnabledGroups(_enabledGroups);
    await SettingsStorage.saveRuleOutbounds(_ruleOutbounds);
    await SettingsStorage.saveRouteFinal(_routeFinal);
    await SettingsStorage.saveAppRules(_appRules);

    if (!mounted) return;

    final config = await widget.subController.generateConfig();
    if (config != null && mounted) {
      final ok = await widget.homeController.saveParsedConfig(config);
      if (ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Routing applied, config regenerated')),
        );
        if (widget.homeController.state.tunnelUp) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Restart VPN to apply changes')),
          );
        }
      }
    }

    _dirty = false;
    setState(() {});
  }

  /// Returns the list of available outbound options depending on enabled groups.
  List<_OutboundOption> _outboundOptions() {
    final opts = <_OutboundOption>[
      const _OutboundOption(label: 'direct', tag: 'direct-out'),
      const _OutboundOption(label: 'proxy', tag: 'proxy-out'),
      const _OutboundOption(label: 'auto', tag: 'auto-proxy-out'),
    ];
    final template = _template;
    if (template != null) {
      for (final g in template.presetGroups) {
        if (_enabledGroups.contains(g.tag) &&
            g.tag != 'proxy-out' &&
            g.tag != 'auto-proxy-out') {
          opts.add(_OutboundOption(label: g.label.isNotEmpty ? g.label : g.tag, tag: g.tag));
        }
      }
    }
    return opts;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Routing')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final template = _template!;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Routing'),
        actions: [
          TextButton(
            onPressed: _dirty ? () => unawaited(_apply()) : null,
            child: const Text('Apply'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          // ---- Proxy Groups ----
          Text('Proxy Groups', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Enabled groups appear in the selector on the home screen.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 8),
          ...template.presetGroups.map(_buildGroupTile),

          const Divider(height: 32),

          // ---- Routing Rules ----
          Text('Routing Rules', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ...template.selectableRules.map(_buildRuleTile),

          const Divider(height: 32),

          // ---- App Rules ----
          Text('App Rules', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Route specific apps through a chosen outbound.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 8),
          ...List.generate(_appRules.length, _buildAppRuleTile),
          TextButton.icon(
            onPressed: _addAppRule,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add App Rule'),
          ),

          const Divider(height: 24),

          // ---- Route Final ----
          _buildRouteFinalTile(),
        ],
      ),
    );
  }

  Widget _buildGroupTile(PresetGroup group) {
    return SwitchListTile(
      title: Text(group.label.isNotEmpty ? group.label : group.tag),
      subtitle: Text(
        '${group.type} \u00b7 ${group.tag}',
        style: const TextStyle(fontSize: 12),
      ),
      value: _enabledGroups.contains(group.tag),
      onChanged: (val) {
        setState(() {
          if (val) {
            _enabledGroups.add(group.tag);
          } else {
            _enabledGroups.remove(group.tag);
          }
          _dirty = true;
        });
      },
    );
  }

  Widget _buildRuleTile(SelectableRule rule) {
    final isEnabled = _enabledRules.contains(rule.label);
    final hasOutbound = rule.rule.containsKey('outbound');
    final options = _outboundOptions();
    final currentOutbound = _ruleOutbounds[rule.label] ??
        (rule.rule['outbound'] as String? ?? '');

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: _downloadingRules.contains(rule.label)
          ? const SizedBox(width: 48, height: 48, child: Padding(
              padding: EdgeInsets.all(12),
              child: CircularProgressIndicator(strokeWidth: 2),
            ))
          : Switch(
              value: isEnabled,
              onChanged: (val) {
                if (val && rule.ruleSets.isNotEmpty) {
                  _enableRuleWithDownload(rule);
                } else {
                  setState(() {
                    if (val) {
                      _enabledRules.add(rule.label);
                    } else {
                      _enabledRules.remove(rule.label);
                    }
                    _dirty = true;
                  });
                }
              },
            ),
      title: Text(rule.label),
      subtitle: rule.description.isNotEmpty
          ? Text(rule.description, style: const TextStyle(fontSize: 12))
          : null,
      trailing: hasOutbound
          ? SizedBox(
              width: 120,
              child: DropdownButton<String>(
                isExpanded: true,
                isDense: true,
                value: options.any((o) => o.tag == currentOutbound)
                    ? currentOutbound
                    : options.first.tag,
                items: options
                    .map((o) => DropdownMenuItem(value: o.tag, child: Text(o.label, style: const TextStyle(fontSize: 13))))
                    .toList(),
                onChanged: isEnabled
                    ? (val) {
                        if (val == null) return;
                        setState(() {
                          _ruleOutbounds[rule.label] = val;
                          _dirty = true;
                        });
                      }
                    : null,
              ),
            )
          : null,
    );
  }

  Widget _buildRouteFinalTile() {
    final options = _outboundOptions();
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      title: const Text('Default traffic'),
      subtitle: const Text(
        'Fallback for unmatched traffic (route.final)',
        style: TextStyle(fontSize: 12),
      ),
      trailing: SizedBox(
        width: 120,
        child: DropdownButton<String>(
          isExpanded: true,
          isDense: true,
          value: options.any((o) => o.tag == _routeFinal) ? _routeFinal : options.first.tag,
          items: options
              .map((o) => DropdownMenuItem(value: o.tag, child: Text(o.label, style: const TextStyle(fontSize: 13))))
              .toList(),
          onChanged: (val) {
            if (val == null) return;
            setState(() {
              _routeFinal = val;
              _dirty = true;
            });
          },
        ),
      ),
    );
  }

  Future<void> _enableRuleWithDownload(SelectableRule rule) async {
    setState(() => _downloadingRules.add(rule.label));

    // Pre-download all remote SRS rule sets for this rule
    var allOk = true;
    for (final rs in rule.ruleSets) {
      final tag = rs['tag'] as String?;
      final url = rs['url'] as String?;
      if (tag == null || url == null || rs['type'] != 'remote') continue;
      final path = await RuleSetDownloader.ensureCached(tag, url);
      if (path == null) {
        allOk = false;
      }
    }

    if (!mounted) return;

    if (allOk) {
      setState(() {
        _enabledRules.add(rule.label);
        _downloadingRules.remove(rule.label);
        _dirty = true;
      });
    } else {
      setState(() => _downloadingRules.remove(rule.label));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to download rule sets for "${rule.label}". Check internet.'),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  void _addAppRule() {
    setState(() {
      _appRules.add(AppRule(name: 'Rule ${_appRules.length + 1}'));
      _dirty = true;
    });
  }

  Widget _buildAppRuleTile(int index) {
    final rule = _appRules[index];
    final options = _outboundOptions();

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      onTap: () => _openAppPicker(index),
      title: Text(rule.name),
      subtitle: Text(
        rule.packages.isEmpty
            ? 'Tap to select apps'
            : '${rule.packages.length} apps',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 100,
            child: DropdownButton<String>(
              isExpanded: true,
              isDense: true,
              value: options.any((o) => o.tag == rule.outbound) ? rule.outbound : options.first.tag,
              items: options
                  .map((o) => DropdownMenuItem(
                        value: o.tag,
                        child: Text(o.label, style: const TextStyle(fontSize: 13)),
                      ))
                  .toList(),
              onChanged: (val) {
                if (val == null) return;
                setState(() {
                  rule.outbound = val;
                  _dirty = true;
                });
              },
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20),
            tooltip: 'Delete rule',
            onPressed: () {
              setState(() {
                _appRules.removeAt(index);
                _dirty = true;
              });
            },
          ),
        ],
      ),
    );
  }

  Future<void> _openAppPicker(int index) async {
    final rule = _appRules[index];
    final result = await Navigator.push<List<String>>(
      context,
      MaterialPageRoute(
        builder: (_) => AppPickerScreen(
          ruleName: rule.name,
          selected: rule.packages.toSet(),
        ),
      ),
    );
    if (result != null && mounted) {
      setState(() {
        rule.packages = result;
        _dirty = true;
      });
    }
  }
}

class _OutboundOption {
  const _OutboundOption({required this.label, required this.tag});
  final String label;
  final String tag;
}
