import '../../../config/consts.dart' show kDirectOutboundTag;
import '../../../models/custom_rule.dart';
import '../../../models/parser_config.dart' show kUserRuleNumStart;
import '../../builder/rule_order.dart';
import '../../settings_storage.dart';
import '../../template_loader.dart';
import '../context.dart';
import '../contract/errors.dart';
import '../serializers/rules.dart';
import '../transport/request.dart';
import '../transport/response.dart';
import '_shared.dart';

/// §256 — тест-хук для чистого парсера тела правила (без storage/rebuild),
/// чтобы покрыть read/write симметрию DNS-полей. Суффикс `ForTest` —
/// конвенция «вызывать только из тестов» (meta-аннотацию не тянем в deps).
CustomRule ruleFromJsonStrictForTest(Map<String, dynamic> j) =>
    _ruleFromJsonStrict(j);

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
/// - `POST /rules/move`          → §370 переставить одно правило по оси `num`
///                                  (зеркало drag'а: `{id, after}`)
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

  // §370 — точечный move (зеркало drag'а в UI).
  if (path == '/rules/move') {
    if (req.method != 'POST') {
      throw BadRequest('move requires POST, got ${req.method}');
    }
    return _move(req);
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
  // §370 — тот же путь, что UI (`_addCustomRule`): пресет садится на свой
  // шаблонный `num`, пользовательское правило — в конец занятой части зоны.
  // Явный `num` в body уважаем: он нужен, чтобы гонять раскладку из тестов.
  rule.orderNum ??= rule.kind == CustomRuleKind.preset
      ? (await _templateNumFor(rule.presetId)) ?? nextUserRuleNum(rules)
      : nextUserRuleNum(rules);
  rules.add(rule);
  await SettingsStorage.saveCustomRules(sortRulesByNum(rules));
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
  // §240 — L4-транспорт (tcp/udp/icmp).
  setIfPresent('network', fieldStringList(body, 'network'));
  setIfPresent('ipIsPrivate', fieldBool(body, 'ip_is_private'));
  // §030/new_fields — source-ось + inbound.
  setIfPresent('sourceIpCidrs', fieldStringList(body, 'source_ip_cidrs'));
  setIfPresent('sourceIpIsPrivate', fieldBool(body, 'source_ip_is_private'));
  setIfPresent('inbounds', fieldStringList(body, 'inbounds'));
  // §051 — wifi-условия. `wifi_ssids` остаётся as-is, `wifi_bssids`
  // нормализуем lower-case на write-side для consistency.
  setIfPresent('wifiSsids', fieldStringList(body, 'wifi_ssids'));
  final patchBssids = fieldStringList(body, 'wifi_bssids');
  if (patchBssids != null) {
    patched['wifiBssids'] = _validateBssids(patchBssids);
  }
  setIfPresent('srsUrl', fieldString(body, 'srs_url'));
  setIfPresent('outbound', fieldString(body, 'outbound'));
  // Preset-kind поля (task 011 / spec §033).
  setIfPresent('presetId', fieldString(body, 'preset_id'));
  setIfPresent('varsValues', fieldStringMap(body, 'vars_values'));
  // §117 задача 3 — DNS-опция. `"dns": null` явно очищает поле.
  if (body.containsKey('dns')) {
    if (body['dns'] == null) {
      patched.remove('dns');
    } else {
      patched['dns'] = _fieldRuleDns(body, 'dns')!.toJson();
    }
  }
  // §247 — resolve-опция. `"resolve": null` явно очищает поле.
  if (body.containsKey('resolve')) {
    if (body['resolve'] == null) {
      patched.remove('resolve');
    } else {
      patched['resolve'] = _fieldRuleResolve(body, 'resolve')!.toJson();
    }
  }

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
  // §370 — порядок задаёт ось `num`, а не позиция в массиве: без пересчёта
  // перестановка молча откатывалась бы при следующей загрузке (sortRulesByNum
  // вернул бы всё по старым номерам). Несортируемые держат свой номер, поэтому
  // они обязаны остаться на своих местах — иначе запрос противоречит инварианту.
  final sortable = await _sortablePredicate();
  var cursor = kUserRuleNumStart;
  for (final r in reordered) {
    if (!sortable(r)) continue;
    cursor++;
    r.orderNum = cursor;
  }
  final result = sortRulesByNum(reordered);
  if (!_sameIds(result, reordered)) {
    throw const BadRequest(
      'requested order conflicts with pinned rules (isSortable:false must '
      'keep their template position)',
    );
  }
  await SettingsStorage.saveCustomRules(result);
  return JsonResponse({
    'ok': true,
    'action': 'rules-reorder',
    'count': result.length,
    'nums': {for (final r in result) r.id: r.orderNum},
  });
}

/// §370 — переставить ОДНО правило: точное зеркало drag'а в UI
/// (`_onReorderCustomRule` → `placeRuleAfter`). Тело:
/// `{"id": "<uuid>", "after": "<uuid>"|null}` — `after: null` = в начало
/// сортируемой части.
///
/// Существует ради тестируемости: без него порядок можно было проверить
/// только тапами по экрану, а `/rules/reorder` задаёт список целиком и не
/// проверяет ленивый сдвиг (сохранение зазоров и шаблонных якорей).
Future<DebugResponse> _move(DebugRequest req) async {
  final body = req.jsonBodyAsMap();
  final id = fieldString(body, 'id');
  if (id == null || id.isEmpty) {
    throw const BadRequest('body must contain "id": "<rule uuid>"');
  }
  if (!body.containsKey('after')) {
    throw const BadRequest('body must contain "after": "<rule uuid>" or null');
  }
  final afterRaw = body['after'];
  if (afterRaw != null && afterRaw is! String) {
    throw const BadRequest('field "after" must be string or null');
  }

  final rules = await SettingsStorage.getCustomRules();
  final moved = rules.where((r) => r.id == id).firstOrNull;
  if (moved == null) throw NotFound('rule: $id');

  CustomRule? target;
  if (afterRaw is String) {
    target = rules.where((r) => r.id == afterRaw).firstOrNull;
    if (target == null) throw NotFound('rule (after): $afterRaw');
    if (identical(target, moved)) {
      throw const BadRequest('"after" must differ from "id"');
    }
  }

  final sortable = await _sortablePredicate();
  if (!sortable(moved)) {
    throw const BadRequest('rule is not sortable (isSortable:false)');
  }

  // Разметка на случай storage до §370 — иначе `num` null и сдвиг некорректен.
  final template = await TemplateLoader.load();
  markRuleOrder(rules, template.selectableRules);

  placeRuleAfter(rules, moved, target, isSortable: sortable);
  final result = sortRulesByNum(rules);
  await SettingsStorage.saveCustomRules(result);
  return JsonResponse({
    'ok': true,
    'action': 'rules-move',
    'id': id,
    'after': afterRaw,
    'num': moved.orderNum,
    'order': [
      for (final r in result)
        {'id': r.id, 'name': r.name, 'preset_id': r.presetId, 'num': r.orderNum}
    ],
  });
}

/// §370 — предикат «правило можно двигать», построенный по шаблону.
/// Общий источник с UI (`_isSortable`): правило вне шаблона сортируемо.
Future<bool Function(CustomRule)> _sortablePredicate() async {
  final template = await TemplateLoader.load();
  final byId = {for (final sr in template.selectableRules) sr.presetId: sr};
  return (CustomRule r) {
    if (r.kind != CustomRuleKind.preset) return true;
    return byId[r.presetId]?.isSortable ?? true;
  };
}

/// §370 — шаблонный `num` пресета (null, если пресета в шаблоне нет).
Future<int?> _templateNumFor(String presetId) async {
  if (presetId.isEmpty) return null;
  final template = await TemplateLoader.load();
  for (final sr in template.selectableRules) {
    if (sr.presetId == presetId) return sr.num;
  }
  return null;
}

bool _sameIds(List<CustomRule> a, List<CustomRule> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].id != b[i].id) return false;
  }
  return true;
}

CustomRuleKind? _fieldKind(Map<String, dynamic> m, String key) {
  if (!m.containsKey(key)) return null;
  final v = m[key];
  if (v is! String) throw BadRequest('field "$key" must be string');
  for (final k in CustomRuleKind.values) {
    if (k.name == v) return k;
  }
  throw BadRequest('unknown kind: $v (expected inline|srs|preset|json)');
}

/// Строгий парсинг для POST — отклоняет пустое `name`, wrong-types.
/// Отличается от `CustomRule.fromJson` который лояльно приводит значения.
/// Возвращает конкретный подкласс по `kind` (sealed dispatch).
CustomRule _ruleFromJsonStrict(Map<String, dynamic> j) {
  final name = fieldString(j, 'name') ?? '';
  if (name.trim().isEmpty) throw const BadRequest('field "name" required');
  final kind = _fieldKind(j, 'kind') ?? CustomRuleKind.inline;
  final enabled = fieldBool(j, 'enabled') ?? true;
  final outbound = fieldString(j, 'outbound') ?? kDirectOutboundTag;

  // §051 — общие wifi-условия. Валидируем BSSID format строго (на read-side
  // в model — tolerant lower-case). Empty list / null → no condition.
  final wifiSsids = fieldStringList(j, 'wifi_ssids') ?? const [];
  final wifiBssidsRaw = fieldStringList(j, 'wifi_bssids') ?? const [];
  final wifiBssids = _validateBssids(wifiBssidsRaw);
  // §030/new_fields — source-ось + inbound (inline/srs).
  final sourceIpCidrs = fieldStringList(j, 'source_ip_cidrs') ?? const [];
  final sourceIpIsPrivate = fieldBool(j, 'source_ip_is_private') ?? false;
  final inbounds = fieldStringList(j, 'inbounds') ?? const [];
  // §117 задача 3 — DNS-опция (inline/srs).
  final dns = _fieldRuleDns(j, 'dns');
  // §247 — resolve-опция (inline/srs).
  final resolve = _fieldRuleResolve(j, 'resolve');

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
        network: fieldStringList(j, 'network') ?? const [],
        ipIsPrivate: fieldBool(j, 'ip_is_private') ?? false,
        sourceIpCidrs: sourceIpCidrs,
        sourceIpIsPrivate: sourceIpIsPrivate,
        inbounds: inbounds,
        wifiSsids: wifiSsids,
        wifiBssids: wifiBssids,
        outbound: outbound,
        dns: dns,
        resolve: resolve,
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
        network: fieldStringList(j, 'network') ?? const [],
        ipIsPrivate: fieldBool(j, 'ip_is_private') ?? false,
        sourceIpCidrs: sourceIpCidrs,
        sourceIpIsPrivate: sourceIpIsPrivate,
        inbounds: inbounds,
        wifiSsids: wifiSsids,
        wifiBssids: wifiBssids,
        outbound: outbound,
        dns: dns,
        resolve: resolve,
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
    case CustomRuleKind.json:
      // §225 — raw-JSON правило: тело в поле `json` (сырой текст route.rule).
      final body = fieldString(j, 'json') ?? '';
      if (body.trim().isEmpty) {
        throw const BadRequest('field "json" required for json rules');
      }
      return CustomRuleJson(name: name, enabled: enabled, json: body);
  }
}

/// §117 задача 3 / §256 — DNS-опция правила. Wire shape (snake_case как у
/// остальных полей API): `{"enabled": bool, "server_tag": dns-server-tag,
/// "force_ipv4": bool}`. Отсутствие ключа → null (поле не задано).
///
/// §256: `enabled`/`server_tag`/`force_ipv4` независимы — DNS-опция может
/// нести только Force IPv4 (глушилка AAAA серверу не нужна). Поэтому
/// `enabled` дефолтит в false, а `server_tag` обязателен ТОЛЬКО когда
/// `enabled == true` (dedicated-server-mirror без tag'а бессмыслен). Сервер
/// по tag не валидируем — пропавший реф build тихо не эмитит (решение №3).
RuleDns? _fieldRuleDns(Map<String, dynamic> m, String key) {
  if (!m.containsKey(key)) return null;
  final v = m[key];
  if (v is! Map) throw BadRequest('field "$key" must be object');
  final enabledRaw = v['enabled'];
  if (enabledRaw != null && enabledRaw is! bool) {
    throw BadRequest('field "$key.enabled" must be bool');
  }
  final enabled = enabledRaw == true;
  final forceRaw = v['force_ipv4'];
  if (forceRaw != null && forceRaw is! bool) {
    throw BadRequest('field "$key.force_ipv4" must be bool');
  }
  final forceIpv4 = forceRaw == true;
  final tagRaw = v['server_tag'];
  if (tagRaw != null && tagRaw is! String) {
    throw BadRequest('field "$key.server_tag" must be string');
  }
  final tag = (tagRaw as String?) ?? '';
  if (enabled && tag.isEmpty) {
    throw BadRequest(
        'field "$key.server_tag" must be non-empty when enabled is true');
  }
  return RuleDns(enabled: enabled, serverTag: tag, forceIpv4: forceIpv4);
}

/// §247 — resolve-опция правила. Wire shape (snake_case):
/// `{"only": bool, "strategy": "ipv4_only", "server_tag": "...",
///   "disable_cache": bool, "disable_optimistic_cache": bool,
///   "rewrite_ttl": uint, "timeout": "5s", "client_subnet": "1.2.3.0/24"}`.
/// Все поля кроме `only` опциональны. Отсутствие ключа → null (не задано).
RuleResolve? _fieldRuleResolve(Map<String, dynamic> m, String key) {
  if (!m.containsKey(key)) return null;
  final v = m[key];
  if (v is! Map) throw BadRequest('field "$key" must be object');
  const strategies = {'prefer_ipv4', 'prefer_ipv6', 'ipv4_only', 'ipv6_only'};
  final strategy = v['strategy']?.toString() ?? '';
  if (strategy.isNotEmpty && !strategies.contains(strategy)) {
    throw BadRequest(
        'field "$key.strategy" must be one of ${strategies.join('/')}');
  }
  // Strict bools — заданный ключ обязан быть bool (паттерн _fieldRuleDns);
  // отсутствие ключа = дефолт false.
  bool strictBool(String name) {
    final raw = v[name];
    if (raw == null) return false;
    if (raw is! bool) throw BadRequest('field "$key.$name" must be bool');
    return raw;
  }

  // rewrite_ttl: int или числовая строка; всё прочее (включая "abc") — 400,
  // а не тихо «не задано» (битое поле не должно молча теряться).
  final ttlRaw = v['rewrite_ttl'];
  final int? ttl;
  switch (ttlRaw) {
    case null:
      ttl = null;
    case final int n when n >= 0:
      ttl = n;
    case final String s when int.tryParse(s) != null && int.parse(s) >= 0:
      ttl = int.parse(s);
    default:
      throw BadRequest(
          'field "$key.rewrite_ttl" must be non-negative integer');
  }
  // timeout: duration-строка sing-box (та же проверка, что в UI-окне).
  final timeout = v['timeout']?.toString() ?? '';
  if (timeout.isNotEmpty && !RegExp(r'^\d+(ms|s|m|h)$').hasMatch(timeout)) {
    throw BadRequest('field "$key.timeout" must be duration (e.g. "5s")');
  }
  // client_subnet: IP или CIDR — битое значение валит конфиг на старте ядра,
  // поэтому режем на входе.
  final subnet = v['client_subnet']?.toString() ?? '';
  if (subnet.isNotEmpty && !_clientSubnetPattern.hasMatch(subnet)) {
    throw BadRequest(
        'field "$key.client_subnet" must be IP or CIDR (e.g. "1.2.3.0/24")');
  }
  return RuleResolve(
    only: strictBool('only'),
    strategy: strategy,
    serverTag: v['server_tag']?.toString() ?? '',
    disableCache: strictBool('disable_cache'),
    disableOptimisticCache: strictBool('disable_optimistic_cache'),
    rewriteTtl: ttl,
    timeout: timeout,
    clientSubnet: subnet,
  );
}

/// §247 — IPv4/IPv6-адрес с опциональным /prefix (лёгкая структурная
/// проверка; полную семантику проверит ядро).
final RegExp _clientSubnetPattern = RegExp(
    r'^([0-9]{1,3}(\.[0-9]{1,3}){3}|[0-9A-Fa-f:]+:[0-9A-Fa-f:]*)(/\d{1,3})?$');

/// §051 — strict BSSID validation для Debug API (write-side).
/// Принимает `xx:xx:xx:xx:xx:xx` (case-insensitive), нормализует к lower-case.
/// На любую невалидную строку — `BadRequest` с конкретным offending value.
final RegExp _bssidPattern =
    RegExp(r'^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$');

List<String> _validateBssids(List<String> raw) {
  final out = <String>[];
  for (final b in raw) {
    final trimmed = b.trim();
    if (!_bssidPattern.hasMatch(trimmed)) {
      throw BadRequest(
        'invalid wifi_bssid "$b" (expected xx:xx:xx:xx:xx:xx)',
      );
    }
    out.add(trimmed.toLowerCase());
  }
  return out;
}
