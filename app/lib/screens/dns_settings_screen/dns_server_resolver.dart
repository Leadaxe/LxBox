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
  Map<String, Map<String, dynamic>> presetServersByTag,
) {
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
    ));
  }
  // §044: render-order — template → preset → inline (см. ServerKind enum).
  // Stable sort: внутри каждой группы insertion-order сохраняется.
  out.sort((a, b) => a.kind.index.compareTo(b.kind.index));
  return out;
}

/// Tags доступные в dropdown'ах (DNS Final / Default Resolver / per-rule).
/// Filter `enabled` на ref-level. §117: locked-сервер (реферится активным
/// пресетом) build всегда force-include'ит — показываем его даже при
/// выключенном тоггле.
///
/// pure.
List<String> enabledServerTags(List<ResolvedServer> displayedServers) {
  final out = <String>[];
  for (final s in displayedServers) {
    if (!s.enabled && !s.lockedByPreset) continue;
    if (s.tag.isEmpty) continue;
    out.add(s.tag);
  }
  return out;
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
