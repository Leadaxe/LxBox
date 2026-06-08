import '../../controllers/subscription_controller.dart';
import '../../models/server_list.dart';
import '../../services/tag_resolver.dart';

/// §077 — Pure helper для lookup'а подписок-кандидатов по display-тэгу.
///
/// **Ambiguity-aware**: возвращает Set всех subscription id'ов которые
/// **могли** создать данный display-тэг (включая collision-suffix
/// `'base-N'` от `_BuildCtx.allocateTag`). Пустой Set = нода неизвестного
/// происхождения (UserServer / control outbound / imported JSON) — caller
/// маппит в категорию `'custom'`.
///
/// Tag в `state.nodes` это **prefixed form** — `_withPrefix(n.tag)` =
/// `'$tagPrefix $base'` если `tagPrefix.isNotEmpty`, иначе `base`
/// (см. `services/builder/server_list_build.dart::_withPrefix`).
///
/// При коллизии (две подписки даёт одинаковый prefixed-tag —
/// `_BuildCtx.allocateTag` добавляет `-1`/`-2`/... к одной из них)
/// honestly возвращаем **все** entries у которых `(tagPrefix, n.tag)`
/// пара мэтчит. Юзер видит ноду в chip-фильтре каждой подписки которая
/// могла её создать — без deceptive disambiguation.
///
/// **Known false-positive**: если подписка A имеет node literally
/// названный `'M1-1'` (без префикса), а подписка B имеет node `'M1'`,
/// то tag `'M1-1'` мэтчит обе (A через exact + B через collision-suffix
/// heuristic). Builder allocation order не персистится в `state.nodes`,
/// поэтому различить literal-suffix от collision-suffix без второго
/// прохода невозможно. UX impact: superset в chip filter — приемлемо.
Set<String> subscriptionsOfTag(
  String tag,
  List<SubscriptionEntry> entries,
) {
  final result = <String>{};
  for (final e in entries) {
    final list = e.list;
    if (list is! SubscriptionServers) continue;
    if (!e.enabled) continue; // disabled subs не эмитят node'ы в config
    final prefix = list.tagPrefix;
    for (final n in list.nodes) {
      // §085 R1 — display-form + collision-suffix через TagResolver
      // (был inline дубль логики из server_list_build/_BuildCtx).
      final base = TagResolver.displayTag(prefix, n.tag);
      if (TagResolver.matchesAllocated(tag, base)) {
        result.add(e.id);
        break;
      }
    }
  }
  return result;
}
