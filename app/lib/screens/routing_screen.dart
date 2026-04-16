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
  final _downloadingRules = <String>{}; // labels of rules currently downloading SRS
  Timer? _saveTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () => unawaited(_apply()));
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

          // ---- App Groups ----
          Text('App Groups', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Group apps and route them through a chosen outbound.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 8),
          ...List.generate(_appRules.length, _buildAppRuleTile),
          TextButton.icon(
            onPressed: _addAppRule,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add App Group'),
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
          _scheduleSave();
        });
      },
    );
  }

  Widget _buildRuleTile(SelectableRule rule) {
    final isEnabled = _enabledRules.contains(rule.label);
    final hasOutbound = rule.rule.containsKey('outbound');
    final hasSrs = rule.ruleSets.isNotEmpty;
    final options = _outboundOptions();
    final currentOutbound = _ruleOutbounds[rule.label] ??
        (rule.rule['outbound'] as String? ?? '');

    final switchWidget = _downloadingRules.contains(rule.label)
        ? const SizedBox(
            width: 48, height: 24,
            child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
          )
        : Switch(
            value: isEnabled,
            onChanged: (val) {
              if (val && hasSrs) {
                _enableRuleWithDownload(rule);
              } else {
                setState(() {
                  if (val) {
                    _enabledRules.add(rule.label);
                  } else {
                    _enabledRules.remove(rule.label);
                  }
                  _scheduleSave();
                });
              }
            },
          );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              switchWidget,
              const SizedBox(width: 8),
              Expanded(child: Text(rule.label)),
              if (hasSrs)
                Tooltip(
                  message: 'Requires rule set download',
                  child: Icon(Icons.cloud_download_outlined, size: 16,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              if (hasOutbound) ...[
                const SizedBox(width: 8),
                SizedBox(
                  width: 110,
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
                              _scheduleSave();
                            });
                          }
                        : null,
                  ),
                ),
              ],
            ],
          ),
          if (rule.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 56),
              child: Text(rule.description, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ),
        ],
      ),
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
              _scheduleSave();
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
        _scheduleSave();
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
      _appRules.add(AppRule(name: 'Group ${_appRules.length + 1}'));
      _scheduleSave();
    });
  }

  Widget _buildAppRuleTile(int index) {
    final rule = _appRules[index];
    final options = _outboundOptions();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Row 1: editable name + outbound dropdown + delete
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => _openAppPicker(index),
                  child: Text(rule.name, style: const TextStyle(fontWeight: FontWeight.w500)),
                ),
              ),
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
                      _scheduleSave();
                    });
                  },
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                tooltip: 'Delete group',
                onPressed: () {
                  setState(() {
                    _appRules.removeAt(index);
                    _scheduleSave();
                  });
                },
              ),
            ],
          ),
          // Row 2: apps count, tap to select
          GestureDetector(
            onTap: () => _openAppPicker(index),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                rule.packages.isEmpty
                    ? 'Tap to select apps'
                    : '${rule.packages.length} apps — tap to edit',
                style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.primary),
              ),
            ),
          ),
          const Divider(height: 1),
        ],
      ),
    );
  }

  bool _pickerOpen = false;

  Future<void> _openAppPicker(int index) async {
    if (_pickerOpen) return;
    _pickerOpen = true;
    final rule = _appRules[index];
    final result = await Navigator.push<AppPickerResult>(
      context,
      MaterialPageRoute(
        builder: (_) => AppPickerScreen(
          ruleName: rule.name,
          selected: rule.packages.toSet(),
        ),
      ),
    );
    _pickerOpen = false;
    if (result != null && mounted) {
      setState(() {
        rule.packages = result.packages;
        if (result.name.isNotEmpty) rule.name = result.name;
        _scheduleSave();
      });
    }
  }
}

class _OutboundOption {
  const _OutboundOption({required this.label, required this.tag});
  final String label;
  final String tag;
}
