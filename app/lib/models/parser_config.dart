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

  /// §265 — первичная декларация глобальной var по имени (обычная, НЕ ref).
  /// Ref-var (`{"ref": name}`) подтягивает отсюда type/options/title/tooltip/
  /// default. `null` — глобали нет (битая ссылка → UI скрывает контрол).
  WizardVar? globalVar(String name) {
    for (final v in vars) {
      if (v.name == name && !v.isRef) return v;
    }
    return null;
  }

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
    this.onChange,
    this.ref = '',
  });

  final String name;
  // §120: typed template engine. bool/int коэрсятся по типу; остальные —
  // дословная строка (НЕ угадывание по содержимому). text/enum/secret/outbound/
  // dns_servers — все строковые. §033 добавил outbound/dns_servers.
  final String type; // bool, int, text, enum, secret, outbound, dns_servers
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

  /// §232 — декларативный side-effect при переключении этой var. Форма:
  /// `{"set": {"@target": <#if-node>, ...}}`. При изменении значения var
  /// каждый `@target` пере-вычисляется через #if-движок (резолвер отдаёт
  /// НОВОЕ значение этой var) и записывается. Пример: галка `ipv6_enabled`
  /// ставит `dns_strategy`/`resolve_strategy` в prefer_ipv6/ipv4. `null` —
  /// нет side-effect (обычная var). Значения — литералы (юзер потом волен
  /// переопределить вручную; это разовый эффект переключения, не форс).
  final Map<String, dynamic>? onChange;

  /// §265 — ref-var: если непустое, эта запись `vars[]` — не декларация, а
  /// ССЫЛКА на глобальную var с именем `ref` (объявленную в секции). Значение
  /// живёт в глобальном `userVars[ref]`, НЕ в `rule.varsValues`; метаданные
  /// (type/options/title/tooltip/default) подтягиваются из целевой var через
  /// [WizardTemplate.globalVar]. Пресет ссылается на общую настройку, не
  /// заводя копию (пример: `resolve_strategy` — она же питает `dns.strategy`).
  final String ref;

  /// §265 — эта var-запись есть ссылка на глобальную (не собственная декларация).
  bool get isRef => ref.isNotEmpty;

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
    // §265 — ref-var: `{"ref": "<global-name>"}`. Метаданные не несёт —
    // `name` = ref, остальное подтянется из целевой глобали через
    // WizardTemplate.globalVar на этапе рендера/резолва.
    final refName = json['ref'] as String? ?? '';
    if (refName.isNotEmpty) {
      return WizardVar(
        name: refName,
        type: 'text', // placeholder; реальный тип — у целевой глобали
        defaultValue: '',
        section: section,
        chapter: chapter,
        ref: refName,
      );
    }

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
      onChange: json['on_change'] as Map<String, dynamic>?,
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
/// Bundle-режим (spec §033): пресет self-contained — несёт rule_set +
/// dns_rule + routing rule + dns_servers + типизированные переменные.
/// `CustomRule(kind: preset)` хранит только ссылку `{presetId, varsValues}`,
/// expansion + merge выполняется в `preset_expand.dart`.
///
/// `presetId` обязательный (§067 убрал legacy mode без preset_id).
class SelectableRule {
  SelectableRule({
    required this.label,
    required this.presetId,
    this.description = '',
    this.defaultEnabled = false,
    this.locked = false,
    this.pinned,
    this.ruleSets = const [],
    dynamic rule,
    this.vars = const [],
    dynamic dnsRule,
    this.dnsServers = const [],
  })  : rules = _normalizeRules(rule),
        dnsRules = _normalizeRules(dnsRule);

  final String label;
  final String description;
  final bool defaultEnabled;

  /// §264 — locked: пресет нельзя выключить/удалить/подвинуть (свич disabled,
  /// нет delete, drag off). Продуктовый инвариант (как `vpn-1` §125).
  final bool locked;

  /// §264 — pinned: фиксированная позиция в списке правил и в `route.rules`.
  /// `0` = всегда первый (критично для traffic-processing: `sniff` обязан быть
  /// первым правилом). `null` = не пиннится (обычный пресет, порядок свободный).
  final int? pinned;

  /// §264 — пресет закреплён на фиксированной позиции (pinned != null).
  bool get isPinned => pinned != null;

  final List<Map<String, dynamic>> ruleSets;

  /// Route-правила пресета в порядке шаблона (§246).
  ///
  /// Template-форма `rule` — Map (legacy, один rule) ИЛИ List (несколько,
  /// напр. `[resolve-#if, route]` у ru-direct). Конструктор нормализует
  /// обе в список; элементы могут быть `#if`-обёртками (§120) — они
  /// разворачиваются на expansion'е, не здесь.
  final List<Map<String, dynamic>> rules;

  /// Терминальный элемент [rules] — с `outbound` или терминальным `action`
  /// (не resolve/sniff/route-options). Для UI fallback-chain'а
  /// (`presetOut`): у пресетов без var:outbound терминальное правило —
  /// единственный источник дефолта (Block Ads → `action: reject`).
  /// `#if`-обёртки пропускаются (не имеют outbound/action на верхнем
  /// уровне) — такие пресеты объявляют var:outbound, chain до сюда не
  /// доходит. Нет терминального → пустой Map (fallback `direct-out`).
  Map<String, dynamic> get terminalRule {
    for (final r in rules.reversed) {
      final action = r['action'];
      if (action is String && _intermediateActions.contains(action)) continue;
      if (r['outbound'] is String || action is String) return r;
    }
    return const {};
  }

  static const _intermediateActions = {'resolve', 'sniff', 'route-options'};

  static List<Map<String, dynamic>> _normalizeRules(dynamic rule) {
    if (rule is Map<String, dynamic>) return rule.isEmpty ? const [] : [rule];
    if (rule is List) {
      return rule.whereType<Map<String, dynamic>>().toList();
    }
    return const [];
  }

  /// Stable slug для bundle-пресетов (spec §033). Пустой → legacy-режим.
  final String presetId;

  /// Типизированные переменные пресета (spec §033). `@name` в
  /// rule_set/dns_rule/rule/dns_servers подставляется при expansion'е.
  final List<WizardVar> vars;

  /// DNS-правила, которые пресет вносит в `dns.rules`, в порядке шаблона
  /// (§253). Template-форма `dns_rules` — List (канонический) ИЛИ
  /// `dns_rule` — Map (legacy single, fakeip). Пустой список → пресет не
  /// трогает DNS-rules. Элементы могут быть `#if`-обёртками (§120/§246) —
  /// разворачиваются на expansion'е.
  final List<Map<String, dynamic>> dnsRules;

  /// DNS-серверы, из которых `@dns_server` var выбирает один для
  /// добавления в `dns.servers`. Пустой список → пресет не вносит
  /// DNS-серверов.
  final List<Map<String, dynamic>> dnsServers;

  /// Показывать ли outbound-picker в строке пресета. Критерий строгий: пресет
  /// объявляет var типа `outbound`. Наличие var = явное намерение автора
  /// шаблона «тут outbound выбирается» (билдер применяет выбор через
  /// `varsValues['outbound']`, см. preset_expand.dart override-ветку).
  ///
  /// Пресеты БЕЗ var:outbound (`block-ads` — чистый reject; `fakeip` — DNS-only)
  /// picker не получают: менять нечего. Захотел дать выбор — добавь var:outbound
  /// в шаблон (как у ru-inside/bittorrent/private-ip/unknown-traffic).
  bool get hasOutboundAffordance => vars.any((v) => v.type == 'outbound');

  /// §231 — пресет вносит изменения в DNS (DNS-сервер и/или DNS-правило в
  /// `dns.servers`/`dns.rules`). Для UI-маркера «DNS» в списке правил: глядя на
  /// строку, не видно, что пресет (напр. FakeIP / ru-direct) трогает DNS
  /// Settings. Тот же split, что в debug-сериализаторе (has_dns_rule /
  /// dns_servers_count) и в гейте билдера (`p.dnsRules.isNotEmpty`).
  bool get touchesDns => dnsRules.isNotEmpty || dnsServers.isNotEmpty;

  factory SelectableRule.fromJson(Map<String, dynamic> json) {
    final presetId = (json['preset_id'] as String?) ?? '';
    if (presetId.isEmpty) {
      throw FormatException(
        'SelectableRule "${json['ui']?['label'] ?? '<no-label>'}" missing '
        'required `preset_id` (legacy entries without preset_id are no longer '
        'supported)',
      );
    }
    // §264 — метаданные пресета живут ТОЛЬКО в объекте `ui`
    // (label/description/default/locked/pinned). Плоские поля больше не
    // читаются — все пресеты шаблона переведены на `ui`. Отсутствие `ui` →
    // пустые дефолты (пресет без имени = баг шаблона, поймает тест).
    final ui = json['ui'] as Map<String, dynamic>? ?? const {};
    return SelectableRule(
      label: ui['label'] as String? ?? '',
      description: ui['description'] as String? ?? '',
      defaultEnabled: ui['default'] as bool? ?? false,
      locked: ui['locked'] as bool? ?? false,
      pinned: ui['pinned'] as int?,
      ruleSets: (json['rule_set'] as List<dynamic>?)
              ?.map((e) => Map<String, dynamic>.from(e as Map))
              .toList() ??
          [],
      // §246: `rules` (List, канонический ключ массивной формы) |
      // `rule` (Map, legacy single) — нормализует конструктор.
      rule: json['rules'] ?? json['rule'],
      presetId: presetId,
      vars: (json['vars'] as List<dynamic>?)
              ?.whereType<Map<String, dynamic>>()
              .map((v) => WizardVar.fromJson(v))
              .toList() ??
          const [],
      // §253: `dns_rules` (List, канонический ключ массивной формы) |
      // `dns_rule` (Map, legacy single) — нормализует конструктор.
      dnsRule: json['dns_rules'] ?? json['dns_rule'],
      dnsServers: (json['dns_servers'] as List<dynamic>?)
              ?.map((e) => Map<String, dynamic>.from(e as Map))
              .toList() ??
          const [],
    );
  }
}
