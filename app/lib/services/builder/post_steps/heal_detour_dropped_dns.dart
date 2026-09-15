part of '../post_steps.dart';

/// §441/§443 (SPEC 129 Н10, D-118) — ссылки на DNS-серверы, выпавшие второй
/// линией fail-closed: `detour` после подстановки указывает на тег, которого
/// нет в конфиге ([resolveDnsServersBodies], [detourDropped]), и DNS-группы,
/// опустевшие от этого.
///
/// ЕДИНСТВЕННОЕ место политики этого случая, форма — таблица Н10 SPEC 129
/// лаунчера (`core/build/dns_detour_sanitize.go`):
///
/// - `dns.rules[]` с `server` из [detourDropped] → `action: reject` (SPEC 129
///   §13 п. 4). Снятое правило отдало бы свои домены `dns.final`, а при
///   прямом `final` это утечка по доменам правила. Сопоставители остаются,
///   поля маршрута снимаются: у `reject` ядро принимает только
///   `method`/`no_drop`, лишний ключ роняет конфиг.
/// - `dns.final` на выпавший сервер → ключ снимается, последним DNS-правилом
///   встаёт `{"action": "reject"}` без условий. Без `final` ядро берёт первый
///   сервер списка — у шаблона это системный резолвер; заглушка не пускает к
///   нему ни один запрос (ядро lx.39: `check` принимает, живое отвечает
///   REFUSED).
/// - `route.default_domain_resolver`, `domain_resolver` узлов
///   (`outbounds[]`, `endpoints[]`) и DNS-серверов → замена: умолчание шаблона
///   (`dns_default_domain_resolver` из [defaults]), если он эмитирован и
///   пригоден, иначе первый эмитированный сервер не `fakeip`/`hosts`
///   ([_DnsResolverPool]). Резолвер адреса сервера работает ДО туннеля:
///   пользовательских доменов там нет, а без резолвера ядро не стартует.
///   Заменить нечем — ключ снимается. У DNS-сервера, чей адрес — IP (или
///   адреса нет), `domain_resolver` просто снимается: резолвер ему не нужен.
///   Значение-объект (`{server, strategy, …}`) сохраняет форму.
///
/// Сервер, выпавший из-за висячего `endpoint` (Tailscale, NODE_SECTIONS §6),
/// сюда не попадает и лечится прежним механизмом: правило снимается,
/// `dns.final` — политика §419 ([healDanglingDnsResolvers]).
///
/// Замены НЕ персистятся (в отличие от §419): сервер выпал, а выбор
/// пользователя цел — вернётся Направление, вернётся и сервер со всеми
/// ссылками. [detourDropped] пуст — конфиг не меняется ни в одном байте.
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
  // Копии, а не правка на месте: тело правила может быть картой модели.
  final out = <dynamic>[];
  var rulesChanged = false;
  if (rules is List) {
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
      rulesChanged = true;
      warnings.add('DNS rule #$i now rejects: its server "$server" was dropped '
          '(detour is not in the config).');
    }
  }

  final dnsFinal = dns['final'];
  if (dnsFinal is String && detourDropped.contains(dnsFinal)) {
    dns.remove('final');
    out.add(<String, dynamic>{'action': 'reject'});
    rulesChanged = true;
    warnings.add('dns.final removed: DNS server "$dnsFinal" was dropped '
        '(detour is not in the config), remaining queries are rejected.');
  }
  if (rulesChanged) dns['rules'] = out;

  final pool = _DnsResolverPool.of(config);
  final preferred = defaults['dns_default_domain_resolver'] ?? '';

  /// Ключ-резолвер [key] объекта [owner] на выпавший сервер: замена
  /// ([except] — сам носитель), заменить нечем или [dropOnly] — ключ
  /// снимается. Строка или объект `{server, …}` — форма значения сохраняется.
  void heal(Map<String, dynamic> owner, String key, String where,
      {String except = '', bool dropOnly = false}) {
    final value = owner[key];
    final target = switch (value) {
      String s => s,
      Map m when m['server'] is String => m['server'] as String,
      _ => null,
    };
    if (target == null || !detourDropped.contains(target)) return;
    final to =
        dropOnly ? null : pool?.replacement(preferred, except: except);
    if (to == null) {
      owner.remove(key);
      warnings.add(dropOnly
          ? '$where: $key removed, DNS server "$target" was dropped (detour '
              'is not in the config).'
          : '$where: $key removed, DNS server "$target" was dropped (detour '
              'is not in the config) and no DNS server can replace it.');
      return;
    }
    if (value is Map) {
      owner[key] = <String, dynamic>{...value.cast<String, dynamic>(), 'server': to};
    } else {
      owner[key] = to;
    }
    warnings.add('$where: $key switched to "$to", DNS server "$target" was '
        'dropped (detour is not in the config).');
  }

  final route = config['route'];
  if (route is Map<String, dynamic>) {
    heal(route, 'default_domain_resolver', 'route');
  }
  for (final section in const ['outbounds', 'endpoints']) {
    for (final o in (config[section] as List<dynamic>? ?? const [])) {
      if (o is! Map<String, dynamic>) continue;
      heal(o, 'domain_resolver', '$section "${o['tag'] ?? ''}"');
    }
  }
  for (final s in (dns['servers'] as List<dynamic>? ?? const [])) {
    if (s is! Map<String, dynamic>) continue;
    final tag = s['tag'] as String? ?? '';
    heal(s, 'domain_resolver', 'DNS server "$tag"',
        except: tag, dropOnly: !_dnsAddressIsDomain(s['server']));
  }
  return warnings;
}

/// Адрес DNS-сервера — имя, а не IP-литерал (`[v6]` тоже IP). Пусто или не
/// строка — не имя: резолвер такому серверу не нужен.
bool _dnsAddressIsDomain(Object? address) {
  if (address is! String) return false;
  var a = address.trim();
  if (a.isEmpty) return false;
  if (a.startsWith('[') && a.endsWith(']')) a = a.substring(1, a.length - 1);
  try {
    Uri.parseIPv4Address(a);
    return false;
  } on FormatException {
    // не IPv4
  }
  try {
    Uri.parseIPv6Address(a);
    return false;
  } on FormatException {
    return true;
  }
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
