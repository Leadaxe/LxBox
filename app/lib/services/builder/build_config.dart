import 'dart:convert';

import '../../models/channel.dart';
import '../../models/ui_msg.dart';
import '../../models/custom_rule.dart';
import '../../models/emit_context.dart';
import '../../models/node_spec.dart' show Awg;
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
import 'normalize_pinned_presets.dart';
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

  /// §274 — display-имена каналов, у которых непустой node_filter отсёк все
  /// ноды (канал живёт на fallback-опциях: block-default, либо
  /// direct/block по include-галкам). UI показывает по ним транзиентный
  /// SnackBar; фактический исход — в тексте [emitWarnings]/AppLog.
  final List<String> channelsWithoutNodes;
  const BuildResult({
    required this.configJson,
    required this.config,
    required this.validation,
    required this.emitWarnings,
    required this.generatedVars,
    this.channelsWithoutNodes = const [],
  });
}

/// Настройки сборки — то что UI/контроллер прокидывает в `buildConfig`.
class BuildSettings {
  final Map<String, String> userVars;
  final Set<String> enabledGroups;
  final List<CustomRule> customRules;
  final String routeFinal;

  /// §125 — каналы роутинга (source-of-truth состава). Пусто = старое
  /// поведение через template.groupTemplates (для тестов без storage).
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

  /// §272: второе, длинное окно простоя для ДОСТИЖИМЫХ эндпоинтов
  /// (ядро SPEC 020 rev. 2026-07-15, `route.lx_idle_suspend_reachable`).
  /// Пусто = достижимые не засыпают. Эмитится ТОЛЬКО при непустом
  /// [idleSuspend] — ядро отвергает reachable без базового порога.
  final String idleSuspendReachable;

  /// §272: passive health check (ядро SPEC 019, `urltest.passive_check`) —
  /// пишется в urltest-двойники каналов. Пока свежий успешный TCP-дайл
  /// подтверждает узел, периодические пробы группы пропускаются.
  /// ⚠ Требует ядра >= ревизии 2026-07-15 (незнакомое поле роняет конфиг).
  final bool passiveCheck;

  const BuildSettings({
    this.userVars = const {},
    this.enabledGroups = const {},
    this.customRules = const [],
    this.routeFinal = '',
    this.channels = const [],
    this.tunApps,
    this.vpnMode,
    this.idleSuspend = '',
    this.idleSuspendReachable = '',
    this.passiveCheck = false,
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
        final line = '${node.tag}: ${w.renderEn()}';
        if (!emitWarnings.contains(line)) emitWarnings.add(line);
      }
    }
  }

  final selectorTags =
      ctx.selectorEntries.map((e) => e.tag).toList(growable: false);

  // §125 — каналы из storage (source-of-truth). Если пусто (тесты без storage /
  // первый билд до миграции) — синтезируем из template.groupTemplates через ту
  // же seed-логику, что и one-shot миграция, чтобы билдер всегда работал с
  // List<Channel> единообразно. autoTags больше не нужен: каждый канал делает
  // свой urltest-двойник по своему node-set.
  final channels = settings.channels.isNotEmpty
      ? settings.channels
      : _channelsFromTemplate(
          template.groupTemplates, settings.enabledGroups, resolve);

  // §248/§254 — эмитированные узлы (те же map-объекты уходят в config ниже):
  // AWG-advisory читает типы. detour больше НЕ правится in-place (§254 —
  // детекция циклов переехала в validateConfig, конфиг не мутируется).
  // Endpoints тоже — WG/AWG живут там.
  final nodeEntries = <Map<String, dynamic>>[
    for (final e in ctx.outbounds) e.map,
    for (final e in ctx.endpoints) e.map,
  ];

  final channelsWithoutNodes = <String>[]; // §274 — для SnackBar на Home
  final presetOutbounds = _buildChannelGroups(
    channels: channels,
    selectorTags: selectorTags,
    nodeEntries: nodeEntries,
    emitWarnings: emitWarnings,
    channelsWithoutNodes: channelsWithoutNodes,
    passiveCheck: settings.passiveCheck, // §272
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

  // §264 — нормализация pinned-пресетов: гарантирует, что locked+pinned
  // пресет (traffic-processing) присутствует и стоит первым, независимо от
  // storage (fresh/restore/upgrade). Критично для порядка route.rules (sniff
  // первым). Одноразово здесь → все нижеследующие проходы видят нормализованный
  // список.
  final customRules = normalizePinnedPresets(
    settings.customRules,
    template.selectableRules,
    template,
  );

  // Pre-resolve srs local paths (sing-box получает file:// — rule set
  // `{type: local, path: …}`). Удалённо ничего не качается.
  final srsPaths = <String, String>{};
  for (final cr in customRules) {
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
  for (final cr in customRules) {
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

  // §257: DNS-аспект пресета теперь гейтится магической var `dns_enable`
  // (внутри _applyPresetSingle) — прежний isPresetDnsEnabled из
  // dns_options.rules[kind:preset].enabled удалён (два тумблера на один
  // флаг = источник багов «поставил, а не сработало»). Запись kind:preset
  // остаётся только позиционным якорем mirror-группы (§117); её `enabled` —
  // мёртвое поле. Storage всё ещё читаем — для kind:srs cached-paths ниже.
  final dnsRulesStorage = await SettingsStorage.getDnsRulesList();

  // §033: presetIds with custom_rules.kind:preset entry AND dns_rules defined
  // in template — для auto-discovery `kind:preset` записей в dns_options.rules.
  // §121: routing-тоггл = король — выключенный пресет (cr.enabled=false) не
  // считается active'ным для DNS-правил, поэтому его kind:preset запись в
  // dns_options.rules orphan-чистится (симметрия с серверами).
  final activePresetIdsWithDnsRule = <String>{
    for (final cr in customRules)
      if (cr is CustomRulePreset && cr.enabled && cr.presetId.isNotEmpty)
        if (template.selectableRules
            .any((p) => p.presetId == cr.presetId && p.dnsRules.isNotEmpty))
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
    customRules,
    template.selectableRules,
    srsPaths: srsPaths,
    presetSrsPaths: presetSrsPaths,
    globalVars: vars, // §265 — ref-vars резолвятся из flat global vars
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
    // §272 — reachable-окно валидно ТОЛЬКО при включённом базовом пороге
    // (ядро: "lx_idle_suspend_reachable requires lx_idle_suspend").
    final reachable = settings.idleSuspendReachable.trim();
    if (reachable.isNotEmpty) {
      route['lx_idle_suspend_reachable'] = reachable;
    }
  }

  // §125 — деградация dangling route_final → vpn-1. Ссылка на удалённый канал
  // или legacy ✨auto (которого больше нет, Решение 2/3) схлопывается в vpn-1
  // (неудаляем → всегда валидная мишень).
  // §219 — валидные мишени берём из ФАКТИЧЕСКИ эмитированных `presetOutbounds`
  // (теги селекторов + auto-двойники), а не переугадываем `[tag, autoTag]`:
  // auto-двойник `<tag>-auto` эмитится лишь при `auto != null && nodes.isNotEmpty`
  // (см. `_buildChannelGroups`), поэтому статичный `autoTag` для канала с пустым
  // node-set давал бы висячую ссылку в конфиге (fatal в sing-box).
  // §274 — detour-каналы валидные rules-мишени (вычитание detourChannelTags
  // из validFinals снято вместе с взаимоисключением ролей §248).
  if (settings.routeFinal.isNotEmpty) {
    final validFinals = <String>{
      kDirectOutboundTag,
      kBlockOutboundTag, // §201 — block системный outbound, валидная route_final-мишень
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

  // §247 — деградация битых `server`-ссылок у resolve-правил (симметрично
  // detour-heal выше): ядро валит каждое сматчившееся соединение лениво
  // («DNS server not found»), а не на старте — validator этого не видит.
  // Снятый server → резолв через обычный DNS-роутинг.
  final healedResolve = healDanglingResolveServers(config);
  for (final h in healedResolve) {
    emitWarnings.add(
        'Resolve server removed: route rule #${h.ruleIndex} referenced '
        'missing DNS server "${h.target}" — falling back to DNS routing.');
  }

  // §246 hotfix — легаси `strategy` в dns.rules × query_type/ip_version
  // (FakeIP §228, Force IPv4 §253) = fatal у ядра 1.14 на старте. Снимаем
  // strategy, если несовместимая пара присутствует (деградация вместо
  // мёртвого VPN).
  final healedDnsStrategy = healLegacyDnsStrategy(config);
  if (healedDnsStrategy.isNotEmpty) {
    emitWarnings.add(
        'DNS rule strategy removed on rules ${healedDnsStrategy.join(", ")}: '
        'incompatible with query_type/ip_version DNS rules (e.g. FakeIP or '
        'Force IPv4) — kernel would reject the config. Resolution falls back '
        'to the global DNS strategy.');
  }

  // §281 — неизвестный uTLS fingerprint = fatal у ядра при создании outbound
  // («unknown uTLS fingerprint») — конфиг не встаёт целиком. Парсер уже
  // канонизирует на входе (xray-псевдонимы hellochrome_* → chrome, мусор →
  // chrome); этот post-step — страховка для путей мимо парсера.
  final healedFingerprints = healUnknownUtlsFingerprints(config);
  for (final h in healedFingerprints) {
    emitWarnings.add(
        'Fingerprint replaced: outbound "${h.owner}" had unknown uTLS '
        'fingerprint "${h.original}" — using "chrome" instead.');
  }

  final validation = validateConfig(config);
  return BuildResult(
    configJson: jsonEncode(config),
    config: config,
    validation: validation,
    emitWarnings: emitWarnings,
    generatedVars: generatedVars,
    channelsWithoutNodes: channelsWithoutNodes,
  );
}

/// Реализация `EmitContext`: vars + аллокатор уникальных тегов +
/// аккумуляторы entries + RuleSetRegistry.
class _BuildCtx implements EmitContext {
  _BuildCtx(this._vars, this._ruleSets);
  final TemplateVars _vars;
  final RuleSetRegistry _ruleSets;
  final _taken = <String>{kDirectOutboundTag, 'dns-out', 'block-out'};

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
  required List<Map<String, dynamic>> nodeEntries,
  required List<String> emitWarnings,
  required List<String> channelsWithoutNodes, // §274 — display-имена, out-параметр
  bool passiveCheck = false, // §272 — urltest.passive_check в auto-двойники
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

  // §248 — member-set'ы считаем один раз: их делят selector и auto-двойник.
  // §254 — детур-циклы билдер больше НЕ рвёт: детекция и минимальный набор
  // виновников — в validateConfig (fatal, конфиг не собирается); здесь
  // структуры графа нужны только AWG-advisory ниже.
  final memberSets = [for (final c in active) nodesFor(c)];
  final entryByTag = <String, Map<String, dynamic>>{
    for (final m in nodeEntries)
      if (m['tag'] is String) m['tag'] as String: m,
  };
  final channelByAlias = <String, int>{
    for (var i = 0; i < active.length; i++) ...{
      active[i].tag: i,
      active[i].autoTag: i,
    },
  };

  _warnAwgDetourViaWgChannels(
    active: active,
    memberSets: memberSets,
    nodeEntries: nodeEntries,
    entryByTag: entryByTag,
    channelByAlias: channelByAlias,
    emitWarnings: emitWarnings,
  );

  final result = <Map<String, dynamic>>[];
  for (var i = 0; i < active.length; i++) {
    final c = active[i];
    final nodes = memberSets[i];
    final emitAuto = c.auto != null && nodes.isNotEmpty;

    // selector outbounds: ноды + (direct?) + (block?) + (<tag>-auto если эмит)
    final selectorOutbounds = <String>[
      ...nodes,
      if (c.includeDirect) kDirectOutboundTag,
      if (c.includeBlock) kBlockOutboundTag, // §274 — совместим с detour
      if (emitAuto) c.autoTag,
    ];
    // §201/§274 — пустой набор (regex не матчит / нет нод) → fallback на
    // [block, direct-out] с default=block для ВСЕХ каналов (безопаснее
    // блокировать, чем выпускать мимо VPN; direct остаётся доступной
    // опцией). Detour-исключение §248 Q1 ([direct], «нет хопа») снято:
    // detour-канал может одновременно быть целью правил, и direct-fallback
    // молча выпускал бы rule-трафик мимо VPN. selector не должен быть
    // пустой группой (fatal в sing-box).
    final emptyFallback = selectorOutbounds.isEmpty;
    if (emptyFallback) {
      selectorOutbounds.addAll([kBlockOutboundTag, kDirectOutboundTag]);
    }
    // §200/§274 — предупреждаем, если ИМЕННО фильтр канала отсёк все ноды
    // (фильтр непустой, но 0 совпадений): в AppLog текстом, в UI
    // транзиентным SnackBar (channelsWithoutNodes). Текст отражает
    // ФАКТИЧЕСКИЙ исход: при emptyFallback ядро берёт default=block, иначе
    // (include_direct/include_block без нод) — ПЕРВУЮ опцию списка, и при
    // include_direct это direct-out (юзер сам включил опцию — трафик идёт
    // мимо VPN, врать «blocked» нельзя). Пустой фильтр с 0 нод (нет
    // подписки) НЕ варним — это не вина фильтра.
    if (nodes.isEmpty && c.nodeFilter.isNotEmpty && selectorTags.isNotEmpty) {
      final effective =
          emptyFallback ? kBlockOutboundTag : selectorOutbounds.first;
      emitWarnings.add(
          'Channel "${c.displayLabel}" (${c.tag}): node filter matched no '
          'nodes — ${effective == kDirectOutboundTag ? 'traffic goes direct (no VPN hop)' : 'traffic is blocked (default)'}. '
          'Check its node filter.');
      channelsWithoutNodes.add(c.displayLabel);
    }

    final selector = <String, dynamic>{
      'tag': c.tag,
      'type': 'selector',
      'outbounds': selectorOutbounds,
      'interrupt_exist_connections': c.interruptExistConnections,
    };
    // §201/§274 — fallback пустого канала: block для всех.
    if (emptyFallback) {
      selector['default'] = kBlockOutboundTag;
    }
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
      // §272 — passive health check (ядро SPEC 019): пока свежий успешный
      // TCP-дайл подтверждает узел, периодические пробы пропускаются —
      // активная группа не будит спящие узлы. Эмитим только при true
      // (omitempty-семантика: отсутствие = false = апстрим-поведение).
      if (passiveCheck) {
        urltest['passive_check'] = true;
      }
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

/// §248 — advisory: узел AmneziaWG детурится через канал, в node-set
/// которого есть wireguard-эндпоинты. Прямую ссылку AWG→WG прячет §130-гейт
/// пикера; канальная секция его осознанно обходит (состав канала не
/// ограничен) — предупреждаем, не запрещаем (AWG через WireGuard вешает
/// ядро на Android).
void _warnAwgDetourViaWgChannels({
  required List<Channel> active,
  required List<List<String>> memberSets,
  required List<Map<String, dynamic>> nodeEntries,
  required Map<String, Map<String, dynamic>> entryByTag,
  required Map<String, int> channelByAlias,
  required List<String> emitWarnings,
}) {
  bool isWg(Map<String, dynamic> m) => m['type'] == 'wireguard';
  // §097 — AWG = wireguard-endpoint с obfuscation-полями в корне (writeInto).
  bool isAwg(Map<String, dynamic> m) =>
      isWg(m) &&
      (Awg.numKeys.any(m.containsKey) || Awg.strKeys.any(m.containsKey));

  final channelHasWg = <int, bool>{};
  for (final m in nodeEntries) {
    final d = m['detour'];
    if (d is! String || d.isEmpty) continue;
    final ci = channelByAlias[d];
    if (ci == null || !isAwg(m)) continue;
    final hasWg = channelHasWg[ci] ??= memberSets[ci].any((t) {
      final e = entryByTag[t];
      return e != null && isWg(e);
    });
    if (hasWg) {
      final c = active[ci];
      final label = c.label.isNotEmpty ? c.label : c.tag;
      emitWarnings.add('Node "${m['tag']}" (AmneziaWG) detours via channel '
          '"$label" which contains WireGuard node(s) — this can hang the '
          'tunnel on Android.');
    }
  }
}

/// §125 fallback — синтез `List<Channel>` из `template.groupTemplates`, когда
/// storage ещё пуст (тесты без storage / первый билд до миграции). Та же
/// seed-логика, что и one-shot миграция `_migrateChannelsIfNeeded`, но auto-
/// параметры резолвятся через [resolve] (@urltest_* vars). §267 — итерируем
/// `default_channels`, auto-подгруппа при `channel.include ∋ auto`.
List<Channel> _channelsFromTemplate(
  GroupTemplates gt,
  Set<String> enabledGroupTags,
  VarResolver resolve,
) {
  String s(String name, String fallback) {
    final v = resolve(name);
    return v == null ? fallback : v.toString();
  }

  ChannelAuto seedAuto() => ChannelAuto(
        url: s('urltest_url', 'https://cp.cloudflare.com/generate_204'),
        interval: s('urltest_interval', '15m'), // §272 — батарея: см. channel.dart
        tolerance: int.tryParse(s('urltest_tolerance', '50')) ?? 50,
        idleTimeout: '30m',
        interruptExistConnections: false,
      );

  final hasAuto = gt.channel.include.contains('auto');
  final out = <Channel>[];
  for (final dc in gt.defaultChannels) {
    final enabled = dc.tag == 'vpn-1'
        ? true
        : (enabledGroupTags.isEmpty
            ? dc.defaultEnabled
            : enabledGroupTags.contains(dc.tag));
    final auto = hasAuto ? seedAuto() : null;
    out.add(
        Channel.seedFromDefault(dc, gt.channel, enabled: enabled, auto: auto));
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
