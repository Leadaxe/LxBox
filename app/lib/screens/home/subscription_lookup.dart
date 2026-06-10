import '../../controllers/subscription_controller.dart';
import '../../models/server_list.dart';

/// §091 — какие подписки «владеют» данным display-тэгом, по **префиксу**.
///
/// `config-tag == нода в Clash`, но `subId` в конфиг не пишется — единственный
/// реальный mismatch (§091 spec). Восстанавливаем принадлежность чисто по
/// эмитированному префиксу: билдер кладёт тег как `'$tagPrefix $bare'`
/// (`TagResolver.displayTag`), поэтому нода принадлежит подписке ⇔
/// `tag.startsWith('$prefix ')`.
///
/// **Только подписки с заданным префиксом** участвуют (юзер: «префикс не
/// задан → нет поиска»). Пустой результат = тег не начинается ни с одного
/// префикса → caller относит его к категории `'custom'` (UserServer,
/// подписка без префикса, импортированный JSON).
///
/// Заменил §077 reverse-map по node-спискам + collision-suffix эвристику
/// (`TagResolver.matchesAllocated`) — целый класс багов §077/§079/§080
/// исчезает структурно (UI больше не reverse-парсит тег).
///
/// **Prefix-collision (принятый tradeoff модели):** если две подписки имеют
/// одинаковый префикс — нода честно мэтчит обе. Тот же эффект, если нода
/// **чужого списка** (UserServer / подписка без своего chip'а) случайно
/// начинается с префикса реальной подписки: она будет приписана подписке, а
/// не «Custom». Достижимо только нестандартно (UI не даёт UserServer'у
/// префикс при наличии нод — только v1-миграция `proxy_source_migration` или
/// backup-импорт), и решается уникальностью префиксов. Чистого prefix-фикса
/// нет без возврата проверки членства в node-списках (ровно то, что §091
/// убрал ради устранения класса §077/§079/§080). См. §091 edge-cases.
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
    if (prefix.isEmpty) continue; // §091: нет префикса → нет фильтра
    if (tag.startsWith('$prefix ')) result.add(e.id);
  }
  return result;
}
