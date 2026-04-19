import '../../models/node_spec.dart';
import 'body_decoder.dart';
import 'ini_parser.dart';
import 'json_parsers.dart';
import 'uri_parsers.dart';

/// Парсинг декодированного тела в список узлов (§3.3).
///
/// Ошибки отдельных строк — null-skip, не throw. Верхнеуровневый exhaustive
/// switch гарантирует, что новый тип DecodedBody сломает компиляцию.
List<NodeSpec> parseAll(DecodedBody decoded) {
  return switch (decoded) {
    UriLines(lines: final ls) =>
      ls.map(parseUri).whereType<NodeSpec>().toList(),
    IniConfig(text: final t) => [
        parseWireguardIni(t),
      ].whereType<NodeSpec>().toList(),
    JsonConfig() => _parseJson(decoded),
    DecodeFailure() => const <NodeSpec>[],
  };
}

List<NodeSpec> _parseJson(JsonConfig j) {
  switch (j.flavor) {
    case JsonFlavor.xrayArray:
      if (j.value is! List) return const [];
      return (j.value as List)
          .whereType<Map<String, dynamic>>()
          .map(parseXrayOutbound)
          .whereType<NodeSpec>()
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
