import '../../../models/channel.dart';
import '../../settings_storage.dart';
import '../context.dart';
import '../contract/errors.dart';
import '../transport/request.dart';
import '../transport/response.dart';
import '_shared.dart';

/// §238 — `/channels/*` — CRUD каналов роутинга (§125).
///
/// Тонкая обёртка над `SettingsStorage.getChannels / addChannel /
/// updateChannel / deleteChannel` — та же семантика, что у UI:
/// vpn-1 неудаляем и всегда enabled, лимит [kMaxChannels], удаление /
/// выключение / смена detour-роли канала лечит ссылки в storage
/// (rules-ссылки → vpn-1, §202-механика; detour-ссылки → '', §248);
/// счётчики вылеченного — блок `healed` в ответах мутаций.
///
/// Routes:
/// - `GET    /channels`            → list (Channel.toJson, snake_case)
/// - `POST   /channels`            → create (body: `{"label":"..."}` +
///                                    опционально любые PATCH-поля)
/// - `POST   /channels/reorder`    → reorder (body: `{"order":[tag,...]}`)
/// - `GET    /channels/{tag}`      → single
/// - `PATCH  /channels/{tag}`      → partial update
/// - `DELETE /channels/{tag}`      → remove
///
/// Все write'ы принимают `?rebuild=true`. Порядок каналов = порядок эмита
/// в конфиге, поэтому reorder тоже config-significant.
Future<DebugResponse> channelsHandler(DebugRequest req, DebugContext ctx) async {
  final path = req.path;

  if (path == '/channels') {
    return switch (req.method) {
      'GET' => _list(),
      'POST' => _create(req, ctx),
      _ => throw BadRequest('method ${req.method} not allowed on /channels'),
    };
  }

  if (path == '/channels/reorder') {
    if (req.method != 'POST') {
      throw BadRequest('reorder requires POST, got ${req.method}');
    }
    return _reorder(req, ctx);
  }

  if (path.startsWith('/channels/')) {
    final tag = path.substring('/channels/'.length);
    if (tag.isEmpty || tag.contains('/')) {
      throw NotFound('channels path: $path');
    }
    return switch (req.method) {
      'GET' => _single(tag),
      'PATCH' => _update(tag, req, ctx),
      'DELETE' => _delete(tag, req, ctx),
      _ => throw BadRequest('method ${req.method} not allowed on /channels/{tag}'),
    };
  }

  throw NotFound('channels path: $path');
}

Future<DebugResponse> _list() async {
  final channels = await SettingsStorage.getChannels();
  return JsonResponse(channels.map((c) => c.toJson()).toList());
}

Future<DebugResponse> _single(String tag) async {
  final channels = await SettingsStorage.getChannels();
  final ch = channels.where((c) => c.tag == tag).firstOrNull;
  if (ch == null) throw NotFound('channel: $tag');
  return JsonResponse(ch.toJson());
}

Future<DebugResponse> _create(DebugRequest req, DebugContext ctx) async {
  final body = req.jsonBodyAsMap();
  final label = fieldString(body, 'label');
  final Channel created;
  try {
    created = await SettingsStorage.addChannel(label: label);
  } on StateError catch (e) {
    // Лимит каналов — precondition, юзер может удалить лишний и повторить.
    throw Conflict(e.message);
  }
  // Остальные поля body — как PATCH сразу после создания (один вызов
  // вместо POST+PATCH). label уже применён.
  var ch = created;
  // Свежий tag обычно ни на что не ссылается (счётчики нули), но re-create
  // тега после restore из backup может встретить stale-ссылку — heal тот же,
  // что у PATCH, поэтому и shape ответа единый.
  ChannelHealResult healed = (rules: 0, detours: 0);
  final patched = _applyPatch(ch, body);
  if (patched != null) {
    ch = patched;
    healed = await SettingsStorage.updateChannel(ch);
  }
  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({
    ...ch.toJson(),
    'healed': {'rules': healed.rules, 'detours': healed.detours},
    ...extras,
  }, status: 201);
}

Future<DebugResponse> _update(String tag, DebugRequest req, DebugContext ctx) async {
  final body = req.jsonBodyAsMap();
  final channels = await SettingsStorage.getChannels();
  final ch = channels.where((c) => c.tag == tag).firstOrNull;
  if (ch == null) throw NotFound('channel: $tag');

  final next = _applyPatch(ch, body) ?? ch;
  final healed = await SettingsStorage.updateChannel(next);
  // §248 — зеркальный ресинк in-memory _entries контроллера: без него
  // следующий _persist()/generateConfig() воскресил бы вылеченный storage.
  if (healed.detours > 0) {
    ctx.registry.sub?.syncDetourChannelRefsCleared(tag);
  }
  final extras = await maybeRebuild(req, ctx);
  // §238-паттерн «снапшот в ответе»: healed-счётчики — API-аналог
  // UI-SnackBar'а о вылеченных ссылках (§202/§248), heal молчаливым не бывает.
  return JsonResponse({
    ...next.toJson(),
    'healed': {'rules': healed.rules, 'detours': healed.detours},
    ...extras,
  });
}

Future<DebugResponse> _delete(String tag, DebugRequest req, DebugContext ctx) async {
  final channels = await SettingsStorage.getChannels();
  if (!channels.any((c) => c.tag == tag)) throw NotFound('channel: $tag');
  final ChannelHealResult healed;
  try {
    healed = await SettingsStorage.deleteChannel(tag);
  } on StateError catch (e) {
    throw Conflict(e.message); // vpn-1 is not deletable
  }
  // §248 — зеркальный ресинк _entries контроллера (см. _update).
  if (healed.detours > 0) {
    ctx.registry.sub?.syncDetourChannelRefsCleared(tag);
  }
  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({
    'ok': true,
    'action': 'channels-delete',
    'tag': tag,
    'healed': {'rules': healed.rules, 'detours': healed.detours},
    ...extras,
  });
}

Future<DebugResponse> _reorder(DebugRequest req, DebugContext ctx) async {
  final body = req.jsonBodyAsMap();
  final order = fieldStringList(body, 'order');
  if (order == null) {
    throw const BadRequest('body must contain "order": [tag, ...]');
  }
  final channels = await SettingsStorage.getChannels();
  final current = channels.map((c) => c.tag).toList();
  if (order.length != current.length) {
    throw BadRequest(
      'order length ${order.length} != current channel count ${current.length}',
    );
  }
  final missing = current.toSet().difference(order.toSet());
  final extra = order.toSet().difference(current.toSet());
  if (missing.isNotEmpty || extra.isNotEmpty) {
    throw BadRequest(
      'order must contain exactly the current channel tags '
      '(missing: $missing, extra: $extra)',
    );
  }
  final byTag = {for (final c in channels) c.tag: c};
  await SettingsStorage.setChannels([for (final t in order) byTag[t]!]);
  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({
    'ok': true,
    'action': 'channels-reorder',
    'count': order.length,
    ...extras,
  });
}

/// Применяет PATCH-поля body к [ch]. Возвращает новый Channel или null,
/// если ни одно изменяемое поле не передано. Бросает [BadRequest] /
/// [Conflict] на невалидные значения и нарушение инвариантов.
Channel? _applyPatch(Channel ch, Map<String, dynamic> body) {
  if (body.containsKey('tag')) {
    throw const BadRequest('field "tag" is immutable (system id, edit "label" instead)');
  }

  final enabled = fieldBool(body, 'enabled');
  if (enabled == false && ch.isRequired) {
    throw Conflict('channel ${ch.tag} is always enabled and cannot be disabled');
  }

  final nodeFilter = fieldString(body, 'node_filter');
  final defaultFilter = fieldString(body, 'default_filter');
  _requireValidRegex('node_filter', nodeFilter);
  _requireValidRegex('default_filter', defaultFilter);

  // auto: null (ключ присутствует) = снять галку; object = merge в текущий
  // (или дефолтный) ChannelAuto — PATCH одним полем не должен сбрасывать
  // остальные urltest-опции в дефолты. balancer{} мержится одним уровнем.
  var clearAuto = false;
  ChannelAuto? auto;
  if (body.containsKey('auto')) {
    final rawAuto = body['auto'];
    if (rawAuto == null) {
      clearAuto = true;
    } else if (rawAuto is Map<String, dynamic>) {
      final base = (ch.auto ?? const ChannelAuto()).toJson();
      final baseBal = base['balancer'] as Map<String, dynamic>;
      final patchBal = rawAuto['balancer'];
      if (patchBal != null && patchBal is! Map<String, dynamic>) {
        throw BadRequest('field "auto.balancer" must be object, got ${patchBal.runtimeType}');
      }
      auto = ChannelAuto.fromJson({
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
  final nodeFilterInvert = fieldBool(body, 'node_filter_invert');
  final interrupt = fieldBool(body, 'interrupt_exist_connections');

  // §248 — роль detour-прослойки. vpn-1 — резервная мишень heal-путей,
  // detour ему запрещён; block в прослойке запрещён («upstream недоступен»
  // не должен превращаться в «весь флот мёртв»). Явный include_block:true
  // при detour-роли — отказ; унаследованный из storage при включении detour
  // — молча нормализуем в false (merge-философия: PATCH одним полем не
  // обязан знать про ранее выставленные галки).
  final detour = fieldBool(body, 'detour');
  if (detour == true && ch.isRequired) {
    throw Conflict(
      'channel ${ch.tag} is the fallback rule target and cannot be a detour channel',
    );
  }
  if (includeBlock == true && (detour ?? ch.isDetour)) {
    throw const Conflict(
      'a detour channel cannot include block '
      '("detour" and "include_block" are mutually exclusive)',
    );
  }
  final dropBlock = detour == true && ch.includeBlock;

  final changed = label != null ||
      enabled != null ||
      includeDirect != null ||
      includeBlock != null ||
      nodeFilter != null ||
      nodeFilterInvert != null ||
      defaultFilter != null ||
      interrupt != null ||
      detour != null ||
      auto != null ||
      clearAuto;
  if (!changed) return null;

  return ch.copyWith(
    label: label,
    enabled: enabled,
    includeDirect: includeDirect,
    includeBlock: dropBlock ? false : includeBlock,
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
