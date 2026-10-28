import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/builder/post_steps.dart'
    show resolveTemplateDnsServerBody;
import 'package:lxbox/services/builder/preset_expand.dart'
    show normalizeDnsDetour;

/// §684 — одно правило дефолтов Направления для всех DNS-серверов шаблона:
/// нешифрованный (udp) — через туннель (`vpn-1`), шифрованный (tls/https) —
/// напрямую (тело без `detour`). У каждого сервера с путём — var `outbound`.
void main() {
  final tpl = jsonDecode(File('assets/wizard_template.json').readAsStringSync())
      as Map<String, dynamic>;
  final wrappers = <String, Map<String, dynamic>>{
    for (final e in (tpl['dns_options'] as Map)['servers'] as List)
      if ((e as Map)['server'] is Map &&
          const {'udp', 'tls', 'https'}.contains((e['server'] as Map)['type']))
        (e['server'] as Map)['tag'] as String: e.cast<String, dynamic>(),
  };

  test('каталог: все серверы с путём на месте', () {
    expect(
        wrappers.keys,
        containsAll(<String>[
          'google_udp', 'cloudflare_udp', 'opendns_udp', //
          'google_dot', 'cloudflare_dot', 'yandex_dot', 'safe_dns_dot',
          'google_doh', 'opendns_doh', 'quad9_doh',
        ]));
  });

  for (final tag in wrappers.keys) {
    test('$tag: дефолт Направления — udp через vpn-1, шифрованный напрямую',
        () {
      final w = wrappers[tag]!;
      final names = [for (final v in w['vars'] as List) (v as Map)['name']];
      expect(names, contains('outbound'));
      final body = resolveTemplateDnsServerBody(w)!;
      normalizeDnsDetour(body);
      if (body['type'] == 'udp') {
        expect(body['detour'], 'vpn-1');
      } else {
        expect(body.containsKey('detour'), isFalse,
            reason: 'шифрованный сервер по умолчанию идёт напрямую');
      }
    });

    test('$tag: выбор Направления меняет тело', () {
      final body = resolveTemplateDnsServerBody(wrappers[tag]!,
          varValues: {'outbound': 'vpn-2'})!;
      normalizeDnsDetour(body);
      expect(body['detour'], 'vpn-2');
    });
  }

  test('safe_dns_dot: резолвер своего имени — google_doh', () {
    final body = resolveTemplateDnsServerBody(wrappers['safe_dns_dot']!)!;
    expect(body['domain_resolver'], 'google_doh');
  });

  test('ru-direct: UDP через outbound пресета, DoT/DoH напрямую', () {
    final preset = (tpl['selectable_rules'] as List)
        .cast<Map>()
        .firstWhere((p) => p['preset_id'] == 'ru-direct');
    final vars = {
      for (final v in (preset['vars'] as List).cast<Map>())
        v['name']: v['default_value'],
    };
    // §684 поправка 29.10: правило «UDP через vpn-1» — для общих серверов;
    // UDP пресета идёт Направлением самого пресета.
    expect(vars.containsKey('dns_plain_outbound'), isFalse);
    expect(vars['dns_encrypted_outbound'], 'direct-out');
    final servers = {
      for (final s in (preset['dns_servers'] as List).cast<Map>())
        s['tag']: s['detour'],
    };
    expect(servers['yandex_udp'], '@outbound');
    expect(servers['yandex_dot'], '@dns_encrypted_outbound');
    expect(servers['yandex_doh'], '@dns_encrypted_outbound');
  });
}
