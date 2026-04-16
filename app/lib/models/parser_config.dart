/// Full wizard template loaded from asset.
class WizardTemplate {
  WizardTemplate({
    required this.parserConfig,
    required this.presetGroups,
    required this.vars,
    required this.config,
    required this.selectableRules,
    required this.dnsOptions,
  });

  final ParserConfigBlock parserConfig;
  final List<PresetGroup> presetGroups;
  final List<WizardVar> vars;
  final Map<String, dynamic> config;
  final List<SelectableRule> selectableRules;
  final Map<String, dynamic> dnsOptions;

  factory WizardTemplate.fromJson(Map<String, dynamic> json) {
    final pcJson = json['parser_config'] as Map<String, dynamic>? ?? {};
    final varsJson = json['vars'] as List<dynamic>? ?? [];
    final rulesJson = json['selectable_rules'] as List<dynamic>? ?? [];
    final groupsJson = json['preset_groups'] as List<dynamic>? ?? [];

    return WizardTemplate(
      parserConfig: ParserConfigBlock.fromJson(pcJson),
      presetGroups: groupsJson
          .whereType<Map<String, dynamic>>()
          .map(PresetGroup.fromJson)
          .toList(),
      vars: varsJson
          .whereType<Map<String, dynamic>>()
          .where((v) => v.containsKey('name'))
          .map(WizardVar.fromJson)
          .toList(),
      config: json['config'] as Map<String, dynamic>? ?? {},
      selectableRules:
          rulesJson.map((e) => SelectableRule.fromJson(e as Map<String, dynamic>)).toList(),
      dnsOptions: json['dns_options'] as Map<String, dynamic>? ?? {},
    );
  }
}

/// The `parser_config` block from wizard template.
class ParserConfigBlock {
  ParserConfigBlock({
    this.version = 5,
    this.reload = '12h',
  });

  final int version;
  final String reload;

  factory ParserConfigBlock.fromJson(Map<String, dynamic> json) {
    final parser = json['parser'] as Map<String, dynamic>? ?? {};
    return ParserConfigBlock(
      version: json['version'] as int? ?? 5,
      reload: parser['reload'] as String? ?? '12h',
    );
  }
}

/// A fixed preset outbound group (replaces the old OutboundConfig with filters).
/// All subscription nodes are added to every enabled group.
class PresetGroup {
  PresetGroup({
    required this.tag,
    required this.type,
    this.label = '',
    this.defaultEnabled = true,
    this.options = const {},
    this.addOutbounds = const [],
  });

  final String tag;
  final String type; // selector, urltest
  final String label;
  final bool defaultEnabled;
  final Map<String, dynamic> options;
  final List<String> addOutbounds;

  factory PresetGroup.fromJson(Map<String, dynamic> json) {
    return PresetGroup(
      tag: json['tag'] as String? ?? '',
      type: json['type'] as String? ?? 'selector',
      label: json['label'] as String? ?? '',
      defaultEnabled: json['default_enabled'] as bool? ?? true,
      options: json['options'] as Map<String, dynamic>? ?? const {},
      addOutbounds: (json['add_outbounds'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
    );
  }
}

/// A variable from `vars[]` in the wizard template.
class WizardVar {
  WizardVar({
    required this.name,
    required this.type,
    required this.defaultValue,
    this.wizardUI = 'edit',
    this.options = const [],
    this.title = '',
    this.tooltip = '',
  });

  final String name;
  final String type; // bool, text, enum, secret
  final String defaultValue;
  final String wizardUI; // edit, fix, hidden
  final List<String> options; // for enum type
  final String title;
  final String tooltip;

  bool get isEditable => wizardUI == 'edit';

  factory WizardVar.fromJson(Map<String, dynamic> json) {
    var defVal = json['default_value'];
    String defaultStr;
    if (defVal is Map) {
      defaultStr = (defVal['default'] ?? defVal.values.first)?.toString() ?? '';
    } else {
      defaultStr = defVal?.toString() ?? '';
    }

    return WizardVar(
      name: json['name'] as String? ?? '',
      type: json['type'] as String? ?? 'text',
      defaultValue: defaultStr,
      wizardUI: json['wizard_ui'] as String? ?? 'edit',
      options: (json['options'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [],
      title: json['title'] as String? ?? '',
      tooltip: json['tooltip'] as String? ?? '',
    );
  }
}

/// A selectable routing rule from the wizard template.
class SelectableRule {
  SelectableRule({
    required this.label,
    this.description = '',
    this.defaultEnabled = false,
    this.ruleSets = const [],
    this.rule = const {},
  });

  final String label;
  final String description;
  final bool defaultEnabled;
  final List<Map<String, dynamic>> ruleSets;
  final Map<String, dynamic> rule;

  factory SelectableRule.fromJson(Map<String, dynamic> json) {
    return SelectableRule(
      label: json['label'] as String? ?? '',
      description: json['description'] as String? ?? '',
      defaultEnabled: json['default'] as bool? ?? false,
      ruleSets: (json['rule_set'] as List<dynamic>?)
              ?.map((e) => Map<String, dynamic>.from(e as Map))
              .toList() ??
          [],
      rule: json['rule'] as Map<String, dynamic>? ?? {},
    );
  }
}
