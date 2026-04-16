import 'dart:convert';
import 'dart:math';

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

    // Ensure Clash API has a random high port and non-empty secret.
    // Persist so values stay stable across regenerations.
    if (_ensureClashApiDefaults(vars)) {
      if (vars.containsKey('clash_api')) {
        await SettingsStorage.setVar('clash_api', vars['clash_api']!);
      }
      if (vars.containsKey('clash_secret')) {
        await SettingsStorage.setVar('clash_secret', vars['clash_secret']!);
      }
    }

    onProgress?.call(0.1, 'Fetching subscriptions...');

    final tagCounts = <String, int>{};
    final allNodes = <ParsedNode>[];
    for (var i = 0; i < sources.length; i++) {
      if (!sources[i].enabled) continue;
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

    // Remove sniff rule if disabled
    if (vars['sniff_enabled'] == 'false') {
      final route = config['route'] as Map<String, dynamic>?;
      if (route != null) {
        final rules = route['rules'] as List<dynamic>?;
        rules?.removeWhere((r) => r is Map && r['action'] == 'sniff');
      }
    }

    // Excluded nodes — filtered only from urltest groups, not from all outbounds
    final excludedNodes = await SettingsStorage.getExcludedNodes();

    // Build preset groups and node outbounds
    final outbounds = _buildPresetOutbounds(
      template.presetGroups,
      enabledGroups,
      allNodes,
      excludedNodes,
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

    // Apply custom DNS servers and rules
    await _applyCustomDns(config);

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
    Set<String> excludedNodes,
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

    // First pass: determine which groups will actually be emitted (non-empty)
    final emittedGroupTags = <String>{};
    for (final preset in activePresets) {
      final nodeTags = preset.type == 'urltest' && excludedNodes.isNotEmpty
          ? allNodeTags.where((t) => !excludedNodes.contains(t)).toList()
          : allNodeTags;
      if (nodeTags.isNotEmpty || preset.type != 'urltest') {
        emittedGroupTags.add(preset.tag);
      }
    }

    // Build known tags for validation — only include groups that will be emitted
    final knownTags = <String>{
      'direct-out',
      ...allNodeTags,
      ...emittedGroupTags,
    };

    for (final preset in activePresets) {
      // For urltest groups, exclude filtered nodes; for selectors, include all
      final nodeTags = preset.type == 'urltest' && excludedNodes.isNotEmpty
          ? allNodeTags.where((t) => !excludedNodes.contains(t)).toList()
          : allNodeTags;
      final tags = <String>[
        ...nodeTags,
        ...preset.addOutbounds.where(knownTags.contains),
      ];
      // Skip empty urltest; for others add direct-out fallback
      if (tags.isEmpty) {
        if (preset.type == 'urltest') continue;
        tags.add('direct-out');
      }

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

  /// Ensures Clash API uses a random high port and always has a secret.
  /// Returns true if any value was changed (caller should persist).
  static bool _ensureClashApiDefaults(Map<String, String> vars) {
    final rng = Random.secure();
    var changed = false;

    // Random port in 49152-65535 if still default 9090
    final currentApi = vars['clash_api'] ?? '127.0.0.1:9090';
    if (currentApi == '127.0.0.1:9090' || currentApi.endsWith(':9090')) {
      final port = 49152 + rng.nextInt(65535 - 49152);
      vars['clash_api'] = '127.0.0.1:$port';
      changed = true;
    }

    // Always generate secret if empty
    final currentSecret = vars['clash_secret'] ?? '';
    if (currentSecret.isEmpty) {
      final bytes = List.generate(16, (_) => rng.nextInt(256));
      vars['clash_secret'] = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      changed = true;
    }

    return changed;
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
  /// Applies DNS servers and rules.
  /// Source: user settings if saved, otherwise dns_options from template.
  /// Strips wizard-only fields (enabled, description) before writing to config.
  static Future<void> _applyCustomDns(Map<String, dynamic> config) async {
    final template = await loadTemplate();
    final userServers = await SettingsStorage.getDnsServers();
    final userRulesJson = await SettingsStorage.getDnsRules();

    final templateDns = template.dnsOptions;
    final dns = (config['dns'] as Map<String, dynamic>?) ?? {};

    // Servers: user override or template dns_options
    final sourceServers = userServers.isNotEmpty
        ? userServers
        : (templateDns['servers'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>().toList();

    final servers = <Map<String, dynamic>>[];
    for (final s in sourceServers) {
      if (s['enabled'] == false) continue;
      final clean = Map<String, dynamic>.from(s);
      clean.remove('enabled');
      clean.remove('description');
      servers.add(clean);
    }
    dns['servers'] = servers;

    // Rules: user override or template dns_options
    if (userRulesJson.isNotEmpty) {
      try {
        final rules = jsonDecode(userRulesJson);
        if (rules is List) dns['rules'] = rules;
      } catch (_) {}
    } else {
      final templateRules = templateDns['rules'] as List<dynamic>?;
      if (templateRules != null) dns['rules'] = templateRules;
    }

    config['dns'] = dns;
  }

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
