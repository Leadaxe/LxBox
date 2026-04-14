import 'proxy_source.dart';

/// Full wizard template loaded from asset.
class WizardTemplate {
  WizardTemplate({
    required this.parserConfig,
    required this.vars,
    required this.config,
    required this.selectableRules,
  });

  final ParserConfigBlock parserConfig;
  final List<WizardVar> vars;
  final Map<String, dynamic> config;
  final List<SelectableRule> selectableRules;

  factory WizardTemplate.fromJson(Map<String, dynamic> json) {
    final pcJson = json['parser_config'] as Map<String, dynamic>? ?? {};
    final varsJson = json['vars'] as List<dynamic>? ?? [];
    final rulesJson = json['selectable_rules'] as List<dynamic>? ?? [];

    return WizardTemplate(
      parserConfig: ParserConfigBlock.fromJson(pcJson),
      vars: varsJson
          .whereType<Map<String, dynamic>>()
          .where((v) => v.containsKey('name'))
          .map(WizardVar.fromJson)
          .toList(),
      config: json['config'] as Map<String, dynamic>? ?? {},
      selectableRules:
          rulesJson.map((e) => SelectableRule.fromJson(e as Map<String, dynamic>)).toList(),
    );
  }
}

/// The `parser_config` block from wizard template.
class ParserConfigBlock {
  ParserConfigBlock({
    this.version = 5,
    this.proxies = const [],
    this.outbounds = const [],
    this.reload = '12h',
    this.lastUpdated = '',
  });

  final int version;
  final List<ProxySource> proxies;
  final List<OutboundConfig> outbounds;
  final String reload;
  final String lastUpdated;

  factory ParserConfigBlock.fromJson(Map<String, dynamic> json) {
    final parser = json['parser'] as Map<String, dynamic>? ?? {};
    return ParserConfigBlock(
      version: json['version'] as int? ?? 5,
      proxies: (json['proxies'] as List<dynamic>?)
              ?.map((e) => ProxySource.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      outbounds: (json['outbounds'] as List<dynamic>?)
              ?.map((e) => OutboundConfig.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      reload: parser['reload'] as String? ?? '12h',
      lastUpdated: parser['last_updated'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'proxies': proxies.map((e) => e.toJson()).toList(),
        'outbounds': outbounds.map((e) => e.toJson()).toList(),
        'parser': {
          'reload': reload,
          'last_updated': lastUpdated,
        },
      };
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
  bool get isSeparator => false;

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
