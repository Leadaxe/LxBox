import '../config/consts.dart';

/// §085 R1 — единый владелец domain-концепта «display-tag».
///
/// **Display-tag** = тег как он эмитится в sing-box config:
/// `'$tagPrefix $base'` при непустом prefix, иначе bare `base`. До §085 эта
/// логика была размазана по 6+ местам (builder `_withPrefix`, UI
/// reverse-lookup, detour-detection, prefix-strip, collision-suffix), что
/// породило целый класс багов: §077 (subscription filter не мэтчил
/// prefixed), §079 (detour-hide ломался на prefixed), §080 (detour picker
/// хранил bare вместо display).
///
/// Все методы pure static — без состояния, тестируются изолированно
/// (`tag_resolver_test.dart`). Единственная зависимость — `kDetourTagPrefix`
/// из consts.
class TagResolver {
  TagResolver._();

  /// Forward: subscription prefix + bare node-tag → display-tag.
  /// **Источник истины эмиссии** — должен совпадать с тем, что builder
  /// кладёт в `outbound.tag` (`server_list_build` использует именно это).
  static String displayTag(String tagPrefix, String bareTag) =>
      tagPrefix.isEmpty ? bareTag : '$tagPrefix $bareTag';

  /// True если display-tag принадлежит detour-серверу. Маркер
  /// [kDetourTagPrefix] (`⚙ `) может стоять в начале (prefix пустой) ИЛИ в
  /// середине после subscription prefix (`'🇷🇺 ⚙ Hop'`). §079.
  static bool isDetourMarker(String displayTag) =>
      displayTag.startsWith(kDetourTagPrefix) ||
      displayTag.contains(' $kDetourTagPrefix');

  /// Reverse: убрать subscription prefix из display-tag → bare. Возвращает
  /// сам тег если prefix пустой или не совпал в начале.
  static String stripPrefix(String displayTag, String tagPrefix) {
    if (tagPrefix.isEmpty) return displayTag;
    final p = '$tagPrefix ';
    return displayTag.startsWith(p)
        ? displayTag.substring(p.length)
        : displayTag;
  }

}
