import 'dart:convert';
import 'dart:math';

import '../../models/custom_rule.dart';
import '../../models/emit_context.dart';
import '../../models/parser_config.dart';
import '../../models/server_list.dart';
import '../../models/singbox_entry.dart';
import '../../models/template_vars.dart';
import '../../config/consts.dart';
import '../../models/validation.dart';
import '../rule_set_downloader.dart';
import '../template_loader.dart';
import 'post_steps.dart';
import 'rule_set_registry.dart';
import 'server_list_build.dart';
import 'validator.dart';

/// Результат сборки — готовый JSON + валидация + warnings + generated-vars
/// которые контроллеру надо записать обратно в storage (Clash API port/secret
/// — рандомизируются здесь на первом запуске).
class BuildResult {
  final String configJson;
  final Map<String, dynamic> config; // тот же config, но как Map (для тестов/debug)
  final ValidationResult validation;
  final List<String> emitWarnings;
  final Map<String, String> generatedVars; // подмножество vars, которые сгенерились в процессе
  const BuildResult({
    required this.configJson,
    required this.config,
    required this.validation,
    required this.emitWarnings,
    required this.generatedVars,
  });
}

/// Настройки сборки — то что UI/контроллер прокидывает в `buildConfig`.
class BuildSettings {
  final Map<String, String> userVars;
  final Set<String> enabledGroups;
  final Set<String> excludedNodes;
  final List<CustomRule> customRules;
  final String routeFinal;

  const BuildSettings({
    this.userVars = const {},
    this.enabledGroups = const {},
    this.excludedNodes = const {},
    this.customRules = const [],
    this.routeFinal = '',
  });
}

/// **Единственная точка сборки sing-box конфига** (§3.4).
///
/// Вход: список подписок + параметры. Выход: готовый JSON-конфиг.
/// GUI/контроллер ничего про wizard template, dedup, preset-группы знать
/// не должен.
///
/// Шаги (все inline):
/// 1. Load wizard template.
/// 2. Merge template defaults + user overrides → vars; randomize clash_api.
/// 3. Deep-copy template.config, substitute vars.
/// 4. Пройти по `lists` → `nodes`, применить `DetourPolicy`, дедуп тегов с
///    учётом `tagPrefix`, emit() → разложить по outbounds/endpoints.
/// 5. Собрать preset-группы (vpn-1/2/3 + auto).
/// 6. Applied selectable rules, app rules, route final.
/// 7. Post-steps: tls_fragment, custom DNS.
/// 8. Validate → вернуть BuildResult с готовым `configJson`.
Future<BuildResult> buildConfig({
  required List<ServerList> lists,
  BuildSettings settings = const BuildSettings(),
  WizardTemplate? template,
}) async {
  template ??= await TemplateLoader.load();

  // Merge template defaults + user overrides.
  final vars = <String, String>{};
  for (final v in template.vars) {
    vars[v.name] = settings.userVars[v.name] ?? v.defaultValue;
  }
  // Также пропускаем user-override'ы, которые могут прийти вне template.vars
  // (например, clash_api/secret, сохранённые раньше).
  for (final e in settings.userVars.entries) {
    vars.putIfAbsent(e.key, () => e.value);
  }

  final generatedVars = <String, String>{};
  _ensureClashApiDefaults(vars, generatedVars);

  final config = _deepCopy(template.config);
  _substituteVars(config, vars);

  // Remove sniff rule if disabled
  if (vars['sniff_enabled'] == 'false') {
    final route = config['route'] as Map<String, dynamic>?;
    final rules = route?['rules'] as List<dynamic>?;
    rules?.removeWhere((r) => r is Map && r['action'] == 'sniff');
  }

  final tvars = TemplateVars(
    tlsFragment: vars['tls_fragment'] == 'true',
    tlsRecordFragment: vars['tls_record_fragment'] == 'true',
  );

  // Реестр rule_set/rules инициализируется из template — template может
  // содержать built-in inline rule_set (например `ru-domains`). Реестр
  // живёт один на весь buildConfig, доступен post-steps'ам через прямой
  // параметр, а ServerList.build'у — через `ctx.ruleSets`.
  final route = config['route'] as Map<String, dynamic>? ?? {};
  final ruleSets = RuleSetRegistry(
    initialRuleSets: route['rule_set'] as List<dynamic>? ?? const [],
    initialRules: route['rules'] as List<dynamic>? ?? const [],
  );

  // buildConfig — тонкий оркестратор. ServerList.build(ctx) сам решает
  // политику, аллоцирует теги через ctx, регистрирует в selector/auto.
  final ctx = _BuildCtx(tvars, ruleSets);
  for (final list in lists) {
    list.build(ctx);
  }

  // Warnings собираем отдельно прямым обходом (ctx их не знает).
  final emitWarnings = <String>[];
  for (final list in lists) {
    if (!list.enabled) continue;
    for (final node in list.nodes) {
      for (final w in node.warnings) {
        final line = '${node.tag}: ${w.message}';
        if (!emitWarnings.contains(line)) emitWarnings.add(line);
      }
    }
  }

  final selectorTags =
      ctx.selectorEntries.map((e) => e.tag).toList(growable: false);
  final autoTags =
      ctx.autoEntries.map((e) => e.tag).toList(growable: false);

  final presetOutbounds = _buildPresetGroups(
    presets: template.presetGroups,
    enabledGroupTags: settings.enabledGroups,
    selectorTags: selectorTags,
    autoTags: autoTags,
    excludedNodes: settings.excludedNodes,
    vars: vars,
  );

  final baseOutbounds = config['outbounds'] as List<dynamic>? ?? const [];
  config['outbounds'] = [
    ...baseOutbounds,
    ...ctx.outbounds.map((e) => e.map),
    ...presetOutbounds,
  ];

  if (ctx.endpoints.isNotEmpty) {
    final baseEndpoints = config['endpoints'] as List<dynamic>? ?? const [];
    config['endpoints'] = [
      ...baseEndpoints,
      ...ctx.endpoints.map((e) => e.map),
    ];
  }

  // Pre-resolve srs local paths (sing-box получает file:// — rule set
  // `{type: local, path: …}`). Удалённо ничего не качается.
  final srsPaths = <String, String>{};
  for (final cr in settings.customRules) {
    if (cr.kind != CustomRuleKind.srs) continue;
    final p = await RuleSetDownloader.cachedPath(cr.id);
    if (p != null) srsPaths[cr.id] = p;
  }
  // Bundle presets (spec §033, task 011) — expansion + merge. Регистрирует
  // rule-set и routing-правила в registry, extra DNS-данные возвращает для
  // передачи в applyCustomDns. Выполняется **до** applyCustomRules, чтобы
  // bundle получал свои tag'и чисто (без auto-suffix), а inline/srs правила
  // пользователя, если вдруг совпадают по name с bundle-tag'ом, ушли
  // в auto-suffix.
  //
  // Pre-resolve локально закэшированных remote rule_set'ов пресета:
  // spec §011 требует `type: local, path: <кэш>` вместо `type: remote`.
  // Ключ плоский: `<presetId>|<rule_set_tag>`.
  final presetSrsPaths = <String, String>{};
  for (final cr in settings.customRules) {
    if (cr is! CustomRulePreset) continue;
    if (cr.presetId.isEmpty) continue;
    SelectableRule? preset;
    for (final p in template.selectableRules) {
      if (p.presetId == cr.presetId) {
        preset = p;
        break;
      }
    }
    if (preset == null) continue;
    for (final rs in preset.ruleSets) {
      if (rs['type'] != 'remote') continue;
      final tag = rs['tag'];
      if (tag is! String || tag.isEmpty) continue;
      final path = await RuleSetDownloader.cachedPathForPreset(cr.presetId, tag);
      if (path != null) {
        presetSrsPaths['${cr.presetId}|$tag'] = path;
      }
    }
  }

  final presetApply = applyPresetBundles(
    ruleSets,
    settings.customRules,
    template.selectableRules,
    presetSrsPaths: presetSrsPaths,
  );
  emitWarnings.addAll(presetApply.warnings);

  emitWarnings.addAll(applyCustomRules(
    ruleSets,
    settings.customRules,
    srsPaths: srsPaths,
  ));

  // Flush реестра в config.route. Один раз в конце — следующие post-steps
  // (tls_fragment, mixed_case_sni) не трогают rule_set/rules.
  route['rule_set'] = ruleSets.getRuleSets();
  route['rules'] = ruleSets.getRules();
  config['route'] = route;

  if (settings.routeFinal.isNotEmpty) {
    route['final'] = settings.routeFinal;
  }

  applyTlsFragment(config, vars);
  applyMixedCaseSni(config, vars);

  await applyCustomDns(
    config,
    template.dnsOptions,
    extraServers: presetApply.extraDnsServers,
    extraRules: presetApply.extraDnsRules,
  );

  final validation = validateConfig(config);
  return BuildResult(
    configJson: jsonEncode(config),
    config: config,
    validation: validation,
    emitWarnings: emitWarnings,
    generatedVars: generatedVars,
  );
}

/// Реализация `EmitContext`: vars + аллокатор уникальных тегов +
/// аккумуляторы entries + RuleSetRegistry.
class _BuildCtx implements EmitContext {
  _BuildCtx(this._vars, this._ruleSets);
  final TemplateVars _vars;
  final RuleSetRegistry _ruleSets;
  final _taken = <String>{'direct-out', 'dns-out', 'block-out'};

  final outbounds = <Outbound>[];
  final endpoints = <Endpoint>[];
  final selectorEntries = <SingboxEntry>[];
  final autoEntries = <SingboxEntry>[];

  @override
  TemplateVars get vars => _vars;

  @override
  RuleSetRegistry get ruleSets => _ruleSets;

  @override
  String allocateTag(String baseTag) {
    if (!_taken.contains(baseTag)) {
      _taken.add(baseTag);
      return baseTag;
    }
    for (var i = 1; i < 100000; i++) {
      final c = '$baseTag-$i';
      if (!_taken.contains(c)) {
        _taken.add(c);
        return c;
      }
    }
    return baseTag;
  }

  @override
  void addEntry(SingboxEntry entry) {
    switch (entry) {
      case Outbound():
        outbounds.add(entry);
      case Endpoint():
        endpoints.add(entry);
    }
  }

  @override
  void addToSelectorTagList(SingboxEntry entry) => selectorEntries.add(entry);

  @override
  void addToAutoList(SingboxEntry entry) => autoEntries.add(entry);
}

/// Собирает preset-группы (vpn-1/vpn-2/vpn-3/auto). Приватный
/// helper `buildConfig` — специфичен для одного вызова, выделение в
/// отдельный файл/модуль не даёт пользы (YAGNI, решение §Принципы #4).
List<Map<String, dynamic>> _buildPresetGroups({
  required List<PresetGroup> presets,
  required Set<String> enabledGroupTags,
  required List<String> selectorTags,
  required List<String> autoTags,
  required Set<String> excludedNodes,
  required Map<String, String> vars,
}) {
  final activePresets = presets.where((p) {
    if (p.tag == 'vpn-1') return true;
    if (enabledGroupTags.isEmpty) return p.defaultEnabled;
    return enabledGroupTags.contains(p.tag);
  }).toList();

  final autoProxyEnabled =
      activePresets.any((p) => p.tag == kAutoOutboundTag);

  List<String> tagsFor(PresetGroup p) {
    if (p.type == 'urltest') {
      return autoTags.where((t) => !excludedNodes.contains(t)).toList();
    }
    return selectorTags;
  }

  final emittedGroupTags = <String>{};
  for (final preset in activePresets) {
    final nodes = tagsFor(preset);
    if (nodes.isNotEmpty || preset.type != 'urltest') {
      emittedGroupTags.add(preset.tag);
    }
  }

  final knownTags = <String>{
    'direct-out',
    ...selectorTags,
    ...autoTags,
    ...emittedGroupTags,
  };

  final result = <Map<String, dynamic>>[];
  for (final preset in activePresets) {
    final nodes = tagsFor(preset);
    final addOutbounds = preset.addOutbounds
        .where(knownTags.contains)
        .where((t) => t != kAutoOutboundTag || autoProxyEnabled);
    final tags = <String>[...nodes, ...addOutbounds];
    if (tags.isEmpty) {
      if (preset.type == 'urltest') continue;
      tags.add('direct-out');
    }

    final options = _deepCopy(preset.options);
    _substituteVars(options, vars);
    final def = options['default'];
    if (def is String && !tags.contains(def)) options.remove('default');

    result.add({
      'tag': preset.tag,
      'type': preset.type,
      'outbounds': tags,
      ...options,
    });
  }
  return result;
}

void _ensureClashApiDefaults(Map<String, String> vars, Map<String, String> generated) {
  final rng = Random.secure();

  final api = vars['clash_api'] ?? '127.0.0.1:9090';
  if (api == '127.0.0.1:9090' || api.endsWith(':9090')) {
    final port = 49152 + rng.nextInt(65535 - 49152);
    vars['clash_api'] = '127.0.0.1:$port';
    generated['clash_api'] = vars['clash_api']!;
  }
  final secret = vars['clash_secret'] ?? '';
  if (secret.isEmpty) {
    final bytes = List.generate(16, (_) => rng.nextInt(256));
    vars['clash_secret'] =
        bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    generated['clash_secret'] = vars['clash_secret']!;
  }
}

Map<String, dynamic> _deepCopy(Map<String, dynamic> s) =>
    jsonDecode(jsonEncode(s)) as Map<String, dynamic>;

void _substituteVars(dynamic obj, Map<String, String> vars) {
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

dynamic _resolveVar(dynamic value, Map<String, String> vars) {
  if (value is! String || !value.startsWith('@')) return null;
  final name = value.substring(1);
  if (!vars.containsKey(name)) return null;
  final v = vars[name]!;
  if (v == 'true') return true;
  if (v == 'false') return false;
  return int.tryParse(v) ?? v;
}
