import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/builder/post_steps.dart';

/// §419 — healDanglingDnsResolvers: `dns.final` / `route.default_domain_resolver`
/// на исчезнувший сервер (пресет выключен/удалён) заменяются дефолтом шаблона
/// в сборке, а не только при открытии экрана DNS (§121 слой D). Иначе каждая
/// сборка — fatal DanglingDnsServerRef и вечная плашка «Settings changed».
void main() {
  const defaults = {
    'dns_final': 'local_dns_resolver',
    'dns_default_domain_resolver': 'cloudflare_udp',
  };

  Map<String, dynamic> cfg({
    required List<Map<String, dynamic>> servers,
    String? dnsFinal,
    String? resolver,
  }) =>
      {
        'dns': {
          'servers': servers,
          'final': ?dnsFinal,
        },
        'route': {
          'rules': <dynamic>[],
          'default_domain_resolver': ?resolver,
        },
      };

  const local = {'tag': 'local_dns_resolver', 'type': 'local'};
  const cf = {'tag': 'cloudflare_udp', 'type': 'udp', 'server': '1.1.1.1'};
  const fake = {'tag': 'fakeip', 'type': 'fakeip'};

  test('живые ссылки — не трогаем', () {
    final c = cfg(
        servers: [local, cf], dnsFinal: 'cloudflare_udp', resolver: 'local_dns_resolver');
    expect(healDanglingDnsResolvers(c, defaults: defaults), isEmpty);
    expect(c['dns']['final'], 'cloudflare_udp');
    expect(c['route']['default_domain_resolver'], 'local_dns_resolver');
  });

  test('битые обе ссылки → дефолты шаблона, var-имена для персиста', () {
    final c = cfg(
        servers: [local, cf],
        dnsFinal: 'ru-direct:yandex_dot',
        resolver: 'ru-direct:yandex_dot');
    final healed = healDanglingDnsResolvers(c, defaults: defaults);
    expect(healed.map((h) => (h.field, h.varName, h.from, h.to)), [
      ('dns.final', 'dns_final', 'ru-direct:yandex_dot', 'local_dns_resolver'),
      (
        'route.default_domain_resolver',
        'dns_default_domain_resolver',
        'ru-direct:yandex_dot',
        'cloudflare_udp'
      ),
    ]);
    expect(c['dns']['final'], 'local_dns_resolver');
    expect(c['route']['default_domain_resolver'], 'cloudflare_udp');
  });

  test('дефолт не эмитится → первый пригодный сервер, fakeip/hosts мимо', () {
    final c = cfg(
      servers: [fake, {'tag': 'hosts', 'type': 'hosts'}, cf],
      dnsFinal: 'gone',
    );
    final healed = healDanglingDnsResolvers(c, defaults: defaults);
    expect(healed.single.to, 'cloudflare_udp');
    expect(c['dns']['final'], 'cloudflare_udp');
  });

  test('только непригодные серверы — не трогаем (валидатор скажет своё)', () {
    final c = cfg(servers: [fake], dnsFinal: 'gone');
    expect(healDanglingDnsResolvers(c, defaults: defaults), isEmpty);
    expect(c['dns']['final'], 'gone');
  });

  test('пустое поле и отсутствие dns — no-op', () {
    final c = cfg(servers: [local], dnsFinal: '');
    expect(healDanglingDnsResolvers(c, defaults: defaults), isEmpty);
    expect(healDanglingDnsResolvers(<String, dynamic>{'route': {}},
        defaults: defaults), isEmpty);
  });
}
