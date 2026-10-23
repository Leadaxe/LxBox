part of '../post_steps.dart';

/// Post-step: §680 — `domain_resolver` DNS-сервера на неэмитированный тег.
///
/// ПРОБЛЕМА: после §680 список DNS-серверов принадлежит пользователю, тег,
/// на который ссылается `domain_resolver` (var `dom_resolver` шаблонного
/// сервера, inline-ключ), может в список не входить: новая версия шаблона
/// сменила дефолт var на сервер, которого у пользователя нет. Гарда в
/// [resolveTemplateDnsServerBody] нет — ядро отвергло бы конфиг на старте.
/// Лок «used by» закрывает только пользовательское удаление.
///
/// РЕШЕНИЕ: ключ `domain_resolver` (строка или `{server, …}`), указывающий на
/// тег вне `dns.servers`, снимается с предупреждением сборки. Ядро тогда
/// берёт `route.default_domain_resolver`. Ссылки на серверы, выпавшие из-за
/// висячего detour, сюда не доходят — их раньше лечит
/// [healDetourDroppedDnsRefs].
///
/// Мутирует [config]. Возвращает тексты предупреждений.
List<String> healDanglingDnsServerResolvers(Map<String, dynamic> config) {
  final dns = config['dns'];
  if (dns is! Map<String, dynamic>) return const [];
  final servers = dns['servers'];
  if (servers is! List) return const [];
  final tags = <String>{
    for (final s in servers)
      if (s is Map && s['tag'] is String) s['tag'] as String,
  };
  final warnings = <String>[];
  for (final s in servers) {
    if (s is! Map<String, dynamic>) continue;
    final ref = domainResolverServer(s['domain_resolver']);
    if (ref == null || tags.contains(ref)) continue;
    s.remove('domain_resolver');
    warnings.add(
        "DNS server '${s['tag']}': domain_resolver '$ref' dropped (not in list)");
  }
  return warnings;
}
