import 'package:flutter/material.dart';

import '../../../models/parser_config.dart' show WizardVar;
import '../../../widgets/outbound_picker.dart';
import '../edit_controller.dart';
import 'params_tab.dart' show ParamsTabActions;

/// §053 Stage 3 — Params tab для preset-ветки (§033 / §045).
///
/// Если preset null — broken-preset fallback с Delete-кнопкой.
/// Иначе — banner с preset.label + Name/Switch + список var-widgets.
class PresetParamsTab extends StatelessWidget {
  const PresetParamsTab({
    super.key,
    required this.outboundOptions,
    required this.actions,
  });

  final List<OutboundOption> outboundOptions;
  final ParamsTabActions actions;

  @override
  Widget build(BuildContext context) {
    final c = CustomRuleEditScope.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final preset = c.preset;

    if (preset == null) {
      return ListView(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, MediaQuery.of(context).padding.bottom + 24),
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cs.errorContainer.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(Icons.warning_amber_outlined,
                      color: cs.error, size: 18),
                  const SizedBox(width: 6),
                  Text('Preset not found',
                      style: TextStyle(
                          fontWeight: FontWeight.w600, color: cs.error)),
                ]),
                const SizedBox(height: 4),
                Text(
                  'Preset "${c.initial.presetId}" no longer exists in '
                  'this version of the app. The rule will be skipped when '
                  'the config is generated. Delete it or update to a newer '
                  'version that still has this preset.',
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            icon: Icon(Icons.delete_outline, size: 18, color: cs.error),
            label: Text('Delete rule', style: TextStyle(color: cs.error)),
            onPressed: actions.onDelete,
          ),
        ],
      );
    }

    return ListView(
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, MediaQuery.of(context).padding.bottom + 24),
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: cs.primaryContainer.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(Icons.push_pin_outlined, size: 16, color: cs.primary),
                const SizedBox(width: 6),
                Text('Based on preset',
                    style: TextStyle(fontSize: 12, color: cs.primary)),
              ]),
              const SizedBox(height: 4),
              Text(preset.label,
                  style: theme.textTheme.bodyLarge
                      ?.copyWith(fontWeight: FontWeight.w600)),
              if (preset.description.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(preset.description,
                    style: TextStyle(
                        fontSize: 12, color: cs.onSurfaceVariant)),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: c.nameCtrl,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Name',
                  isDense: true,
                  prefixIcon: Icon(Icons.label_outline, size: 18),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Switch(
              value: c.enabled,
              onChanged: c.setEnabled,
            ),
          ],
        ),
        // PARAMETERS секция показывается только если у preset'а есть vars.
        // Для preset'ов без vars (e.g. Block Ads, BitTorrent direct) — пусто;
        // показывать заголовок без контента — шум.
        if (preset.vars.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text('PARAMETERS',
              style: theme.textTheme.titleSmall?.copyWith(
                  color: cs.primary, fontWeight: FontWeight.w600)),
          const Divider(),
          for (final v in preset.vars)
            _PresetVarWidget(
              v: v,
              outboundOptions: outboundOptions,
              onBoolVarFailed: actions.onBoolVarFailed,
            ),
        ],
        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 12),
        FilledButton.icon(
          icon: const Icon(Icons.save, size: 18),
          label: const Text('Save'),
          onPressed: actions.onSave,
        ),
      ],
    );
  }
}

/// Один var-widget из preset (одно поле PARAMETERS-секции). Тип решается
/// `v.type`: outbound / dns_servers / enum / bool. Unsupported тип →
/// error-text (видим в Params tab — пресет шаблона требует апдейт).
class _PresetVarWidget extends StatelessWidget {
  const _PresetVarWidget({
    required this.v,
    required this.outboundOptions,
    required this.onBoolVarFailed,
  });

  final WizardVar v;
  final List<OutboundOption> outboundOptions;
  final void Function(String varDisplay) onBoolVarFailed;

  @override
  Widget build(BuildContext context) {
    final c = CustomRuleEditScope.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final preset = c.preset!;
    final label = v.title.isNotEmpty ? v.title : v.name;
    final subtitle = v.required
        ? v.tooltip
        : (v.tooltip.isEmpty ? '(optional)' : '${v.tooltip} · (optional)');

    Widget control;
    switch (v.type) {
      case 'outbound':
        final current = c.varsValues[v.name] ?? v.defaultValue;
        control = OutboundPicker(
          value: current,
          options: outboundOptions,
          onChanged: (val) => c.setVarValue(v.name, val),
          dense: false,
        );
      case 'dns_servers':
        // Семантика (§033): varsValues содержит ключ → explicit выбор
        // (включая пустую строку = "— default DNS" для optional); ключ
        // отсутствует → применяется `default_value` пресета.
        final hasExplicit = c.varsValues.containsKey(v.name);
        final stored = c.varsValues[v.name];
        final currentKey = hasExplicit ? (stored ?? '') : v.defaultValue;
        final items = <DropdownMenuItem<String>>[];
        if (!v.required) {
          items.add(const DropdownMenuItem<String>(
            value: '',
            child: Text('— (default DNS)',
                style:
                    TextStyle(fontSize: 13, fontStyle: FontStyle.italic)),
          ));
        }
        for (final s in preset.dnsServers) {
          final tag = s['tag'] as String?;
          if (tag == null || tag.isEmpty) continue;
          final descr = (s['description'] as String?) ?? tag;
          items.add(DropdownMenuItem<String>(
            value: tag,
            child: Text(descr, style: const TextStyle(fontSize: 13)),
          ));
        }
        final effectiveKey = items.any((i) => i.value == currentKey)
            ? currentKey
            : (items.isNotEmpty ? items.first.value! : '');
        control = DropdownButton<String>(
          isExpanded: true,
          isDense: false,
          value: effectiveKey,
          items: items,
          onChanged: (val) {
            if (val == null) return;
            c.setVarValue(v.name, val);
          },
        );
      case 'enum':
        final hasExplicit = c.varsValues.containsKey(v.name);
        final stored = c.varsValues[v.name];
        final currentKey = hasExplicit ? (stored ?? '') : v.defaultValue;
        final items = <DropdownMenuItem<String>>[];
        if (!v.required) {
          items.add(const DropdownMenuItem<String>(
            value: '',
            child: Text('— (none)',
                style:
                    TextStyle(fontSize: 13, fontStyle: FontStyle.italic)),
          ));
        }
        for (final o in v.options) {
          items.add(DropdownMenuItem<String>(
            value: o.value,
            child: Text(o.title, style: const TextStyle(fontSize: 13)),
          ));
        }
        final effectiveKey = items.any((i) => i.value == currentKey)
            ? currentKey
            : (items.isNotEmpty ? items.first.value! : '');
        control = DropdownButton<String>(
          isExpanded: true,
          isDense: false,
          value: effectiveKey,
          items: items,
          onChanged: (val) {
            if (val == null) return;
            c.setVarValue(v.name, val);
          },
        );
      case 'bool':
        // §045: bool var → Switch; storage хранит "true"/"false" string'ом.
        // Если var управляет remote rule_set'ом (`enabled: "@<v.name>"`):
        // toggle-on auto-downloads .srs; на fail откатываем + caller
        // показывает snackbar через `onBoolVarFailed`.
        final hasExplicit = c.varsValues.containsKey(v.name);
        final stored = c.varsValues[v.name];
        final raw = hasExplicit ? (stored ?? '') : v.defaultValue;
        final current = raw.toLowerCase() == 'true';
        final downloading = c.boolVarDownloading.contains(v.name);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: theme.textTheme.bodyLarge),
                    if (subtitle.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(subtitle,
                            style: TextStyle(
                                fontSize: 12, color: cs.onSurfaceVariant)),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (downloading)
                const SizedBox(
                  width: 32,
                  height: 32,
                  child: Padding(
                    padding: EdgeInsets.all(8),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                Switch(
                  value: current,
                  onChanged: (val) async {
                    final failed = await c.onBoolVarToggle(v, val);
                    if (failed) onBoolVarFailed(label);
                  },
                ),
            ],
          ),
        );
      default:
        control = Text(
          '(unsupported var type: ${v.type})',
          style: TextStyle(fontSize: 12, color: cs.error),
        );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: theme.textTheme.bodyLarge),
          if (subtitle.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(subtitle,
                  style: TextStyle(
                      fontSize: 12, color: cs.onSurfaceVariant)),
            ),
          const SizedBox(height: 8),
          control,
        ],
      ),
    );
  }
}
