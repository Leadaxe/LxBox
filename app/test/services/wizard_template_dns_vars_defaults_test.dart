import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/builder/post_steps.dart'
    show resolveTemplateDnsServerBody;
import 'package:lxbox/services/builder/preset_expand.dart'
    show normalizeDnsDetour;

/// §682 — четырём зашитым серверам каталога добавлены vars `outbound` и
/// `dns_ip`. Дефолты обязаны давать то же тело, что было зашито до ревизии,
/// байт в байт (порядок ключей тоже): у существующих установок конфиг не
/// меняется.
void main() {
  // Тела до §682 — дословно из wizard_template.json.
  const before = <String, String>{
    'opendns_udp':
        '{"type":"udp","tag":"opendns_udp","server_port":53,"server":"208.67.222.222"}',
    'opendns_doh':
        '{"type":"https","tag":"opendns_doh","server_port":443,"server":"208.67.222.222","path":"/dns-query","tls":{"enabled":true,"server_name":"dns.opendns.com"}}',
    'quad9_doh':
        '{"type":"https","tag":"quad9_doh","server_port":443,"server":"9.9.9.9","path":"/dns-query","tls":{"enabled":true,"server_name":"dns.quad9.net"},"detour":"vpn-1"}',
    'yandex_dot':
        '{"type":"tls","tag":"yandex_dot","server_port":853,"server":"77.88.8.8","tls":{"enabled":true,"server_name":"common.dot.dns.yandex.net"}}',
  };

  final tpl = jsonDecode(File('assets/wizard_template.json').readAsStringSync())
      as Map<String, dynamic>;
  final wrappers = <String, Map<String, dynamic>>{
    for (final e in (tpl['dns_options'] as Map)['servers'] as List)
      if ((e as Map)['server'] is Map)
        (e['server'] as Map)['tag'] as String: e.cast<String, dynamic>(),
  };

  for (final tag in before.keys) {
    test('$tag: тело с дефолтами vars = тело до ревизии', () {
      final w = wrappers[tag]!;
      final names = [
        for (final v in w['vars'] as List) (v as Map)['name'],
      ];
      expect(names, containsAll(['outbound', 'dns_ip']));
      final body = resolveTemplateDnsServerBody(w)!;
      normalizeDnsDetour(body);
      final old = jsonDecode(before[tag]!) as Map<String, dynamic>;
      normalizeDnsDetour(old);
      expect(jsonEncode(body), jsonEncode(old));
    });

    test('$tag: выбор адреса и Направления меняет тело', () {
      final w = wrappers[tag]!;
      final ipVar = (w['vars'] as List)
          .cast<Map>()
          .firstWhere((v) => v['name'] == 'dns_ip');
      final options = [for (final o in ipVar['options'] as List) o['value']];
      final alt = options.last as String;
      final body = resolveTemplateDnsServerBody(w,
          varValues: {'dns_ip': alt, 'outbound': 'vpn-2'})!;
      normalizeDnsDetour(body);
      expect(body['server'], alt);
      expect(body['detour'], 'vpn-2');
    });
  }
}
