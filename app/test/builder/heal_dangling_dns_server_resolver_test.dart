import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/builder/post_steps.dart';

/// §680 — healDanglingDnsServerResolvers: `domain_resolver` DNS-сервера на
/// тег, которого нет в `dns.servers`, снимается с предупреждением сборки.
void main() {
  Map<String, dynamic> cfg(List<Map<String, dynamic>> servers) => {
        'dns': {'servers': servers},
        'route': {'default_domain_resolver': 'cloudflare_udp'},
      };

  test('ссылка на сервер из списка — не трогаем', () {
    final c = cfg([
      {'tag': 'google_udp', 'type': 'udp', 'server': '8.8.8.8'},
      {
        'tag': 'safe_dns_dot',
        'type': 'tls',
        'server': 'dns.example',
        'domain_resolver': 'google_udp',
      },
    ]);
    expect(healDanglingDnsServerResolvers(c), isEmpty);
    expect((c['dns']['servers'] as List)[1]['domain_resolver'], 'google_udp');
  });

  test('строка на тег вне списка — ключ снят, предупреждение', () {
    final c = cfg([
      {
        'tag': 'safe_dns_dot',
        'type': 'tls',
        'server': 'dns.example',
        'domain_resolver': 'google_udp',
      },
    ]);
    expect(healDanglingDnsServerResolvers(c), [
      "DNS server 'safe_dns_dot': domain_resolver 'google_udp' dropped "
          '(not in list)',
    ]);
    final s = (c['dns']['servers'] as List).single as Map;
    expect(s.containsKey('domain_resolver'), isFalse);
    expect(s['server'], 'dns.example');
  });

  test('объектная форма {server} на тег вне списка — ключ снят', () {
    final c = cfg([
      {
        'tag': 'my-doh',
        'type': 'https',
        'server': 'dns.example',
        'domain_resolver': {'server': 'gone', 'strategy': 'ipv4_only'},
      },
    ]);
    expect(healDanglingDnsServerResolvers(c), hasLength(1));
    expect(
        ((c['dns']['servers'] as List).single as Map)
            .containsKey('domain_resolver'),
        isFalse);
  });

  test('нет dns.servers — no-op', () {
    expect(healDanglingDnsServerResolvers(<String, dynamic>{}), isEmpty);
  });
}
