part of '../post_steps.dart';

/// Post-step: §247 — деградация битых `server`-ссылок у resolve-правил.
///
/// ПРОБЛЕМА: route-правило `{action: resolve, server: <tag>}` ссылается на
/// DNS-сервер, которого в собранном `dns.servers` нет. Источники: пресет
/// ru-direct (`server: @dns_server` эмитится route-аспектом, а сам сервер —
/// DNS-аспектом; выключенная DNS-галка → тег повисает), юзер-правило §247
/// (выбранный сервер позже выключили/удалили в DNS Settings), raw-JSON.
/// Ядро НЕ валидирует это на старте — падает лениво на каждом сматчившемся
/// соединении: `DNS server not found: <tag>` → fatal per-connection → весь
/// трафик матча мёртв (route/route.go actionResolve). Наш validator проверяет
/// только `dns.final` / `route.default_domain_resolver` — эту ссылку не видит.
///
/// РЕШЕНИЕ (как §172 с detour): битая ссылка ДЕГРАДИРУЕТ, не убивает трафик.
/// `server` снимается — резолв уходит в обычный DNS-роутинг (dns.rules /
/// `route.default_domain_resolver`), правило продолжает работать. Зовётся
/// ПЕРЕД `validateConfig`.
///
/// Возвращает список снятых ссылок (`ruleIndex → отсутствующий-tag`) для
/// emitWarnings. Пустой = всё чисто.
List<({int ruleIndex, String target})> healDanglingResolveServers(
    Map<String, dynamic> config) {
  final dns = config['dns'];
  final serverTags = <String>{
    if (dns is Map<String, dynamic>)
      for (final s in (dns['servers'] as List<dynamic>? ?? const []))
        if (s is Map<String, dynamic>) s['tag'] as String? ?? '',
  }..remove('');

  final route = config['route'];
  if (route is! Map<String, dynamic>) return const [];
  final rules = route['rules'];
  if (rules is! List) return const [];

  final removed = <({int ruleIndex, String target})>[];
  for (var i = 0; i < rules.length; i++) {
    final r = rules[i];
    if (r is! Map<String, dynamic>) continue;
    if (r['action'] != 'resolve') continue;
    final server = r['server'];
    if (server is! String || server.isEmpty) continue;
    if (serverTags.contains(server)) continue;
    r.remove('server');
    removed.add((ruleIndex: i, target: server));
  }
  return removed;
}
