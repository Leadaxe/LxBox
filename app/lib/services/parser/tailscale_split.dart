import 'dart:convert';

import '../../models/node_spec.dart';
import 'body_decoder.dart';

/// §437 — текст вставленного JSON без `tailscale`-записей.
///
/// Многоузловой конфиг с endpoint'ом Tailscale контроллер разбирает надвое:
/// узлы Tailscale уезжают в свои `UserServer` (связка живёт только у
/// свободных узлов), а остаток идёт прежним путём. Остаток обязан быть
/// ТЕКСТОМ без tailscale, а не отфильтрованным списком узлов: файловая
/// подписка хранит тело в кэше и перечитывает его на старте
/// (`_rehydrateFromCache`) — иначе узел вернулся бы дублем.
///
/// `null` — форма, в которой вырезать нечего (Xray/Clash/URI-строки) или
/// вырезать нечего по факту (tailscale-записей не было).
String? textWithoutTailscale(JsonConfig decoded) {
  final copy = deepCopyJson(decoded.value);
  var removed = false;

  bool isTailscale(Object? e) =>
      e is Map && e['type']?.toString() == 'tailscale';

  void stripConfig(Map<String, dynamic> cfg) {
    for (final key in const ['outbounds', 'endpoints']) {
      final list = cfg[key];
      if (list is! List) continue;
      final kept = [for (final e in list) if (!isTailscale(e)) e];
      if (kept.length == list.length) continue;
      removed = true;
      // Пустой `endpoints` убираем целиком: ключ-пустышка ничего не значит и
      // только мешает опознанию формы.
      if (kept.isEmpty && key == 'endpoints') {
        cfg.remove(key);
      } else {
        cfg[key] = kept;
      }
    }
  }

  Object? out;
  switch (decoded.flavor) {
    case JsonFlavor.singboxConfig:
      if (copy is! Map<String, dynamic>) return null;
      stripConfig(copy);
      out = copy;
    case JsonFlavor.singboxMulti:
      if (copy is! List) return null;
      for (final c in copy.whereType<Map<String, dynamic>>()) {
        stripConfig(c);
      }
      out = copy;
    case JsonFlavor.singboxArray:
      if (copy is! List) return null;
      final kept = [for (final e in copy) if (!isTailscale(e)) e];
      removed = kept.length != copy.length;
      out = kept;
    case JsonFlavor.singboxOutbound:
    case JsonFlavor.xrayArray:
    case JsonFlavor.clashYaml:
    case JsonFlavor.unknown:
      return null;
  }
  if (!removed) return null;
  return const JsonEncoder.withIndent('  ').convert(out);
}
