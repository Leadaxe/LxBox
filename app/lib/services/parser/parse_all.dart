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

List<NodeSpec> _parseJson(JsonConfig j) {
  switch (j.flavor) {
    case JsonFlavor.xrayArray:
      if (j.value is! List) return const [];
      // §310 — элемент массива даёт N узлов (все VLESS, кроме dialer-целей),
      // а не один «main». Порядок узлов внутри элемента задаёт парсер.
      return (j.value as List)
          .whereType<Map<String, dynamic>>()
          .expand(parseXrayElement)
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
