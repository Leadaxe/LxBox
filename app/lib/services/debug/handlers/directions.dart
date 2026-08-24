import '../../../models/direction.dart';
import '../../direction_mutations.dart';
import '../../settings_storage.dart';
import '../context.dart';
import '../contract/errors.dart';
import '../transport/request.dart';
import '../transport/response.dart';
import '_shared.dart';

/// §238 — `/directions/*` — CRUD Направлений роутинга (§125).
///
/// Тонкая обёртка над `DirectionMutations.add / update / delete` (§275 —
/// storage-мутация + зеркальный ресинк `_entries` контроллера одной
/// операцией) — та же семантика, что у UI:
/// vpn-1 неудаляем и всегда enabled; лимита на количество нет (§393 A3).
/// Heal ссылок в
/// storage: rules-ссылки → vpn-1 при удалении/выключении (§202-механика;
/// установка detour-флага rules НЕ лечит — §274, флаг = разрешение);
/// detour-ссылки → '' при удалении/выключении/снятии флага (§248);
/// счётчики вылеченного — блок `healed` в ответах мутаций.
///
/// Routes:
/// - `GET    /directions`            → list (Direction.toJson, snake_case)
/// - `POST   /directions`            → create (body: `{"label":"...",
///                                    "tag":"..."}` + опционально любые
///                                    PATCH-поля; `tag` только при создании)
/// - `POST   /directions/reorder`    → reorder (body: `{"order":[tag,...]}`)
/// - `GET    /directions/{tag}`      → single
/// - `PATCH  /directions/{tag}`      → partial update
/// - `DELETE /directions/{tag}`      → remove
///
/// Все write'ы принимают `?rebuild=true`. Порядок Направлений = порядок эмита
/// в конфиге, поэтому reorder тоже config-significant.
Future<DebugResponse> directionsHandler(DebugRequest req, DebugContext ctx) async {
  final path = req.path;

  if (path == '/directions') {
    return switch (req.method) {
      'GET' => _list(),
      'POST' => _create(req, ctx),
      _ => throw BadRequest('method ${req.method} not allowed on /directions'),
    };
  }

  if (path == '/directions/reorder') {
    if (req.method != 'POST') {
      throw BadRequest('reorder requires POST, got ${req.method}');
    }
    return _reorder(req, ctx);
  }

  if (path.startsWith('/directions/')) {
    final tag = path.substring('/directions/'.length);
    if (tag.isEmpty || tag.contains('/')) {
      throw NotFound('directions path: $path');
    }
    return switch (req.method) {
      'GET' => _single(tag),
      'PATCH' => _update(tag, req, ctx),
      'DELETE' => _delete(tag, req, ctx),
      _ => throw BadRequest('method ${req.method} not allowed on /directions/{tag}'),
    };
  }

  throw NotFound('directions path: $path');
}

Future<DebugResponse> _list() async {
  final directions = await SettingsStorage.getDirections();
  return JsonResponse(directions.map((c) => c.toJson()).toList());
}

Future<DebugResponse> _single(String tag) async {
  final directions = await SettingsStorage.getDirections();
  final ch = directions.where((c) => c.tag == tag).firstOrNull;
  if (ch == null) throw NotFound('direction: $tag');
  return JsonResponse(ch.toJson());
}

Future<DebugResponse> _create(DebugRequest req, DebugContext ctx) async {
  final body = req.jsonBodyAsMap();
  final label = fieldString(body, 'label');
  // §393 A3 — опциональный пользовательский тег; отсутствует → первый
  // свободный `vpn-N`. Валидацию (пустой/служебный/дубль/тёзка `<tag>-auto`)
  // делает storage — одна точка для UI и API.
  final tag = fieldString(body, 'tag');
  final Direction created;
  try {
    created = await DirectionMutations.add(label: label, tag: tag);
  } on StateError catch (e) {
    // Конфликт тега — precondition: юзер может выбрать другой и повторить.
    throw Conflict(e.message);
  }
  // Остальные поля body — как PATCH сразу после создания (один вызов
  // вместо POST+PATCH). label уже применён.
  var ch = created;
  // Свежий tag обычно ни на что не ссылается (счётчики нули), но re-create
  // тега после restore из backup может встретить stale-ссылку — heal тот же,
  // что у PATCH, поэтому и shape ответа единый. Достижимый путь: body с
  // `enabled:false` даёт disabling-переход, а он лечит ОБА рода ссылок.
  DirectionHealResult healed =
      (rules: 0, detours: 0, includes: 0, chainPositions: 0);
  final patched = _applyPatch(ch, body, tagConsumed: true);
  if (patched != null) {
    ch = patched;
    healed = await DirectionMutations.update(ch, ctx.registry.sub);
  }
  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({
    ...ch.toJson(),
    'healed': {
      'rules': healed.rules,
      'detours': healed.detours,
      'includes': healed.includes, // §393 A3
      // §393 D2 — ПОЗИЦИИ цепочек, снятые вместе с удалённым Направлением
      // (сами цепочки остались). Маршрут мог укоротиться — агент обязан
      // увидеть это в ответе, а не по пропавшему хопу в конфиге.
      'chain_positions': healed.chainPositions,
    },
    ...extras,
  }, status: 201);
}

Future<DebugResponse> _update(String tag, DebugRequest req, DebugContext ctx) async {
  final body = req.jsonBodyAsMap();
  final directions = await SettingsStorage.getDirections();
  final ch = directions.where((c) => c.tag == tag).firstOrNull;
  if (ch == null) throw NotFound('direction: $tag');

  final next = _applyPatch(ch, body) ?? ch;
  final healed = await DirectionMutations.update(next, ctx.registry.sub);
  final extras = await maybeRebuild(req, ctx);
  // §238-паттерн «снапшот в ответе»: healed-счётчики — API-аналог
  // UI-SnackBar'а о вылеченных ссылках (§202/§248), heal молчаливым не бывает.
  return JsonResponse({
    ...next.toJson(),
    'healed': {
      'rules': healed.rules,
      'detours': healed.detours,
      'includes': healed.includes, // §393 A3
      // §393 D2 — ПОЗИЦИИ цепочек, снятые вместе с удалённым Направлением
      // (сами цепочки остались). Маршрут мог укоротиться — агент обязан
      // увидеть это в ответе, а не по пропавшему хопу в конфиге.
      'chain_positions': healed.chainPositions,
    },
    ...extras,
  });
}

Future<DebugResponse> _delete(String tag, DebugRequest req, DebugContext ctx) async {
  final directions = await SettingsStorage.getDirections();
  if (!directions.any((c) => c.tag == tag)) throw NotFound('direction: $tag');
  final DirectionHealResult healed;
  try {
    healed = await DirectionMutations.delete(tag, ctx.registry.sub);
  } on StateError catch (e) {
    throw Conflict(e.message); // vpn-1 is not deletable
  }
  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({
    'ok': true,
    'action': 'directions-delete',
    'tag': tag,
    'healed': {
      'rules': healed.rules,
      'detours': healed.detours,
      'includes': healed.includes, // §393 A3
      // §393 D2 — ПОЗИЦИИ цепочек, снятые вместе с удалённым Направлением
      // (сами цепочки остались). Маршрут мог укоротиться — агент обязан
      // увидеть это в ответе, а не по пропавшему хопу в конфиге.
      'chain_positions': healed.chainPositions,
    },
    ...extras,
  });
}

Future<DebugResponse> _reorder(DebugRequest req, DebugContext ctx) async {
  final body = req.jsonBodyAsMap();
  final order = fieldStringList(body, 'order');
  if (order == null) {
    throw const BadRequest('body must contain "order": [tag, ...]');
  }
  final directions = await SettingsStorage.getDirections();
  final current = directions.map((c) => c.tag).toList();
  if (order.length != current.length) {
    throw BadRequest(
      'order length ${order.length} != current direction count ${current.length}',
    );
  }
  final missing = current.toSet().difference(order.toSet());
  final extra = order.toSet().difference(current.toSet());
  if (missing.isNotEmpty || extra.isNotEmpty) {
    throw BadRequest(
      'order must contain exactly the current direction tags '
      '(missing: $missing, extra: $extra)',
    );
  }
  final byTag = {for (final c in directions) c.tag: c};
  await DirectionMutations.bulkReplace([for (final t in order) byTag[t]!]);
  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({
    'ok': true,
    'action': 'directions-reorder',
    'count': order.length,
    ...extras,
  });
}

/// Применяет PATCH-поля body к [ch]. Возвращает новый Direction или null,
/// если ни одно изменяемое поле не передано. Бросает [BadRequest] /
/// [Conflict] на невалидные значения и нарушение инвариантов.
Direction? _applyPatch(Direction ch, Map<String, dynamic> body,
    {bool tagConsumed = false}) {
  // §393 A3 — POST принимает `tag` (пожелание для СОЗДАНИЯ, уже применён
  // выше); PATCH — нет: после создания тег immutable, на него ссылаются
  // правила/detour'ы.
  if (!tagConsumed && body.containsKey('tag')) {
    throw const BadRequest('field "tag" is immutable (system id, edit "label" instead)');
  }

  final enabled = fieldBool(body, 'enabled');
  if (enabled == false && ch.isRequired) {
    throw Conflict('direction ${ch.tag} is always enabled and cannot be disabled');
  }

  final nodeFilter = fieldString(body, 'node_filter');
  final defaultFilter = fieldString(body, 'default_filter');
  _requireValidRegex('node_filter', nodeFilter);
  _requireValidRegex('default_filter', defaultFilter);

  // auto: null (ключ присутствует) = снять галку; object = merge в текущий
  // (или дефолтный) DirectionAuto — PATCH одним полем не должен сбрасывать
  // остальные urltest-опции в дефолты. balancer{} мержится одним уровнем.
  var clearAuto = false;
  DirectionAuto? auto;
  if (body.containsKey('auto')) {
    final rawAuto = body['auto'];
    if (rawAuto == null) {
      clearAuto = true;
    } else if (rawAuto is Map<String, dynamic>) {
      final base = (ch.auto ?? const DirectionAuto()).toJson();
      final baseBal = base['balancer'] as Map<String, dynamic>;
      final patchBal = rawAuto['balancer'];
      if (patchBal != null && patchBal is! Map<String, dynamic>) {
        throw BadRequest('field "auto.balancer" must be object, got ${patchBal.runtimeType}');
      }
      auto = DirectionAuto.fromJson({
        ...base,
        ...rawAuto,
        'balancer': {...baseBal, if (patchBal is Map<String, dynamic>) ...patchBal},
      });
    } else {
      throw BadRequest('field "auto" must be object or null, got ${rawAuto.runtimeType}');
    }
  }

  final label = fieldString(body, 'label');
  final includeDirect = fieldBool(body, 'include_direct');
  final includeBlock = fieldBool(body, 'include_block');
  // §393 A3 — `include`: теги других Направлений опциями селектора. Здесь
  // проверяем только ФОРМУ (список строк): «стоит ли цель выше по списку»
  // зависит от порядка, а порядок меняет отдельный `/directions/reorder` —
  // санитайзить хранилище на каждый чих значило бы молча стирать ссылку,
  // которую вернёт следующий reorder. Инвариант деградирует ВЫХЛОП: билдер
  // не эмитит ссылку вниз и предупреждает (см. `_buildDirectionGroups`).
  final include = fieldStringList(body, 'include');
  final nodeFilterInvert = fieldBool(body, 'node_filter_invert');
  final interrupt = fieldBool(body, 'interrupt_exist_connections');

  // §248/§274 — detour-флаг = разрешение выбирать Направление как detour-мишень;
  // роль в правилах ортогональна, include_block совместим (запрет Q1 снят
  // §274). vpn-1 — главное Направление (дефолтная мишень всего и heal-резерв),
  // detour ему запрещён: продуктовое решение.
  final detour = fieldBool(body, 'detour');
  if (detour == true && ch.isRequired) {
    throw Conflict(
      'direction ${ch.tag} is the primary direction and cannot be a detour direction',
    );
  }

  final changed = label != null ||
      enabled != null ||
      includeDirect != null ||
      includeBlock != null ||
      nodeFilter != null ||
      nodeFilterInvert != null ||
      defaultFilter != null ||
      include != null ||
      interrupt != null ||
      detour != null ||
      auto != null ||
      clearAuto;
  if (!changed) return null;

  return ch.copyWith(
    label: label,
    enabled: enabled,
    includeDirect: includeDirect,
    includeBlock: includeBlock,
    include: include,
    nodeFilter: nodeFilter,
    nodeFilterInvert: nodeFilterInvert,
    defaultFilter: defaultFilter,
    interruptExistConnections: interrupt,
    auto: auto,
    clearAuto: clearAuto,
    isDetour: detour,
  );
}

/// Битый regex в node_filter/default_filter ронял бы сборку конфига —
/// отклоняем на входе.
void _requireValidRegex(String field, String? value) {
  if (value == null || value.isEmpty) return;
  try {
    RegExp(value);
  } on FormatException catch (e) {
    throw BadRequest('field "$field" is not a valid regex: ${e.message}');
  }
}
