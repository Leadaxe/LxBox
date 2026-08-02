import 'dart:async';

import '../../../controllers/subscription_controller.dart';
import '../../../models/import_rule.dart';
import '../../../models/server_list.dart';
import '../context.dart';
import '../contract/errors.dart';
import '../serializers/subs.dart';
import '../transport/request.dart';
import '../transport/response.dart';
import '_shared.dart';

/// `/subs/*` — CRUD для subscriptions / user servers.
///
/// Не дёргает `SettingsStorage` напрямую — идёт через публичные методы
/// `SubscriptionController`, которые несут дополнительную логику
/// (configDirty флаг, notifyListeners для UI, fetch-state машину).
///
/// Routes:
/// - `GET    /subs`               → list (alias для /state/subs)
/// - `POST   /subs`               → create (body: `{"input":"<url|URI|WG|JSON>"}`)
/// - `POST   /subs/reorder`       → reorder (body: `{"order":[id,...]}`)
/// - `GET    /subs/{id}`          → single
/// - `PATCH  /subs/{id}`          → update meta (enabled/name/url/identity/...)
/// - `DELETE /subs/{id}`          → remove
/// - `POST   /subs/{id}/refresh`  → force refresh (HTTP fetch)
///
/// §346 — import-правила подписки (§302) под-ресурсом (список упорядоченный и
/// потенциально длинный — целиком в PATCH его слать нельзя: гонка двух
/// клиентов затирала бы правки, и нет адресации к одному правилу):
/// - `GET    /subs/{id}/rules`          → набор + общий тумблер
/// - `POST   /subs/{id}/rules[?index=N]`→ create (201), по умолчанию в конец
/// - `GET    /subs/{id}/rules/{idx}`    → single
/// - `PATCH  /subs/{id}/rules/{idx}`    → subset полей правила
/// - `DELETE /subs/{id}/rules/{idx}`    → remove
/// - `POST   /subs/{id}/rules/reorder`  → `{"order":[старые индексы]}`
///
/// Все write'ы принимают `?rebuild=true` — авторегенерация конфига после.
/// `?reveal=true` (как в `/state/subs`) — не маскирует subscription URL в
/// ответе. POST `input` и PATCH `url` всегда принимают clear URL.
Future<DebugResponse> subsHandler(DebugRequest req, DebugContext ctx) async {
  final path = req.path;

  if (path == '/subs') {
    return switch (req.method) {
      'GET' => _list(ctx, req),
      'POST' => _create(req, ctx),
      _ => throw BadRequest('method ${req.method} not allowed on /subs'),
    };
  }

  if (path == '/subs/reorder') {
    if (req.method != 'POST') {
      throw BadRequest('reorder requires POST, got ${req.method}');
    }
    return _reorder(req, ctx);
  }

  if (!path.startsWith('/subs/')) throw NotFound('subs path: $path');
  final segs = path.substring('/subs/'.length).split('/');
  final id = segs.first;
  if (id.isEmpty) throw NotFound('subs path: $path');

  // /subs/{id}
  if (segs.length == 1) {
    return switch (req.method) {
      'GET' => _single(id, ctx, req),
      'PATCH' => _update(id, req, ctx),
      'DELETE' => _delete(id, req, ctx),
      _ => throw BadRequest('method ${req.method} not allowed on /subs/{id}'),
    };
  }

  // /subs/{id}/refresh
  if (segs.length == 2 && segs[1] == 'refresh') {
    if (req.method != 'POST') {
      throw BadRequest('refresh requires POST, got ${req.method}');
    }
    return _refresh(id, req, ctx);
  }

  // §346 — /subs/{id}/rules[...] — import-правила §302.
  if (segs[1] == 'rules') {
    // /subs/{id}/rules
    if (segs.length == 2) {
      return switch (req.method) {
        'GET' => _rulesList(id, req, ctx),
        'POST' => _rulesCreate(id, req, ctx),
        _ => throw BadRequest(
            'method ${req.method} not allowed on /subs/{id}/rules'),
      };
    }
    // /subs/{id}/rules/reorder
    if (segs.length == 3 && segs[2] == 'reorder') {
      if (req.method != 'POST') {
        throw BadRequest('reorder requires POST, got ${req.method}');
      }
      return _rulesReorder(id, req, ctx);
    }
    // /subs/{id}/rules/{idx}
    if (segs.length == 3) {
      final ruleIdx = int.tryParse(segs[2]);
      if (ruleIdx == null) throw NotFound('rule index: ${segs[2]}');
      return switch (req.method) {
        'GET' => _rulesSingle(id, ruleIdx, req, ctx),
        'PATCH' => _rulesUpdate(id, ruleIdx, req, ctx),
        'DELETE' => _rulesDelete(id, ruleIdx, req, ctx),
        _ => throw BadRequest(
            'method ${req.method} not allowed on /subs/{id}/rules/{idx}'),
      };
    }
  }

  throw NotFound('subs path: $path');
}

Future<DebugResponse> _list(DebugContext ctx, DebugRequest req) async {
  final sub = ctx.requireSub();
  final reveal = req.qBool('reveal');
  final entries = sub.entries.map((e) => serializeSubEntry(e, reveal: reveal)).toList();
  return JsonResponse(entries);
}

Future<DebugResponse> _single(String id, DebugContext ctx, DebugRequest req) async {
  final sub = ctx.requireSub();
  final reveal = req.qBool('reveal');
  for (final e in sub.entries) {
    if (e.id == id) {
      return JsonResponse(serializeSubEntry(e, reveal: reveal));
    }
  }
  throw NotFound('sub: $id');
}

Future<DebugResponse> _create(DebugRequest req, DebugContext ctx) async {
  final body = req.jsonBodyAsMap();
  final input = fieldString(body, 'input') ?? '';
  if (input.trim().isEmpty) {
    throw const BadRequest('field "input" required (url|URI|WG|JSON)');
  }
  final sub = ctx.requireSub();
  final before = sub.entries.map((e) => e.id).toSet();
  await sub.addFromInput(input);
  // Если controller записал lastError — input отвергнут целиком, ничего не добавилось.
  if (sub.lastError != null &&
      sub.entries.map((e) => e.id).toSet().length == before.length) {
    throw BadRequest(
        'addFromInput rejected: ${sub.lastError?.renderEn() ?? ''}');
  }
  // Находим новую запись (или записи — JSON outbounds могут создать несколько).
  final added = sub.entries.where((e) => !before.contains(e.id)).toList();
  final extras = await maybeRebuild(req, ctx);
  if (added.length == 1) {
    return JsonResponse({
      'ok': true,
      'action': 'subs-add',
      'id': added.first.id,
      'kind': added.first.list is SubscriptionServers
          ? 'SubscriptionServers'
          : 'UserServer',
      ...extras,
    }, status: 201);
  }
  return JsonResponse({
    'ok': true,
    'action': 'subs-add',
    'ids': added.map((e) => e.id).toList(),
    'count': added.length,
    ...extras,
  }, status: 201);
}

Future<DebugResponse> _update(
  String id,
  DebugRequest req,
  DebugContext ctx,
) async {
  final body = req.jsonBodyAsMap();
  final sub = ctx.requireSub();
  final idx = sub.entries.indexWhere((e) => e.id == id);
  if (idx < 0) throw NotFound('sub: $id');
  final entry = sub.entries[idx];

  // Простые setter'ы через SubscriptionEntry — они мутируют wrapped list
  // через copyWith, после всех изменений дёргаем persistSources().
  final name = fieldString(body, 'name');
  if (name != null) entry.name = name;
  final enabled = fieldBool(body, 'enabled');
  if (enabled != null) entry.enabled = enabled;
  final tagPrefix = fieldString(body, 'tag_prefix');
  if (tagPrefix != null) entry.tagPrefix = tagPrefix;
  final interval = fieldInt(body, 'update_interval_hours');
  if (interval != null) entry.updateIntervalHours = interval;
  final overrideDetour = fieldString(body, 'override_detour');
  if (overrideDetour != null) entry.overrideDetour = overrideDetour;
  final regDetourServers = fieldBool(body, 'register_detour_servers');
  if (regDetourServers != null) entry.registerDetourServers = regDetourServers;
  final regDetourInAuto = fieldBool(body, 'register_detour_in_auto');
  if (regDetourInAuto != null) entry.registerDetourInAuto = regDetourInAuto;
  final useDetour = fieldBool(body, 'use_detour_servers');
  if (useDetour != null) entry.useDetourServers = useDetour;
  // §073 — был пропущен (асимметрия: соседние detour-поля маппились, это нет).
  final replaceDetour = fieldBool(body, 'replace_detour_chain');
  if (replaceDetour != null) entry.replaceDetourChain = replaceDetour;

  // §346 — поля SubscriptionServers, ранее недоступные headless-пути (тот же
  // класс дефекта, что §073 выше). Setter'ы — no-op для не-подписок.

  // §323 — реакция на успешное авто-обновление.
  final onUpdate = fieldString(body, 'on_update_action');
  if (onUpdate != null) {
    // Строго, в отличие от толерантного fromJson: там мусор → дефолт (защита
    // загрузки storage), здесь это превратило бы опечатку в тихо другое
    // поведение.
    final parsed = SubscriptionOnUpdateAction.values
        .where((a) => a.name == onUpdate)
        .firstOrNull;
    if (parsed == null) {
      throw BadRequest('on_update_action must be one of '
          '${SubscriptionOnUpdateAction.values.map((a) => a.name).join('|')}, '
          'got "$onUpdate"');
    }
    entry.onUpdateAction = parsed;
  }

  // §302 — общий тумблер набора import-правил (сами правила — /subs/{id}/rules).
  final rulesEnabled = fieldBool(body, 'import_rules_enabled');
  if (rulesEnabled != null) entry.importRulesEnabled = rulesEnabled;

  // §289 — identity: тристейт, поэтому не через field*-хелперы (они не
  // отличают «ключ отсутствует» от «ключ = null»).
  if (body.containsKey('identity')) {
    _applyIdentity(entry, body['identity']);
  }

  // URL — только для SubscriptionServers. Для UserServer молча игнорируем
  // (как и в UI: URL у inline-сервера просто нет).
  final newUrl = fieldString(body, 'url');
  if (newUrl != null) {
    final list = entry.list;
    if (list is SubscriptionServers) {
      await sub.replaceList(idx, list.copyWith(url: newUrl));
    }
    // UserServer — no-op.
  }

  // persist изменения setter'ов (replaceList уже persist'ит своё).
  await sub.persistSources();

  final reveal = req.qBool('reveal');
  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({
    ...serializeSubEntry(entry, reveal: reveal),
    ...extras,
  });
}

/// §346/§289 — применяет `identity` из PATCH-body. Тристейт:
///
/// - `null`  → Custom off (вернуться к глобальной идентичности §118);
/// - объект  → Custom on + наложение переданных полей **поверх слепка**.
///
/// Патч, а не полная замена: типовой вызов — «включить HWID этой подписке»
/// (`{"send_hwid":true,"hwid":"…"}`), и он не должен попутно обнулять UA и
/// device-meta. Если Custom ещё не активен, слепок сначала инициализируется
/// копией глобальных значений — ровно как `enableCustomIdentity` в UI.
///
/// No-op для не-подписок (у UserServer/FolderServers идентичности фетча нет —
/// их никто не фетчит).
void _applyIdentity(SubscriptionEntry entry, Object? raw) {
  if (raw == null) {
    entry.disableCustomIdentity();
    return;
  }
  if (raw is! Map) {
    throw BadRequest('field "identity" must be object or null, '
        'got ${raw.runtimeType}');
  }
  final body = raw.cast<String, dynamic>();
  const known = {
    'user_agent',
    'send_hwid',
    'hwid',
    'device_os',
    'ver_os',
    'device_model',
  };
  // Опечатка в ключе иначе молча не сработала бы: слепок остался бы прежним,
  // а ответ 200 выглядел бы как успех.
  final unknown = body.keys.where((k) => !known.contains(k)).toList();
  if (unknown.isNotEmpty) {
    throw BadRequest('identity: unknown field(s) ${unknown.join(', ')}; '
        'allowed: ${known.join(', ')}');
  }

  entry.enableCustomIdentity(); // no-op если Custom уже активен
  final current = entry.identity;
  if (current == null) return; // не-подписка: enable был no-op

  entry.updateIdentity(current.copyWith(
    userAgent: fieldString(body, 'user_agent'),
    sendHwid: fieldBool(body, 'send_hwid'),
    hwid: fieldString(body, 'hwid'),
    deviceOs: fieldString(body, 'device_os'),
    verOs: fieldString(body, 'ver_os'),
    deviceModel: fieldString(body, 'device_model'),
  ));
}

Future<DebugResponse> _delete(
  String id,
  DebugRequest req,
  DebugContext ctx,
) async {
  final sub = ctx.requireSub();
  final idx = sub.entries.indexWhere((e) => e.id == id);
  if (idx < 0) throw NotFound('sub: $id');
  await sub.removeAt(idx);
  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({
    'ok': true,
    'action': 'subs-delete',
    'id': id,
    ...extras,
  });
}

Future<DebugResponse> _refresh(
  String id,
  DebugRequest req,
  DebugContext ctx,
) async {
  final sub = ctx.requireSub();
  final idx = sub.entries.indexWhere((e) => e.id == id);
  if (idx < 0) throw NotFound('sub: $id');
  final entry = sub.entries[idx];
  if (entry.list is! SubscriptionServers) {
    throw const Conflict('refresh requires SubscriptionServers (UserServer has no URL)');
  }
  // Fire-and-forget: долгий HTTP fetch, не держим TCP-коннект открытым.
  unawaited(sub.refreshEntry(entry));
  return JsonResponse({
    'ok': true,
    'action': 'subs-refresh',
    'id': id,
  });
}

Future<DebugResponse> _reorder(DebugRequest req, DebugContext ctx) async {
  final body = req.jsonBodyAsMap();
  final order = fieldStringList(body, 'order');
  if (order == null) {
    throw const BadRequest('body must contain "order": [id, ...]');
  }
  final sub = ctx.requireSub();
  final current = sub.entries.map((e) => e.id).toList();
  if (order.length != current.length) {
    throw BadRequest(
      'order length ${order.length} != current sub count ${current.length}',
    );
  }
  final missing = current.toSet().difference(order.toSet());
  final extra = order.toSet().difference(current.toSet());
  if (missing.isNotEmpty || extra.isNotEmpty) {
    throw BadRequest(
      'order must contain exactly the current sub IDs '
      '(missing: $missing, extra: $extra)',
    );
  }
  // moveEntry by-one от текущей позиции до target'а. O(n²) но n обычно ≤10.
  for (var targetIdx = 0; targetIdx < order.length; targetIdx++) {
    final id = order[targetIdx];
    final curIdx = sub.entries.indexWhere((e) => e.id == id);
    if (curIdx != targetIdx) {
      await sub.moveEntry(curIdx, targetIdx);
    }
  }
  return JsonResponse({
    'ok': true,
    'action': 'subs-reorder',
    'count': order.length,
  });
}

// ─────────────────────────── §346 — import rules (§302) ───────────────────────
//
// Правила — упорядоченная коллекция без id: порядок значим (применяются
// последовательно, последнее сработавшее enable/disable побеждает, §332).
// Адресация позиционным индексом — как у членов папки в §238, с той же
// оговоркой: после DELETE/reorder индексы съезжают, следующий вызов строить по
// свежему снапшоту из ответа (все write'ы его возвращают в `rules`).

(int, SubscriptionEntry, SubscriptionServers) _requireSubscription(
  SubscriptionController sub,
  String id,
) {
  final idx = sub.entries.indexWhere((e) => e.id == id);
  if (idx < 0) throw NotFound('sub: $id');
  final entry = sub.entries[idx];
  final list = entry.list;
  if (list is! SubscriptionServers) {
    throw Conflict('entry $id is ${list.type}, not a subscription '
        '(import rules apply to fetched bodies only)');
  }
  return (idx, entry, list);
}

int _ruleIndex(int i, SubscriptionServers list) {
  if (i < 0 || i >= list.importRules.length) {
    throw NotFound('rule index $i out of range '
        '(subscription has ${list.importRules.length} rule(s))');
  }
  return i;
}

List<Map<String, Object?>> _serializeRules(SubscriptionServers list) => [
      for (var i = 0; i < list.importRules.length; i++)
        serializeImportRule(list.importRules[i], i),
    ];

/// Общий хвост write'ов: persist + `?rebuild` + свежий снапшот набора.
///
/// `?rebuild=true` здесь почти всегда бесполезен (правила применяются на
/// СЛЕДУЮЩЕМ refresh, существующие ноды на месте не переразбираются — §302),
/// но принимается для единообразия со всеми write'ами Debug API.
Future<DebugResponse> _rulesWriteResponse(
  SubscriptionController sub,
  SubscriptionEntry entry,
  String action,
  DebugRequest req,
  DebugContext ctx, {
  int status = 200,
  Map<String, Object?> extra = const {},
}) async {
  await sub.persistSources();
  final list = entry.list as SubscriptionServers;
  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({
    'ok': true,
    'action': action,
    'id': entry.id,
    ...extra,
    'rules': _serializeRules(list),
    ...extras,
  }, status: status);
}

/// Строгий парс правила из body. В отличие от толерантного [ImportRule.fromJson]
/// (мусор в storage не должен ронять загрузку) здесь enum'ы проверяются по
/// закрытым спискам: иначе `{"action":"replase"}` молча стало бы `replace`.
///
/// [base] — правило, поверх которого накладываются переданные поля (PATCH);
/// `null` — создание с нуля (POST), пропущенные поля берут дефолты модели.
ImportRule _parseRule(Map<String, dynamic> body, {ImportRule? base}) {
  const known = {
    'conditions',
    'match',
    'action',
    'target_path',
    'replacement',
    'replace_mode',
    'substitute',
    'enabled',
  };
  final unknown = body.keys.where((k) => !known.contains(k)).toList();
  if (unknown.isNotEmpty) {
    throw BadRequest('rule: unknown field(s) ${unknown.join(', ')}; '
        'allowed: ${known.join(', ')}');
  }

  T enumField<T extends Enum>(String key, List<T> values) {
    final raw = fieldString(body, key);
    if (raw == null) throw StateError('unreachable'); // caller проверил ключ
    final hit = values.where((v) => v.name == raw).firstOrNull;
    if (hit == null) {
      throw BadRequest('$key must be one of '
          '${values.map((v) => v.name).join('|')}, got "$raw"');
    }
    return hit;
  }

  List<ImportRuleCondition>? conditions;
  if (body.containsKey('conditions')) {
    final raw = body['conditions'];
    if (raw is! List) {
      throw BadRequest('field "conditions" must be array, '
          'got ${raw.runtimeType}');
    }
    conditions = [
      for (var i = 0; i < raw.length; i++)
        _parseCondition(raw[i], i),
    ];
  }

  final start = base ?? const ImportRule();
  return start.copyWith(
    conditions: conditions,
    matchMode: body.containsKey('match')
        ? enumField('match', ImportRuleMatchMode.values)
        : null,
    action: body.containsKey('action')
        ? enumField('action', ImportRuleAction.values)
        : null,
    targetPath: fieldString(body, 'target_path'),
    replacement: fieldString(body, 'replacement'),
    replaceMode: body.containsKey('replace_mode')
        ? enumField('replace_mode', ImportRuleReplaceMode.values)
        : null,
    substitutePattern: fieldString(body, 'substitute'),
    enabled: fieldBool(body, 'enabled'),
  );
}

ImportRuleCondition _parseCondition(Object? raw, int i) {
  if (raw is! Map) {
    throw BadRequest('conditions[$i] must be object, got ${raw.runtimeType}');
  }
  final c = raw.cast<String, dynamic>();
  const known = {'path', 'op', 'pattern', 'negate', 'case_sensitive'};
  final unknown = c.keys.where((k) => !known.contains(k)).toList();
  if (unknown.isNotEmpty) {
    throw BadRequest('conditions[$i]: unknown field(s) ${unknown.join(', ')}; '
        'allowed: ${known.join(', ')}');
  }
  final opRaw = fieldString(c, 'op');
  final op = opRaw == null
      ? ImportRuleOperator.contains
      : (ImportRuleOperator.values.where((v) => v.name == opRaw).firstOrNull ??
          (throw BadRequest('conditions[$i].op must be one of '
              '${ImportRuleOperator.values.map((v) => v.name).join('|')}, '
              'got "$opRaw"')));
  return ImportRuleCondition(
    path: fieldString(c, 'path') ?? '',
    op: op,
    pattern: fieldString(c, 'pattern') ?? '',
    negate: fieldBool(c, 'negate') ?? false,
    caseSensitive: fieldBool(c, 'case_sensitive') ?? false,
  );
}

Future<DebugResponse> _rulesList(
  String id,
  DebugRequest req,
  DebugContext ctx,
) async {
  final sub = ctx.requireSub();
  final (_, _, list) = _requireSubscription(sub, id);
  return JsonResponse({
    'id': id,
    'import_rules_enabled': list.importRulesEnabled,
    'rules': _serializeRules(list),
  });
}

Future<DebugResponse> _rulesSingle(
  String id,
  int ruleIdx,
  DebugRequest req,
  DebugContext ctx,
) async {
  final sub = ctx.requireSub();
  final (_, _, list) = _requireSubscription(sub, id);
  final i = _ruleIndex(ruleIdx, list);
  return JsonResponse(serializeImportRule(list.importRules[i], i));
}

/// `?index=N` — вставка в позицию (порядок значим); по умолчанию в конец.
Future<DebugResponse> _rulesCreate(
  String id,
  DebugRequest req,
  DebugContext ctx,
) async {
  final body = req.jsonBodyAsMap();
  final sub = ctx.requireSub();
  final (_, entry, list) = _requireSubscription(sub, id);
  final rule = _parseRule(body);

  final rules = [...list.importRules];
  final at = req.qInt('index') ?? rules.length;
  if (at < 0 || at > rules.length) {
    throw BadRequest('index $at out of range (0..${rules.length})');
  }
  rules.insert(at, rule);
  entry.updateImportRules(rules);

  return _rulesWriteResponse(
    sub, entry, 'subs-rule-add', req, ctx,
    status: 201,
    extra: {'index': at, 'usable': rule.isUsable},
  );
}

Future<DebugResponse> _rulesUpdate(
  String id,
  int ruleIdx,
  DebugRequest req,
  DebugContext ctx,
) async {
  final body = req.jsonBodyAsMap();
  final sub = ctx.requireSub();
  final (_, entry, list) = _requireSubscription(sub, id);
  final i = _ruleIndex(ruleIdx, list);

  final next = _parseRule(body, base: list.importRules[i]);
  final rules = [...list.importRules]..[i] = next;
  entry.updateImportRules(rules);

  return _rulesWriteResponse(
    sub, entry, 'subs-rule-update', req, ctx,
    extra: {'index': i, 'usable': next.isUsable},
  );
}

Future<DebugResponse> _rulesDelete(
  String id,
  int ruleIdx,
  DebugRequest req,
  DebugContext ctx,
) async {
  final sub = ctx.requireSub();
  final (_, entry, list) = _requireSubscription(sub, id);
  final i = _ruleIndex(ruleIdx, list);

  final rules = [...list.importRules]..removeAt(i);
  entry.updateImportRules(rules);

  return _rulesWriteResponse(
    sub, entry, 'subs-rule-delete', req, ctx,
    extra: {'index': i},
  );
}

Future<DebugResponse> _rulesReorder(
  String id,
  DebugRequest req,
  DebugContext ctx,
) async {
  final body = req.jsonBodyAsMap();
  final order = fieldIntList(body, 'order');
  if (order == null) {
    throw const BadRequest(
        'body must contain "order": [old rule indexes in new order]');
  }
  final sub = ctx.requireSub();
  final (_, entry, list) = _requireSubscription(sub, id);
  final n = list.importRules.length;
  if (order.length != n ||
      order.toSet().length != n ||
      order.any((i) => i < 0 || i >= n)) {
    throw BadRequest(
        'order must be a full permutation of rule indexes 0..${n - 1}');
  }

  entry.updateImportRules([for (final i in order) list.importRules[i]]);

  return _rulesWriteResponse(
    sub, entry, 'subs-rules-reorder', req, ctx,
    extra: {'count': n},
  );
}
