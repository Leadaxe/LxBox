import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/home_controller.dart';
import '../controllers/subscription_controller.dart';
import '../models/parser_config.dart';
import '../services/settings_storage.dart';
import '../services/template_loader.dart';
import '../widgets/template_var_list.dart';

/// VPN Settings — экран для sing-box core variables (`chapter: core`).
/// Routing- и DNS-специфичные vars (chapter: routing/dns) живут на своих
/// экранах (Routing, DNS Settings). Фильтрация по chapter — в [build].
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
  bool _loading = true;
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

  Future<void> _load() async {
    final template = await TemplateLoader.load();
    final storedVars = await SettingsStorage.getAllVars();
    for (final v in template.vars) {
      _varValues[v.name] = storedVars[v.name] ?? v.defaultValue;
    }
    setState(() {
      _template = template;
      _loading = false;
    });
  }

  void _onVarChanged(String name, String value) {
    _varValues[name] = value;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () async {
      await SettingsStorage.setVar(name, value);
      await _regenerateConfig();
    });
  }

  Future<void> _regenerateConfig() async {
    if (!mounted) return;
    final config = await widget.subController.generateConfig();
    if (config == null || !mounted) return;
    final ok = await widget.homeController.saveParsedConfig(config);
    if (!ok || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Settings applied, config regenerated')),
    );
    if (widget.homeController.state.tunnelUp && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Restart VPN to apply changes')),
      );
    }
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
    final editableVars = template
        .varsFor('core')
        .where((v) => v.isEditable)
        .toList();

    if (editableVars.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: const Center(child: Text('No configurable variables')),
      );
    }

    final sectionDescriptions = {
      for (final s in template.sectionsFor('core')) s.title: s.description,
    };

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          12,
          12,
          12,
          MediaQuery.of(context).padding.bottom + 24,
        ),
        children: [
          TemplateVarListView(
            vars: editableVars,
            initialValues: _varValues,
            sectionDescriptions: sectionDescriptions,
            onChanged: _onVarChanged,
          ),
        ],
      ),
    );
  }
}
