import '../../../controllers/subscription_controller.dart';
import '../../../models/node_spec.dart';
import '../../tag_resolver.dart';
import '../context.dart';
import '../contract/errors.dart';
import '../transport/request.dart';
import '../transport/response.dart';

/// `/nodes/*` — Фича 478. Узел глазами ЭМИТТЕРА, а не хранения.
///
/// Почему отдельно от `/subs/{id}`: там узел виден так, как лежит (`raw`,
/// секции, поля записи), а проверять надо ещё и обратную сторону — что
/// приложение отдаст наружу по этому узлу. Между ними стоит эмиттер, и
/// расхождение видно только когда обе стороны читаются рядом.
///
/// Routes:
/// - `GET /nodes/link?tag=<tag>` → ссылка узла (тот же emit, что у Copy link)
Future<DebugResponse> nodesHandler(DebugRequest req, DebugContext ctx) async {
  if (req.path != '/nodes/link') throw NotFound('nodes path: ${req.path}');
  if (req.method != 'GET') {
    throw BadRequest('method ${req.method} not allowed on /nodes/link');
  }
  return _link(req, ctx);
}

/// `GET /nodes/link?tag=<tag>` — экспорт узла ссылкой: ровно то, что кладёт в
/// буфер `Copy link` (`NodeSpec.toUri()`), без экрана и без буфера обмена.
///
/// [tag] принимается и «как в конфиге» (с префиксом подписки), и голым: экран
/// адресует узлы первым, хранение — вторым, и заставлять проверяющего
/// угадывать, какой из них взял этот путь, незачем.
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
      'private_key': hit.linkCarriesPrivateKey,
      'error': 'reveal required',
    });
  }

  final uri = hit.toUri();
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
    'private_key': hit.linkCarriesPrivateKey,
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
