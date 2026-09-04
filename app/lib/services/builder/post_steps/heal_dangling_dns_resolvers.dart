part of '../post_steps.dart';

/// Post-step: §419 — лечение битых resolver-ссылок `dns.final` /
/// `route.default_domain_resolver`.
///
/// ПРОБЛЕМА: оба поля приходят из vars (`@dns_final`,
/// `@dns_default_domain_resolver`) и могут указывать на DNS-сервер, которого в
/// собранном `dns.servers` больше нет: сервер принадлежал пресету
/// (`ru-direct:yandex_dot`), пресет выключили или удалили — §121 «routing
/// король» унёс его серверы, а выбранный резольвер остался. Валидатор честно
/// ставит fatal [DanglingDnsServerRef], конфиг не сохраняется, флаг «грязно»
/// не снимается — плашка «Settings changed» висит вечно, а тап по ней падает
/// в тот же fatal. Автосброс §121 (слой D) жил только в `DnsController._load`,
/// то есть срабатывал лишь при ОТКРЫТИИ экрана DNS Settings.
///
/// РЕШЕНИЕ: та же деградация, что у §247 для resolve-правил, — здесь, в
/// сборке. Битая ссылка заменяется дефолтом шаблона (`local_dns_resolver` /
/// `cloudflare_udp` — оба всегда в каталоге, §121 п. 6); если дефолт
/// почему-то не эмитится — первым эмитированным сервером, пригодным как
/// резольвер (не `fakeip`/`hosts`, иначе §384 [BadResolverServerType]).
/// Нет ни одного пригодного сервера — не трогаем, валидатор скажет своё.
///
/// Мутирует [config]. Возвращает список замен: `varName` — какую var
/// персистить (через `generatedVars` контроллер запишет её в сторадж, чтобы
/// следующая сборка была чистой, а экран DNS показывал то же значение).
List<({String field, String varName, String from, String to})>
    healDanglingDnsResolvers(
  Map<String, dynamic> config, {
  required Map<String, String> defaults,
}) {
  final dns = config['dns'];
  if (dns is! Map<String, dynamic>) return const [];
  final servers = (dns['servers'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .toList();
  final tags = <String>{
    for (final s in servers) s['tag'] as String? ?? '',
  }..remove('');
  if (tags.isEmpty) return const [];
  const forbidden = {'fakeip', 'hosts'};
  final usable = <String>[
    for (final s in servers)
      if ((s['tag'] as String? ?? '').isNotEmpty &&
          !forbidden.contains(s['type']))
        s['tag'] as String,
  ];
  if (usable.isEmpty) return const [];

  String? replacementFor(String current, String varName) {
    if (current.isEmpty || tags.contains(current)) return null;
    final def = defaults[varName] ?? '';
    if (def.isNotEmpty && usable.contains(def)) return def;
    return usable.first;
  }

  final healed = <({String field, String varName, String from, String to})>[];

  final dnsFinal = dns['final'];
  if (dnsFinal is String) {
    final to = replacementFor(dnsFinal, 'dns_final');
    if (to != null) {
      dns['final'] = to;
      healed.add((
        field: 'dns.final',
        varName: 'dns_final',
        from: dnsFinal,
        to: to,
      ));
    }
  }

  final route = config['route'];
  if (route is Map<String, dynamic>) {
    final resolver = route['default_domain_resolver'];
    if (resolver is String) {
      final to = replacementFor(resolver, 'dns_default_domain_resolver');
      if (to != null) {
        route['default_domain_resolver'] = to;
        healed.add((
          field: 'route.default_domain_resolver',
          varName: 'dns_default_domain_resolver',
          from: resolver,
          to: to,
        ));
      }
    }
  }
  return healed;
}
