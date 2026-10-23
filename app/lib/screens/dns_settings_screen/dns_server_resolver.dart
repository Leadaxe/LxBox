import '../../models/custom_rule.dart';
import '../../models/dns_ref.dart';
import '../../models/parser_config.dart' show WizardVar;
import '../../services/builder/post_steps.dart'
    show resolveTemplateDnsServerBody;
import '../../services/builder/preset_expand.dart' show normalizeDnsDetour;
import '../../services/dns/dns_server_holds.dart';
import 'resolved_server.dart';

/// §044: render list — typed `ResolvedServer` для каждой ref-записи.
///
/// Single source of truth для полей:
/// - `tag` — из ref'а (синтезируется в body для display)
/// - `description` — из ref'а если переопределён, иначе из canonical
/// - `enabled` — из ref'а
/// - `body` — для inline это `ref.body` + injected tag; для template —
///   §117-обёртка `{vars, server}` с подставленными `@var`'ами (значения из
///   `ref.varValues` / дефолты) + нормализованный detour (display = emit);
///   для preset — canonical lookup + strip meta + injected tag
///
/// `kind` / `overrides` / `presetLabel` / `vars` / `varValues` /
/// `lockedByPreset` — typed accessors на `ResolvedServer`.
///
/// — pure.
List<ResolvedServer> resolveDisplayedServers(
  List<DnsServerRef> servers,
  Map<String, Map<String, dynamic>> templateByTag,
  Map<String, Map<String, dynamic>> presetServersByTag, {
  // §117 задача 3: tag → имя routing-правила с активной DNS-опцией
  // (lifecycle-лок «used by <правило>»).
  Map<String, String> ruleRefsByTag = const {},
  // §680 — значения пикеров вкладки: сервер под ними залочен с меткой
  // [dnsFinalLabel] / [defaultResolverLabel] (caller передаёт локализованные).
  String dnsFinal = '',
  String defaultResolver = '',
  String dnsFinalLabel = 'DNS Final',
  String defaultResolverLabel = 'Default Domain Resolver',
}) {
  final out = <ResolvedServer>[];
  for (final ref in servers) {
    final tag = ref.tag;
    if (tag.isEmpty) continue;

    final ServerKind kind;
    final Map<String, dynamic> body;
    ServerKind? overrides;
    String? presetLabel;
    var presetId = '';
    String? canonicalDescription;
    var vars = const <WizardVar>[];
    var varValues = const <String, String>{};

    switch (ref) {
      case DnsServerInline():
        kind = ServerKind.inline;
        body = Map<String, dynamic>.from(ref.body);
        // Override-detection (preset wins over template).
        if (presetServersByTag.containsKey(tag)) {
          overrides = ServerKind.preset;
          final p = presetServersByTag[tag]!;
          presetLabel = p['_preset_label']?.toString();
          presetId = p['_preset_id']?.toString() ?? '';
          canonicalDescription = p['description']?.toString();
        } else if (templateByTag.containsKey(tag)) {
          overrides = ServerKind.template;
          canonicalDescription = templateByTag[tag]?['description']?.toString();
        }
      case DnsServerPreset():
        kind = ServerKind.preset;
        final p = presetServersByTag[tag];
        if (p == null) continue; // orphan
        body = Map<String, dynamic>.from(p)
          ..remove('_preset_label')
          ..remove('_preset_id');
        presetLabel = p['_preset_label']?.toString();
        presetId = ref.presetId.isNotEmpty
            ? ref.presetId
            : p['_preset_id']?.toString() ?? '';
        canonicalDescription = p['description']?.toString();
      case DnsServerTemplate():
        kind = ServerKind.template;
        final t = templateByTag[tag];
        if (t == null) continue; // orphan
        // §117: обёртка `{description, enabled, vars?, server}` — body это
        // `server` с подставленными vars; display показывает emit-форму
        // (detour normalized), поэтому direct-out в диалоге не светится.
        varValues = ref.varValues;
        final resolvedBody =
            resolveTemplateDnsServerBody(t, varValues: varValues);
        if (resolvedBody == null) continue; // malformed wrapper
        normalizeDnsDetour(resolvedBody);
        body = resolvedBody;
        vars = (t['vars'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(WizardVar.fromJson)
            .toList();
        canonicalDescription = t['description']?.toString();
    }

    // Synthesize tag в body (single source of truth — ref.tag).
    // Strip meta (description/enabled из canonical body не нужны).
    body
      ..['tag'] = tag
      ..remove('description')
      ..remove('enabled');

    // Resolved description: ref.description если есть; иначе canonical's.
    final refDesc = ref.description;
    final description = (refDesc != null && refDesc.isNotEmpty)
        ? refDesc
        : (canonicalDescription ?? '');

    out.add(ResolvedServer(
      kind: kind,
      tag: tag,
      description: description,
      enabled: ref.enabled,
      body: body,
      overrides: overrides,
      presetLabel: presetLabel,
      presetId: presetId,
      vars: vars,
      varValues: varValues,
      usedByRule: ruleRefsByTag[tag],
    ));
  }
  // §044: render-order — template → preset → inline (см. ServerKind enum).
  // Stable sort: внутри каждой группы insertion-order сохраняется.
  out.sort((a, b) => a.kind.index.compareTo(b.kind.index));
  final listRefs = dnsServerListRefs(
    out,
    dnsFinal: dnsFinal,
    defaultResolver: defaultResolver,
    dnsFinalLabel: dnsFinalLabel,
    defaultResolverLabel: defaultResolverLabel,
  );
  if (listRefs.isEmpty) return out;
  return [
    for (final s in out)
      if (listRefs[s.tag] case final refs?) s.withUsedByList(refs) else s,
  ];
}

/// §680 — кто из самого списка ссылается на сервер: tag → метки источников.
/// Расчёт ссылок — [dnsServerListHolds] (общий с импортом бэкапа, §681);
/// здесь только подписи: группа и `domain_resolver` — description
/// сервера-источника, иначе его тег; [dnsFinal] / [defaultResolver] — метки
/// [dnsFinalLabel] / [defaultResolverLabel]. — pure.
Map<String, List<String>> dnsServerListRefs(
  List<ResolvedServer> servers, {
  String dnsFinal = '',
  String defaultResolver = '',
  String dnsFinalLabel = 'DNS Final',
  String defaultResolverLabel = 'Default Domain Resolver',
}) {
  final labelByTag = <String, String>{};
  for (final s in servers) {
    labelByTag.putIfAbsent(
        s.tag, () => s.description.isNotEmpty ? s.description : s.tag);
  }
  final holds = dnsServerListHolds(
    [for (final s in servers) (tag: s.tag, body: s.body)],
    dnsFinal: dnsFinal,
    defaultResolver: defaultResolver,
  );
  final refs = <String, List<String>>{};
  for (final e in holds.entries) {
    final labels = <String>[];
    for (final h in e.value) {
      final label = switch (h.kind) {
        DnsHoldKind.dnsFinal => dnsFinalLabel,
        DnsHoldKind.defaultDomainResolver => defaultResolverLabel,
        _ => labelByTag[h.source] ?? h.source,
      };
      if (!labels.contains(label)) labels.add(label);
    }
    refs[e.key] = labels;
  }
  return refs;
}

/// §680 — дефолтный сервер для авто-выбора (DNS-опция правила,
/// `domain_resolver` hostname-адреса): `google_udp`, если он в [tags];
/// иначе первый пригодный ([eligible] — не fakeip/hosts); иначе пусто.
/// [tags] — только теги списка: сервер вне списка дал бы висящую ссылку.
/// — pure.
String defaultDnsServerTag(
  List<String> tags, {
  bool Function(String tag)? eligible,
}) {
  if (tags.contains('google_udp')) return 'google_udp';
  for (final t in tags) {
    if (t.isNotEmpty && (eligible == null || eligible(t))) return t;
  }
  return '';
}

/// Tags доступные в dropdown'ах (DNS Final / Default Resolver / per-rule).
/// Filter `enabled` на ref-level. §117: locked-сервер (реферится активным
/// пресетом или правилом) build всегда force-include'ит — показываем его
/// даже при выключенном тоггле.
///
/// pure.
List<String> enabledServerTags(List<ResolvedServer> displayedServers) {
  final out = <String>[];
  for (final s in displayedServers) {
    if (!s.enabled && !s.forceIncluded) continue;
    if (s.tag.isEmpty) continue;
    out.add(s.tag);
  }
  return out;
}

/// §117 (задача 4b): rename тега inline-сервера — каскад по ссылкам в
/// state'е DNS-экрана, чтобы переименование не орфанило рефы:
/// - `domain_resolver` в body других inline-серверов;
/// - значения vars типа `dns_servers` (dom_resolver) у template-серверов;
/// - `server` в §061 DNS-правилах (kind inline/srs);
/// - `dns_final` / `dns_default_domain_resolver`.
///
/// Мутирует [servers]/[rules] in-place; обновлённые resolver-значения
/// возвращает record'ом. Рефы routing-правил (задача 3) — отдельным
/// [renameRuleDnsServerTag] (другой storage). — pure.
({String dnsFinal, String defaultResolver}) renameDnsServerTagRefs({
  required List<DnsServerRef> servers,
  required List<DnsRuleRef> rules,
  required Map<String, Map<String, dynamic>> templateByTag,
  required String oldTag,
  required String newTag,
  required String dnsFinal,
  required String defaultResolver,
}) {
  for (var i = 0; i < servers.length; i++) {
    final entry = servers[i];
    switch (entry) {
      case DnsServerInline(:final body):
        if (body['domain_resolver'] == oldTag) {
          servers[i] = entry.copyWith(
              body: {...body, 'domain_resolver': newTag});
        }
      case DnsServerTemplate(:final varValues) when varValues.isNotEmpty:
        // Только vars типа dns_servers — enum-значение может текстуально
        // совпасть с тегом, его не трогаем.
        final wrapper = templateByTag[entry.tag];
        final dnsVarNames = <String>{
          for (final d in (wrapper?['vars'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>())
            if (d['type'] == 'dns_servers' && d['name'] is String)
              d['name'] as String,
        };
        if (dnsVarNames.any((name) => varValues[name] == oldTag)) {
          servers[i] = entry.copyWith(varValues: {
            for (final e in varValues.entries)
              e.key: dnsVarNames.contains(e.key) && e.value == oldTag
                  ? newTag
                  : e.value,
          });
        }
      case DnsServerTemplate() || DnsServerPreset():
        break;
    }
  }

  for (var i = 0; i < rules.length; i++) {
    final entry = rules[i];
    switch (entry) {
      case DnsRuleInline(:final rule) when rule['server'] == oldTag:
        rules[i] = entry.copyWith(rule: {...rule, 'server': newTag});
      case DnsRuleSrs(:final server) when server == oldTag:
        rules[i] = entry.copyWith(server: newTag);
      // §439 A1 — сборка читает `server` и из `body` (форма §294).
      case DnsRuleSrs(:final body?) when body['server'] == oldTag:
        rules[i] = entry.copyWith(body: {...body, 'server': newTag});
      default:
        break;
    }
  }

  return (
    dnsFinal: dnsFinal == oldTag ? newTag : dnsFinal,
    defaultResolver: defaultResolver == oldTag ? newTag : defaultResolver,
  );
}

/// §117 (задача 4b): rename тега в DNS-опциях routing-правил (задача 3,
/// `dns.serverTag`). Возвращает обновлённый список; если ссылок нет —
/// исходный (identical — caller может не персистить). — pure.
List<CustomRule> renameRuleDnsServerTag(
  List<CustomRule> rules,
  String oldTag,
  String newTag,
) {
  var changed = false;
  final out = rules.map((cr) {
    final dns = cr.dns;
    if (dns == null || dns.serverTag != oldTag) return cr;
    changed = true;
    return switch (cr) {
      CustomRuleInline() => cr.copyWith(dns: dns.copyWith(serverTag: newTag)),
      CustomRuleSrs() => cr.copyWith(dns: dns.copyWith(serverTag: newTag)),
      CustomRulePreset() => cr,
      // §225 — json-правило не имеет dns-опции (cr.dns==null отсеян выше).
      CustomRuleJson() => cr,
    };
  }).toList(growable: false);
  return changed ? out : rules;
}

/// §033: orphan-cleanup safety — only persist entries whose source still
/// exists. UI mutation already filtered, но keep guard symmetric с
/// resolveDnsRulesList semantics.
///
/// pure.
List<DnsRuleRef> cleanDnsRulesForPersist(
  List<DnsRuleRef> rules,
  Map<String, Map<String, dynamic>> templateRulesByName,
  Map<String, List<Map<String, dynamic>>> presetRulesByPresetId,
) {
  return rules
      .where((e) => switch (e) {
            DnsRuleInline() || DnsRuleSrs() => true,
            DnsRuleTemplate(:final name) =>
              templateRulesByName.containsKey(name),
            DnsRulePreset(:final presetId) =>
              presetRulesByPresetId.containsKey(presetId),
          })
      .toList();
}

/// §682 — Default Domain Resolver через туннель: резолвер ищет адреса узлов,
/// пока туннеля ещё нет, и запрос через `detour` ждёт сам себя. Возвращает
/// тег Направления, когда предупреждать, иначе null:
/// - одиночный сервер — его `detour` после нормализации (`direct-out` = нет);
/// - группа — только если ВСЕ эмитируемые члены (есть в списке, включены или
///   залочены) с `detour`; тег — первого из них. Хоть один прямой член,
///   член-группа или ни одного эмитируемого — null.
/// Тела берутся из [servers] (template — с подставленными vars). — pure.
String? defaultResolverTunnelDetour(
  String resolverTag,
  List<ResolvedServer> servers,
) {
  final byTag = {for (final s in servers) s.tag: s};
  String? detourOf(ResolvedServer s) {
    if (s.body['type'] == 'group') return null;
    final body = Map<String, dynamic>.of(s.body);
    normalizeDnsDetour(body);
    final d = body['detour'];
    return d is String && d.isNotEmpty ? d : null;
  }

  final selected = byTag[resolverTag];
  if (selected == null) return null;
  if (selected.body['type'] != 'group') return detourOf(selected);
  final members = selected.body['servers'];
  if (members is! List) return null;
  String? first;
  var emitted = 0;
  for (final m in members) {
    final member = byTag[m?.toString() ?? ''];
    if (member == null || member.tag == selected.tag) continue;
    if (!member.enabled && !member.forceIncluded) continue;
    emitted++;
    final d = detourOf(member);
    if (d == null) return null;
    first ??= d;
  }
  return emitted == 0 ? null : first;
}
