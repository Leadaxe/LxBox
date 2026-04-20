import 'dart:async';

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
/// - `PATCH  /subs/{id}`          → update meta (enabled/name/url/...)
/// - `DELETE /subs/{id}`          → remove
/// - `POST   /subs/{id}/refresh`  → force refresh (HTTP fetch)
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

  // /subs/{id}/refresh
  if (path.endsWith('/refresh')) {
    final mid = path.substring('/subs/'.length, path.length - '/refresh'.length);
    if (mid.isEmpty || mid.contains('/')) {
      throw NotFound('subs path: $path');
    }
    if (req.method != 'POST') {
      throw BadRequest('refresh requires POST, got ${req.method}');
    }
    return _refresh(mid, req, ctx);
  }

  // /subs/{id}
  if (path.startsWith('/subs/')) {
    final id = path.substring('/subs/'.length);
    if (id.isEmpty || id.contains('/')) {
      throw NotFound('subs path: $path');
    }
    return switch (req.method) {
      'GET' => _single(id, ctx, req),
      'PATCH' => _update(id, req, ctx),
      'DELETE' => _delete(id, req, ctx),
      _ => throw BadRequest('method ${req.method} not allowed on /subs/{id}'),
    };
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
  if (sub.lastError.isNotEmpty && sub.entries.map((e) => e.id).toSet().length == before.length) {
    throw BadRequest('addFromInput rejected: ${sub.lastError}');
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
