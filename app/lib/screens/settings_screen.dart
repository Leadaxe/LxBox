import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../controllers/home_controller.dart';
import '../controllers/subscription_controller.dart';
import '../models/parser_config.dart';
import '../services/config_builder.dart';
import '../services/settings_storage.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.subController,
    required this.homeController,
  });

  final SubscriptionController subController;
  final HomeController homeController;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  WizardTemplate? _template;
  final _varValues = <String, String>{};
  final _enabledRules = <String>{};
  bool _loading = true;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final template = await ConfigBuilder.loadTemplate();
    final storedVars = await SettingsStorage.getAllVars();
    final storedRules = await SettingsStorage.getEnabledRules();

    for (final v in template.vars) {
      _varValues[v.name] = storedVars[v.name] ?? v.defaultValue;
    }

    if (storedRules.isEmpty) {
      for (final r in template.selectableRules) {
        if (r.defaultEnabled) _enabledRules.add(r.label);
      }
    } else {
      _enabledRules.addAll(storedRules);
    }

    setState(() {
      _template = template;
      _loading = false;
    });
  }

  Future<void> _apply() async {
    for (final entry in _varValues.entries) {
      await SettingsStorage.setVar(entry.key, entry.value);
    }
    await SettingsStorage.saveEnabledRules(_enabledRules);

    if (!mounted) return;

    final config = await widget.subController.generateConfig();
    if (config != null && mounted) {
      final ok = await widget.homeController.saveParsedConfig(config);
      if (ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Settings applied, config regenerated')),
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

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final template = _template!;
    final editableVars =
        template.vars.where((v) => v.isEditable).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
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
          ...editableVars.map(_buildVarWidget),
          const Divider(height: 32),
          Text(
            'Routing Rules',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          ...template.selectableRules.map(_buildRuleWidget),
        ],
      ),
    );
  }

  Widget _buildVarWidget(WizardVar v) {
    switch (v.type) {
      case 'bool':
        return SwitchListTile(
          title: Text(v.title.isNotEmpty ? v.title : v.name),
          subtitle: v.tooltip.isNotEmpty ? Text(v.tooltip, style: const TextStyle(fontSize: 12)) : null,
          value: _varValues[v.name] == 'true',
          onChanged: (val) {
            setState(() {
              _varValues[v.name] = val.toString();
              _dirty = true;
            });
          },
        );
      case 'enum':
        return ListTile(
          title: Text(v.title.isNotEmpty ? v.title : v.name),
          subtitle: v.tooltip.isNotEmpty ? Text(v.tooltip, style: const TextStyle(fontSize: 12)) : null,
          trailing: DropdownButton<String>(
            value: v.options.contains(_varValues[v.name])
                ? _varValues[v.name]
                : v.defaultValue,
            items: v.options
                .map((o) => DropdownMenuItem(value: o, child: Text(o)))
                .toList(),
            onChanged: (val) {
              if (val == null) return;
              setState(() {
                _varValues[v.name] = val;
                _dirty = true;
              });
            },
          ),
        );
      case 'secret':
        return ListTile(
          title: Text(v.title.isNotEmpty ? v.title : v.name),
          subtitle: v.tooltip.isNotEmpty ? Text(v.tooltip, style: const TextStyle(fontSize: 12)) : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 150,
                child: TextField(
                  controller: TextEditingController(text: _varValues[v.name]),
                  obscureText: true,
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  ),
                  onChanged: (val) {
                    _varValues[v.name] = val;
                    _dirty = true;
                  },
                ),
              ),
              IconButton(
                tooltip: 'Generate random',
                icon: const Icon(Icons.refresh, size: 20),
                onPressed: () {
                  final rng = Random.secure();
                  final bytes = List.generate(16, (_) => rng.nextInt(256));
                  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
                  setState(() {
                    _varValues[v.name] = hex;
                    _dirty = true;
                  });
                },
              ),
            ],
          ),
        );
      default: // text
        return ListTile(
          title: Text(v.title.isNotEmpty ? v.title : v.name),
          subtitle: v.tooltip.isNotEmpty ? Text(v.tooltip, style: const TextStyle(fontSize: 12)) : null,
          trailing: SizedBox(
            width: 180,
            child: TextField(
              controller: TextEditingController(text: _varValues[v.name]),
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              ),
              onChanged: (val) {
                _varValues[v.name] = val;
                _dirty = true;
              },
            ),
          ),
        );
    }
  }

  Widget _buildRuleWidget(SelectableRule rule) {
    return SwitchListTile(
      title: Text(rule.label),
      subtitle: rule.description.isNotEmpty
          ? Text(rule.description, style: const TextStyle(fontSize: 12))
          : null,
      value: _enabledRules.contains(rule.label),
      onChanged: (val) {
        setState(() {
          if (val) {
            _enabledRules.add(rule.label);
          } else {
            _enabledRules.remove(rule.label);
          }
          _dirty = true;
        });
      },
    );
  }
}
