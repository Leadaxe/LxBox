import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../models/parsed_node.dart';
import '../models/parser_config.dart';
import '../models/proxy_source.dart';
import 'settings_storage.dart';
import 'source_loader.dart';

/// Builds a complete sing-box config from wizard template + user vars + subscriptions.
class ConfigBuilder {
  ConfigBuilder._();

  static WizardTemplate? _template;

  /// Loads and caches the wizard template from the Flutter asset bundle.
  static Future<WizardTemplate> loadTemplate() async {
    if (_template != null) return _template!;
    final raw = await rootBundle.loadString('assets/wizard_template.json');
    final json = jsonDecode(raw) as Map<String, dynamic>;
    _template = WizardTemplate.fromJson(json);
    return _template!;
  }

  /// Full config generation cycle:
  /// 1. Load template
  /// 2. Read user vars from storage
  /// 3. Fetch and parse all subscriptions
  /// 4. Generate outbounds (selectors + nodes)
  /// 5. Assemble final config
  /// Returns canonical JSON string ready for sing-box.
  static Future<String> generateConfig({
    void Function(double, String)? onProgress,
  }) async {
    final template = await loadTemplate();

    onProgress?.call(0.05, 'Loading settings...');
    final userVars = await SettingsStorage.getAllVars();
    final sources = await SettingsStorage.getProxySources();
    final enabledRules = await SettingsStorage.getEnabledRules();

    // Build effective vars: defaults + user overrides
    final vars = <String, String>{};
    for (final v in template.vars) {
      vars[v.name] = userVars[v.name] ?? v.defaultValue;
    }

    onProgress?.call(0.1, 'Fetching subscriptions...');

    // Load nodes from all sources
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
      } catch (_) {
        // Individual source errors don't block generation
      }
    }

    onProgress?.call(0.7, 'Building config...');

    // Start with template config
    final config = _deepCopy(template.config);

    // Substitute vars
    _substituteVars(config, vars);

    // Generate outbounds from nodes + selectors
    final generatedOutbounds = _generateOutbounds(
      template.parserConfig.outbounds,
      allNodes,
    );

    // Merge outbounds: template base + generated
    final baseOutbounds = config['outbounds'] as List<dynamic>? ?? [];
    config['outbounds'] = [...baseOutbounds, ...generatedOutbounds];

    // Merge selectable rules
    _applySelectableRules(config, template.selectableRules, enabledRules);

    onProgress?.call(0.95, 'Finalizing...');

    return jsonEncode(config);
  }

  /// Recursively substitutes `@var_name` placeholders with values from [vars].
  static void _substituteVars(dynamic obj, Map<String, String> vars) {
    if (obj is Map<String, dynamic>) {
      for (final key in obj.keys.toList()) {
        final value = obj[key];
        if (value is String && value.startsWith('@')) {
          final varName = value.substring(1);
          if (vars.containsKey(varName)) {
            final resolved = vars[varName]!;
            // Type coercion for JSON compatibility
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

  /// Generates outbound entries from template selectors and parsed nodes.
  static List<Map<String, dynamic>> _generateOutbounds(
    List<OutboundConfig> selectorConfigs,
    List<ParsedNode> allNodes,
  ) {
    final result = <Map<String, dynamic>>[];

    // First, add all node outbounds
    for (final node in allNodes) {
      if (node.outbound.isNotEmpty) {
        result.add(node.outbound);
      }
    }

    // Then, build selectors
    for (final cfg in selectorConfigs) {
      final filtered = _filterNodesForSelector(allNodes, cfg.filters);
      if (filtered.isEmpty && cfg.addOutbounds.isEmpty) continue;

      final outboundTags = <String>[
        ...filtered.map((n) => n.tag),
        ...cfg.addOutbounds,
      ];

      // Remove tags that don't exist (except well-known like direct-out)
      final existingTags = <String>{
        'direct-out',
        ...allNodes.map((n) => n.tag),
        ...selectorConfigs.map((s) => s.tag),
      };
      final validTags = outboundTags.where((t) => existingTags.contains(t)).toList();
      if (validTags.isEmpty) continue;

      final selector = <String, dynamic>{
        'tag': cfg.tag,
        'type': cfg.type,
        'outbounds': validTags,
        ...cfg.options,
      };

      result.add(selector);
    }

    return result;
  }

  /// Filters nodes for a selector based on filter config.
  static List<ParsedNode> _filterNodesForSelector(
    List<ParsedNode> nodes,
    Map<String, dynamic> filters,
  ) {
    if (filters.isEmpty) return List.of(nodes);

    return nodes.where((node) {
      for (final entry in filters.entries) {
        final key = entry.key;
        final pattern = entry.value.toString();
        final value = _getNodeField(node, key);

        if (!_matchesFilter(value, pattern)) return false;
      }
      return true;
    }).toList();
  }

  static String _getNodeField(ParsedNode node, String key) {
    switch (key) {
      case 'tag':
        return node.tag;
      case 'host':
        return node.server;
      case 'scheme':
        return node.scheme;
      default:
        return '';
    }
  }

  static bool _matchesFilter(String value, String pattern) {
    if (pattern.startsWith('!/') && pattern.endsWith('/i')) {
      final regex = pattern.substring(2, pattern.length - 2);
      return !RegExp(regex, caseSensitive: false).hasMatch(value);
    }
    if (pattern.startsWith('!')) return value != pattern.substring(1);
    if (pattern.startsWith('/') && pattern.endsWith('/i')) {
      final regex = pattern.substring(1, pattern.length - 2);
      return RegExp(regex, caseSensitive: false).hasMatch(value);
    }
    return value == pattern;
  }

  /// Applies enabled selectable rules to the config.
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

      // Add rule_sets
      for (final rs in sr.ruleSets) {
        final tag = rs['tag'];
        if (tag != null && !ruleSets.any((e) => e is Map && e['tag'] == tag)) {
          ruleSets.add(rs);
        }
      }

      // Add rule (before final catch-all)
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
