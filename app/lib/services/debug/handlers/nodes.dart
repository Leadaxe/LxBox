import '../../../controllers/subscription_controller.dart';
import '../../../models/codec/node_link_record.dart';
import '../../../models/node_link.dart';
import '../../../models/server_list.dart';
import '../../node_link_address.dart';
import '../../../models/node_spec.dart';
import '../../../models/template_vars.dart';
import '../../contract/body_sanitizer.dart' show carriesPrivateKeyByRegistry;
import '../../tag_resolver.dart';
import '../context.dart';
import '../contract/errors.dart';
import '../transport/request.dart';
import '../transport/response.dart';
import '_shared.dart';

/// `/nodes/*` — Фича 478. Узел глазами ЭМИТТЕРА, а не хранения.
///
/// Почему отдельно от `/subs/{id}`: там узел виден так, как лежит (`raw`,
/// секции, поля записи), а проверять надо ещё и обратную сторону — что
/// приложение отдаст наружу по этому узлу. Между ними стоит эмиттер, и
/// расхождение видно только когда обе стороны читаются рядом.
///
/// Routes:
/// - `GET /nodes/link?tag=<tag>` → ссылка узла (тот же emit, что у Copy link)
/// - `PATCH /nodes/{tag}[?rebuild=true]` → `{"detour": <tag | {folder_id?,
///   tag} | null>}` — §762: личный detour узла по тегу (одиночный сервер —
///   `override_detour` записи, член папки — `detour` члена)
Future<DebugResponse> nodesHandler(DebugRequest req, DebugContext ctx) async {
  final s = req.uri.pathSegments;
  // Чтения узла по тегу нет: прочие методы на `/nodes/{tag}` — 404, как
  // любой чужой путь.
  if (req.method == 'PATCH' &&
      s.length == 2 &&
      s[0] == 'nodes' &&
      s[1] != 'link' &&
      s[1].isNotEmpty) {
    return _setDetour(s[1], req, ctx);
  }
  if (req.path != '/nodes/link') throw NotFound('nodes path: ${req.path}');
  if (req.method != 'GET') {
    throw BadRequest('method ${req.method} not allowed on /nodes/link');
  }
  return _link(req, ctx);
}

/// `GET /nodes/link?tag=<tag>` — экспорт узла ссылкой: ровно то, что кладёт в
/// буфер `Copy link` (`NodeSpec.shareUri()`), без экрана и без буфера обмена.
///
/// [tag] принимается и «как в конфиге» (с префиксом подписки), и голым: экран
/// адресует узлы первым, хранение — вторым, и заставлять проверяющего
/// угадывать, какой из них взял этот путь, незачем.
///
/// `uri` несёт credentials → только с `?reveal=true`. Без флага ответ
/// `{error:"reveal required"}` без ссылки (как `raw` члена папки).
///
/// Диалога про приватный ключ здесь нет — спрашивать некого. Вместо него в
/// ответе едет `private_key: true`: тот же признак, по которому экран решает
/// спросить (§466), так что предупреждение не теряется, а становится данными.
///
/// `{error}` вместо `{uri}` — когда узел найден, но ссылкой не выражается
/// (группы §208 и прочие узлы, собранные приложением без текста): это не 404,
/// узел есть, и ответ обязан отличать «нет узла» от «нет ссылки».
Future<DebugResponse> _link(DebugRequest req, DebugContext ctx) async {
  final sub = ctx.requireSub();
  final tag = (req.q('tag') ?? '').trim();
  if (tag.isEmpty) throw const BadRequest('param "tag" required');

  final hit = _findByTag(tag, sub);
  if (hit == null) throw NotFound('node by tag: $tag');

  if (!req.qBool('reveal')) {
    return JsonResponse({
      'tag': hit.tag,
      'protocol': hit.protocol,
      'private_key': carriesPrivateKeyByRegistry(hit.emit(TemplateVars.empty).map),
      'error': 'reveal required',
    });
  }

  final uri = hit.shareUri();
  if (uri.isEmpty) {
    return JsonResponse({
      'tag': hit.tag,
      'protocol': hit.protocol,
      'error': 'node has no link form',
    });
  }
  return JsonResponse({
    'tag': hit.tag,
    'protocol': hit.protocol,
    'uri': uri,
    // §466 — ссылка несёт приватный ключ владельца.
    'private_key': carriesPrivateKeyByRegistry(hit.emit(TemplateVars.empty).map),
  });
}

/// Поиск узла по тегу — та же логика, что у экрана (`node_actions.dart`):
/// снимаем префикс подписки и идём по узлам, включая звенья цепочки (§404).
/// Дополнительно принимаем уже голый тег: снаружи адресуют и так.
NodeSpec? _findByTag(String tag, SubscriptionController sub) {
  for (final e in sub.entries) {
    final base = TagResolver.stripPrefix(tag, e.tagPrefix);
    for (final n in e.list.nodes) {
      for (NodeSpec? hop = n; hop != null; hop = hop.chained) {
        if (hop.tag == base || hop.tag == tag) return hop;
      }
    }
  }
  return null;
}

/// §762 — `PATCH /nodes/{tag}`: detour узла по его тегу, тем же путём, что
/// экран узла (§237): одиночный сервер — `override_detour` записи, член
/// папки — `setMemberDetour` (отказ self/цикла — 400). У узла подписки
/// своего detour нет — только общий у подписки (`PATCH /subs/{id}`
/// `override_detour`), поэтому 409 с подсказкой. Тег — как в конфиге или
/// голый, URL-encoded.
Future<DebugResponse> _setDetour(
    String tag, DebugRequest req, DebugContext ctx) async {
  final body = req.jsonBodyAsMap();
  if (!body.containsKey('detour')) {
    throw const BadRequest('field "detour" required (tag, {folder_id?, tag} '
        'or null)');
  }
  final link = fieldNodeLink(body, 'detour')!;
  final sub = ctx.requireSub();
  for (var idx = 0; idx < sub.entries.length; idx++) {
    final e = sub.entries[idx];
    final base = TagResolver.stripPrefix(tag, e.tagPrefix);
    bool hit(NodeSpec? n) => n != null && (n.tag == base || n.tag == tag);
    final list = e.list;
    if (list is UserServer) {
      if (!list.nodes.any(hit)) continue;
      e.overrideDetour = link;
      await sub.persistSources();
      return _detourResponse(req, ctx, e, e.overrideDetour, tag);
    }
    if (list is FolderServers) {
      final i = list.members.indexWhere((m) => hit(m.node));
      if (i < 0) continue;
      final lifted =
          liftSiblingLink(link, list.id, containerRawTagSet(list));
      final err = await sub.setMemberDetour(idx, i, lifted);
      if (err != null) throw BadRequest('detour rejected: ${err.renderEn()}');
      final now = (sub.entries[idx].list as FolderServers).members[i].detour;
      return _detourResponse(req, ctx, sub.entries[idx], now, tag);
    }
    if (list.nodes.any(hit)) {
      throw Conflict('node "$tag" belongs to a subscription: a subscription '
          'node has no own detour; use PATCH /subs/${e.id} '
          '{"override_detour": ...} (all its nodes)');
    }
  }
  throw NotFound('node by tag: $tag');
}

Future<DebugResponse> _detourResponse(DebugRequest req, DebugContext ctx,
    SubscriptionEntry e, NodeLink detour, String tag) async {
  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({
    'ok': true,
    'action': 'node-detour',
    'tag': tag,
    'entry_id': e.id,
    'kind': e.list is FolderServers ? 'FolderServers' : 'UserServer',
    'detour': nodeLinkToRecordOrNull(detour),
    ...extras,
  });
}
