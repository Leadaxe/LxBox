import 'dart:convert';

import '../../models/channel.dart';
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
  final List<CustomRule> customRules;
  final String routeFinal;

  /// §125 — каналы роутинга (source-of-truth состава). Пусто = старое
  /// поведение через template.presetGroups (для тестов без storage).
  final List<Channel> channels;

  /// §046: OS-level split-tunneling apps list. `null` = pipeline возьмёт
  /// дефолт (mode=off — все apps через tun, sing-box обычное поведение).
  final TunAppsConfig? tunApps;

  /// §119: VPN-mode (proxy/vpn/vpn_proxy). `null` = mode=vpn (текущее
  /// поведение, post-step no-op).
  final VpnModeConfig? vpnMode;

  /// §215: порог простоя для idle-suspend недостижимых WG/AWG эндпоинтов
  /// (ядро SPEC 020, `route.lx_idle_suspend`). Duration-строка (`"5m"`,
  /// `"30s"`). Пусто = фича выключена (поле не пишется, дефолт ядра =
  /// idle-тик не запускается).
  final String idleSuspend;

  const BuildSettings({
    this.userVars = const {},
    this.enabledGroups = const {},
    this.customRules = const [],
    this.routeFinal = '',
    this.channels = const [],
    this.tunApps,
    this.vpnMode,
    this.idleSuspend = '',
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

  // §122 Фаза 1b — clash_api БОЛЬШЕ НЕ инжектится: ядро rc.3 собрано без
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

  // §125 — каналы из storage (source-of-truth). Если пусто (тесты без storage /
  // первый билд до миграции) — синтезируем из template.presetGroups через ту же
  // seed-логику, что и one-shot миграция, чтобы билдер всегда работал с
  // List<Channel> единообразно. autoTags больше не нужен: каждый канал делает
  // свой urltest-двойник по своему node-set.
  final channels = settings.channels.isNotEmpty
      ? settings.channels
      : _channelsFromTemplate(
          template.presetGroups, settings.enabledGroups, resolve);

  final presetOutbounds = _buildChannelGroups(
    channels: channels,
    selectorTags: selectorTags,
    emitWarnings: emitWarnings,
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

  // §215 — idle-suspend недостижимых WG/AWG эндпоинтов (ядро SPEC 020).
  // Пишем поле только когда порог задан (непустой), чтобы сохранить
  // omitempty-семантику ядра: отсутствие/пусто = фича выключена (idle-тик
  // не запускается — безопасный kill-switch).
  final idle = settings.idleSuspend.trim();
  if (idle.isNotEmpty) {
    route['lx_idle_suspend'] = idle;
  }

  // §125 — деградация dangling route_final → vpn-1. Ссылка на удалённый канал
  // или legacy ✨auto (которого больше нет, Решение 2/3) схлопывается в vpn-1
  // (неудаляем → всегда валидная мишень).
  // §219 — валидные мишени берём из ФАКТИЧЕСКИ эмитированных `presetOutbounds`
  // (теги селекторов + auto-двойники), а не переугадываем `[tag, autoTag]`:
  // auto-двойник `<tag>-auto` эмитится лишь при `auto != null && nodes.isNotEmpty`
  // (см. `_buildChannelGroups`), поэтому статичный `autoTag` для канала с пустым
  // node-set давал бы висячую ссылку в конфиге (fatal в sing-box).
  if (settings.routeFinal.isNotEmpty) {
    final validFinals = <String>{
      'direct-out',
      'block', // §201 — block системный outbound, валидная route_final-мишень
      for (final o in presetOutbounds)
        if (o['tag'] is String) o['tag'] as String,
    };
    var finalTag = settings.routeFinal;
    if (!validFinals.contains(finalTag)) {
      emitWarnings.add(
          'Route final "$finalTag" no longer exists — switched to vpn-1.');
      finalTag = 'vpn-1';
    }
    route['final'] = finalTag;
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

  // §172 — деградация битых detour-ссылок ПЕРЕД валидацией: detour на
  // несуществующий outbound (напр. отключённый WARP-target из подписки) →
  // снимаем поле, нода работает напрямую, а не роняет весь конфиг (как §169
  // с REALITY). Снятые detour'ы добавляем в emitWarnings (видно юзеру).
  final healedDetours = healDanglingDetours(config);
  for (final h in healedDetours) {
    emitWarnings.add(
        'Detour removed: outbound "${h.owner}" referenced missing '
        '"${h.target}" — node works directly.');
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

/// Собирает channel-группы (vpn-1..vpn-10 + их auto-двойники). Приватный
/// helper `buildConfig` — специфичен для одного вызова, выделение в
/// отдельный файл/модуль не даёт пользы (YAGNI, решение §Принципы #4).
/// §125 — собирает outbound-группы из пользовательских [channels] (storage).
/// Каждый **включённый** канал эмитит selector `<tag>`; если у канала есть
/// `auto` И его node-set непуст — дополнительно urltest-двойник `<tag>-auto`.
///
/// Per-channel node-set: `selectorTags`, отфильтрованные `channel.nodeFilter`
/// (regex по **итоговому tag** ноды, §048-style — что видно в имени, то и
/// матчится). Пустой/невалидный фильтр → все ноды. Это снимает прежнее
/// допущение «все selector делят один набор нод».
List<Map<String, dynamic>> _buildChannelGroups({
  required List<Channel> channels,
  required List<String> selectorTags,
  required List<String> emitWarnings,
}) {
  // §125 — единственный слой фильтрации нод теперь per-channel regex
  // (node_filter). Глобальный excluded_nodes (§048) удалён.
  final baseNodes = selectorTags;

  final active = channels.where((c) => c.enabled || c.isRequired).toList();

  /// Ноды канала после regex-фильтра. Пустой/битый regex → все baseNodes.
  /// §197 — nodeFilterInvert инвертирует смысл: true → ноды, чей tag НЕ матчит.
  List<String> nodesFor(Channel c) {
    if (c.nodeFilter.isEmpty) return baseNodes;
    final re = _tryCompileRegex(c.nodeFilter);
    if (re == null) return baseNodes;
    return baseNodes
        .where((t) => re.hasMatch(t) != c.nodeFilterInvert)
        .toList();
  }

  final result = <Map<String, dynamic>>[];
  for (final c in active) {
    final nodes = nodesFor(c);
    final emitAuto = c.auto != null && nodes.isNotEmpty;

    // selector outbounds: ноды + (direct?) + (block?) + (<tag>-auto если эмит)
    final selectorOutbounds = <String>[
      ...nodes,
      if (c.includeDirect) 'direct-out',
      if (c.includeBlock) 'block',
      if (emitAuto) c.autoTag,
    ];
    // §201 — пустой набор (regex не матчит / нет нод) → fallback на [block,
    // direct-out] с default=block (безопаснее блокировать, чем выпускать мимо
    // VPN; direct остаётся доступной опцией). selector не должен быть пустой
    // группой (fatal в sing-box).
    final emptyFallback = selectorOutbounds.isEmpty;
    if (emptyFallback) {
      selectorOutbounds.addAll(['block', 'direct-out']);
    }
    // §200 — предупреждаем, если ИМЕННО фильтр канала отсёк все ноды (фильтр
    // непустой, но 0 совпадений). Канал свалился на block — юзеру важно знать.
    // Пустой фильтр с 0 нод (нет подписки) НЕ варним — это не вина фильтра.
    if (nodes.isEmpty && c.nodeFilter.isNotEmpty && selectorTags.isNotEmpty) {
      final label = c.label.isNotEmpty ? c.label : c.tag;
      emitWarnings.add(
          'Channel "$label" (${c.tag}): node filter matched no nodes — '
          'traffic is blocked (default), or use direct.');
    }

    final selector = <String, dynamic>{
      'tag': c.tag,
      'type': 'selector',
      'outbounds': selectorOutbounds,
      'interrupt_exist_connections': c.interruptExistConnections,
    };
    // §201 — fallback пустого канала: block выбран дефолтом.
    if (emptyFallback) selector['default'] = 'block';
    // §141 — default = первая нода канала, чей итоговый tag матчит defaultFilter.
    // Не матчит/пусто → default не выставляется (sing-box берёт первую опцию).
    if (c.defaultFilter.isNotEmpty) {
      final re = _tryCompileRegex(c.defaultFilter);
      final def = re == null ? null : _firstMatch(nodes, re);
      // Гейт-защита (§141 P1.8b): default обязан быть валидным членом outbounds.
      if (def != null && selectorOutbounds.contains(def)) {
        selector['default'] = def;
      }
    }
    result.add(selector);

    // urltest-двойник: ТОЛЬКО ноды канала (без direct/auto). Не эмитим при
    // пустом наборе (urltest без нод недопустим).
    if (emitAuto) {
      final a = c.auto!;
      final urltest = <String, dynamic>{
        'tag': c.autoTag,
        'type': 'urltest',
        'outbounds': nodes,
        'url': a.url,
        'interval': a.interval,
        'tolerance': a.tolerance,
        'idle_timeout': a.idleTimeout,
        'interrupt_exist_connections': a.interruptExistConnections,
      };
      // §208 — round_robin: дописываем `mode` + `balancer{}` (ядро SPEC 019).
      // least_test → НИЧЕГО не пишем (бит-в-бит апстрим, нулевой diff). `balancer`
      // без round_robin роняет старт ядра, поэтому только под round_robin.
      //
      // sticky_hash (контракт ядра rc.15): пустой набор НЕ выключает липкость —
      // ядро ре-маршалит конфиг (badjson) и схлопывает `[]`→nil, неотличимо от
      // «поле опущено» → дефолт ["process","domain"]. Чтобы ВЫКЛЮЧИТЬ липкость,
      // нужен sentinel ["none"]. Поэтому: пусто (юзер снял все чипы) → ["none"];
      // непусто → компоненты.
      if (a.mode == UrltestMode.roundRobin) {
        urltest['mode'] = a.mode.wire;
        final sticky = a.stickyHash.isEmpty
            ? const ['none'] // sentinel: липкость выключена (чистая ротация)
            : a.stickyHash.map((k) => k.wire).toList();
        urltest['balancer'] = <String, dynamic>{
          'pool': a.pool,
          'pool_tolerance': a.poolTolerance,
          'sticky_hash': sticky,
        };
      }
      result.add(urltest);
    }
  }
  return result;
}

/// §125 fallback — синтез `List<Channel>` из `template.presetGroups`, когда
/// storage ещё пуст (тесты без storage / первый билд до миграции). Та же
/// seed-логика, что и one-shot миграция `_migrateChannelsIfNeeded`, но auto-
/// параметры резолвятся через [resolve] (@urltest_* vars). ✨auto-preset не
/// канал — пропускается.
List<Channel> _channelsFromTemplate(
  List<PresetGroup> presets,
  Set<String> enabledGroupTags,
  VarResolver resolve,
) {
  String s(String name, String fallback) {
    final v = resolve(name);
    return v == null ? fallback : v.toString();
  }

  ChannelAuto seedAuto() => ChannelAuto(
        url: s('urltest_url', 'https://cp.cloudflare.com/generate_204'),
        interval: s('urltest_interval', '5m'),
        tolerance: int.tryParse(s('urltest_tolerance', '50')) ?? 50,
        idleTimeout: '30m',
        interruptExistConnections: false,
      );

  final out = <Channel>[];
  for (final p in presets) {
    if (p.tag == kAutoOutboundTag) continue;
    final enabled = p.tag == 'vpn-1'
        ? true
        : (enabledGroupTags.isEmpty
            ? p.defaultEnabled
            : enabledGroupTags.contains(p.tag));
    final auto = p.addOutbounds.contains(kAutoOutboundTag) ? seedAuto() : null;
    out.add(Channel.seedFromPreset(p, enabled: enabled, auto: auto));
  }
  return out;
}

/// Компилирует regex, `null` при невалидном паттерне (caller → fallback на все
/// ноды). Общий helper для билдера и live-превью редактора (§125 F4).
RegExp? _tryCompileRegex(String pattern) {
  try {
    return RegExp(pattern);
  } catch (_) {
    return null;
  }
}

/// Первая нода (по порядку) из [tags], чей итоговый tag матчит [re]. `null` если
/// нет совпадений.
String? _firstMatch(List<String> tags, RegExp re) {
  for (final t in tags) {
    if (re.hasMatch(t)) return t;
  }
  return null;
}

// §122 Фаза 1b — `_ensureClashApiDefaults` удалён: clash_api больше не инжектится
// (ядро rc.3 без with_clash_api → блок даёт фатальный отказ старта). Управление
// через CommandClient (§122). Рандомизация порта/secret больше не нужна.

/// §120 — typed substitution + `#if`. Тонкая обёртка над общим [walk]-движком
/// ([if_engine.dart]). `obj` мутируется на месте. Coerce — по `node.type`
/// (через [resolve]), `#if` — резолвится здесь же (substitution-фаза, до
/// post-steps). §219 — переписанная версия: заменяет ЛОГИКУ прежних
/// `_substituteVars`/`_resolveVar` (гадали тип по содержимому строки) на
/// типизированный walk-движок.
void _substituteVars(dynamic obj, VarResolver resolve) {
  walk(obj, resolve);
}
