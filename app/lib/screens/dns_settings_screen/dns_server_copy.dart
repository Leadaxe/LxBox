import '../../models/dns_ref.dart';
import '../../services/builder/preset_expand.dart' show normalizeDnsDetour;
import '../../services/json_clone.dart' show deepCopyJson;

// §682 — копия шаблонного/пресетного сервера: новая inline-запись, тело
// которой — разрешённое тело оригинала. Оригинал не трогается, ссылок на
// копию не появляется. — pure.

/// Тег копии: `<тег>_copy`, при занятости `_copy2`, `_copy3`, … Пространство
/// пресета (`ru-direct:yandex_dot`) снимается: копия — свой сервер.
String dnsCopyTag(String tag, Set<String> taken) {
  final colon = tag.indexOf(':');
  final base = colon >= 0 ? tag.substring(colon + 1) : tag;
  var candidate = '${base}_copy';
  for (var n = 2; taken.contains(candidate); n++) {
    candidate = '${base}_copy$n';
  }
  return candidate;
}

/// Inline-запись из разрешённого тела [body] (vars уже подставлены).
/// `detour` нормализуется как в превью и сборке (`direct-out` = нет ключа);
/// ref-level поля и UI-аннотации из тела снимаются.
DnsServerInline dnsServerCopy({
  required Map<String, dynamic> body,
  required String tag,
  required bool enabled,
  String? description,
}) {
  final b = deepCopyJson(body)
    ..remove('tag')
    ..remove('description')
    ..remove('enabled')
    ..remove('_preset_label')
    ..remove('_preset_id');
  normalizeDnsDetour(b);
  return DnsServerInline(
    enabled: enabled,
    tag: tag,
    description: (description == null || description.isEmpty)
        ? null
        : description,
    body: b,
  );
}
