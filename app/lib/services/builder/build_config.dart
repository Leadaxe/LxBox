import 'dart:convert';

import '../../models/custom_rule.dart';
import '../../models/emit_context.dart';
import '../../models/parser_config.dart';
import '../../models/server_list.dart';
import '../../models/singbox_entry.dart';
import '../../models/template_vars.dart';
import '../../config/consts.dart';
import '../../models/validation.dart';
import '../json_clone.dart';
import '../rule_set_downloader.dart';
import '../settings_storage.dart';
import '../template_loader.dart';
import 'if_engine.dart';
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

  /// §046: OS-level split-tunneling apps list. `null` = pipeline возьмёт
  /// дефолт (mode=off — все apps через tun, sing-box обычное поведение).
  final TunAppsConfig? tunApps;

  /// §119: VPN-mode (proxy/vpn/vpn_proxy). `null` = mode=vpn (текущее
  /// поведение, post-step no-op).
  final VpnModeConfig? vpnMode;

  const BuildSettings({
    this.userVars = const {},
    this.enabledGroups = const {},
    this.excludedNodes = const {},
    this.customRules = const [],
    this.routeFinal = '',
    this.tunApps,
    this.vpnMode,
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
/// 2. Merge template defaults + user overrides → vars (§122: clash_api удалён).
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
  // §120: ноды переменных (метаданные: type) — из шаблона, единственный источник
  // правды о типе. Значение — из state (ниже). byName нужен резолверу для
  // coerce по node.type.
  final byName = <String, WizardVar>{};
  for (final v in template.vars) {
    final raw = settings.userVars[v.name] ?? v.defaultValue;
    // §161 backstop: пустое required-поле с непустым default → default. Ловит
    // источники в обход UI (импорт бэкапа/пресета, legacy-state с пустым
    // значением — напр. стёртый tolerance). ДО _substituteVars, не трогает
    // #if-логику. secret/optional (required:false) исключены — для них пусто
    // легитимно.
    vars[v.name] =
        (raw.isEmpty && v.required && v.defaultValue.isNotEmpty && v.type != 'secret')
            ? v.defaultValue
            : raw;
    byName[v.name] = v;
  }
  // Также пропускаем user-override'ы, которые могут прийти вне template.vars
  // (например, clash_api/secret, сохранённые раньше).
  for (final e in settings.userVars.entries) {
    vars.putIfAbsent(e.key, () => e.value);
  }

  // §122 Фаза 1b — clash_api БОЛЬШЕ НЕ инжектится: ядро rc.2 собрано без
  // with_clash_api (server вырезан, §1a), и блок experimental.clash_api в конфиге
  // даёт ФАТАЛЬНЫЙ отказ старта ("clash api is not included in this build").
  // Управление — через CommandClient (§122). `_ensureClashApiDefaults` удалён.
  final generatedVars = <String, String>{};

  // §120/§119: проброс VPN-mode в плоский vars ПРЯМЫМ присваиванием (live
  // VpnModeConfig побеждает любой залежавшийся flat-userVar — НЕ putIfAbsent).
  // Делается ДО _substituteVars, т.к. #if в
  // шаблоне (tun-in/mixed-in/route-rules) гейтится по @vpn_mode/@proxy_*.
  // applyVpnMode удалён — вся структура теперь декларативна в шаблоне.
  final vpnMode = settings.vpnMode;
  if (vpnMode != null) {
    vars['vpn_mode'] = vpnMode.mode;
    vars['proxy_type'] = vpnMode.proxyProtocol;
    vars['proxy_listen'] = vpnMode.proxyListen;
    vars['proxy_port'] = '${vpnMode.proxyPort}';
    vars['proxy_user'] = vpnMode.proxyUsername;
    vars['proxy_pass'] = vpnMode.proxyPassword;
    // proxy_auth несёт ЭФФЕКТИВНЫЙ флаг: effectiveAuth (0.0.0.0 форсит) И
    // непустой пароль — иначе users отсутствует (защита 067 от [{"":""}]).
    vars['proxy_auth'] =
        (vpnMode.effectiveAuth && vpnMode.proxyPassword.isNotEmpty)
            ? 'true'
            : 'false';
  } else {
    vars['vpn_mode'] = 'vpn'; // degrade к tun-only (иначе пустой inbounds[])
  }

  final resolve = makeResolver(vars, byName);

  final config = deepCopyJson(template.config);
  _substituteVars(config, resolve);

  // §120: sniff-rule теперь обёрнут #if @sniff_enabled в шаблоне — отдельный
  // removal-шаг не нужен (walker дропает array-element при false).

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
    resolve: resolve,
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

  // §033: Read DNS rules storage to determine independent DNS-aspect enable
  // for each preset (custom_rules entry has its own .enabled, dns side has
  // its own .enabled — independent flags).
  final dnsRulesStorage = await SettingsStorage.getDnsRulesList();
  final isPresetDnsEnabled = <String, bool>{
    for (final e in dnsRulesStorage)
      if (e['kind'] == 'preset' && e['presetId'] is String)
        e['presetId'] as String: e['enabled'] == true,
  };

  // §033: presetIds with custom_rules.kind:preset entry AND dns_rule defined
  // in template — для auto-discovery `kind:preset` записей в dns_options.rules.
  // §121: routing-тоггл = король — выключенный пресет (cr.enabled=false) не
  // считается active'ным для DNS-правил, поэтому его kind:preset запись в
  // dns_options.rules orphan-чистится (симметрия с серверами).
  final activePresetIdsWithDnsRule = <String>{
    for (final cr in settings.customRules)
      if (cr is CustomRulePreset && cr.enabled && cr.presetId.isNotEmpty)
        if (template.selectableRules
            .any((p) => p.presetId == cr.presetId && p.dnsRule != null))
          cr.presetId,
  };

  // §033: Resolve cached paths for kind:srs DNS-rules. Same RuleSetDownloader
  // as routing srs but separate id namespace (prefix `ds_` vs route's `r_`).
  final dnsSrsCachedPaths = <String, String>{};
  for (final entry in dnsRulesStorage) {
    if (entry['kind'] != 'srs') continue;
    final id = entry['id'] as String?;
    if (id == null || id.isEmpty) continue;
    final p = await RuleSetDownloader.cachedPath(id);
    if (p != null) dnsSrsCachedPaths[id] = p;
  }

  // §062: единый entry-point — обходит все custom rules (preset/inline/srs)
  // в storage order, dispatch по kind. Сохраняет user-managed order между
  // kind'ами (старый pipeline разделял на 2 прохода что ломало порядок).
  final unifiedApply = applyAllCustomRules(
    ruleSets,
    settings.customRules,
    template.selectableRules,
    srsPaths: srsPaths,
    presetSrsPaths: presetSrsPaths,
    isPresetDnsEnabled: isPresetDnsEnabled,
  );
  emitWarnings.addAll(unifiedApply.warnings);

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
    extraServers: unifiedApply.extraDnsServers,
    extraDnsRulesByPresetId: unifiedApply.dnsRulesByPresetId,
    activePresetIdsWithDnsRule: activePresetIdsWithDnsRule,
    dnsSrsCachedPaths: dnsSrsCachedPaths,
    dnsMirrors: unifiedApply.dnsMirrors,
  );

  // §119/§120: VPN-mode (tun-in/mixed-in/route-rules) теперь декларативен —
  // резолвится #if-walker'ом в substitution-фазе (выше, по @vpn_mode/@proxy_*).
  // applyVpnMode удалён. К этому моменту inbounds[] уже финальный: в proxy
  // tun-in физически отсутствует → applyTunPackages (по type=='tun') no-op'ит.

  // §046: OS-level split-tunneling. Должен быть **последним** post-step'ом —
  // финальный transform tun-inbound, после всего остального.
  if (settings.tunApps != null) {
    applyTunPackages(config, settings.tunApps!);
  }

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
  required VarResolver resolve,
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

    final options = deepCopyJson(preset.options);
    _substituteVars(options, resolve);
    final def = options['default'];
    // §141 P1.8b — раньше гейт был `def is String && !tags.contains(def)`:
    // не-строковый `default` (число/bool из кривого template) проскакивал бы
    // мимо и оба гейта (здесь + validator) его не ловили. Удаляем любой
    // присутствующий default, который не является валидным tag'ом.
    if (def != null && (def is! String || !tags.contains(def))) {
      options.remove('default');
    }

    result.add({
      'tag': preset.tag,
      'type': preset.type,
      'outbounds': tags,
      ...options,
    });
  }
  return result;
}

// §122 Фаза 1b — `_ensureClashApiDefaults` удалён: clash_api больше не инжектится
// (ядро rc.2 без with_clash_api → блок даёт фатальный отказ старта). Управление
// через CommandClient (§122). Рандомизация порта/secret больше не нужна.

/// §120 — typed substitution + `#if`. Тонкая обёртка над общим [walk]-движком
/// ([if_engine.dart]). `obj` мутируется на месте. Coerce — по `node.type`
/// (через [resolve]), `#if` — резолвится здесь же (substitution-фаза, до
/// post-steps). Заменяет старые `_substituteVars`/`_resolveVar`, которые гадали
/// тип по содержимому строки.
void _substituteVars(dynamic obj, VarResolver resolve) {
  walk(obj, resolve);
}
