import '../../models/node_spec.dart';
import '../../models/node_warning.dart';
import 'body_decoder.dart';
import 'ini_parser.dart';
import 'json_parsers.dart';
import 'singbox_config.dart';
import 'uri_parsers.dart';

/// Парсинг декодированного тела в список узлов (§3.3).
///
/// Ошибки отдельных строк — null-skip, не throw. Верхнеуровневый exhaustive
/// switch гарантирует, что новый тип DecodedBody сломает компиляцию.
///
/// §243 — [nameHint] (имя файла при импорте) прокидывается только в
/// INI-ветки: у INI нет собственного имени, tag берётся из фрагмента
/// синтетического URI. URI-строки и JSON несут имена сами — hint игнорируют.
///
/// §404 / D-088 — [dropped] (необязательный) собирает причины ОТБРАКОВКИ
/// целых записей тела: узел был узнан и осознанно отвергнут (недостижимый
/// `dialerProxy`), а не «не распознан вовсе». Возвращаемый список узлов о
/// таких записях не рассказывает по построению — их в нём нет, — а когда
/// подписка вырождается в пустую, причина не доезжает и до
/// `nodes.first.warnings`. Параметр не меняет поведения ни одного текущего
/// вызывающего (все передают его `null`) и нужен конформанс-раннеру корпуса:
/// конверт контракта несёт `dropped[]` наравне с `nodes[]`.
List<NodeSpec> parseAll(
  DecodedBody decoded, {
  String? nameHint,
  List<NodeWarning>? dropped,
}) {
  return switch (decoded) {
    // §302 — источник ноды для UI (вкладка Source на экране ноды): для
    // URI-тел это сама строка. У JSON-веток источник проставляет парсер
    // (там rawUri — синтетическая заглушка, см. json_parsers).
    UriLines(lines: final ls) => [
        for (final l in ls)
          if (parseUri(l) case final NodeSpec n) n..sourceCompact = l,
      ],
    IniConfig(text: final t) => [
        parseWireguardIni(t, nameHint: nameHint),
      ].whereType<NodeSpec>().map((n) => n..sourceCompact = t).toList(),
    // §110 — Amnezia vpn://: каждый контейнер → INI → нода (null-skip).
    // §243 — hint с индексным суффиксом (`hint`, `hint 2`, …): фрагмент
    // теперь «собственное имя» raw, суффикс-логика addMembersToFolder до
    // таких нод не дойдёт — разводим коллизии здесь.
    AmneziaConfig(iniTexts: final ts) => [
        for (var i = 0; i < ts.length; i++)
          parseWireguardIni(ts[i], nameHint: _indexedHint(nameHint, i)),
      ].whereType<NodeSpec>().toList(),
    JsonConfig() => _parseJson(decoded, dropped),
    DecodeFailure() => const <NodeSpec>[],
  };
}

// Суффикс — по индексу КОНТЕЙНЕРА, не произведённой ноды: при null-skip
// битого среднего контейнера в нумерации остаётся дыра («hint», «hint 3»).
// Намеренно: имя каждой ноды стабильно привязано к своему контейнеру и не
// съезжает, когда соседний контейнер перестаёт парситься.
String? _indexedHint(String? hint, int i) {
  final h = hint?.trim() ?? '';
  if (h.isEmpty) return null;
  return i == 0 ? h : '$h ${i + 1}';
}

/// §321 P2 — сколько payload-серверов описывает элемент. Служебные
/// (`freedom`/`blackhole`/`dns`) не в счёт: они есть в каждом элементе и
/// сортировку бы обнулили.
int _payloadCount(Map<String, dynamic> element) {
  final obs = element['outbounds'];
  if (obs is! List) return 0;
  const service = {'freedom', 'blackhole', 'dns', 'loopback'};
  return obs
      .whereType<Map<String, dynamic>>()
      .where((o) => !service.contains(o['protocol']?.toString() ?? ''))
      .length;
}

List<NodeSpec> _parseJson(JsonConfig j, List<NodeWarning>? out) {
  switch (j.flavor) {
    case JsonFlavor.xrayArray:
      if (j.value is! List) return const [];
      // §310 — элемент массива даёт N узлов (кроме dialer-целей), а не один
      // «main». Порядок узлов внутри элемента задаёт парсер.
      final elements =
          (j.value as List).whereType<Map<String, dynamic>>().toList();
      // §321 P4 / §404 D-086 — накопитель ПОДПИСЕЙ дедупа на всю подписку
      // (эмиссия узла без tag/detour + подпись пути дозвона). Между подписками
      // дедуп НЕ работает намеренно: разные источники = разные
      // tag_prefix/detour_policy, схлопывать их нельзя.
      final seen = <String>{};
      // §321 P6 — таблица синонимов копится по ВСЕЙ подписке: тег провайдера
      // → ключ ПУЛА (`nodeIdentityKey`, грубая четвёрка). §322 резолвит по ней
      // состав пула, написанный на чужих тегах (`selector: ["proxy"]`).
      // Гранулярность тут намеренно другая, чем у дедупа: `selector` называет
      // СЕРВЕР, а не конкретную запись подписки, и подпись §404 (которая
      // разводит два SNI одного сервера) растащила бы состав пула.
      final synonyms = <String, String>{};
      // §404 / D-085 — причины отбраковки узлов с недостижимым релеем, которым
      // не нашлось носителя внутри своего элемента (в элементе не выжил
      // никто). Вешаем их на первый узел подписки: причина обязана дойти до
      // пользователя, иначе узел исчезает молча.
      final dropped = <NodeWarning>[];

      // §342 — ДВА прохода: «кто даёт узлу имя» и «в каком порядке узлы идут»
      // — разные задачи, и раньше они решались одной сортировкой.
      //
      // Проход 1 (черновой, узлы выбрасываются) — элементы от одиночных к
      // многоузловым, ровно как в §321 P2: право выпустить сервер достаётся
      // элементу с осмысленным `remarks` («🇩🇪⚡Германия»), а не пулу («Лучший
      // сервер» с техническими тегами). Здесь же копится таблица синонимов
      // (§321 P6). Побочно узнаём владельца каждой идентичности — `owner`.
      //
      // Проход 2 (боевой) — элементы строго в порядке файла; элемент выпускает
      // только те серверы, которые закреплены за ним в проходе 1. Имена те же,
      // что и до §342, а позиции — авторские. Раньше сортировка была
      // единственным проходом, и её побочный эффект переставлял подписку
      // целиком (на боевой 37-элементной — все 37 позиций, «🚀Авто | Лучший
      // сервер» уезжал с первого места в конец), хотя порядок часто осмыслен:
      // автор ставит рекомендуемый узел первым.
      // Сортировка обязана быть СТАБИЛЬНОЙ (спека §321: связки — в порядке
      // файла), а List.sort в Dart стабилен только до ~32 элементов (дальше
      // quicksort). Индекс в компараторе делает порядок связок детерминированно
      // авторским на подписке любого размера (боевой кейс §342 — 37 элементов).
      final indexed = elements.asMap().entries.toList()
        ..sort((a, b) {
          final byPayload =
              _payloadCount(a.value).compareTo(_payloadCount(b.value));
          return byPayload != 0 ? byPayload : a.key.compareTo(b.key);
        });
      final priming = [for (final e in indexed) e.value];
      final owner = <String, Map<String, dynamic>>{};
      for (final e in priming) {
        final before = seen.toSet();
        parseXrayElement(e, seen: seen, synonyms: synonyms);
        for (final id in seen.difference(before)) {
          owner[id] = e;
        }
      }
      final nodes = elements
          .expand((e) => parseXrayElement(
                e,
                // `seen` этого прохода — свой: общий накопитель уже полон, и
                // дедуп-`continue` съел бы все узлы. Ownership из прохода 1
                // передаём через `ownedBy`.
                seen: <String>{},
                synonyms: synonyms,
                ownedBy: (sig) => identical(owner[sig], e),
                dropped: dropped,
              ))
          .toList();
      // §404 P3 — то, что осталось в `dropped`, носителя в своём элементе не
      // нашло. Последний носитель — первый узел подписки; если и его нет,
      // подписка пустая и сообщать некому (та же документированная дыра, что
      // у §321 P5).
      // D-088 — отбраковка едет наружу ЦЕЛИКОМ, независимо от того, нашёлся ли
      // ей носитель среди узлов: конверт контракта различает «запись отвергли»
      // и «тело не распознано», а `nodes.first.warnings` этого различия не
      // несёт и на пустой подписке пропадает совсем.
      out?.addAll(dropped);
      if (dropped.isNotEmpty && nodes.isNotEmpty) {
        for (final w in dropped) {
          if (!nodes.first.warnings.contains(w)) nodes.first.warnings.add(w);
        }
      }
      return nodes;
    // §368 — четыре sing-box-формы отличаются только обёрткой; нормализуем к
    // «массиву конфигов» и отдаём одному ядру. Одиночный outbound больше не
    // ходит в `parseSingboxEntry` напрямую: общий путь даёт ему то же, что
    // остальным (detour, warning'и), а массив из одного элемента вырождает
    // сортировку §342 и дедуп P4.
    case JsonFlavor.singboxOutbound:
      if (j.value is! Map<String, dynamic>) return const [];
      return parseSingboxConfigs([
        {
          'outbounds': [j.value],
        },
      ]);
    case JsonFlavor.singboxArray:
      if (j.value is! List) return const [];
      return parseSingboxConfigs([
        {'outbounds': j.value},
      ]);
    case JsonFlavor.singboxConfig:
      if (j.value is! Map<String, dynamic>) return const [];
      return parseSingboxConfigs([j.value as Map<String, dynamic>]);
    case JsonFlavor.singboxMulti:
      if (j.value is! List) return const [];
      return parseSingboxConfigs(
        (j.value as List).whereType<Map<String, dynamic>>().toList(),
      );
    case JsonFlavor.clashYaml:
    case JsonFlavor.unknown:
      return const [];
  }
}
