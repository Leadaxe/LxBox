import '../../models/node_spec.dart';
import 'body_decoder.dart';
import 'ini_parser.dart';
import 'json_parsers.dart';
import 'uri_parsers.dart';

/// Парсинг декодированного тела в список узлов (§3.3).
///
/// Ошибки отдельных строк — null-skip, не throw. Верхнеуровневый exhaustive
/// switch гарантирует, что новый тип DecodedBody сломает компиляцию.
///
/// §243 — [nameHint] (имя файла при импорте) прокидывается только в
/// INI-ветки: у INI нет собственного имени, tag берётся из фрагмента
/// синтетического URI. URI-строки и JSON несут имена сами — hint игнорируют.
List<NodeSpec> parseAll(DecodedBody decoded, {String? nameHint}) {
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
    JsonConfig() => _parseJson(decoded),
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

List<NodeSpec> _parseJson(JsonConfig j) {
  switch (j.flavor) {
    case JsonFlavor.xrayArray:
      if (j.value is! List) return const [];
      // §310 — элемент массива даёт N узлов (кроме dialer-целей), а не один
      // «main». Порядок узлов внутри элемента задаёт парсер.
      final elements =
          (j.value as List).whereType<Map<String, dynamic>>().toList();
      // §321 P4 — накопитель идентичностей на всю подписку. Между подписками
      // дедуп НЕ работает намеренно: разные источники = разные
      // tag_prefix/detour_policy, схлопывать их нельзя.
      final seen = <String>{};
      // §321 P6 — таблица синонимов копится по ВСЕЙ подписке: тег провайдера
      // → идентичность. §322 резолвит по ней состав пула, написанный на чужих
      // тегах (`selector: ["proxy"]`).
      final synonyms = <String, String>{};

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
      final priming = elements.toList()
        ..sort((a, b) => _payloadCount(a).compareTo(_payloadCount(b)));
      final owner = <String, Map<String, dynamic>>{};
      for (final e in priming) {
        final before = seen.toSet();
        parseXrayElement(e, seen: seen, synonyms: synonyms);
        for (final id in seen.difference(before)) {
          owner[id] = e;
        }
      }
      return elements
          .expand((e) => parseXrayElement(
                e,
                // `seen` этого прохода — свой: общий накопитель уже полон, и
                // дедуп-`continue` съел бы все узлы. Ownership из прохода 1
                // передаём через `ownedBy`.
                seen: <String>{},
                synonyms: synonyms,
                ownedBy: (id) => identical(owner[id], e),
              ))
          .toList();
    case JsonFlavor.singboxOutbound:
      if (j.value is! Map<String, dynamic>) return const [];
      final spec = parseSingboxEntry(j.value as Map<String, dynamic>);
      return spec == null ? const [] : [spec];
    case JsonFlavor.clashYaml:
    case JsonFlavor.unknown:
      return const [];
  }
}
