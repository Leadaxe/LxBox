/// Full wizard template loaded from asset.
class WizardTemplate {
  WizardTemplate({
    required this.parserConfig,
    required this.presetGroups,
    required this.vars,
    required this.varSections,
    required this.config,
    required this.selectableRules,
    required this.dnsOptions,
    required this.pingOptions,
    required this.speedTestOptions,
  });

  final ParserConfigBlock parserConfig;
  final List<PresetGroup> presetGroups;
  final List<WizardVar> vars;
  final Map<String, dynamic> config;
  final List<SelectableRule> selectableRules;
  final Map<String, dynamic> dnsOptions;
  final Map<String, dynamic> pingOptions;
  final Map<String, dynamic> speedTestOptions;

  final List<VarSection> varSections;

  /// Все переменные заданного `chapter` в порядке объявления в template.
  /// `chapter` — категория экрана-владельца: `core` (VPN Settings), `routing`
  /// (Routing), `dns` (DNS Settings). Переменные с `wizard_ui: hidden`
  /// исключаются — они запекаются в template до UI.
  List<WizardVar> varsFor(String chapter) => vars
      .where((v) => v.chapter == chapter && v.wizardUI != 'hidden')
      .toList(growable: false);

  /// Секции заданного `chapter` для построения UI. Нужно для отображения
  /// заголовков-группировок и описаний на экранах.
  List<VarSection> sectionsFor(String chapter) =>
      varSections.where((s) => s.chapter == chapter).toList(growable: false);

  factory WizardTemplate.fromJson(Map<String, dynamic> json) {
    final pcJson = json['parser_config'] as Map<String, dynamic>? ?? {};
    final rulesJson = json['selectable_rules'] as List<dynamic>? ?? [];
    final groupsJson = json['preset_groups'] as List<dynamic>? ?? [];

    // Парсим nested `sections` — секция → chapter → vars.
    // Каждая WizardVar наследует chapter+section от своей секции-родителя.
    final allVars = <WizardVar>[];
    final sections = <VarSection>[];
    final sectionsJson = json['sections'] as List<dynamic>? ?? [];
    for (final s in sectionsJson.whereType<Map<String, dynamic>>()) {
      final name = s['name'] as String? ?? '';
      final chapter = s['chapter'] as String? ?? 'core';
      final description = s['description'] as String? ?? '';
      sections.add(VarSection(
        title: name,
        description: description,
        chapter: chapter,
      ));
      final varsArr = s['vars'] as List<dynamic>? ?? [];
      for (final v in varsArr.whereType<Map<String, dynamic>>()) {
        if (!v.containsKey('name')) continue;
        allVars.add(WizardVar.fromJson(v, section: name, chapter: chapter));
      }
    }

    return WizardTemplate(
      parserConfig: ParserConfigBlock.fromJson(pcJson),
      presetGroups: groupsJson
          .whereType<Map<String, dynamic>>()
          .map(PresetGroup.fromJson)
          .toList(),
      vars: allVars,
      varSections: sections,
      config: json['config'] as Map<String, dynamic>? ?? {},
      selectableRules: rulesJson
          .map((e) => SelectableRule.fromJson(e as Map<String, dynamic>))
          .toList(),
      dnsOptions: json['dns_options'] as Map<String, dynamic>? ?? {},
      pingOptions: json['ping_options'] as Map<String, dynamic>? ?? {},
      speedTestOptions: json['speed_test_options'] as Map<String, dynamic>? ?? {},
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

/// Один вариант для `enum`/`text-with-suggestions` var'ов.
///
/// Парсится из строки (legacy: `"foo"` → `value=foo, title=foo`) или из
/// объекта (`{"title": "Human-readable", "value": "machine_id"}`). UI
/// показывает `title`, `value` подставляется в `@var`-плейсхолдерах и
/// сохраняется в varsValues.
class WizardOption {
  final String value;
  final String title;
  const WizardOption({required this.value, required this.title});

  /// Парсит любой JSON-элемент `options[]`. Строка → value==title. Map →
  /// `title`/`value` (fallback-ы: title пустой берёт value, пустое оба
  /// сваливается в пустую опцию, которую caller пусть отфильтрует).
  factory WizardOption.fromAny(dynamic raw) {
    if (raw is String) return WizardOption(value: raw, title: raw);
    if (raw is Map) {
      final v = raw['value']?.toString() ?? '';
      final t = (raw['title']?.toString() ?? '').trim();
      return WizardOption(value: v, title: t.isEmpty ? v : t);
    }
    return const WizardOption(value: '', title: '');
  }
}

/// A variable from a section's `vars[]` in the wizard template, либо
/// preset-local var из `selectable_rules[i].vars[]` (spec §033).
///
/// `chapter` определяет, какому экрану принадлежит переменная:
/// `core` (VPN Settings — sing-box низкоуровневое), `routing` (Routing),
/// `dns` (DNS Settings). Переменные без chapter при парсинге получают `core`.
/// Для preset-local vars chapter не используется (форма рендерится в редакторе
/// правила).
class WizardVar {
  WizardVar({
    required this.name,
    required this.type,
    required this.defaultValue,
    this.wizardUI = 'edit',
    this.options = const [],
    this.title = '',
    this.tooltip = '',
    this.section = '',
    this.chapter = 'core',
    this.required = true,
  });

  final String name;
  final String type; // bool, text, enum, secret, outbound, dns_servers (spec §033)
  final String defaultValue;
  final String wizardUI; // edit, fix, hidden
  final List<WizardOption> options; // for enum / text-with-suggestions
  final String title;
  final String tooltip;
  final String section;
  final String chapter;

  /// Optional-флаг (spec §033). `true` (default) — значение обязательно,
  /// null запрещён. `false` — в UI появляется пункт "—", юзер может не
  /// выбирать, фрагменты с unresolved `@name` выкидываются целиком.
  final bool required;

  bool get isEditable => wizardUI == 'edit';

  /// Legacy-aware accessor: только `value`-part каждой опции. Для кода,
  /// которому нужен plain `List<String>` (валидация, sing-box emit).
  List<String> get optionValues =>
      options.map((o) => o.value).toList(growable: false);

  factory WizardVar.fromJson(
    Map<String, dynamic> json, {
    String section = '',
    String chapter = 'core',
  }) {
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
      options: (json['options'] as List<dynamic>?)
              ?.map(WizardOption.fromAny)
              .where((o) => o.value.isNotEmpty)
              .toList() ??
          const [],
      title: json['title'] as String? ?? '',
      tooltip: json['tooltip'] as String? ?? '',
      section: section,
      chapter: chapter,
      required: json['required'] as bool? ?? true,
    );
  }
}

/// A section header for grouping vars in the settings UI.
/// `chapter` наследуется на все переменные этой секции и определяет
/// экран-владелец (см. [WizardVar.chapter]).
class VarSection {
  VarSection({
    required this.title,
    this.description = '',
    this.chapter = 'core',
  });
  final String title;
  final String description;
  final String chapter;
}

/// A selectable routing rule from the wizard template.
///
/// Два режима существования (spec §033):
///
/// 1. **Legacy (1.4.x)** — `presetId` пустой, `vars`/`dnsRule`/`dnsServers`
///    пустые. Правило конвертируется в `CustomRule(kind: inline/srs)` через
///    `selectableRuleToCustom`, содержимое копируется в правило.
///
/// 2. **Bundle (1.5+)** — `presetId` задан. Пресет self-contained: несёт
///    rule_set + dns_rule + routing rule + dns_servers + типизированные
///    переменные. `CustomRule(kind: preset)` хранит только ссылку
///    `{presetId, varsValues}`. Expansion + merge в `preset_expand.dart`.
class SelectableRule {
  SelectableRule({
    required this.label,
    this.description = '',
    this.defaultEnabled = false,
    this.ruleSets = const [],
    this.rule = const {},
    this.presetId = '',
    this.vars = const [],
    this.dnsRule,
    this.dnsServers = const [],
  });

  final String label;
  final String description;
  final bool defaultEnabled;
  final List<Map<String, dynamic>> ruleSets;
  final Map<String, dynamic> rule;

  /// Stable slug для bundle-пресетов (spec §033). Пустой → legacy-режим.
  final String presetId;

  /// Типизированные переменные пресета (spec §033). `@name` в
  /// rule_set/dns_rule/rule/dns_servers подставляется при expansion'е.
  final List<WizardVar> vars;

  /// DNS-правило, которое пресет вносит в `dns.rules` (insert перед
  /// fallback). Null → пресет не трогает DNS-rules.
  final Map<String, dynamic>? dnsRule;

  /// DNS-серверы, из которых `@dns_server` var выбирает один для
  /// добавления в `dns.servers`. Пустой список → пресет не вносит
  /// DNS-серверов.
  final List<Map<String, dynamic>> dnsServers;

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
      presetId: json['preset_id'] as String? ?? '',
      vars: (json['vars'] as List<dynamic>?)
              ?.whereType<Map<String, dynamic>>()
              .map((v) => WizardVar.fromJson(v))
              .toList() ??
          const [],
      dnsRule: json['dns_rule'] as Map<String, dynamic>?,
      dnsServers: (json['dns_servers'] as List<dynamic>?)
              ?.map((e) => Map<String, dynamic>.from(e as Map))
              .toList() ??
          const [],
    );
  }
}
