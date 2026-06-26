part of '../post_steps.dart';

/// Post-step: §172 — деградация битых detour-ссылок.
///
/// ПРОБЛЕМА: подписка может задавать ноде `detour` (нативная цепочка ИЛИ
/// `detourPolicy.overrideDetour`) на outbound, которого в собранном конфиге
/// нет — напр. `detour: "warp gen"`, когда WARP-пресет-цель выключен/не
/// сгенерирован. sing-box реджектит ВЕСЬ config при старте (dangling detour =
/// fatal в `validateConfig`) → один битый detour из подписки роняет весь VPN.
///
/// РЕШЕНИЕ (как §169 с REALITY): битая ссылка ДЕГРАДИРУЕТ, не роняет конфиг.
/// Если `detour` указывает на несуществующий tag → убираем поле `detour`,
/// нода остаётся рабочей (прямое соединение, без цепочки). Зовётся ПЕРЕД
/// `validateConfig` — тот уже не увидит dangling ref.
///
/// Возвращает список снятых detour'ов (`owner → отсутствующий-target`) для
/// диагностики/логов. Пустой = всё чисто.
List<({String owner, String target})> healDanglingDetours(
    Map<String, dynamic> config) {
  final outbounds = (config['outbounds'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .toList();
  final endpoints = (config['endpoints'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .toList();

  final allTags = <String>{
    for (final o in outbounds) o['tag'] as String? ?? '',
    for (final e in endpoints) e['tag'] as String? ?? '',
  }..remove('');

  final removed = <({String owner, String target})>[];
  for (final o in [...outbounds, ...endpoints]) {
    final detour = o['detour'];
    if (detour is! String || detour.isEmpty) continue;
    if (allTags.contains(detour)) continue;
    // Битая ссылка → снимаем detour, нода работает напрямую.
    o.remove('detour');
    removed.add((owner: o['tag'] as String? ?? '', target: detour));
  }
  return removed;
}
