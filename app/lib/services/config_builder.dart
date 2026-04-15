import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../models/parsed_node.dart';
import '../models/parser_config.dart';
import 'rule_set_downloader.dart';
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

    final ruleOutbounds = await SettingsStorage.getRuleOutbounds();
    _applySelectableRules(
      config,
      template.selectableRules,
      enabledRules,
      ruleOutbounds,
      enabledGroups,
    );

    // App routing rules (per-app outbound)
    final appRules = await SettingsStorage.getAppRules();
    _applyAppRules(config, appRules);

    final routeFinal = await SettingsStorage.getRouteFinal();
    if (routeFinal.isNotEmpty) {
      final route = config['route'] as Map<String, dynamic>?;
      if (route != null) route['final'] = routeFinal;
    }

    onProgress?.call(0.85, 'Downloading rule sets...');
    await _cacheRemoteRuleSets(config, onProgress: onProgress);

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
    final emittedJumpTags = <String>{};

    for (final node in allNodes) {
      if (node.outbound.isEmpty) continue;

      // If node has a jump server, emit the jump outbound first
      // and set `detour` on the main outbound to route through it.
      if (node.jump != null && node.jump!.outbound.isNotEmpty) {
        final jumpTag = node.jump!.tag;
        if (!emittedJumpTags.contains(jumpTag)) {
          result.add(node.jump!.outbound);
          emittedJumpTags.add(jumpTag);
        }
        node.outbound['detour'] = jumpTag;
      }

      result.add(node.outbound);
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
        final resolved = _resolveVar(obj[key], vars);
        if (resolved != null) {
          obj[key] = resolved;
        } else {
          _substituteVars(obj[key], vars);
        }
      }
    } else if (obj is List) {
      for (var i = 0; i < obj.length; i++) {
        final resolved = _resolveVar(obj[i], vars);
        if (resolved != null) {
          obj[i] = resolved;
        } else {
          _substituteVars(obj[i], vars);
        }
      }
    }
  }

  /// Resolves a `@varName` reference to its typed value, or returns null
  /// if the value is not a variable reference.
  static dynamic _resolveVar(dynamic value, Map<String, String> vars) {
    if (value is! String || !value.startsWith('@')) return null;
    final varName = value.substring(1);
    if (!vars.containsKey(varName)) return null;
    final resolved = vars[varName]!;
    if (resolved == 'true') return true;
    if (resolved == 'false') return false;
    return int.tryParse(resolved) ?? resolved;
  }

  static void _applySelectableRules(
    Map<String, dynamic> config,
    List<SelectableRule> allRules,
    Set<String> enabledLabels,
    Map<String, String> ruleOutbounds,
    Set<String> enabledGroups,
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
        final userOutbound = ruleOutbounds[sr.label];
        final ruleToAdd =
            (userOutbound != null && userOutbound.isNotEmpty && sr.rule.containsKey('outbound'))
                ? {...sr.rule, 'outbound': userOutbound}
                : sr.rule;
        if (ruleToAdd.isNotEmpty) rules.add(ruleToAdd);
      }
    }

    route['rule_set'] = ruleSets;
    route['rules'] = rules;
    config['route'] = route;
  }

  /// Adds per-app routing rules (package_name → outbound) to the config.
  static void _applyAppRules(
    Map<String, dynamic> config,
    List<AppRule> appRules,
  ) {
    if (appRules.isEmpty) return;
    final route = config['route'] as Map<String, dynamic>? ?? {};
    final rules = route['rules'] as List<dynamic>? ?? [];

    for (final ar in appRules) {
      if (ar.packages.isEmpty || ar.outbound.isEmpty) continue;
      rules.add(<String, dynamic>{
        'package_name': ar.packages,
        'outbound': ar.outbound,
      });
    }

    route['rules'] = rules;
    config['route'] = route;
  }

  /// Downloads remote .srs rule sets and rewrites entries to local paths.
  /// Non-fatal: on failure the entry stays remote and sing-box fetches it.
  static Future<void> _cacheRemoteRuleSets(
    Map<String, dynamic> config, {
    void Function(double, String)? onProgress,
  }) async {
    final route = config['route'] as Map<String, dynamic>?;
    if (route == null) return;
    final ruleSets = route['rule_set'] as List<dynamic>?;
    if (ruleSets == null || ruleSets.isEmpty) return;

    final remoteEntries = <Map<String, dynamic>>[];
    for (final entry in ruleSets) {
      if (entry is Map<String, dynamic> && entry['type'] == 'remote') {
        remoteEntries.add(entry);
      }
    }
    if (remoteEntries.isEmpty) return;

    final cached = await RuleSetDownloader.cacheAll(
      remoteEntries,
      onProgress: (tag) => onProgress?.call(0.88, 'Rule set: $tag'),
    );

    for (final entry in remoteEntries) {
      final tag = entry['tag'] as String?;
      if (tag != null && cached.containsKey(tag)) {
        entry['type'] = 'local';
        entry['path'] = cached[tag];
        entry.remove('url');
        entry.remove('download_detour');
        entry.remove('update_interval');
      }
    }
  }

  static Map<String, dynamic> _deepCopy(Map<String, dynamic> source) {
    return jsonDecode(jsonEncode(source)) as Map<String, dynamic>;
  }
}
