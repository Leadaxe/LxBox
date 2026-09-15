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
/// сборке. Битая ссылка заменяется дефолтом шаблона (`default_value` var'а;
/// сейчас `dns_shield` для обеих — template-группа, всегда эмитится); если
/// дефолт почему-то не эмитится — первым эмитированным сервером, пригодным
/// как резольвер (не `fakeip`/`hosts`, иначе §384 [BadResolverServerType]).
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
  final pool = _DnsResolverPool.of(config);
  if (pool == null) return const [];

  String? replacementFor(String current, String varName) {
    if (current.isEmpty || pool.tags.contains(current)) return null;
    return pool.replacement(defaults[varName] ?? '');
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

/// §419 — эмитированные DNS-серверы как пул замен для резолвер-ссылок:
/// [tags] — все теги `dns.servers`, [usable] — пригодные резольверы (не
/// `fakeip`/`hosts`, §384). Одна политика замены на §419 и §441
/// ([healDetourDroppedDnsRefs]).
class _DnsResolverPool {
  _DnsResolverPool(this.tags, this.usable);

  final Set<String> tags;
  final List<String> usable;

  /// `null` — серверов или пригодных резольверов нет: заменять нечем.
  static _DnsResolverPool? of(Map<String, dynamic> config) {
    final dns = config['dns'];
    if (dns is! Map<String, dynamic>) return null;
    final servers = (dns['servers'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final tags = <String>{
      for (final s in servers) s['tag'] as String? ?? '',
    }..remove('');
    if (tags.isEmpty) return null;
    const forbidden = {'fakeip', 'hosts'};
    final usable = <String>[
      for (final s in servers)
        if ((s['tag'] as String? ?? '').isNotEmpty &&
            !forbidden.contains(s['type']))
          s['tag'] as String,
    ];
    if (usable.isEmpty) return null;
    return _DnsResolverPool(tags, usable);
  }

  /// Замена битой ссылки: [preferred] (умолчание шаблона), если он пригоден,
  /// иначе первый пригодный, кроме [except]. `null` — пригодного нет.
  String? replacement(String preferred, {String except = ''}) {
    if (preferred.isNotEmpty &&
        preferred != except &&
        usable.contains(preferred)) {
      return preferred;
    }
    for (final t in usable) {
      if (t != except) return t;
    }
    return null;
  }
}
