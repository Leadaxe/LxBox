import '../../controllers/subscription_controller.dart';
import '../../models/server_list.dart';
import '../../services/tag_resolver.dart';

/// §091/§235 — какие ИСТОЧНИКИ (подписки + папки §234) «владеют» данным
/// display-тэгом, по **префиксу**.
///
/// `config-tag == нода в Clash`, но `subId` в конфиг не пишется — единственный
/// реальный mismatch (§091 spec). Восстанавливаем принадлежность чисто по
/// эмитированному префиксу: билдер кладёт тег как `'$tagPrefix $bare'`
/// (`TagResolver.displayTag`), поэтому нода принадлежит источнику ⇔
/// `tag.startsWith('$prefix ')`.
///
/// **Только источники с заданным префиксом** участвуют (юзер: «префикс не
/// задан → нет поиска»). Пустой результат = тег не начинается ни с одного
/// префикса → caller относит его к категории `'custom'` (UserServer,
/// источник без префикса, импортированный JSON). Одиночный `UserServer` НЕ
/// участвует (§091: UI не даёт ему префикс при наличии нод).
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
Set<String> sourcesOfTag(
  String tag,
  List<SubscriptionEntry> entries,
) {
  final result = <String>{};
  for (final e in entries) {
    final list = e.list;
    // §235 — источник = подписка ИЛИ папка (§234).
    if (list is! SubscriptionServers && list is! FolderServers) continue;
    if (!e.enabled) continue; // disabled источники не эмитят node'ы в config
    final prefix = list.tagPrefix;
    if (prefix.isEmpty) continue; // §091: нет префикса → нет фильтра
    if (tag.startsWith('$prefix ')) result.add(e.id);
  }
  return result;
}

/// §255 — владелец config-тэга: entry + (для папки) индекс члена. Для
/// навигации из detour-cycle sheet прямо в экран владельца.
class TagOwner {
  /// Индекс entry в `SubscriptionController.entries`.
  final int entryIndex;

  /// Индекс члена в `FolderServers.members` (null = не папка / одиночный).
  final int? memberIndex;

  const TagOwner(this.entryIndex, {this.memberIndex});
}

/// §254/§255 — какой entry владеет данным config-тэгом (для навигации из
/// detour-cycle sheet в экран владельца). В отличие от [sourcesOfTag] —
/// суперсет: ловит и `UserServer` (без префикса), и одиночный сервер, и члена
/// папки, матча по bare-тегу ноды (не только по префиксу). Возвращает
/// [TagOwner] первого совпавшего entry (+ memberIndex для папки) либо `null`
/// (тег без владельца — custom JSON).
///
/// Тег в конфиге = `TagResolver.displayTag(prefix, bare)`, плюс возможный
/// `allocateTag`-суффикс дедупликации `-<digits>`. Пробуем сперва тег как есть
/// (bare-тег, легитимно кончающийся на `-2`, выигрывает), затем со снятым
/// суффиксом.
///
/// Tradeoff (как [sourcesOfTag] §091): prefix-collision → вернём соседа с тем
/// же префиксом; неоднозначность суффикса → косметически не та строка. Оба
/// приемлемы для affordance «открыть владельца».
TagOwner? ownerOfTag(String culpritTag, List<SubscriptionEntry> entries) {
  final candidates = <String>[culpritTag];
  final m = RegExp(r'^(.*)-\d+$').firstMatch(culpritTag);
  if (m != null) candidates.add(m.group(1)!);

  for (final cand in candidates) {
    for (var ei = 0; ei < entries.length; ei++) {
      final list = entries[ei].list;
      final bare = TagResolver.stripPrefix(cand, list.tagPrefix);
      if (list is FolderServers) {
        for (var mi = 0; mi < list.members.length; mi++) {
          if (list.members[mi].node?.tag == bare) {
            return TagOwner(ei, memberIndex: mi);
          }
        }
      } else {
        for (final n in list.nodes) {
          if (n.tag == bare) return TagOwner(ei);
          // §404 — цепочка бывает многохоповой (`dialerProxy` релея на
          // следующий релей): ищем по всем звеньям, не только по первому.
          for (var hop = n.chained; hop != null; hop = hop.chained) {
            if (hop.tag == bare) return TagOwner(ei);
          }
        }
      }
    }
  }
  return null;
}
