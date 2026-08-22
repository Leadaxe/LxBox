/// Full wizard template loaded from asset.
class WizardTemplate {
  WizardTemplate({
    required this.parserConfig,
    required this.groupTemplates,
    required this.vars,
    required this.varSections,
    required this.config,
    required this.selectableRules,
    required this.dnsOptions,
    required this.pingOptions,
    required this.speedTestOptions,
    DnsOptionsModel? dnsOptionsModel,
    PingOptionsModel? pingOptionsModel,
    SpeedTestOptionsModel? speedTestOptionsModel,
  })  : dnsOptionsModel =
            dnsOptionsModel ?? DnsOptionsModel.fromJson(dnsOptions),
        pingOptionsModel =
            pingOptionsModel ?? PingOptionsModel.fromJson(pingOptions),
        speedTestOptionsModel = speedTestOptionsModel ??
            SpeedTestOptionsModel.fromJson(speedTestOptions);

  final ParserConfigBlock parserConfig;
  final GroupTemplates groupTemplates; // §267 (было: List<PresetGroup> presetGroups)
  final List<WizardVar> vars;
  final Map<String, dynamic> config;
  final List<SelectableRule> selectableRules;
  final Map<String, dynamic> dnsOptions;
  final Map<String, dynamic> pingOptions;
  final Map<String, dynamic> speedTestOptions;

  /// §279 Phase 2 (§3.3 hardening) — typed-модели трёх raw-секций для экранов.
  /// Парсятся из УЖЕ оверлеенного JSON (display-поля локализованы) — новое
  /// display-поле нельзя потребить мимо choke point. Raw-мапы выше остаются
  /// для machine-level билдера (build_config), он display-текст не читает.
  final DnsOptionsModel dnsOptionsModel;
  final PingOptionsModel pingOptionsModel;
  final SpeedTestOptionsModel speedTestOptionsModel;

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
    // §267 — group_templates + top-level default_channels (было preset_groups).
    final groupTemplatesJson =
        json['group_templates'] as Map<String, dynamic>? ?? const {};
    final defaultChannelsJson =
        json['default_channels'] as List<dynamic>? ?? const [];

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
        id: s['id'] as String? ?? '',
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
      groupTemplates:
          GroupTemplates.fromJson(groupTemplatesJson, defaultChannelsJson),
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

// ===========================================================================
// §279 Phase 2 (§3.3) — typed-модели raw-секций dns_options / ping_options /
// speed_test_options. Тонкие: только поля, реально потребляемые экранами
// (tag/id, name/description, vars). У DNS-серверов дополнительно хранится
// исходная §117-обёртка (`wrapper`) — резолверу/редактору нужен machine-body.
// ===========================================================================

/// §279 — один template-DNS-server из `dns_options.servers[]` (§117-обёртка
/// `{description, enabled, vars?, server}`). `tag` — из вложенного `server`
/// (single source of truth, top-level `tag` не существует).
class TemplateDnsServerEntry {
  TemplateDnsServerEntry({
    required this.tag,
    this.description = '',
    this.enabled = true,
    this.vars = const [],
    this.wrapper = const {},
  });

  final String tag;
  final String description; // display (локализуется overlay'ем)
  final bool enabled;
  final List<WizardVar> vars; // display-титулы var'ов (локализуются)

  /// Исходная §117-обёртка целиком — для резолвера body
  /// (`resolveTemplateDnsServerBody`) и редактора. Machine-уровень.
  final Map<String, dynamic> wrapper;

  /// null если у записи нет валидного `server.tag` (malformed — пропускается).
  static TemplateDnsServerEntry? fromWrapper(Map<String, dynamic> w) {
    final server = w['server'];
    final tag = server is Map ? server['tag'] : null;
    if (tag is! String || tag.isEmpty) return null;
    return TemplateDnsServerEntry(
      tag: tag,
      description: w['description']?.toString() ?? '',
      enabled: w['enabled'] as bool? ?? true,
      vars: (w['vars'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map((v) => WizardVar.fromJson(v))
          .toList(),
      wrapper: w,
    );
  }
}

/// §279 — typed-view `dns_options` для экранов (DNS Settings, редактор
/// правила). `rules` остаются raw (их `name` — identity-ключ, не display).
class DnsOptionsModel {
  DnsOptionsModel({this.servers = const []});

  final List<TemplateDnsServerEntry> servers;

  /// tag → §117-обёртка (зеркало `templateDnsServersByTag` билдера).
  Map<String, Map<String, dynamic>> get wrappersByTag =>
      {for (final s in servers) s.tag: s.wrapper};

  factory DnsOptionsModel.fromJson(Map<String, dynamic> json) {
    final servers = <TemplateDnsServerEntry>[];
    for (final s in json['servers'] as List<dynamic>? ?? const []) {
      if (s is! Map<String, dynamic>) continue;
      final entry = TemplateDnsServerEntry.fromWrapper(s);
      if (entry != null) servers.add(entry);
    }
    return DnsOptionsModel(servers: servers);
  }
}

/// §279 — пресет ping-URL из `ping_options.presets[]` (id — стабильный
/// machine-ключ, §279 Phase 0; name — display).
class PingPreset {
  PingPreset({required this.id, this.name = '', this.url = ''});

  final String id;
  final String name; // display (локализуется overlay'ем)
  final String url;

  factory PingPreset.fromJson(Map<String, dynamic> json) => PingPreset(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        url: json['url']?.toString() ?? '',
      );
}

/// §279 — typed-view `ping_options` (дефолтный URL/timeout + пресеты).
class PingOptionsModel {
  PingOptionsModel({
    this.defaultUrl = '',
    this.defaultTimeoutMs = 0,
    this.presets = const [],
  });

  final String defaultUrl;
  final int defaultTimeoutMs; // 0 = не задан (caller применяет свой дефолт)
  final List<PingPreset> presets;

  factory PingOptionsModel.fromJson(Map<String, dynamic> json) {
    final timeout = json['timeout_ms'];
    return PingOptionsModel(
      defaultUrl: json['url']?.toString() ?? '',
      defaultTimeoutMs: (timeout is num && timeout > 0) ? timeout.toInt() : 0,
      presets: (json['presets'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(PingPreset.fromJson)
          .toList(),
    );
  }
}

/// §279 — speed-test сервер из `speed_test_options.servers[]` (id —
/// стабильный machine-ключ выбора, §279 Phase 0; name — display).
class SpeedTestServer {
  SpeedTestServer({
    required this.id,
    this.name = '',
    this.downloadUrl = '',
    this.uploadUrl,
    this.uploadMethod = 'PUT',
    this.pingUrl = '',
  });

  final String id;
  final String name; // display (локализуется overlay'ем)
  final String downloadUrl;
  final String? uploadUrl; // null → fallback на downloadUrl
  final String uploadMethod; // 'PUT' | 'POST'
  final String pingUrl; // пустой → fallback на downloadUrl

  factory SpeedTestServer.fromJson(Map<String, dynamic> json) =>
      SpeedTestServer(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        downloadUrl: json['download_url']?.toString() ?? '',
        uploadUrl: json['upload_url']?.toString(),
        uploadMethod: json['upload_method']?.toString() ?? 'PUT',
        pingUrl: json['ping_url']?.toString() ?? '',
      );
}

/// §279 — typed-view `speed_test_options` (серверы + варианты потоков).
class SpeedTestOptionsModel {
  SpeedTestOptionsModel({
    this.servers = const [],
    this.streamOptions = const [],
    this.defaultStreams,
  });

  final List<SpeedTestServer> servers;
  final List<int> streamOptions;
  final int? defaultStreams;

  factory SpeedTestOptionsModel.fromJson(Map<String, dynamic> json) =>
      SpeedTestOptionsModel(
        servers: (json['servers'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(SpeedTestServer.fromJson)
            .toList(),
        streamOptions: (json['stream_options'] as List<dynamic>? ?? const [])
            .whereType<num>()
            .map((n) => n.toInt())
            .toList(),
        defaultStreams: (json['default_streams'] as num?)?.toInt(),
      );
}

// §267 — `group_templates` + `default_channels` заменяют плоский `preset_groups`.
//
// Раньше `preset_groups` сваливал в один массив три разнородные сущности
// (шаблон auto-подгруппы под фейковым tag `@auto_proxy_tag`, каналы vpn-N) и
// читался только как seed первой миграции. Теперь разделено на:
//   - `magic_nodes` — реестр служебных нод (auto/direct/block) по role-ключу;
//   - `channel`/`auto` — шаблоны сборки канала и его urltest-подгруппы;
//   - `default_channels` — плоский список каналов для сида первого запуска.
//
// Полное описание — docs/spec/tasks/267-group-templates-magic-nodes.md.

/// §267 — служебная нода из `group_templates.magic_nodes`. Ключ мапы = `role`.
///
/// `source` (`generate`/`preset`) — как нода рождается: `generate` — билдер
/// синтезирует её per-channel (auto/urltest, статического tag нет — тег из
/// `tpl`); `preset` — готовый объект уже лежит в `config.outbounds` (direct/
/// block, `tag` — ссылка на него). НЕ путать с sing-box outbound-`type`
/// (`urltest`/`direct`/`block`) — это другая ось.
class MagicNode {
  MagicNode({
    required this.role,
    required this.title,
    required this.source,
    this.tag,
    this.tpl,
  });

  final String role; // 'auto' | 'direct' | 'block' (ключ мапы)
  final String title; // human-label для UI (special_node_display)
  final String source; // 'generate' | 'preset'
  final String? tag; // preset: ссылка на config.outbounds; generate: null
  final String? tpl; // generate: шаблон тега ('{parent_tag}-auto'); preset: null

  factory MagicNode.fromJson(String role, Map<String, dynamic> json) {
    return MagicNode(
      role: role,
      title: json['title'] as String? ?? '',
      source: json['source'] as String? ?? 'preset',
      tag: json['tag'] as String?,
      tpl: json['tpl'] as String?,
    );
  }
}

/// §267 — шаблон обычного канала (selector) из `group_templates.channel`.
/// `include` — role-ключи `magic_nodes`, показываемые в selector канала
/// (`direct`/`auto`); `block` по умолчанию не включён.
class ChannelTemplate {
  ChannelTemplate({
    this.type = 'selector',
    this.include = const [],
    this.options = const {},
  });

  final String type; // 'selector'
  final List<String> include; // role-ключи magic_nodes
  final Map<String, dynamic> options;

  factory ChannelTemplate.fromJson(Map<String, dynamic> json) {
    return ChannelTemplate(
      type: json['type'] as String? ?? 'selector',
      include: (json['include'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
      options: json['options'] as Map<String, dynamic>? ?? const {},
    );
  }
}

/// §267 — шаблон auto-подгруппы (urltest) из `group_templates.auto`.
/// `options` — сырой template (`@urltest_*`-плейсхолдеры НЕ резолвены; var-
/// substitution идёт позже, в билдере/seed'е).
class AutoTemplate {
  AutoTemplate({this.type = 'urltest', this.options = const {}});

  final String type; // 'urltest'
  final Map<String, dynamic> options;

  factory AutoTemplate.fromJson(Map<String, dynamic> json) {
    return AutoTemplate(
      type: json['type'] as String? ?? 'urltest',
      options: json['options'] as Map<String, dynamic>? ?? const {},
    );
  }
}

/// §267 — один канал для сида первого запуска из `default_channels[i]`.
class DefaultChannel {
  DefaultChannel({
    required this.tag,
    this.label = '',
    this.defaultEnabled = true,
  });

  final String tag;
  final String label;
  final bool defaultEnabled;

  factory DefaultChannel.fromJson(Map<String, dynamic> json) {
    return DefaultChannel(
      tag: json['tag'] as String? ?? '',
      label: json['label'] as String? ?? '',
      defaultEnabled: json['default_enabled'] as bool? ?? true,
    );
  }
}

/// §267 — верхнеуровневый блок `group_templates` + top-level `default_channels`.
/// `magicNodes` — реестр по role-ключу; `channel`/`auto` — шаблоны сборки;
/// `defaultChannels` — сид первого запуска (собирается из top-level ключа,
/// НЕ внутри `group_templates`).
class GroupTemplates {
  GroupTemplates({
    this.magicNodes = const {},
    ChannelTemplate? channel,
    AutoTemplate? auto,
    this.defaultChannels = const [],
  })  : channel = channel ?? ChannelTemplate(),
        auto = auto ?? AutoTemplate();

  final Map<String, MagicNode> magicNodes; // role → node
  final ChannelTemplate channel;
  final AutoTemplate auto;
  final List<DefaultChannel> defaultChannels;

  factory GroupTemplates.fromJson(
    Map<String, dynamic> groupTemplatesJson,
    List<dynamic> defaultChannelsJson,
  ) {
    final nodesJson =
        groupTemplatesJson['magic_nodes'] as Map<String, dynamic>? ?? const {};
    final magicNodes = <String, MagicNode>{};
    for (final entry in nodesJson.entries) {
      final v = entry.value;
      if (v is Map<String, dynamic>) {
        magicNodes[entry.key] = MagicNode.fromJson(entry.key, v);
      }
    }
    return GroupTemplates(
      magicNodes: magicNodes,
      channel: ChannelTemplate.fromJson(
          groupTemplatesJson['channel'] as Map<String, dynamic>? ?? const {}),
      auto: AutoTemplate.fromJson(
          groupTemplatesJson['auto'] as Map<String, dynamic>? ?? const {}),
      defaultChannels: defaultChannelsJson
          .whereType<Map<String, dynamic>>()
          .map(DefaultChannel.fromJson)
          .toList(),
    );
  }
}

/// §267 — резолв `magic_nodes.*.tpl` для `generate`-ноды: подставляет tag
/// родительского канала в шаблон. Формализует нынешний `Channel.autoTag`.
/// `resolveTpl('{parent_tag}-auto', 'vpn-1') == 'vpn-1-auto'`.
String resolveTpl(String tpl, String parentTag) =>
    tpl.replaceAll('{parent_tag}', parentTag);

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
  // SPEC 103: канонический набор типов языка шаблонов — 8 (TEMPLATE_LANG §2.2).
  // text_list добавлен вместе с коэрцией в if_engine (разрыв C6).
  final String
      type; // bool, int, text, text_list, enum, secret, outbound, dns_servers
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
      // SPEC 107: канон — помеченный `#on_change`; легаси `on_change`
      // читается бессрочно.
      onChange: (json['#on_change'] ?? json['on_change']) as Map<String, dynamic>?,
    );
  }
}

/// A section header for grouping vars in the settings UI.
/// `chapter` наследуется на все переменные этой секции и определяет
/// экран-владелец (см. [WizardVar.chapter]).
class VarSection {
  VarSection({
    required this.title,
    this.id = '',
    this.description = '',
    this.chapter = 'core',
  });

  /// §279 — стабильный machine-id секции (адрес l10n-overlay). Display-поля
  /// (`title`/`description`) станут переводимыми; join-ключом между секцией и
  /// её vars остаётся `name` (=[title]) — id его НЕ заменяет.
  final String id;
  final String title;
  final String description;
  final String chapter;
}

/// §370 — границы зоны пользовательских правил на оси `num`.
///
/// Ось разреженная: шаблонные пресеты стоят по краям с шагом 10 (зазор под
/// будущие вставки), между ними — сто слотов под правила юзера. Полная
/// раскладка в `docs/spec/tasks/370-rule-order-num-axis.md` §2.
const int kUserRuleNumStart = 1000;
const int kUserRuleNumEnd = 1100;

/// §370 — дефолт для правила без явного `num` (середина пользовательской зоны).
const int kDefaultRuleNum = kUserRuleNumStart;

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
    this.num = kDefaultRuleNum,
    this.isSortable = true,
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

  /// §370 — позиция на разреженной оси порядка правил. Это СТАРТОВАЯ позиция,
  /// а не забитая навсегда сортировка: юзер двигает правило drag'ом, `num`
  /// пересчитывается (см. §370 §4).
  ///
  /// Раскладка: `0` — голова (traffic-processing), `950..980` — специфичные
  /// пресеты, `1000..1100` — зона пользовательских правил, `1110..1150` —
  /// широкие перехватчики. Шаг 10 между шаблонными оставлен намеренно: в
  /// зазор можно вписать новый пресет, не переделывая раскладку.
  final int num;

  /// §370 — можно ли двигать правило drag'ом. `false` = позиция закреплена
  /// (`traffic-processing`: `sniff` обязан быть первым правилом `route.rules`).
  ///
  /// Ортогонально [locked]: `locked` — про «нельзя выключить/удалить»,
  /// `isSortable` — про «нельзя двигать». У traffic-processing истинны оба,
  /// но это разные инварианты (§370 §1).
  final bool isSortable;

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
    // (label/description/default/locked + §370 num/isSortable). Плоские поля
    // больше не читаются — все пресеты шаблона переведены на `ui`. Отсутствие
    // `ui` → пустые дефолты (пресет без имени = баг шаблона, поймает тест).
    final ui = json['ui'] as Map<String, dynamic>? ?? const {};
    return SelectableRule(
      label: ui['label'] as String? ?? '',
      description: ui['description'] as String? ?? '',
      defaultEnabled: ui['default'] as bool? ?? false,
      locked: ui['locked'] as bool? ?? false,
      num: ui['num'] as int? ?? kDefaultRuleNum,
      isSortable: ui['isSortable'] as bool? ?? true,
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
