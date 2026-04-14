import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../models/parsed_node.dart';
import '../models/parser_config.dart';
import 'settings_storage.dart';
import 'source_loader.dart';

/// Builds a complete sing-box config from wizard template + user vars + subscriptions.
///
/// Simplified mobile approach: all subscription nodes go into every enabled
/// preset group. No regex filters, no per-source outbound constructors.
class ConfigBuilder {
  ConfigBuilder._();

  static WizardTemplate? _template;

  static Future<WizardTemplate> loadTemplate() async {
    if (_template != null) return _template!;
    final raw = await rootBundle.loadString('assets/wizard_template.json');
    final json = jsonDecode(raw) as Map<String, dynamic>;
    _template = WizardTemplate.fromJson(json);
    return _template!;
  }

  /// Full config generation cycle:
  /// 1. Load template + user vars + sources
  /// 2. Fetch and parse all subscriptions → flat node list
  /// 3. Build preset groups (all nodes → each enabled group)
  /// 4. Apply selectable routing rules
  /// 5. Return canonical JSON
  static Future<String> generateConfig({
    void Function(double, String)? onProgress,
  }) async {
    final template = await loadTemplate();

    onProgress?.call(0.05, 'Loading settings...');
    final userVars = await SettingsStorage.getAllVars();
    final sources = await SettingsStorage.getProxySources();
    final enabledRules = await SettingsStorage.getEnabledRules();
    final enabledGroups = await SettingsStorage.getEnabledGroups();

    final vars = <String, String>{};
    for (final v in template.vars) {
      vars[v.name] = userVars[v.name] ?? v.defaultValue;
    }

    onProgress?.call(0.1, 'Fetching subscriptions...');

    final tagCounts = <String, int>{};
    final allNodes = <ParsedNode>[];
    for (var i = 0; i < sources.length; i++) {
      try {
        final nodes = await SourceLoader.loadNodesFromSource(
          sources[i],
          tagCounts,
          onProgress: onProgress,
          sourceIndex: i,
          totalSources: sources.length,
        );
        allNodes.addAll(nodes);
      } catch (_) {}
    }

    onProgress?.call(0.7, 'Building config...');

    final config = _deepCopy(template.config);
    _substituteVars(config, vars);

    // Build preset groups and node outbounds
    final outbounds = _buildPresetOutbounds(
      template.presetGroups,
      enabledGroups,
      allNodes,
    );

    final baseOutbounds = config['outbounds'] as List<dynamic>? ?? [];
    config['outbounds'] = [...baseOutbounds, ...outbounds];

    _applySelectableRules(config, template.selectableRules, enabledRules);

    onProgress?.call(0.95, 'Finalizing...');
    return jsonEncode(config);
  }

  /// Builds outbound entries from preset groups.
  /// All nodes go into every enabled group — no filtering.
  static List<Map<String, dynamic>> _buildPresetOutbounds(
    List<PresetGroup> presets,
    Set<String> enabledGroupTags,
    List<ParsedNode> allNodes,
  ) {
    final result = <Map<String, dynamic>>[];

    // Add all node outbounds first
    for (final node in allNodes) {
      if (node.outbound.isNotEmpty) {
        result.add(node.outbound);
      }
    }

    final allNodeTags = allNodes.map((n) => n.tag).toList();

    // Determine which presets are active
    final activePresets = presets.where((p) {
      if (enabledGroupTags.isEmpty) return p.defaultEnabled;
      return enabledGroupTags.contains(p.tag);
    }).toList();

    // Build known tags for validation
    final knownTags = <String>{
      'direct-out',
      ...allNodeTags,
      ...activePresets.map((p) => p.tag),
    };

    for (final preset in activePresets) {
      final tags = <String>[
        ...allNodeTags,
        ...preset.addOutbounds.where(knownTags.contains),
      ];
      if (tags.isEmpty) continue;

      result.add(<String, dynamic>{
        'tag': preset.tag,
        'type': preset.type,
        'outbounds': tags,
        ...preset.options,
      });
    }

    return result;
  }

  static void _substituteVars(dynamic obj, Map<String, String> vars) {
    if (obj is Map<String, dynamic>) {
      for (final key in obj.keys.toList()) {
        final value = obj[key];
        if (value is String && value.startsWith('@')) {
          final varName = value.substring(1);
          if (vars.containsKey(varName)) {
            final resolved = vars[varName]!;
            if (resolved == 'true') {
              obj[key] = true;
            } else if (resolved == 'false') {
              obj[key] = false;
            } else {
              final asInt = int.tryParse(resolved);
              if (asInt != null) {
                obj[key] = asInt;
              } else {
                obj[key] = resolved;
              }
            }
          }
        } else {
          _substituteVars(value, vars);
        }
      }
    } else if (obj is List) {
      for (var i = 0; i < obj.length; i++) {
        final value = obj[i];
        if (value is String && value.startsWith('@')) {
          final varName = value.substring(1);
          if (vars.containsKey(varName)) {
            final resolved = vars[varName]!;
            if (resolved == 'true') {
              obj[i] = true;
            } else if (resolved == 'false') {
              obj[i] = false;
            } else {
              final asInt = int.tryParse(resolved);
              obj[i] = asInt ?? resolved;
            }
          }
        } else {
          _substituteVars(value, vars);
        }
      }
    }
  }

  static void _applySelectableRules(
    Map<String, dynamic> config,
    List<SelectableRule> allRules,
    Set<String> enabledLabels,
  ) {
    final route = config['route'] as Map<String, dynamic>? ?? {};
    final ruleSets = route['rule_set'] as List<dynamic>? ?? [];
    final rules = route['rules'] as List<dynamic>? ?? [];

    for (final sr in allRules) {
      final isEnabled = enabledLabels.contains(sr.label) ||
          (enabledLabels.isEmpty && sr.defaultEnabled);
      if (!isEnabled) continue;

      for (final rs in sr.ruleSets) {
        final tag = rs['tag'];
        if (tag != null && !ruleSets.any((e) => e is Map && e['tag'] == tag)) {
          ruleSets.add(rs);
        }
      }

      if (sr.rule.isNotEmpty) {
        rules.add(sr.rule);
      }
    }

    route['rule_set'] = ruleSets;
    route['rules'] = rules;
    config['route'] = route;
  }

  static Map<String, dynamic> _deepCopy(Map<String, dynamic> source) {
    return jsonDecode(jsonEncode(source)) as Map<String, dynamic>;
  }
}
