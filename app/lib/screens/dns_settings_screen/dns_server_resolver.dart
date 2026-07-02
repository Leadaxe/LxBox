import '../../models/custom_rule.dart';
import '../../models/parser_config.dart' show WizardVar;
import '../../services/builder/post_steps.dart'
    show resolveTemplateDnsServerBody;
import '../../services/builder/preset_expand.dart' show normalizeDnsDetour;
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
  List<Map<String, dynamic>> servers,
  Map<String, Map<String, dynamic>> templateByTag,
  Map<String, Map<String, dynamic>> presetServersByTag, {
  // §117 задача 3: tag → имя routing-правила с активной DNS-опцией
  // (lifecycle-лок «used by <правило>»).
  Map<String, String> ruleRefsByTag = const {},
}) {
  final out = <ResolvedServer>[];
  for (final ref in servers) {
    final kindStr = ref['kind']?.toString();
    final tag = ref['tag']?.toString();
    if (kindStr == null || tag == null || tag.isEmpty) continue;
    final kind = ServerKind.tryParse(kindStr);
    if (kind == null) continue;

    Map<String, dynamic>? body;
    ServerKind? overrides;
    String? presetLabel;
    String? canonicalDescription;
    var vars = const <WizardVar>[];
    var varValues = const <String, String>{};

    if (kind == ServerKind.inline) {
      final b = ref['body'];
      body = b is Map ? Map<String, dynamic>.from(b) : <String, dynamic>{};
      // Override-detection (preset wins over template).
      if (presetServersByTag.containsKey(tag)) {
        overrides = ServerKind.preset;
        final p = presetServersByTag[tag]!;
        presetLabel = p['_preset_label']?.toString();
        canonicalDescription = p['description']?.toString();
      } else if (templateByTag.containsKey(tag)) {
        overrides = ServerKind.template;
        canonicalDescription = templateByTag[tag]?['description']?.toString();
      }
    } else if (kind == ServerKind.preset) {
      final p = presetServersByTag[tag];
      if (p == null) continue; // orphan
      body = Map<String, dynamic>.from(p)..remove('_preset_label');
      presetLabel = p['_preset_label']?.toString();
      canonicalDescription = p['description']?.toString();
    } else if (kind == ServerKind.template) {
      final t = templateByTag[tag];
      if (t == null) continue; // orphan
      // §117: обёртка `{description, enabled, vars?, server}` — body это
      // `server` с подставленными vars; display показывает emit-форму
      // (detour normalized), поэтому direct-out в диалоге не светится.
      final vv = ref['varValues'];
      varValues = vv is Map
          ? {for (final e in vv.entries) e.key.toString(): '${e.value}'}
          : const {};
      body = resolveTemplateDnsServerBody(t, varValues: varValues);
      if (body == null) continue; // malformed wrapper
      normalizeDnsDetour(body);
      vars = (t['vars'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(WizardVar.fromJson)
          .toList();
      canonicalDescription = t['description']?.toString();
    }

    // Synthesize tag в body (single source of truth — ref.tag).
    // Strip meta (description/enabled из canonical body не нужны).
    body!
      ..['tag'] = tag
      ..remove('description')
      ..remove('enabled');

    // Resolved description: ref.description если есть; иначе canonical's.
    final refDesc = ref['description']?.toString();
    final description = (refDesc != null && refDesc.isNotEmpty)
        ? refDesc
        : (canonicalDescription ?? '');

    out.add(ResolvedServer(
      kind: kind,
      tag: tag,
      description: description,
      enabled: ref['enabled'] != false,
      body: body,
      overrides: overrides,
      presetLabel: presetLabel,
      vars: vars,
      varValues: varValues,
      usedByRule: ruleRefsByTag[tag],
    ));
  }
  // §044: render-order — template → preset → inline (см. ServerKind enum).
  // Stable sort: внутри каждой группы insertion-order сохраняется.
  out.sort((a, b) => a.kind.index.compareTo(b.kind.index));
  return out;
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
    if (!s.enabled && !s.locked) continue;
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
  required List<Map<String, dynamic>> servers,
  required List<Map<String, dynamic>> rules,
  required Map<String, Map<String, dynamic>> templateByTag,
  required String oldTag,
  required String newTag,
  required String dnsFinal,
  required String defaultResolver,
}) {
  for (var i = 0; i < servers.length; i++) {
    final entry = Map<String, dynamic>.from(servers[i]);
    var changed = false;
    if (entry['kind'] == 'inline' && entry['body'] is Map) {
      final body = Map<String, dynamic>.from(entry['body'] as Map);
      if (body['domain_resolver'] == oldTag) {
        body['domain_resolver'] = newTag;
        entry['body'] = body;
        changed = true;
      }
    } else if (entry['kind'] == 'template' && entry['varValues'] is Map) {
      // Только vars типа dns_servers — enum-значение может текстуально
      // совпасть с тегом, его не трогаем.
      final wrapper = templateByTag[entry['tag']?.toString()];
      final dnsVarNames = <String>{
        for (final d in (wrapper?['vars'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>())
          if (d['type'] == 'dns_servers' && d['name'] is String)
            d['name'] as String,
      };
      if (dnsVarNames.isNotEmpty) {
        final vv = Map<String, dynamic>.from(entry['varValues'] as Map);
        var vvChanged = false;
        for (final name in dnsVarNames) {
          if (vv[name] == oldTag) {
            vv[name] = newTag;
            vvChanged = true;
          }
        }
        if (vvChanged) {
          entry['varValues'] = vv;
          changed = true;
        }
      }
    }
    if (changed) servers[i] = entry;
  }

  for (var i = 0; i < rules.length; i++) {
    final entry = Map<String, dynamic>.from(rules[i]);
    var changed = false;
    if (entry['kind'] == 'inline' && entry['rule'] is Map) {
      final rule = Map<String, dynamic>.from(entry['rule'] as Map);
      if (rule['server'] == oldTag) {
        rule['server'] = newTag;
        entry['rule'] = rule;
        changed = true;
      }
    } else if (entry['kind'] == 'srs' && entry['server'] == oldTag) {
      entry['server'] = newTag;
      changed = true;
    }
    if (changed) rules[i] = entry;
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
List<Map<String, dynamic>> cleanDnsRulesForPersist(
  List<Map<String, dynamic>> rules,
  Map<String, Map<String, dynamic>> templateRulesByName,
  Map<String, Map<String, dynamic>> presetRulesByPresetId,
) {
  return rules.where((e) {
    final kind = e['kind'] as String?;
    if (kind == null) return false;
    if (kind == 'inline') {
      final name = e['name'] as String?;
      return name != null && name.isNotEmpty;
    }
    if (kind == 'srs') {
      final id = e['id'] as String?;
      final name = e['name'] as String?;
      return id != null && id.isNotEmpty && name != null && name.isNotEmpty;
    }
    if (kind == 'template') {
      final name = e['name'] as String?;
      return name != null && templateRulesByName.containsKey(name);
    }
    if (kind == 'preset') {
      final pid = e['presetId'] as String?;
      return pid != null && presetRulesByPresetId.containsKey(pid);
    }
    return false;
  }).toList();
}
