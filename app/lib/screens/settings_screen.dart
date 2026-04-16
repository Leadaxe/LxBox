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

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () => unawaited(_apply()));
  }

  Future<void> _load() async {
    final template = await ConfigBuilder.loadTemplate();
    final storedVars = await SettingsStorage.getAllVars();

    for (final v in template.vars) {
      _varValues[v.name] = storedVars[v.name] ?? v.defaultValue;
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
    final editableVars = template.vars.where((v) => v.isEditable).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: editableVars.isEmpty
          ? const Center(child: Text('No configurable variables'))
          : ListView(
              padding: const EdgeInsets.all(12),
              children: editableVars.map(_buildVarWidget).toList(),
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
              _scheduleSave();
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
                _scheduleSave();
              });
            },
          ),
        );
      case 'secret':
        return _VarTextField(
          key: ValueKey('secret-${v.name}'),
          value: _varValues[v.name] ?? '',
          obscure: true,
          width: 150,
          label: v.title.isNotEmpty ? v.title : v.name,
          tooltip: v.tooltip,
          onChanged: (val) {
            _varValues[v.name] = val;
            _scheduleSave();
          },
          trailing: IconButton(
            tooltip: 'Generate random',
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: () {
              final rng = Random.secure();
              final bytes = List.generate(16, (_) => rng.nextInt(256));
              final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
              setState(() {
                _varValues[v.name] = hex;
                _scheduleSave();
              });
            },
          ),
        );
      default: // text
        return _VarTextField(
          key: ValueKey('text-${v.name}'),
          value: _varValues[v.name] ?? '',
          width: 180,
          label: v.title.isNotEmpty ? v.title : v.name,
          tooltip: v.tooltip,
          onChanged: (val) {
            _varValues[v.name] = val;
            _scheduleSave();
          },
        );
    }
  }
}

/// A self-contained text field that manages its own TextEditingController.
/// Avoids the leak of creating TextEditingController inside build().
class _VarTextField extends StatefulWidget {
  const _VarTextField({
    super.key,
    required this.value,
    required this.label,
    required this.onChanged,
    this.tooltip = '',
    this.obscure = false,
    this.width = 180,
    this.trailing,
  });

  final String value;
  final String label;
  final String tooltip;
  final bool obscure;
  final double width;
  final ValueChanged<String> onChanged;
  final Widget? trailing;

  @override
  State<_VarTextField> createState() => _VarTextFieldState();
}

class _VarTextFieldState extends State<_VarTextField> {
  late final TextEditingController _ctrl;
  bool _obscured = true;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.value);
    _obscured = widget.obscure;
  }

  @override
  void didUpdateWidget(_VarTextField old) {
    super.didUpdateWidget(old);
    if (widget.value != old.value && widget.value != _ctrl.text) {
      _ctrl.text = widget.value;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final field = SizedBox(
      width: widget.width,
      child: TextField(
        controller: _ctrl,
        obscureText: _obscured,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          isDense: true,
          border: const OutlineInputBorder(),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          suffixIcon: widget.obscure
              ? IconButton(
                  icon: Icon(
                    _obscured ? Icons.visibility_off : Icons.visibility,
                    size: 18,
                  ),
                  onPressed: () => setState(() => _obscured = !_obscured),
                )
              : null,
        ),
        onChanged: widget.onChanged,
      ),
    );

    return ListTile(
      title: Text(widget.label),
      subtitle: widget.tooltip.isNotEmpty
          ? Text(widget.tooltip, style: const TextStyle(fontSize: 12))
          : null,
      trailing: widget.trailing != null
          ? Row(mainAxisSize: MainAxisSize.min, children: [field, widget.trailing!])
          : field,
    );
  }
}
