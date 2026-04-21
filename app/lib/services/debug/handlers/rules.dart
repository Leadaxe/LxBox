import '../../../models/custom_rule.dart';
import '../../settings_storage.dart';
import '../context.dart';
import '../contract/errors.dart';
import '../serializers/rules.dart';
import '../transport/request.dart';
import '../transport/response.dart';
import '_shared.dart';

/// `/rules/*` — CRUD для custom routing rules (§030).
///
/// Работает поверх [SettingsStorage.getCustomRules] / [saveCustomRules] —
/// тот же write-путь что и UI, атомарность read-modify-write на уровне storage.
///
/// Routes:
/// - `GET    /rules`             → list (alias для /state/rules)
/// - `POST   /rules`             → create (UUID генерится сервером)
/// - `POST   /rules/reorder`     → reorder (body: `{"order":[id,...]}`)
/// - `GET    /rules/{id}`        → single
/// - `PATCH  /rules/{id}`        → partial update
/// - `DELETE /rules/{id}`        → remove
///
/// Любой write принимает `?rebuild=true` — после успешного write'а
/// регенерирует sing-box конфиг (см. [maybeRebuild]).
Future<DebugResponse> rulesHandler(DebugRequest req, DebugContext ctx) async {
  final path = req.path;

  if (path == '/rules') {
    return switch (req.method) {
      'GET' => _list(),
      'POST' => _create(req, ctx),
      _ => throw BadRequest('method ${req.method} not allowed on /rules'),
    };
  }

  if (path == '/rules/reorder') {
    if (req.method != 'POST') {
      throw BadRequest('reorder requires POST, got ${req.method}');
    }
    return _reorder(req);
  }

  if (path.startsWith('/rules/')) {
    final id = path.substring('/rules/'.length);
    if (id.isEmpty || id.contains('/')) {
      throw NotFound('rule path: $path');
    }
    return switch (req.method) {
      'GET' => _single(id),
      'PATCH' => _update(id, req, ctx),
      'DELETE' => _delete(id, req, ctx),
      _ => throw BadRequest('method ${req.method} not allowed on /rules/{id}'),
    };
  }

  throw NotFound('rules path: $path');
}

Future<DebugResponse> _list() async {
  final rules = await SettingsStorage.getCustomRules();
  final serialized = await Future.wait(rules.map(serializeCustomRule));
  return JsonResponse(serialized);
}

Future<DebugResponse> _single(String id) async {
  final rules = await SettingsStorage.getCustomRules();
  for (final r in rules) {
    if (r.id == id) {
      return JsonResponse(await serializeCustomRule(r));
    }
  }
  throw NotFound('rule: $id');
}

Future<DebugResponse> _create(DebugRequest req, DebugContext ctx) async {
  final body = req.jsonBodyAsMap();
  // id из body игнорируется — сервер всегда генерит fresh UUID.
  final stripped = Map<String, dynamic>.from(body)..remove('id');
  final rule = _ruleFromJsonStrict(stripped);
  final rules = await SettingsStorage.getCustomRules();
  rules.add(rule);
  await SettingsStorage.saveCustomRules(rules);
  final extras = await maybeRebuild(req, ctx);
  final serialized = await serializeCustomRule(rule);
  return JsonResponse({...serialized, ...extras}, status: 201);
}

Future<DebugResponse> _update(
  String id,
  DebugRequest req,
  DebugContext ctx,
) async {
  final body = req.jsonBodyAsMap();
  final rules = await SettingsStorage.getCustomRules();
  final idx = rules.indexWhere((r) => r.id == id);
  if (idx < 0) throw NotFound('rule: $id');
  // Патч через merge-в-JSON-then-fromJson: sealed-иерархия не позволяет
  // переключать kind через `copyWith`, но JSON round-trip это делает
  // естественно (spec §030, task 011).
  final current = rules[idx].toJson();
  final patched = <String, dynamic>{...current};
  void setIfPresent(String key, dynamic v) {
    if (v != null) patched[key] = v;
  }

  setIfPresent('name', fieldString(body, 'name'));
  setIfPresent('enabled', fieldBool(body, 'enabled'));
  final patchKind = _fieldKind(body, 'kind');
  if (patchKind != null) patched['kind'] = patchKind.name;
  setIfPresent('domains', fieldStringList(body, 'domains'));
  setIfPresent('domainSuffixes', fieldStringList(body, 'domain_suffixes'));
  setIfPresent('domainKeywords', fieldStringList(body, 'domain_keywords'));
  setIfPresent('ipCidrs', fieldStringList(body, 'ip_cidrs'));
  setIfPresent('ports', fieldStringList(body, 'ports'));
  setIfPresent('portRanges', fieldStringList(body, 'port_ranges'));
  setIfPresent('packages', fieldStringList(body, 'packages'));
  setIfPresent('protocols', fieldStringList(body, 'protocols'));
  setIfPresent('ipIsPrivate', fieldBool(body, 'ip_is_private'));
  setIfPresent('srsUrl', fieldString(body, 'srs_url'));
  setIfPresent('outbound', fieldString(body, 'outbound'));
  // Preset-kind поля (task 011 / spec §033).
  setIfPresent('presetId', fieldString(body, 'preset_id'));
  setIfPresent('varsValues', fieldStringMap(body, 'vars_values'));

  final updated = CustomRule.fromJson(patched);
  rules[idx] = updated;
  await SettingsStorage.saveCustomRules(rules);
  final extras = await maybeRebuild(req, ctx);
  final serialized = await serializeCustomRule(updated);
  return JsonResponse({...serialized, ...extras});
}

Future<DebugResponse> _delete(
  String id,
  DebugRequest req,
  DebugContext ctx,
) async {
  final rules = await SettingsStorage.getCustomRules();
  final idx = rules.indexWhere((r) => r.id == id);
  if (idx < 0) throw NotFound('rule: $id');
  rules.removeAt(idx);
  await SettingsStorage.saveCustomRules(rules);
  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({
    'ok': true,
    'action': 'rules-delete',
    'id': id,
    ...extras,
  });
}

Future<DebugResponse> _reorder(DebugRequest req) async {
  final body = req.jsonBodyAsMap();
  final order = fieldStringList(body, 'order');
  if (order == null) {
    throw const BadRequest('body must contain "order": [id, ...]');
  }
  final rules = await SettingsStorage.getCustomRules();
  if (order.length != rules.length) {
    throw BadRequest(
      'order length ${order.length} != current rule count ${rules.length}',
    );
  }
  final byId = {for (final r in rules) r.id: r};
  final missing = byId.keys.toSet().difference(order.toSet());
  final extra = order.toSet().difference(byId.keys.toSet());
  if (missing.isNotEmpty || extra.isNotEmpty) {
    throw BadRequest(
      'order must contain exactly the current rule IDs '
      '(missing: $missing, extra: $extra)',
    );
  }
  final reordered = order.map((id) => byId[id]!).toList();
  await SettingsStorage.saveCustomRules(reordered);
  return JsonResponse({
    'ok': true,
    'action': 'rules-reorder',
    'count': reordered.length,
  });
}

CustomRuleKind? _fieldKind(Map<String, dynamic> m, String key) {
  if (!m.containsKey(key)) return null;
  final v = m[key];
  if (v is! String) throw BadRequest('field "$key" must be string');
  for (final k in CustomRuleKind.values) {
    if (k.name == v) return k;
  }
  throw BadRequest('unknown kind: $v (expected inline|srs)');
}

/// Строгий парсинг для POST — отклоняет пустое `name`, wrong-types.
/// Отличается от `CustomRule.fromJson` который лояльно приводит значения.
/// Возвращает конкретный подкласс по `kind` (sealed dispatch).
CustomRule _ruleFromJsonStrict(Map<String, dynamic> j) {
  final name = fieldString(j, 'name') ?? '';
  if (name.trim().isEmpty) throw const BadRequest('field "name" required');
  final kind = _fieldKind(j, 'kind') ?? CustomRuleKind.inline;
  final enabled = fieldBool(j, 'enabled') ?? true;
  final outbound = fieldString(j, 'outbound') ?? 'direct-out';

  switch (kind) {
    case CustomRuleKind.inline:
      return CustomRuleInline(
        name: name,
        enabled: enabled,
        domains: fieldStringList(j, 'domains') ?? const [],
        domainSuffixes: fieldStringList(j, 'domain_suffixes') ?? const [],
        domainKeywords: fieldStringList(j, 'domain_keywords') ?? const [],
        ipCidrs: fieldStringList(j, 'ip_cidrs') ?? const [],
        ports: fieldStringList(j, 'ports') ?? const [],
        portRanges: fieldStringList(j, 'port_ranges') ?? const [],
        packages: fieldStringList(j, 'packages') ?? const [],
        protocols: fieldStringList(j, 'protocols') ?? const [],
        ipIsPrivate: fieldBool(j, 'ip_is_private') ?? false,
        outbound: outbound,
      );
    case CustomRuleKind.srs:
      return CustomRuleSrs(
        name: name,
        enabled: enabled,
        srsUrl: fieldString(j, 'srs_url') ?? '',
        ports: fieldStringList(j, 'ports') ?? const [],
        portRanges: fieldStringList(j, 'port_ranges') ?? const [],
        packages: fieldStringList(j, 'packages') ?? const [],
        protocols: fieldStringList(j, 'protocols') ?? const [],
        ipIsPrivate: fieldBool(j, 'ip_is_private') ?? false,
        outbound: outbound,
      );
    case CustomRuleKind.preset:
      final presetId = fieldString(j, 'preset_id') ?? '';
      if (presetId.isEmpty) {
        throw const BadRequest('field "preset_id" required for preset rules');
      }
      return CustomRulePreset(
        name: name,
        enabled: enabled,
        presetId: presetId,
        varsValues: fieldStringMap(j, 'vars_values'),
      );
  }
}
