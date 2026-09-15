part of '../post_steps.dart';

/// §441 (SPEC 128 Н10) — ссылки на DNS-серверы, выпавшие второй линией
/// fail-closed: `detour` после подстановки указывает на тег, которого нет в
/// конфиге ([resolveDnsServersBodies], [detourDropped]).
///
/// ЕДИНСТВЕННОЕ место политики этого случая: лаунчер доопределяет, что
/// делать с `dns.final` и `route.default_domain_resolver` на выпавший сервер
/// («до прямого сервера не должно дойти ничего», SPEC 128), и форма меняется
/// здесь одной правкой.
///
/// - `dns.rules[]` с `server` из [detourDropped] → `action: reject` (решение
///   15.09.2026, SPEC 128 §13 п. 4). Снятое правило отдало бы свои домены
///   `dns.final`, а при прямом `final` это утечка по доменам правила.
///   Сопоставители остаются, поля маршрута снимаются: у `reject` ядро
///   принимает только `method`/`no_drop`, лишний ключ роняет конфиг.
/// - `dns.final`, `route.default_domain_resolver` → замена политикой §419
///   (`heal_dangling_dns_resolvers.dart`): умолчание шаблона из [defaults],
///   иначе первый пригодный эмитированный сервер. Пока — как у сервера
///   выключенного пресета. Замены нет — ссылка остаётся, валидатор ставит
///   fatal `DanglingDnsServerRef`.
/// - `dns.servers[].domain_resolver` → та же замена (умолчание
///   `dns_default_domain_resolver`), кроме самого сервера; замены нет — ключ
///   снимается (ядро не стартует на резолвере, которого нет).
///
/// Замены НЕ персистятся (в отличие от §419): сервер выпал, а выбор
/// пользователя цел — вернётся Направление, вернётся и сервер со всеми
/// ссылками.
///
/// Мутирует [config]. Возвращает warnings сборки.
List<String> healDetourDroppedDnsRefs(
  Map<String, dynamic> config, {
  required Set<String> detourDropped,
  Map<String, String> defaults = const {},
}) {
  if (detourDropped.isEmpty) return const [];
  final dns = config['dns'];
  if (dns is! Map<String, dynamic>) return const [];
  final warnings = <String>[];

  final rules = dns['rules'];
  if (rules is List) {
    // Копии, а не правка на месте: тело правила может быть картой модели.
    var changed = false;
    final out = <dynamic>[];
    for (var i = 0; i < rules.length; i++) {
      final r = rules[i];
      if (r is! Map<String, dynamic>) {
        out.add(r);
        continue;
      }
      final server = r['server'];
      final action = r['action'];
      if (server is! String ||
          !detourDropped.contains(server) ||
          (action != null && action != 'route' && action != 'evaluate')) {
        out.add(r);
        continue;
      }
      out.add(dnsRuleAsReject(r));
      changed = true;
      warnings.add('DNS rule #$i now rejects: its server "$server" was dropped '
          '(detour is not in the config).');
    }
    if (changed) dns['rules'] = out;
  }

  final pool = _DnsResolverPool.of(config);

  /// Замена ссылки [current] на выпавший сервер; `''` — заменить нечем.
  /// `null` — ссылка не на выпавший сервер.
  String? heal(String field, String current, String varName,
      {String except = ''}) {
    if (!detourDropped.contains(current)) return null;
    final to = pool?.replacement(defaults[varName] ?? '', except: except);
    warnings.add(to == null
        ? '$field: DNS server "$current" was dropped (detour is not in the '
            'config), and no DNS server can replace it.'
        : '$field switched to "$to": DNS server "$current" was dropped '
            '(detour is not in the config).');
    return to ?? '';
  }

  final dnsFinal = dns['final'];
  if (dnsFinal is String) {
    final to = heal('dns.final', dnsFinal, 'dns_final');
    if (to != null && to.isNotEmpty) dns['final'] = to;
  }

  final route = config['route'];
  if (route is Map<String, dynamic>) {
    final resolver = route['default_domain_resolver'];
    if (resolver is String) {
      final to = heal('route.default_domain_resolver', resolver,
          'dns_default_domain_resolver');
      if (to != null && to.isNotEmpty) {
        route['default_domain_resolver'] = to;
      }
    }
  }

  for (final s in (dns['servers'] as List<dynamic>? ?? const [])) {
    if (s is! Map<String, dynamic>) continue;
    final resolver = s['domain_resolver'];
    if (resolver is! String) continue;
    final tag = s['tag'] as String? ?? '';
    final to = heal('DNS server "$tag" domain_resolver', resolver,
        'dns_default_domain_resolver',
        except: tag);
    if (to == null) continue;
    if (to.isEmpty) {
      s.remove('domain_resolver');
    } else {
      s['domain_resolver'] = to;
    }
  }
  return warnings;
}

/// DNS-правило [rule] с отказом вместо маршрута: сопоставители те же, поля
/// маршрута (`server` и опции `route`/`evaluate`) сняты.
Map<String, dynamic> dnsRuleAsReject(Map<String, dynamic> rule) {
  const routeKeys = {
    'server',
    'action',
    'tag',
    'strategy',
    'disable_cache',
    'disable_optimistic_cache',
    'rewrite_ttl',
    'client_subnet',
    'remove_client_subnet',
    'timeout',
    'speculative',
    'race',
  };
  return <String, dynamic>{
    for (final e in rule.entries)
      if (!routeKeys.contains(e.key)) e.key: e.value,
    'action': 'reject',
  };
}
