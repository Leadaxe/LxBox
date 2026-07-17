import '../../../controllers/subscription_controller.dart';
import '../../../models/server_list.dart';
import '../../probe/probe_runner.dart';
import '../../settings_storage.dart';
import '../context.dart';
import '../contract/errors.dart';
import '../serializers/subs.dart';
import '../transport/request.dart';
import '../transport/response.dart';
import '_shared.dart';

/// §238 — `/folders/*` — CRUD папок серверов (§234) + headless probe (§236).
///
/// Папка — entry в общем списке `/subs` (kind=FolderServers), поэтому
/// адресация по стабильному `id` entry. Члены адресуются **позиционным
/// индексом** (у FolderMember нет id) — после remove/ungroup/reorder индексы
/// съезжают; write-ответы возвращают свежий снапшот папки, по нему строить
/// следующий вызов. Meta папки (name/enabled/tag_prefix/detour_policy)
/// правится существующим `PATCH /subs/{id}` — здесь не дублируется.
///
/// Routes:
/// - `GET    /folders`                          → list (только folder-entries)
/// - `POST   /folders`                          → create (body: `{"name":"..."}`)
/// - `GET    /folders/{id}`                     → single + members
/// - `DELETE /folders/{id}[?keep_servers=true]` → delete; keep_servers выносит
///                                                члены одиночными серверами
/// - `POST   /folders/{id}/members`             → add: `{"input":"..."}` (paste,
///                                                опц. `name_fallback`) ИЛИ
///                                                `{"url":"..."}` (URL-снапшот)
/// - `PATCH  /folders/{id}/members/{idx}`       → subset `{raw,enabled,detour}`
/// - `DELETE /folders/{id}/members/{idx}`       → remove member
/// - `POST   /folders/{id}/members/reorder`     → `{"order":[старые индексы]}`
/// - `POST   /folders/{id}/members/{idx}/ungroup` → член → одиночный сервер
/// - `POST   /folders/{id}/members/{idx}/move`  → `{"to":"<folder id>"}`
/// - `POST   /folders/{id}/move-server`         → `{"server_id":"<subs id>"}` —
///                                                одиночный сервер в папку
/// - `POST   /folders/{id}/probe`               → Test servers; body опц.
///                                                `{"url":"...","timeout_ms":N}`
///
/// Все write'ы принимают `?rebuild=true`; чтения и write-ответы — `?reveal=true`
/// (raw членов несёт credentials, по умолчанию скрыт).
Future<DebugResponse> foldersHandler(DebugRequest req, DebugContext ctx) async {
  final path = req.path;

  if (path == '/folders') {
    return switch (req.method) {
      'GET' => _list(req, ctx),
      'POST' => _create(req, ctx),
      _ => throw BadRequest('method ${req.method} not allowed on /folders'),
    };
  }

  if (!path.startsWith('/folders/')) throw NotFound('folders path: $path');
  final segs = path.substring('/folders/'.length).split('/');
  final id = segs.first;
  if (id.isEmpty) throw NotFound('folders path: $path');

  // /folders/{id}
  if (segs.length == 1) {
    return switch (req.method) {
      'GET' => _single(id, req, ctx),
      'DELETE' => _deleteFolder(id, req, ctx),
      _ => throw BadRequest('method ${req.method} not allowed on /folders/{id}'),
    };
  }

  void requirePost() {
    if (req.method != 'POST') {
      throw BadRequest('${segs.last} requires POST, got ${req.method}');
    }
  }

  if (segs.length == 2) {
    switch (segs[1]) {
      case 'members':
        requirePost();
        return _addMembers(id, req, ctx);
      case 'move-server':
        requirePost();
        return _moveServerIn(id, req, ctx);
      case 'probe':
        requirePost();
        return _probe(id, req, ctx);
    }
  }
  if (segs.length == 3 && segs[1] == 'members' && segs[2] == 'reorder') {
    requirePost();
    return _reorderMembers(id, req, ctx);
  }
  if (segs.length == 3 && segs[1] == 'members') {
    return switch (req.method) {
      'PATCH' => _updateMember(id, segs[2], req, ctx),
      'DELETE' => _removeMember(id, segs[2], req, ctx),
      _ => throw BadRequest(
          'method ${req.method} not allowed on /folders/{id}/members/{idx}'),
    };
  }
  if (segs.length == 4 && segs[1] == 'members') {
    switch (segs[3]) {
      case 'ungroup':
        requirePost();
        return _ungroupMember(id, segs[2], req, ctx);
      case 'move':
        requirePost();
        return _moveMember(id, segs[2], req, ctx);
    }
  }

  throw NotFound('folders path: $path');
}

/// Entry по id, обязан быть папкой. Не-папка → 409 (диагностируемее, чем 404,
/// при путанице `/subs/{id}` vs `/folders/{id}`).
(int, SubscriptionEntry, FolderServers) _requireFolder(
  SubscriptionController sub,
  String id,
) {
  final idx = sub.entries.indexWhere((e) => e.id == id);
  if (idx < 0) throw NotFound('folder: $id');
  final entry = sub.entries[idx];
  final list = entry.list;
  if (list is! FolderServers) {
    throw Conflict('entry $id is ${list.type}, not a folder');
  }
  return (idx, entry, list);
}

int _memberIndex(String seg, FolderServers folder) {
  final i = int.tryParse(seg);
  if (i == null) throw NotFound('member index: $seg');
  if (i < 0 || i >= folder.members.length) {
    throw NotFound(
        'member index $i out of range (folder has ${folder.members.length} members)');
  }
  return i;
}

Future<DebugResponse> _list(DebugRequest req, DebugContext ctx) async {
  final sub = ctx.requireSub();
  final reveal = req.qBool('reveal');
  return JsonResponse([
    for (final e in sub.entries)
      if (e.list is FolderServers) serializeFolderEntry(e, reveal: reveal),
  ]);
}

Future<DebugResponse> _single(String id, DebugRequest req, DebugContext ctx) async {
  final sub = ctx.requireSub();
  final (_, entry, _) = _requireFolder(sub, id);
  return JsonResponse(serializeFolderEntry(entry, reveal: req.qBool('reveal')));
}

Future<DebugResponse> _create(DebugRequest req, DebugContext ctx) async {
  final body = req.jsonBodyAsMap();
  final name = fieldString(body, 'name') ?? '';
  if (name.trim().isEmpty) {
    throw const BadRequest('field "name" required');
  }
  final sub = ctx.requireSub();
  final before = sub.entries.map((e) => e.id).toSet();
  await sub.addFolder(name.trim());
  final entry = sub.entries.where((e) => !before.contains(e.id)).firstOrNull;
  if (entry == null) throw const InternalError('folder was not created');
  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({
    ...serializeFolderEntry(entry, reveal: req.qBool('reveal')),
    ...extras,
  }, status: 201);
}

Future<DebugResponse> _deleteFolder(String id, DebugRequest req, DebugContext ctx) async {
  final sub = ctx.requireSub();
  final (idx, _, folder) = _requireFolder(sub, id);
  final keepServers = req.qBool('keep_servers');
  await sub.deleteFolderAt(idx, keepServers: keepServers);
  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({
    'ok': true,
    'action': 'folder-delete',
    'id': id,
    'keep_servers': keepServers,
    'members_count': folder.members.length,
    ...extras,
  });
}

Future<DebugResponse> _addMembers(String id, DebugRequest req, DebugContext ctx) async {
  final body = req.jsonBodyAsMap();
  final input = fieldString(body, 'input');
  final url = fieldString(body, 'url');
  if ((input == null) == (url == null)) {
    throw const BadRequest(
        'body must contain exactly one of "input" (paste) or "url" (one-shot snapshot)');
  }
  final sub = ctx.requireSub();
  final (idx, entry, folder) = _requireFolder(sub, id);
  final before = folder.members.length;

  if (input != null) {
    if (input.trim().isEmpty) throw const BadRequest('field "input" is empty');
    final err = await sub.addMembersToFolder(idx, input,
        nameFallback: fieldString(body, 'name_fallback'));
    if (err != null) {
      throw BadRequest('add members rejected: ${err.renderEn()}');
    }
  } else {
    if (url!.trim().isEmpty) throw const BadRequest('field "url" is empty');
    final err = await sub.addUrlSnapshotToFolder(idx, url);
    if (err != null) {
      throw UpstreamError('url snapshot failed: ${err.renderEn()}');
    }
  }

  final after = (entry.list as FolderServers).members.length;
  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({
    'ok': true,
    'action': 'folder-members-add',
    'added': after - before,
    'folder': serializeFolderEntry(entry, reveal: req.qBool('reveal')),
    ...extras,
  }, status: 201);
}

Future<DebugResponse> _updateMember(
  String id,
  String idxSeg,
  DebugRequest req,
  DebugContext ctx,
) async {
  final body = req.jsonBodyAsMap();
  final sub = ctx.requireSub();
  final (idx, entry, folder) = _requireFolder(sub, id);
  final i = _memberIndex(idxSeg, folder);

  final raw = fieldString(body, 'raw');
  final enabled = fieldBool(body, 'enabled');
  final detour = fieldString(body, 'detour');
  if (raw == null && enabled == null && detour == null) {
    throw const BadRequest(
        'body must contain at least one of "raw", "enabled", "detour"');
  }

  if (raw != null) {
    final err = await sub.updateMemberAt(idx, i, raw);
    if (err != null) throw BadRequest('raw rejected: ${err.renderEn()}');
  }
  if (enabled != null) {
    await sub.setMembersEnabled(idx, {i}, enabled);
  }
  if (detour != null) {
    // §239 — контроллер отклоняет self/цикл интра-рёбер; пробрасываем отказ.
    final err = await sub.setMemberDetour(idx, i, detour);
    if (err != null) throw BadRequest('detour rejected: ${err.renderEn()}');
  }

  final reveal = req.qBool('reveal');
  final current = (entry.list as FolderServers).members[i];
  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({
    'ok': true,
    'action': 'folder-member-update',
    'member': serializeFolderMember(current, i, reveal: reveal),
    'folder': serializeFolderEntry(entry, reveal: reveal),
    ...extras,
  });
}

Future<DebugResponse> _removeMember(
  String id,
  String idxSeg,
  DebugRequest req,
  DebugContext ctx,
) async {
  final sub = ctx.requireSub();
  final (idx, entry, folder) = _requireFolder(sub, id);
  final i = _memberIndex(idxSeg, folder);
  await sub.removeMemberAt(idx, i);
  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({
    'ok': true,
    'action': 'folder-member-delete',
    'index': i,
    'folder': serializeFolderEntry(entry, reveal: req.qBool('reveal')),
    ...extras,
  });
}

Future<DebugResponse> _reorderMembers(String id, DebugRequest req, DebugContext ctx) async {
  final body = req.jsonBodyAsMap();
  final order = fieldIntList(body, 'order');
  if (order == null) {
    throw const BadRequest(
        'body must contain "order": [old member indexes in new order]');
  }
  final sub = ctx.requireSub();
  final (idx, entry, folder) = _requireFolder(sub, id);
  final n = folder.members.length;
  if (order.length != n ||
      order.toSet().length != n ||
      order.any((i) => i < 0 || i >= n)) {
    throw BadRequest(
        'order must be a full permutation of member indexes 0..${n - 1}');
  }
  await sub.applyMembersOrder(idx, order);
  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({
    'ok': true,
    'action': 'folder-members-reorder',
    'count': n,
    'folder': serializeFolderEntry(entry, reveal: req.qBool('reveal')),
    ...extras,
  });
}

Future<DebugResponse> _ungroupMember(
  String id,
  String idxSeg,
  DebugRequest req,
  DebugContext ctx,
) async {
  final sub = ctx.requireSub();
  final (idx, entry, folder) = _requireFolder(sub, id);
  final i = _memberIndex(idxSeg, folder);
  final before = sub.entries.map((e) => e.id).toSet();
  await sub.ungroupMemberAt(idx, i);
  // Одиночный сервер вставляется сразу после папки — но id надёжнее диффом.
  final created = sub.entries.where((e) => !before.contains(e.id)).firstOrNull;
  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({
    'ok': true,
    'action': 'folder-member-ungroup',
    'index': i,
    'server_id': created?.id,
    'folder': serializeFolderEntry(entry, reveal: req.qBool('reveal')),
    ...extras,
  });
}

Future<DebugResponse> _moveMember(
  String id,
  String idxSeg,
  DebugRequest req,
  DebugContext ctx,
) async {
  final body = req.jsonBodyAsMap();
  final to = fieldString(body, 'to') ?? '';
  if (to.isEmpty) {
    throw const BadRequest('field "to" required (target folder id)');
  }
  final sub = ctx.requireSub();
  final (fromIdx, _, folder) = _requireFolder(sub, id);
  final i = _memberIndex(idxSeg, folder);
  final (toIdx, toEntry, _) = _requireFolder(sub, to);
  final err = await sub.moveMemberToFolder(fromIdx, i, toIdx);
  if (err != null) throw Conflict('move rejected: ${err.renderEn()}');
  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({
    'ok': true,
    'action': 'folder-member-move',
    'index': i,
    'to': to,
    'folder': serializeFolderEntry(toEntry, reveal: req.qBool('reveal')),
    ...extras,
  });
}

Future<DebugResponse> _moveServerIn(String id, DebugRequest req, DebugContext ctx) async {
  final body = req.jsonBodyAsMap();
  final serverId = fieldString(body, 'server_id') ?? '';
  if (serverId.isEmpty) {
    throw const BadRequest('field "server_id" required (single-server subs entry id)');
  }
  final sub = ctx.requireSub();
  final (folderIdx, entry, _) = _requireFolder(sub, id);
  final serverIdx = sub.entries.indexWhere((e) => e.id == serverId);
  if (serverIdx < 0) throw NotFound('server: $serverId');
  final err = await sub.moveServerToFolder(serverIdx, folderIdx);
  // Пред-проверки сняли not-found ветки; остаток — «не одиночный сервер».
  if (err != null) throw Conflict('move rejected: ${err.renderEn()}');
  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({
    'ok': true,
    'action': 'folder-move-server',
    'server_id': serverId,
    'folder': serializeFolderEntry(entry, reveal: req.qBool('reveal')),
    ...extras,
  });
}

/// §236 — headless «Test servers»: probe-сессия рядом с (или через) боевое
/// ядро, результаты по каждому члену в ответе. Хендлер async — HTTP-сервер
/// (HttpServer.listen конкурентен) остаётся отзывчивым во время теста
/// (device-verified: /ping 17мс при идущем probe). Синхронный ПО ОТВЕТУ:
/// worst-case ~members/6 × timeout_ms; при больших папках снижать
/// timeout_ms, чтобы уложиться в request-timeout сервера (30с).
Future<DebugResponse> _probe(String id, DebugRequest req, DebugContext ctx) async {
  final body = req.jsonBodyAsMap();
  final sub = ctx.requireSub();
  final (_, _, folder) = _requireFolder(sub, id);

  var url = fieldString(body, 'url');
  var timeoutMs = fieldInt(body, 'timeout_ms');
  if (url == null || timeoutMs == null) {
    // Дефолты — глобальные ping_options, как у кнопки Test servers в UI.
    final ping = await SettingsStorage.getPingOptions();
    url ??= (ping['url'] as String?)?.trim() ?? '';
    timeoutMs ??= (ping['timeout_ms'] as num?)?.toInt() ?? 3000;
  }
  if (timeoutMs <= 0) throw const BadRequest('field "timeout_ms" must be > 0');

  final results = <int, ProbeResult>{};
  final err = await FolderProbeRunner().run(
    folder,
    url: url,
    timeoutMs: timeoutMs,
    onResult: (i, r) => results[i] = r,
  );
  if (err.isNotEmpty) throw UpstreamError('probe failed to start: $err');

  final summary = <String, int>{};
  final out = <Map<String, Object?>>[];
  for (var i = 0; i < folder.members.length; i++) {
    final r = results[i] ?? const ProbeResult(ProbeStatus.pending);
    final status = _probeStatusWire(r.status);
    summary[status] = (summary[status] ?? 0) + 1;
    out.add({
      'index': i,
      'tag': folder.members[i].node?.tag,
      'status': status,
      if (r.status == ProbeStatus.ok) 'delay_ms': r.delayMs,
      if (r.message.isNotEmpty) 'message': r.message,
    });
  }
  return JsonResponse({
    'ok': true,
    'action': 'folder-probe',
    'id': id,
    'url': url,
    'timeout_ms': timeoutMs,
    'results': out,
    'summary': summary,
  });
}

String _probeStatusWire(ProbeStatus s) => switch (s) {
      ProbeStatus.pending => 'pending',
      ProbeStatus.ok => 'ok',
      ProbeStatus.failed => 'failed',
      ProbeStatus.broken => 'broken',
      ProbeStatus.invalid => 'invalid',
      ProbeStatus.notInConfig => 'not_in_config',
    };
