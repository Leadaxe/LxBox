// ===========================================================================
// §300 — фасад DNS-настроек под probe-эталон (ProbeController §296).
// Контроллер владеет storage + чистой логикой; экран (dns_settings_screen)
// становится тонким. Здесь — load()/snapshot (единственный domain-shape
// адаптер: сырой List<Map> → §294 типы на краях) + чистые static-решения.
//
// Что НЕ входит (§300 scope-cuts): resolveDisplayedServers/ResolvedServer/
// dns_server_resolver.dart — downstream VIEW (§294 их сохранил); контроллер их
// КОРМИТ, не поглощает. renameDnsServerTagRefs/cleanDnsRulesForPersist —
// оборачиваем, не переписываем. custom_rules dual-write — это §295 (device).
//
// Per-call stateless: без мутабельного состояния; экран держит своё.
// ===========================================================================

import '../../models/custom_rule.dart';
import '../../models/parser_config.dart';
// §300 — resolver/ResolvedServer живут в screens/ (§294 их VIEW-слой);
// контроллер их ВЫЗЫВАЕТ (pure-функции, односторонняя зависимость, не цикл).
// Перенос в services/ — отдельный шаг, не расширяем scope D1.
import '../../screens/dns_settings_screen/dns_server_resolver.dart';
import '../../widgets/outbound_picker.dart' show OutboundOption;
import '../builder/post_steps.dart';
import '../builder/preset_expand.dart';
import '../builder/rule_set_registry.dart';
import '../settings_storage.dart';
import '../template_loader.dart';

/// §300 — типизированный снимок всего, что нужно экрану DNS-настроек. Заменяет
/// разрозненные `setState`-присвоения `_load()`: одно значение, поля 1:1 с
/// прежними полями State. Типизация краёв (servers/rules) — на §294.
class DnsSettingsSnapshot {
  const DnsSettingsSnapshot({
    required this.servers,
    required this.templateByTag,
    required this.presetServersByTag,
    required this.rules,
    required this.templateRulesByName,
    required this.presetRulesByPresetId,
    required this.presetLabelByPresetId,
    required this.presetDnsEnable,
    required this.outboundOptions,
    required this.customRules,
    required this.dnsMirrorsByRuleId,
    required this.strategy,
    required this.dnsFinal,
    required this.defaultResolver,
    required this.resolverReset,
  });

  final List<Map<String, dynamic>> servers;
  final Map<String, Map<String, dynamic>> templateByTag;
  final Map<String, Map<String, dynamic>> presetServersByTag;
  final List<Map<String, dynamic>> rules;
  final Map<String, Map<String, dynamic>> templateRulesByName;
  final Map<String, List<Map<String, dynamic>>> presetRulesByPresetId;
  final Map<String, String> presetLabelByPresetId;
  final Map<String, bool> presetDnsEnable;
  final List<OutboundOption> outboundOptions;
  final List<CustomRule> customRules;
  final Map<String, List<DnsMirrorEntry>> dnsMirrorsByRuleId;
  final String strategy;
  final String dnsFinal;
  final String defaultResolver;

  /// §121 — исчезнувший resolver-tag сброшен на дефолт → экран должен
  /// `markDirty()` (persist битого ref не должен дожить до билда).
  final bool resolverReset;
}

class DnsController {
  const DnsController._();

  /// Читает всё состояние DNS-экрана (template + storage), резолвит серверы/
  /// правила (auto-discover/orphan-cleanup/persist-if-changed как раньше),
  /// строит превью-mirror'ы и считает §121 resolver-autoreset. Чистый
  /// read+derive; типизация краёв через §294. Возвращает [DnsSettingsSnapshot].
  ///
  /// (Тело вынесено verbatim из `dns_settings_screen._load` — §300 D1.)
  static Future<DnsSettingsSnapshot> load() async {
    final template = await TemplateLoader.load();
    final vars = await SettingsStorage.getAllVars();

    // Parse dns_options from template (§279 — typed DnsOptionsModel; raw
    // остаётся только у machine-полей `rules`).
    final templateServersRaw = [
      for (final s in template.dnsOptionsModel.servers) s.wrapper,
    ];
    final templateRulesRaw =
        (template.dnsOptions['rules'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>()
            .toList();

    // §043: storage хранит kind-discriminated refs. §117: template-серверы —
    // обёртки `{description, enabled, vars?, server}`.
    final templateByTag = template.dnsOptionsModel.wrappersByTag;

    // §125: активные Направления для outbound-пикера vars (storage, не template).
    final directions = await SettingsStorage.getDirections();
    final outboundOptions = <OutboundOption>[
      const OutboundOption(value: 'direct-out', label: 'direct'),
      for (final c in directions)
        if (c.enabled || c.isRequired)
          OutboundOption(value: c.tag, label: c.displayLabel),
    ];

    // §033: build template rules map by name
    final templateRulesByName = <String, Map<String, dynamic>>{
      for (final r in templateRulesRaw)
        if (r['name'] is String && (r['name'] as String).isNotEmpty)
          r['name'] as String: r,
    };

    // §033/§121: build active preset rules maps by presetId + dns_servers.
    // §121 — routing-тоггл = король: выключенный пресет не порождает DNS.
    final presetRulesByPresetId = <String, List<Map<String, dynamic>>>{};
    final presetLabelByPresetId = <String, String>{};
    final presetDnsEnable = <String, bool>{}; // §257
    final presetServersWithLabel = <Map<String, dynamic>>[];
    final activeRules = await SettingsStorage.getCustomRules();
    final allPresets = template.selectableRules;
    final activePresetIdsWithDnsRule = <String>{};
    for (final cr in activeRules) {
      if (cr is! CustomRulePreset) continue;
      if (cr.presetId.isEmpty) continue;
      if (!cr.enabled) continue; // §121: routing off → пресет мёртв целиком
      SelectableRule? match;
      for (final p in allPresets) {
        if (p.presetId == cr.presetId) {
          match = p;
          break;
        }
      }
      if (match == null) continue;
      if (match.dnsRules.isNotEmpty) {
        activePresetIdsWithDnsRule.add(cr.presetId);
      }
      // §257: тумблер DNS-блока пресета — магическая var dns_enable.
      if (match.vars.any((v) => v.name == 'dns_enable')) {
        presetDnsEnable[cr.presetId] = presetDnsEnableVar(cr, match);
      }
      final fragments = expandPreset(cr, match);
      if (match.dnsRules.isNotEmpty) {
        presetRulesByPresetId[cr.presetId] = fragments.dnsRules;
      }
      presetLabelByPresetId[cr.presetId] = match.label;
      for (final s in fragments.dnsServers) {
        final annotated = Map<String, dynamic>.from(s)
          ..['_preset_label'] = match.label;
        presetServersWithLabel.add(annotated);
      }
    }

    // §033: resolve current rules list (auto-discover + orphan cleanup +
    // persist if changed).
    final resolvedRules = await resolveDnsRulesList(
      templateRules: templateRulesRaw,
      activePresetIdsWithDnsRule: activePresetIdsWithDnsRule,
    );

    // §043: resolve servers refs list.
    final presetServersByTag = <String, Map<String, dynamic>>{
      for (final s in presetServersWithLabel)
        if (s['tag'] is String && (s['tag'] as String).isNotEmpty)
          s['tag'] as String: s,
    };
    final resolvedServers = await resolveDnsServersList(
      templateServers: templateServersRaw,
      presetServersByTag: presetServersByTag,
    );

    // §117: реальные тела DNS-mirror'ов (rule-источники) для превью.
    final previewRules = [
      for (final cr in activeRules)
        if (cr.dnsMirrorEligible && !(cr.dns?.enabled ?? false))
          switch (cr) {
            CustomRuleInline() =>
              cr.copyWith(dns: cr.dns!.copyWith(enabled: true)),
            CustomRuleSrs() =>
              cr.copyWith(dns: cr.dns!.copyWith(enabled: true)),
            _ => cr,
          }
        else
          cr,
    ];
    final mirrorSrsPaths = <String, String>{
      for (final cr in previewRules)
        if (cr is CustomRuleSrs) cr.id: '<srs>',
    };
    final unifiedMirrors = applyAllCustomRules(
      RuleSetRegistry(),
      previewRules,
      allPresets,
      srsPaths: mirrorSrsPaths,
    );
    // §257: правило может нести ДВА mirror'а — группируем списком.
    final dnsMirrorsByRuleId = <String, List<DnsMirrorEntry>>{};
    for (final m in unifiedMirrors.dnsMirrors) {
      final id = m.ruleId;
      if (id == null || id.isEmpty) continue;
      (dnsMirrorsByRuleId[id] ??= []).add(m);
    }

    // §121: автосброс DNS Final / Default Resolver на template-дефолт, если
    // выбранный сервер исчез из каталога.
    final ruleRefsByTag = <String, String>{
      for (final cr in activeRules)
        if (cr.dnsMirrorActive)
          cr.dns!.serverTag: cr.name.isNotEmpty ? cr.name : 'rule',
    };
    final availableTags = enabledServerTags(resolveDisplayedServers(
        resolvedServers, templateByTag, presetServersByTag,
        ruleRefsByTag: ruleRefsByTag));
    // §327 — единственный источник дефолта для DNS-var'ов: `default_value`
    // шаблона. Раньше их было три (пусто на экране, `cloudflare_udp` в
    // автосбросе, `dns_shield` в шаблоне) — экран показывал «выберите» на
    // чистой установке, хотя билдер собирал конфиг с шаблонным дефолтом
    // (`build_config.dart` — `userVars[name] ?? defaultValue`).
    final templateDefaults = <String, String>{
      for (final v in template.vars) v.name: v.defaultValue,
    };
    String defaultOf(String name) => templateDefaults[name] ?? '';

    // Пустая строка (а не отсутствие ключа) — тоже «не задано»: `stage()`
    // пишет все три var разом, поэтому в storage мог осесть `''`.
    final storedFinal = vars['dns_final'] ?? '';
    final storedResolver = vars['dns_default_domain_resolver'] ?? '';
    var dnsFinal =
        storedFinal.isNotEmpty ? storedFinal : defaultOf('dns_final');
    var defaultResolver = storedResolver.isNotEmpty
        ? storedResolver
        : defaultOf('dns_default_domain_resolver');
    var resolverReset = false;
    if (dnsFinal.isNotEmpty && !availableTags.contains(dnsFinal)) {
      dnsFinal = defaultOf('dns_final');
      resolverReset = true;
    }
    if (defaultResolver.isNotEmpty &&
        !availableTags.contains(defaultResolver)) {
      defaultResolver = defaultOf('dns_default_domain_resolver');
      resolverReset = true;
    }

    return DnsSettingsSnapshot(
      servers: resolvedServers,
      templateByTag: templateByTag,
      presetServersByTag: presetServersByTag,
      rules: resolvedRules,
      templateRulesByName: templateRulesByName,
      presetRulesByPresetId: presetRulesByPresetId,
      presetLabelByPresetId: presetLabelByPresetId,
      presetDnsEnable: presetDnsEnable,
      outboundOptions: outboundOptions,
      customRules: activeRules,
      dnsMirrorsByRuleId: dnsMirrorsByRuleId,
      // §327 — fallback берётся из шаблона, не из литерала-копии.
      strategy: (vars['dns_strategy']?.isNotEmpty ?? false)
          ? vars['dns_strategy']!
          : defaultOf('dns_strategy'),
      dnsFinal: dnsFinal,
      defaultResolver: defaultResolver,
      resolverReset: resolverReset,
    );
  }

  /// §300 D3 — staged-запись DNS-секции (servers/rules/dns-vars). Byte-identical
  /// прежнему `stageChanges` (§221 round-trip). custom_rules НЕ входит — это
  /// §295 (device-required). Всегда `flush: false` — дисковый flush делает
  /// `LazyPersistMixin` экрана на dispose/paused.
  static Future<void> stage({
    required List<Map<String, dynamic>> servers,
    required List<Map<String, dynamic>> rules,
    required Map<String, Map<String, dynamic>> templateRulesByName,
    required Map<String, List<Map<String, dynamic>>> presetRulesByPresetId,
    required String strategy,
    required String dnsFinal,
    required String defaultResolver,
  }) async {
    await SettingsStorage.saveDnsServers(servers, flush: false);
    final cleaned = cleanDnsRulesForPersist(
      rules,
      templateRulesByName,
      presetRulesByPresetId,
    );
    await SettingsStorage.saveDnsRulesList(cleaned, flush: false);
    await SettingsStorage.setVar('dns_strategy', strategy, flush: false);
    await SettingsStorage.setVar('dns_final', dnsFinal, flush: false);
    await SettingsStorage.setVar(
        'dns_default_domain_resolver', defaultResolver,
        flush: false);
  }
}
