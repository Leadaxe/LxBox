import 'dart:convert';

import '../../models/direction.dart';
import '../../models/custom_rule.dart';
import '../../models/emit_context.dart';
import '../../models/parser_config.dart';
import '../../models/server_list.dart';
import '../../models/source_chain.dart';
import '../../models/singbox_entry.dart';
import '../../models/template_vars.dart';
import '../../config/consts.dart';
import '../../models/validation.dart';
import '../json_clone.dart';
import '../node_hash.dart';
import '../safe_regex.dart';
import '../rule_set_downloader.dart';
import '../settings_storage.dart';
import '../template_loader.dart';
import 'chain_nodes.dart';
import 'if_engine.dart';
import 'rule_order.dart';
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

  /// §274 — display-имена Направлений, у которых непустой node_filter отсёк все
  /// ноды (Направление живёт на fallback-опциях: block-default, либо
  /// direct/block по include-галкам). UI показывает по ним транзиентный
  /// SnackBar; фактический исход — в тексте [emitWarnings]/AppLog.
  final List<String> directionsWithoutNodes;
  const BuildResult({
    required this.configJson,
    required this.config,
    required this.validation,
    required this.emitWarnings,
    required this.generatedVars,
    this.directionsWithoutNodes = const [],
  });
}

/// Настройки сборки — то что UI/контроллер прокидывает в `buildConfig`.
class BuildSettings {
  final Map<String, String> userVars;
  final Set<String> enabledGroups;
  final List<CustomRule> customRules;
  final String routeFinal;

  /// §125 — Направления роутинга (source-of-truth состава). Пусто = старое
  /// поведение через template.groupTemplates (для тестов без storage).
  final List<Direction> directions;

  /// §393 C2/C3 — источники-цепочки хопов (SPEC 110), в порядке объявления.
  /// Порядок нормативен: позиция вправе сослаться только на цепочку,
  /// объявленную ВЫШЕ, — этим исключены циклы между цепочками.
  final List<SourceChain> chains;

  /// §393 C5 — версия установленного ядра (`Libbox.version()`), например
  /// `"1.14.0-lx.27-rc.6"`. Гейт возможностей живёт в СБОРКЕ, а не в UI:
  /// ядро без `with_lx_chain` отвергает конфиг ЦЕЛИКОМ на неизвестном типе
  /// outbound'а, и одна цепочка оставила бы пользователя вообще без VPN.
  ///
  /// Пусто = ядро не ответило → fail-open, цепочки эмитятся (деградировать
  /// на догадке значило бы отнять рабочий маршрут; подробности —
  /// `core_chain_capability.dart`).
  final String coreVersion;

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
  /// пишется в urltest-двойники Направлений. Пока свежий успешный TCP-дайл
  /// подтверждает узел, периодические пробы группы пропускаются.
  /// ⚠ Требует ядра >= ревизии 2026-07-15 (незнакомое поле роняет конфиг).
  final bool passiveCheck;

  const BuildSettings({
    this.userVars = const {},
    this.enabledGroups = const {},
    this.customRules = const [],
    this.routeFinal = '',
    this.directions = const [],
    this.chains = const [],
    this.coreVersion = '',
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

  // §125 — Направления из storage (source-of-truth). Если пусто (тесты без storage /
  // первый билд до миграции) — синтезируем из template.groupTemplates через ту
  // же seed-логику, что и one-shot миграция, чтобы билдер всегда работал с
  // List<Direction> единообразно. autoTags больше не нужен: каждое Направление делает
  // свой urltest-двойник по своему node-set. Резолвится ДО эмита узлов:
  // теги Направлений резервируются в аллокаторе (§351).
  final directions = settings.directions.isNotEmpty
      ? settings.directions
      : _directionsFromTemplate(
          template.groupTemplates, settings.enabledGroups, resolve);

  // buildConfig — тонкий оркестратор. ServerList.build(ctx) сам решает
  // политику, аллоцирует теги через ctx, регистрирует в selector/auto.
  //
  // §351 — теги Направлений (селектор + auto-двойник) резервируются заранее:
  // _buildDirectionGroups эмитит их с фиксированным `c.tag` МИМО allocateTag,
  // и узел подписки с меткой `vpn-1` дал бы дубль тега → отказ ядра на
  // старте. С резервом такой узел получает суффикс `-N` штатным путём.
  // autoTag резервируем всегда, хотя эмитится он условно: пере-резерв лишь
  // добавит суффикс узлу-тёзке, а обратная ошибка стоила бы старта.
  //
  // §393 A3 — резерв идёт по ВСЕМ Направлениям, а не по активным
  // (`enabled || required`). Зеркалить фильтр `_buildDirectionGroups` было
  // ошибкой: тег ВЫКЛЮЧЕННОГО Направления не резервировался, узел подписки
  // с таким же именем занимал literal-тег, и `include`-ссылка на выключенное
  // Направление резолвилась НЕ в дроп с warning'ом (её цели в конфиге нет),
  // а В УЗЕЛ-ТЁЗКУ — который к тому же уже лежал в составе от `nodesFor`.
  // Пользователь получал «vpn-2» опцией, ведущей в чужой сервер. Резерв
  // выключенного тега стоит ровно суффикс узлу-тёзке; ошибка стоила
  // молчаливой подмены маршрута.
  final ctx = _BuildCtx(
    tvars,
    ruleSets,
    passiveCheck: settings.passiveCheck, // §322
    reservedTags: [
      for (final c in directions) ...[c.tag, c.autoTag],
    ],
  );
  for (final list in lists) {
    list.build(ctx);
  }

  // Warnings собираем отдельно прямым обходом (ctx их не знает).
  final emitWarnings = <String>[];
  for (final list in lists) {
    if (!list.enabled) continue;
    // §283 — зеркало фильтра ServerListBuild.build: выключенная нода не
    // эмитится → её warnings не сыпем (цикл идёт по list.nodes мимо build).
    final disabledHashes = switch (list) {
      final SubscriptionServers s when s.disabledHashes.isNotEmpty =>
        s.disabledHashes,
      _ => null,
    };
    // §400 — та же карта идентичностей от полного списка, что и в билдере:
    // иначе фильтры warnings и эмиссии разошлись бы на узлах-тёзках.
    final identities =
        disabledHashes == null ? null : sourceNodeIdentities(list.nodes);
    for (final node in list.nodes) {
      final identity = identities?[node];
      if (identity != null && disabledHashes!.containsKey(identity)) {
        continue;
      }
      for (final w in node.warnings) {
        final line = '${node.tag}: ${w.renderEn()}';
        if (!emitWarnings.contains(line)) emitWarnings.add(line);
      }
    }
  }

  // §393 C3 — цепочки становятся узлами ПОСЛЕ материализации ВСЕХ источников
  // и ДО сборки Направлений: их теги окончательны только теперь (подписка
  // переименовывает узлы префиксом и уникализирует дубли), а Направление
  // отбирает цепочку фильтром наравне с обычным узлом.
  //
  // Что считается известным тегом для позиции: КАЖДЫЙ эмитированный узел
  // (включая detour-серверы, которых нет в пуле отбора, — позицией они
  // законны), служебные outbound'ы шаблона (`direct-out`/`block` — форма
  // предлагает их первым хопом «без прокси») и теги ВСЕХ Направлений,
  // включая выключенные: их теги зарезервированы аллокатором (§351), и
  // ссылка на них не может уехать в узел-тёзку. Выключенное Направление в
  // конфиг не попадает — такую позицию поймает граф-санитайзер (§393 A4,
  // правило 3) и дропнет цепочку целиком уже по факту.
  final knownChainTargets = <String>{
    for (final e in ctx.outbounds) e.tag,
    for (final e in ctx.endpoints) e.tag,
    for (final raw in (config['outbounds'] as List<dynamic>? ?? const []))
      if (raw is Map && raw['tag'] is String) raw['tag'] as String,
    for (final c in directions) c.tag,
  };
  final chainResolution = resolveChains(
    settings.chains,
    knownTags: knownChainTargets,
    coreVersion: settings.coreVersion,
  );
  for (final d in chainResolution.degraded) {
    emitWarnings.add(d.reason);
  }

  // §393 C3 — цепочка идёт в пул отбора Направлений последней, ПОСЛЕ узлов
  // подписок: порядок пула = порядок конфига, а цепочки эмитятся после всех
  // источников (корпус `chain_is_a_node_in_directions` нормирует именно
  // `[…узлы, hop-chain]`).
  final selectorTags = <String>[
    ...ctx.selectorEntries.map((e) => e.tag),
    ...chainResolution.tags,
  ];

  // §248/§254 — эмитированные узлы (те же map-объекты уходят в config ниже):
  // AWG-advisory читает типы. detour больше НЕ правится in-place (§254 —
  // детекция циклов переехала в validateConfig, конфиг не мутируется).
  // Endpoints тоже — WG/AWG живут там.
  final nodeEntries = <Map<String, dynamic>>[
    for (final e in ctx.outbounds) e.map,
    for (final e in ctx.endpoints) e.map,
  ];

  final directionsWithoutNodes = <String>[]; // §274 — для SnackBar на Home
  final presetOutbounds = _buildDirectionGroups(
    directions: directions,
    selectorTags: selectorTags,
    nodeEntries: nodeEntries,
    emitWarnings: emitWarnings,
    directionsWithoutNodes: directionsWithoutNodes,
    passiveCheck: settings.passiveCheck, // §272
    // §393 C4/T9 — карта позиций для «Направление не берёт цепочку, идущую
    // через него самого» (транзитивно).
    chainHops: chainHopsByTag(chainResolution.nodes),
  );

  final baseOutbounds = config['outbounds'] as List<dynamic>? ?? const [];
  config['outbounds'] = [
    ...baseOutbounds,
    ...ctx.outbounds.map((e) => e.map),
    // §393 C3 — цепочки ПЕРЕД группами Направлений: они узлы, а группы их
    // отбирают (порядок нормативен, корпус `chain_packet_order`).
    ...chainResolution.nodes,
    ...presetOutbounds,
  ];

  if (ctx.endpoints.isNotEmpty) {
    final baseEndpoints = config['endpoints'] as List<dynamic>? ?? const [];
    config['endpoints'] = [
      ...baseEndpoints,
      ...ctx.endpoints.map((e) => e.map),
    ];
  }

  // §370 — нормализация порядка по оси `num`: seed обязательного пресета
  // (traffic-processing) + разметка неразмеченных + сортировка. Гарантирует,
  // что несортируемый пресет присутствует и стоит первым, независимо от
  // storage (fresh/restore/upgrade). Критично для порядка route.rules (sniff
  // первым). Одноразово здесь → все нижеследующие проходы видят нормализованный
  // список.
  final customRules = normalizeRuleOrder(
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

  // §125 — деградация dangling route_final → vpn-1. Ссылка на удалённое Направление
  // или legacy ✨auto (которого больше нет, Решение 2/3) схлопывается в vpn-1
  // (неудаляем → всегда валидная мишень).
  // §219 — валидные мишени берём из ФАКТИЧЕСКИ эмитированных `presetOutbounds`
  // (теги селекторов + auto-двойники), а не переугадываем `[tag, autoTag]`:
  // auto-двойник `<tag>-auto` эмитится лишь при `auto != null && nodes.isNotEmpty`
  // (см. `_buildDirectionGroups`), поэтому статичный `autoTag` для Направления с пустым
  // node-set давал бы висячую ссылку в конфиге (fatal в sing-box).
  // §274 — detour-Направления валидные rules-мишени (вычитание detourDirectionTags
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
    warningsOut: emitWarnings, // §312 — дропы членов DNS-групп
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

  // §103 C7 — миграция ссылок на теги пресетов. ДО деградаций ниже: они
  // снимают битую ссылку, а мы её чиним, и порядок наоборот означал бы, что
  // настройка пользователя теряется вместо переезда на новый тег.
  final healedPrefixes = healPresetTagPrefix(config);
  if (healedPrefixes.isNotEmpty) {
    final shown = healedPrefixes.take(5).map((h) => '${h.from} → ${h.to}');
    emitWarnings.add(
        'Preset tags migrated to namespaced form (${healedPrefixes.length}): '
        '${shown.join(', ')}${healedPrefixes.length > 5 ? ', …' : ''}');
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

  // §419 — битые `dns.final` / `route.default_domain_resolver` (сервер
  // выключенного/удалённого пресета) → дефолт шаблона, var уходит в
  // generatedVars и персистится контроллером. Иначе каждая сборка — fatal
  // DanglingDnsServerRef, а автосброс §121 срабатывал только при открытии
  // экрана DNS Settings: плашка «Settings changed» висела вечно.
  final healedResolvers = healDanglingDnsResolvers(
    config,
    defaults: {
      for (final name in const ['dns_final', 'dns_default_domain_resolver'])
        name: byName[name]?.defaultValue ?? '',
    },
  );
  for (final h in healedResolvers) {
    generatedVars[h.varName] = h.to;
    emitWarnings.add(
        '${h.field} reset to "${h.to}": DNS server "${h.from}" is gone '
        '(its preset was disabled or removed).');
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

  // §343 — битый REALITY-блок (short_id нечётный/не-hex/>16, public_key не
  // X25519) = fatal ВСЕГО конфига на старте ядра. Парсер гейтит на входе
  // (§169/§343), этот post-step — страховка для путей мимо парсера (raw
  // JSON, §302 import rules, vars). Битое значение отбрасывается, нода
  // деградирует — VPN стартует.
  final healedReality = healInvalidReality(config);
  for (final h in healedReality) {
    emitWarnings.add(h.field == 'short_id'
        ? 'REALITY short_id cleared: outbound "${h.owner}" had invalid '
            'hex "${h.original}" — kernel would reject the whole config.'
        : 'REALITY removed: outbound "${h.owner}" had invalid public_key '
            '"${h.original}" — node degraded to plain TLS.');
  }

  // §393 A4 — ФИНАЛЬНЫЙ граф-санитайзер. Последняя точка, где виден весь
  // outbound-граф целиком: все heal'ы выше уже отработали и могли сделать
  // висячими новые ссылки (снятый REALITY ноду не дропает, но §302-патч или
  // выключенная подписка — вполне). Поглощает §172 `healDanglingDetours`:
  // висячий detour — лишь одно из его правил, и агрегация «Detour removed»
  // (§377, одна строка на target) переехала внутрь. Здесь же чинятся
  // члены-призраки групп, `default` вне состава (L1 — иначе ядро отвергает
  // конфиг целиком) и кольца зависимостей — ДО валидатора, чей §254-fatal
  // остаётся последним рубежом на неразруленное.
  emitWarnings.addAll(sanitizeOutboundGraph(
    config,
    directionTags: {for (final c in directions) c.tag},
  ));

  final validation = validateConfig(config);
  return BuildResult(
    configJson: jsonEncode(config),
    config: config,
    validation: validation,
    emitWarnings: emitWarnings,
    generatedVars: generatedVars,
    directionsWithoutNodes: directionsWithoutNodes,
  );
}

/// Реализация `EmitContext`: vars + аллокатор уникальных тегов +
/// аккумуляторы entries + RuleSetRegistry.
class _BuildCtx implements EmitContext {
  _BuildCtx(
    this._vars,
    this._ruleSets, {
    bool passiveCheck = false,
    Iterable<String> reservedTags = const [],
  }) : _passiveCheck = passiveCheck {
    _taken.addAll(reservedTags); // §351 — теги Направлений, эмитятся мимо аллокатора
  }
  final TemplateVars _vars;
  final RuleSetRegistry _ruleSets;
  final bool _passiveCheck;
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
  bool get passiveCheck => _passiveCheck; // §272/§322

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

/// Собирает direction-группы (vpn-1..vpn-10 + их auto-двойники). Приватный
/// helper `buildConfig` — специфичен для одного вызова, выделение в
/// отдельный файл/модуль не даёт пользы (YAGNI, решение §Принципы #4).
/// §125 — собирает outbound-группы из пользовательских [directions] (storage).
/// Каждый **включённый** Направление эмитит selector `<tag>`; если у Направления есть
/// `auto` И его node-set непуст — дополнительно urltest-двойник `<tag>-auto`.
///
/// Per-direction node-set: `selectorTags`, отфильтрованные `direction.nodeFilter`
/// (regex по **итоговому tag** ноды, §048-style — что видно в имени, то и
/// матчится). Пустой/невалидный фильтр → все ноды. Это снимает прежнее
/// допущение «все selector делят один набор нод».
List<Map<String, dynamic>> _buildDirectionGroups({
  required List<Direction> directions,
  required List<String> selectorTags,
  required List<Map<String, dynamic>> nodeEntries,
  required List<String> emitWarnings,
  required List<String> directionsWithoutNodes, // §274 — display-имена, out-параметр
  bool passiveCheck = false, // §272 — urltest.passive_check в auto-двойники
  // §393 C4 — «тег цепочки → её позиции». Пусто = цепочек нет, и весь блок
  // T9 схлопывается в no-op: конфиги без цепочек собираются как раньше.
  Map<String, List<String>> chainHops = const {},
}) {
  // §125 — единственный слой фильтрации нод теперь per-direction regex
  // (node_filter). Глобальный excluded_nodes (§048) удалён.
  final baseNodes = selectorTags;

  final active = directions.where((c) => c.enabled || c.isRequired).toList();

  /// Ноды Направления после regex-фильтра. Пустой/битый regex → все baseNodes.
  /// §197 — nodeFilterInvert инвертирует смысл: true → ноды, чей tag НЕ матчит.
  List<String> nodesFor(Direction c) {
    if (c.nodeFilter.isEmpty) return baseNodes;
    final re = tryCompileRegex(c.nodeFilter, caseSensitive: false);
    if (re == null) return baseNodes;
    return baseNodes
        .where((t) => re.hasMatch(t) != c.nodeFilterInvert)
        .toList();
  }

  // §248 — member-set'ы считаем один раз: их делят selector и auto-двойник.
  // §254 — детур-циклы билдер больше НЕ рвёт: детекция и минимальный набор
  // виновников — в validateConfig (fatal, конфиг не собирается).
  // §393 C4 / T9 (§393 L6) — Направление НЕ берёт в состав цепочку, которая
  // через него же проходит (транзитивно). Считается ПОСЛЕ фильтра: фильтр не
  // знает, что такое цепочка, и знать не должен — «все узлы» обязано означать
  // все узлы. Самый частый сценарий ломается сразу: цепочка `[proxy-out,
  // exit]` при фильтре «всё» у `proxy-out` замкнула бы трафик на себя.
  final memberSets = <List<String>>[];
  // Отобранное ФИЛЬТРОМ, до вычета T9. Нужно ровно для одного: не соврать в
  // предупреждении «node filter matched no nodes». Фильтр, поймавший только
  // цепочку, которую затем вычел T9, отработал ПРАВИЛЬНО, и посылать
  // пользователя его чинить («Check its node filter») значит отправить его
  // искать несуществующую опечатку вместо настоящей причины — а она названа
  // отдельной строкой про цикл, которая уже выдана выше.
  final filteredCounts = <int>[];
  for (final c in active) {
    final filtered = nodesFor(c);
    filteredCounts.add(filtered.length);
    final (:kept, :dropped) =
        dropChainsThroughDirection(filtered, c.tag, chainHops);
    memberSets.add(kept);
    if (dropped.isNotEmpty) {
      emitWarnings.add(chainCycleThroughDirectionLine(c.displayLabel, dropped));
    }
  }
  // §322 — узел автовыбора в urltest-двойник Направления не идёт: urltest внутри
  // urltest мерил бы уже выбранный внутренней группой узел, а не сервер.
  // Тип берём из эмитированных entry (там же, откуда его читает AWG-advisory).
  final groupTags = {
    for (final e in nodeEntries)
      if (e['type'] == 'urltest') e['tag'] as String,
  };
  final autoSets = [
    for (final ms in memberSets)
      [
        for (final t in ms)
          if (!groupTags.contains(t)) t,
      ],
  ];

  // §393 A3 — теги Направлений, УЖЕ эмитированных выше по списку. Только на
  // них законна ссылка `include`: эмиссия идёт по порядку, и ссылка вниз
  // была бы forward-ref (антицикл держится порядком, как у лаунчера —
  // `tagsAbove` в форме + топологический проход генератора).
  final emittedAbove = <String>{};

  final result = <Map<String, dynamic>>[];
  for (var i = 0; i < active.length; i++) {
    final c = active[i];
    final nodes = memberSets[i];
    final autoNodes = autoSets[i]; // §322 — без узлов автовыбора
    final emitAuto = c.auto != null && autoNodes.isNotEmpty;

    // §393 A3 — фильтр include: в состав идут только теги Направлений,
    // эмитированных ВЫШЕ. Отсеиваются три случая, все одним warning'ом:
    //   • ссылка ВНИЗ по списку (в т.ч. после reorder — Направление
    //     переехало выше своей цели): ядро отвергло бы конфиг на
    //     forward-ref, поэтому деградируем состав, а не ломаем сборку;
    //   • ссылка на выключенное Направление: его нет в `active`, значит и
    //     тега в конфиге нет — dangling ref не даёт ядру стартовать;
    //   • ссылка на несуществующий тег (удалённое Направление, правленый
    //     руками файл, restore из чужого бэкапа).
    // Самоссылка отсеивается тем же условием: свой тег в `emittedAbove` ещё
    // не лежит (кладём его в конце итерации).
    final includeTags = <String>[];
    for (final t in c.include) {
      if (emittedAbove.contains(t)) {
        if (!includeTags.contains(t)) includeTags.add(t);
        continue;
      }
      emitWarnings.add(
          'Direction "${c.displayLabel}" (${c.tag}): option "$t" dropped — '
          'it must be another direction listed above this one (and enabled).');
    }

    // §393 A3 — ПОРЯДОК СОСТАВА нормативен (corpus/direction/README.md
    // «сначала служебные опции и ссылки на другие Направления, потом узлы
    // в порядке конфига»), потому что первый элемент = НЕЯВНЫЙ default
    // sing-box: селектор без поля `default` стартует на первой опции.
    // Служебные опции спереди — это и UX (не листать сотню узлов, чтобы
    // включить direct), и семантика (узел подписки не должен молча стать
    // умолчанием Направления, состоящего из ссылок).
    //
    // Порядок ВНУТРИ служебного блока: `<tag>-auto`, direct-out, block-out,
    // include-теги. Эталон — лаунчер: у него direct/block и include лежат
    // ОДНИМ списком `Direction.AddOutbounds`, который эмитится целиком перед
    // узлами (outbound_generator.go:575-576 «Add addOutbounds first»), а
    // собирается формой в фиксированном порядке чекбоксов
    // `direct-out → block → прочие теги` (edit_dialog.go:462-472). У мобилы
    // те же данные разложены на два флага + список, поэтому порядок
    // воспроизводим руками. auto-двойник впереди всех — так его кладёт
    // `direction_twins.go:112` (`prependUnique(twinTag, parent.AddOutbounds)`).
    //
    // Обе фикстуры корпуса сходятся на этом порядке: у
    // `include_earlier_direction` служебных опций нет → `[vpn-1, узлы…]`;
    // у `include_direct_and_block` нет include → `[direct-out, block-out,
    // узел]`. Кейса с обеими категориями сразу в корпусе нет — тай-брейк
    // взят у лаунчера, а не выдуман.
    final selectorOutbounds = <String>[
      if (emitAuto) c.autoTag,
      if (c.includeDirect) kDirectOutboundTag,
      if (c.includeBlock) kBlockOutboundTag, // §274 — совместим с detour
      ...includeTags,
      ...nodes,
    ];
    // §201/§274 — пустой набор (regex не матчит / нет нод) → fallback на
    // [block, direct-out] с default=block для ВСЕХ Направлений (безопаснее
    // блокировать, чем выпускать мимо VPN; direct остаётся доступной
    // опцией). Detour-исключение §248 Q1 ([direct], «нет хопа») снято:
    // detour-Направление может одновременно быть целью правил, и direct-fallback
    // молча выпускал бы rule-трафик мимо VPN. selector не должен быть
    // пустой группой (fatal в sing-box).
    final emptyFallback = selectorOutbounds.isEmpty;
    if (emptyFallback) {
      selectorOutbounds.addAll([kBlockOutboundTag, kDirectOutboundTag]);
    }
    // §200/§274 — предупреждаем, если ИМЕННО фильтр Направления отсёк все ноды
    // (фильтр непустой, но 0 совпадений): в AppLog текстом, в UI
    // транзиентным SnackBar (directionsWithoutNodes). Текст отражает
    // ФАКТИЧЕСКИЙ исход: при emptyFallback ядро берёт default=block, иначе
    // (include_direct/include_block без нод) — ПЕРВУЮ опцию списка, и при
    // include_direct это direct-out (юзер сам включил опцию — трафик идёт
    // мимо VPN, врать «blocked» нельзя). Пустой фильтр с 0 нод (нет
    // подписки) НЕ варним — это не вина фильтра.
    if (nodes.isEmpty &&
        filteredCounts[i] == 0 && // §393 C4 — не винить фильтр за вычет T9
        c.nodeFilter.isNotEmpty &&
        selectorTags.isNotEmpty) {
      final effective =
          emptyFallback ? kBlockOutboundTag : selectorOutbounds.first;
      // §393 A3 — исход зависит от того, ЧТО стало первой опцией: block
      // (пустой fallback), direct-out (юзер включил галку — трафик идёт мимо
      // VPN, врать «blocked» нельзя) или другое Направление из `include`,
      // которое ведёт трафик СВОИМИ узлами (ни то, ни другое).
      final outcome = switch (effective) {
        kDirectOutboundTag => 'traffic goes direct (no VPN hop)',
        kBlockOutboundTag => 'traffic is blocked (default)',
        _ => 'traffic falls back to "$effective"',
      };
      emitWarnings.add(
          'Direction "${c.displayLabel}" (${c.tag}): node filter matched no '
          'nodes — $outcome. '
          'Check its node filter.');
      // §393 A3 — SnackBar «Направления без узлов» гейтится УЖЕ ИСХОДОМ, а не
      // фактом пустого node-set. Список `directionsWithoutNodes` в UI зовёт
      // пользователя чинить фильтр СРОЧНО, потому что Направление
      // фактически не ведёт трафик: block-fallback (`emptyFallback`) или
      // единственные служебные опции direct/block. Если же `include[]` дал
      // рабочих участников — Направление живое, трафик идёт узлами цели, и
      // поднимать тревогу не за что. Текст в AppLog остаётся в обоих
      // случаях: он информирует, а не требует действия.
      final onlyMagic = selectorOutbounds
          .every((t) => t == kDirectOutboundTag || t == kBlockOutboundTag);
      if (emptyFallback || onlyMagic) {
        directionsWithoutNodes.add(c.displayLabel);
      }
    }

    final selector = <String, dynamic>{
      'tag': c.tag,
      'type': 'selector',
      'outbounds': selectorOutbounds,
      'interrupt_exist_connections': c.interruptExistConnections,
    };
    // §201/§274 — fallback пустого Направления: block для всех.
    if (emptyFallback) {
      selector['default'] = kBlockOutboundTag;
    }
    // §141 — default = первая нода Направления, чей итоговый tag матчит defaultFilter.
    // Не матчит/пусто → default не выставляется (sing-box берёт первую опцию).
    if (c.defaultFilter.isNotEmpty) {
      final re = tryCompileRegex(c.defaultFilter, caseSensitive: false);
      final def = re == null ? null : _firstMatch(nodes, re);
      // Гейт-защита (§141 P1.8b): default обязан быть валидным членом
      // outbounds — иначе ядро отвергает конфиг ЦЕЛИКОМ («default outbound
      // not found», L1). Здесь не-член просто НЕ ставится: ключа нет, ядро
      // берёт первую опцию — это и есть корректный исход, а не расхождение с
      // эталоном (`outbound_graph_sanitize.go:216-221` подставляет `kept[0]`
      // там, где ключ УЖЕ записан и оказался вне состава). Ровно этот случай
      // — состав ужался каскадом, а default остался от прошлой жизни — чинит
      // правило 3 санитайзера (§393 A4).
      if (def != null && selectorOutbounds.contains(def)) {
        selector['default'] = def;
      }
    }
    // §393 A5 — умолчанием Направления с автовыбором становится его двойник:
    // ради автовыбора галку и включали, и без ключа ядро взяло бы ПЕРВУЮ
    // опцию — сегодня это тот же `<tag>-auto`, но стоит юзеру включить
    // direct/block или сослаться include'ом, и умолчание молча уехало бы на
    // служебную опцию. Эталон — `outbound_generator.go:676-682`
    // (`defaultTag == "" && TwinTag != ""`), нормативный кейс корпуса —
    // `auto_twin_emitted_and_default`.
    //
    // Только когда `defaultFilter` пользователя НИЧЕГО не поймал: явно
    // выбранный узел важнее автовыбора (`auto_twin_default_yields_to_
    // explicit`). Условие вхождения в состав выполнено по построению —
    // `emitAuto` кладёт `c.autoTag` первым элементом `selectorOutbounds`.
    if (emitAuto && !selector.containsKey('default')) {
      selector['default'] = c.autoTag;
    }

    // urltest-двойник: ТОЛЬКО ноды Направления (без direct/auto). Не эмитим при
    // пустом наборе (urltest без нод недопустим).
    if (emitAuto) {
      final a = c.auto!;
      final urltest = <String, dynamic>{
        'tag': c.autoTag,
        'type': 'urltest',
        'outbounds': autoNodes,
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
    // §393 A5 — ПОРЯДОК ЭМИССИИ нормативен (corpus/direction/README.md:
    // «сначала auto-группа, потом само Направление»), поэтому селектор
    // добавляется ПОСЛЕ своего двойника, а не до. Дело не в эстетике: и
    // `default`, и первая опция селектора смотрят на `<tag>-auto`, и запись,
    // на которую ссылаются, обязана лежать в файле раньше ссылки — так
    // конфиг читается человеком и так его собирает лаунчер
    // (`direction_twins.go:105-114`: `out = append(out, buildTwin…)`, затем
    // родитель). Ядру порядок безразличен, читателю и диффу — нет.
    result.add(selector);

    // §393 A3 — тег этого Направления становится законной целью `include`
    // для СЛЕДУЮЩИХ. Регистрируем в конце итерации: свой же тег не должен
    // попасть в собственный состав (самоссылка = кольцо на одном узле).
    // Двойник `<tag>-auto` сюда НЕ кладём — он опция только своего
    // Направления (канон схемы + `direction_twins.go:buildTwin`, где
    // производная запись помечена TwinOf и другим не предлагается).
    emittedAbove.add(c.tag);
  }
  return result;
}

/// §125 fallback — синтез `List<Direction>` из `template.groupTemplates`, когда
/// storage ещё пуст (тесты без storage / первый билд до миграции). Та же
/// seed-логика, что и one-shot миграция `_migrateDirectionsIfNeeded`, но auto-
/// параметры резолвятся через [resolve] (@urltest_* vars). §267 — итерируем
/// `default_directions`, auto-подгруппа при `direction.include ∋ auto`.
List<Direction> _directionsFromTemplate(
  GroupTemplates gt,
  Set<String> enabledGroupTags,
  VarResolver resolve,
) {
  // §327 — дефолты живут в шаблоне (`vars[].default_value`), и `resolve` их уже
  // применил: `vars` в buildConfig наполнен `userVars[name] ?? defaultValue`.
  // Прежние литералы (`'50'`, `'15m'`) были недостижимой копией шаблона и
  // разошлись с ним (шаблон: 30). Здесь остаются только дефолты `DirectionAuto`
  // — последний рубеж, если var из шаблона исчезнет.
  const fallback = DirectionAuto();
  String? s(String name) => resolve(name)?.toString();

  DirectionAuto seedAuto() => DirectionAuto(
        url: s('urltest_url') ?? fallback.url,
        interval: s('urltest_interval') ?? fallback.interval,
        tolerance: int.tryParse(s('urltest_tolerance') ?? '') ?? fallback.tolerance,
        idleTimeout: fallback.idleTimeout,
        interruptExistConnections: fallback.interruptExistConnections,
      );

  final hasAuto = gt.direction.include.contains('auto');
  final out = <Direction>[];
  for (final dc in gt.defaultDirections) {
    final enabled = dc.tag == 'vpn-1'
        ? true
        : (enabledGroupTags.isEmpty
            ? dc.defaultEnabled
            : enabledGroupTags.contains(dc.tag));
    final auto = hasAuto ? seedAuto() : null;
    out.add(
        Direction.seedFromDefault(dc, gt.direction, enabled: enabled, auto: auto));
  }
  return out;
}

/// Компилирует regex, `null` при невалидном паттерне (caller → fallback на все
/// ноды). Общий helper для билдера и live-превью редактора (§125 F4).

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
