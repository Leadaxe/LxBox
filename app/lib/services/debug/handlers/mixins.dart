import '../../../models/mixin.dart';
import '../../mixins/mixin_apply.dart';
import '../../mixins/mixin_path.dart';
import '../../mixins/mixin_preview.dart';
import '../../settings_storage.dart';
import '../context.dart';
import '../contract/errors.dart';
import '../transport/request.dart';
import '../transport/response.dart';
import '_shared.dart';

/// §704 — `/mixins/*` — CRUD миксинов итогового конфига.
///
/// Routes:
/// - `GET    /mixins`              → list (порядок = порядок применения)
/// - `POST   /mixins`              → create (body: `{"target","op","value",
///                                   "name"?,"enabled"?}`) → 201, в конец
/// - `POST   /mixins/reorder`      → `{"order":[id,...]}` — ровно текущие id
/// - `GET    /mixins/{id}`         → single
/// - `PATCH  /mixins/{id}`         → partial update (`id` неизменяем)
/// - `DELETE /mixins/{id}`         → remove
/// - `GET    /mixins/{id}/preview` → то же, что форма: совпадения, отказ,
///                                   фрагмент родителя цели после применения
///
/// Запись проверяет синтаксис пути и глагол (400) — совпадения нет: цель
/// может появиться после другого миксина или пересборки, отказ на сборке —
/// fatal `MixinIssue` с `mixin_id`. Все write'ы принимают `?rebuild=true`.
Future<DebugResponse> mixinsHandler(DebugRequest req, DebugContext ctx) async {
  final path = req.path;

  if (path == '/mixins') {
    return switch (req.method) {
      'GET' => _list(),
      'POST' => _create(req, ctx),
      _ => throw BadRequest('method ${req.method} not allowed on /mixins'),
    };
  }

  if (path == '/mixins/reorder') {
    if (req.method != 'POST') {
      throw BadRequest('reorder requires POST, got ${req.method}');
    }
    return _reorder(req, ctx);
  }

  if (path.startsWith('/mixins/')) {
    final rest = path.substring('/mixins/'.length);
    if (rest.endsWith('/preview')) {
      final id = rest.substring(0, rest.length - '/preview'.length);
      if (id.isEmpty || id.contains('/')) throw NotFound('mixins path: $path');
      if (req.method != 'GET') {
        throw BadRequest('preview requires GET, got ${req.method}');
      }
      return _preview(id, ctx);
    }
    if (rest.isEmpty || rest.contains('/')) {
      throw NotFound('mixins path: $path');
    }
    return switch (req.method) {
      'GET' => _single(rest),
      'PATCH' => _update(rest, req, ctx),
      'DELETE' => _delete(rest, req, ctx),
      _ => throw BadRequest('method ${req.method} not allowed on /mixins/{id}'),
    };
  }

  throw NotFound('mixins path: $path');
}

Future<DebugResponse> _list() async {
  final mixins = await SettingsStorage.getMixins();
  return JsonResponse([for (final m in mixins) m.toJson()]);
}

Future<(List<Mixin>, int)> _find(String id) async {
  final mixins = (await SettingsStorage.getMixins()).toList();
  final i = mixins.indexWhere((m) => m.id == id);
  if (i < 0) throw NotFound('mixin: $id');
  return (mixins, i);
}

Future<DebugResponse> _single(String id) async {
  final (mixins, i) = await _find(id);
  return JsonResponse(mixins[i].toJson());
}

/// Проверка записи: путь разбирается, глагол из семи. Совпадения не
/// требуются (см. doc обработчика).
void _validate(Mixin m) {
  final parsed = parseMixinPath(m.target);
  if (parsed is MixinPathError) {
    throw BadRequest('field "target": syntax error at ${parsed.offset}: '
        '${parsed.message}');
  }
  if (m.opKind == null) {
    throw BadRequest('field "op" must be one of '
        '${MixinOp.values.map((o) => o.name).join('|')}, got "${m.op}"');
  }
  if (m.opKind == MixinOp.remove) {
    final v = m.value;
    final keys = v is List && v.every((k) => k is String);
    if (v != true && !keys) {
      throw const BadRequest(
          'remove expects "value": true or a list of key strings');
    }
  }
}

Future<DebugResponse> _create(DebugRequest req, DebugContext ctx) async {
  final body = req.jsonBodyAsMap();
  if (body.containsKey('id')) {
    throw const BadRequest('field "id" is assigned by the app');
  }
  final target = fieldString(body, 'target');
  final op = fieldString(body, 'op');
  if (target == null || op == null) {
    throw const BadRequest('body must contain "target" and "op"');
  }
  final m = Mixin(
    name: fieldString(body, 'name') ?? '',
    enabled: fieldBool(body, 'enabled') ?? true,
    target: target,
    op: op,
    value: body['value'],
  );
  _validate(m);
  final mixins = (await SettingsStorage.getMixins()).toList()..add(m);
  await SettingsStorage.setMixins(mixins);
  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({...m.toJson(), ...extras}, status: 201);
}

Future<DebugResponse> _update(
    String id, DebugRequest req, DebugContext ctx) async {
  final body = req.jsonBodyAsMap();
  if (body.containsKey('id')) {
    throw const BadRequest('field "id" is immutable');
  }
  final (mixins, i) = await _find(id);
  final next = mixins[i].copyWith(
    name: fieldString(body, 'name'),
    enabled: fieldBool(body, 'enabled'),
    target: fieldString(body, 'target'),
    op: fieldString(body, 'op'),
    value: body.containsKey('value') ? body['value'] : mixins[i].value,
  );
  _validate(next);
  mixins[i] = next;
  await SettingsStorage.setMixins(mixins);
  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({...next.toJson(), ...extras});
}

Future<DebugResponse> _delete(
    String id, DebugRequest req, DebugContext ctx) async {
  final (mixins, i) = await _find(id);
  mixins.removeAt(i);
  await SettingsStorage.setMixins(mixins);
  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({
    'ok': true,
    'action': 'mixins-delete',
    'id': id,
    ...extras,
  });
}

Future<DebugResponse> _reorder(DebugRequest req, DebugContext ctx) async {
  final body = req.jsonBodyAsMap();
  final order = fieldStringList(body, 'order');
  if (order == null) {
    throw const BadRequest('body must contain "order": [id, ...]');
  }
  final mixins = await SettingsStorage.getMixins();
  final current = [for (final m in mixins) m.id];
  final missing = current.toSet().difference(order.toSet());
  final extra = order.toSet().difference(current.toSet());
  if (order.length != current.length ||
      missing.isNotEmpty ||
      extra.isNotEmpty) {
    throw BadRequest('order must contain exactly the current mixin ids '
        '(missing: $missing, extra: $extra)');
  }
  final byId = {for (final m in mixins) m.id: m};
  await SettingsStorage.setMixins([for (final id in order) byId[id]!]);
  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({
    'ok': true,
    'action': 'mixins-reorder',
    'count': order.length,
    ...extras,
  });
}

/// База — конфиг последней сборки ДО миксинов с применёнными миксинами выше
/// этого: собранный конфиг уже несёт включённые миксины, и предпросмотр по
/// нему применил бы миксин дважды. Сборки в сессии не было — 409.
Future<DebugResponse> _preview(String id, DebugContext ctx) async {
  final (mixins, i) = await _find(id);
  final base = ctx.requireSub().lastConfigBeforeMixins;
  if (base == null) {
    throw const Conflict('no config built in this session yet: rebuild '
        'first (any write with ?rebuild=true)');
  }
  final at = mixinPreviewBase(base, mixins, beforeId: id);
  return JsonResponse({
    'id': id,
    ...previewMixin(at, mixins[i]).toJson(),
  });
}
