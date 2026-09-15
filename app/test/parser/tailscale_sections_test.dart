import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/singbox_entry.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/node_identity.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/json_parsers.dart';
import 'package:lxbox/services/parser/parse_all.dart';

/// §435 / контракт ## 13 — узел Tailscale и извлечение связки из целого
/// конфига (NODE_SECTIONS.md §6, §7).
void main() {
  final tsBody = <String, dynamic>{
    'type': 'tailscale',
    'tag': 'home-ts',
    'auth_key': 'tskey-auth-xxx',
    'accept_routes': true,
    'hostname': 'phone',
  };

  group('§435 TailscaleSpec — разбор и эмиссия', () {
    test('parseSingboxEntry: без адреса, тело как есть, kind endpoint', () {
      final spec = parseSingboxEntry(tsBody);
      expect(spec, isA<TailscaleSpec>());
      final ts = spec! as TailscaleSpec;
      expect(ts.tag, 'home-ts');
      expect(ts.label, 'home-ts');
      expect(ts.server, '');
      expect(ts.port, 0);
      expect(ts.isAddressless, isTrue);
      expect(ts.isGroup, isFalse);
      expect(ts.hasExitNode, isFalse);
      expect(ts.body, {
        'auth_key': 'tskey-auth-xxx',
        'accept_routes': true,
        'hostname': 'phone',
      });
      final entry = ts.emit(TemplateVars.empty);
      expect(entry, isA<Endpoint>());
      expect(entry.map, {
        'type': 'tailscale',
        'tag': 'home-ts',
        'auth_key': 'tskey-auth-xxx',
        'accept_routes': true,
        'hostname': 'phone',
      });
      // Идентичность пула — нет (адреса нет), как у группы.
      expect(nodeIdentityKey(ts), isNull);
    });

    test('тег пустой → tailscale; exit_node непустой → hasExitNode', () {
      final a = parseSingboxEntry({'type': 'tailscale'})! as TailscaleSpec;
      expect(a.tag, 'tailscale');
      final b = parseSingboxEntry({'type': 'tailscale', 'tag': 'x', 'exit_node': 'srv'})!
          as TailscaleSpec;
      expect(b.hasExitNode, isTrue);
      final c = parseSingboxEntry({'type': 'tailscale', 'tag': 'x', 'exit_node': ' '})!
          as TailscaleSpec;
      expect(c.hasExitNode, isFalse);
    });

    test('принимается из outbounds[] и endpoints[]', () {
      final fromOut = parseAll(decode(jsonEncode({'outbounds': [tsBody]})));
      final fromEp = parseAll(decode(jsonEncode({'endpoints': [tsBody]})));
      expect(fromOut.single, isA<TailscaleSpec>());
      expect(fromEp.single, isA<TailscaleSpec>());
    });

    test('toUri — JSON-текст с tag, парсится обратно как singboxOutbound', () {
      final ts = parseSingboxEntry(tsBody)! as TailscaleSpec;
      final text = ts.toUri();
      final decoded = decode(text);
      expect((decoded as JsonConfig).flavor, JsonFlavor.singboxOutbound);
      final back = parseAll(decoded).single as TailscaleSpec;
      expect(back.tag, 'home-ts');
      expect(back.body, ts.body);
      expect(jsonDecode(text)['detour'], isNull);
    });

    test('detour из конфига → chained, эмиссия несёт detour', () {
      final nodes = parseText({
        'outbounds': [
          {'type': 'vless', 'tag': 'jump', 'server': 'j.com', 'server_port': 443, 'uuid': 'u'},
        ],
        'endpoints': [
          {...tsBody, 'detour': 'jump'},
        ],
      });
      final ts = nodes.whereType<TailscaleSpec>().single;
      expect(ts.chained, isNotNull);
      expect(ts.chained!.tag, 'jump');
      expect(ts.emit(TemplateVars.empty).map['detour'], 'jump');
      expect(ts.body.containsKey('detour'), isFalse);
    });
  });

  group('§435 целый конфиг как источник связки (NODE_SECTIONS.md §6)', () {
    final whole = <String, dynamic>{
      'dns': {
        'servers': [
          {'type': 'udp', 'tag': 'cf', 'server': '1.1.1.1'},
          {'type': 'tailscale', 'tag': 'ts-dns', 'endpoint': 'home-ts'},
          {'type': 'udp', 'tag': 'lan', 'server': '10.0.0.1', 'detour': 'home-ts'},
        ],
        'rules': [
          {'domain_suffix': ['.ts.net'], 'server': 'ts-dns'},
          {'domain_suffix': ['.lan'], 'server': 'lan'},
          {'domain_suffix': ['.com'], 'server': 'cf'},
        ],
        'final': 'cf',
      },
      'endpoints': [tsBody],
      'route': {
        'rules': [
          {'ip_cidr': ['100.64.0.0/10'], 'outbound': 'home-ts'},
          {'domain_suffix': ['.lan'], 'outbound': 'home-ts', 'name': 'LAN', 'rule_set': ['x']},
          {'domain_suffix': ['.ru'], 'outbound': 'direct'},
          {'action': 'reject', 'domain': ['ads']},
        ],
        'final': 'home-ts',
      },
    };

    test('один узел → importedSections с переписанными ссылками', () {
      final node = parseText(whole).single as TailscaleSpec;
      final s = node.importedSections;
      expect(s, isNotNull);
      // DNS-серверы: по endpoint и по detour, теги → @{self}-<тег>.
      expect(s!.dnsServers.map((x) => x.tag), ['@{self}-ts-dns', '@{self}-lan']);
      expect(s.dnsServers[0].body, {'type': 'tailscale', 'endpoint': '@self'});
      expect(s.dnsServers[1].body, {'type': 'udp', 'server': '10.0.0.1', 'detour': '@self'});
      // DNS-правила: только на взятые серверы.
      expect(s.dnsRules, hasLength(2));
      expect(s.dnsRules[0].rule, {'domain_suffix': ['.ts.net'], 'server': '@{self}-ts-dns'});
      expect(s.dnsRules[1].rule, {'domain_suffix': ['.lan'], 'server': '@{self}-lan'});
      // Правила маршрута: по outbound == тег узла; имя из body.name либо
      // `@{self} rule N`; num = 945 + i. Правило с `rule_set` (ссылка на
      // набор конфига) отброшено целиком с предупреждением (норма B3) — не
      // вырезано до match-all.
      expect(s.rules, hasLength(1));
      final r0 = s.rules[0] as CustomRuleInline;
      expect(r0.name, '@{self} rule 1');
      expect(r0.orderNum, 945);
      expect(r0.ipCidrs, ['100.64.0.0/10']);
      expect(r0.outbound, '@self');
      // Форма записи — §2 ONE_NAMESPACE.
      final json = s.toJson();
      expect((json['rules'] as List).first['body'], {
        'ip_cidr': ['100.64.0.0/10'],
        'outbound': '@self',
      });
      final w = node.warnings.whereType<SectionsRecordDroppedWarning>().single;
      expect(w.detail, contains('LAN'));
      expect(w.detail, contains('rule_set'));
    });

    test('§437 многоузловой конфиг: tailscale со связкой, прокси — без', () {
      final nodes = parseText({
        ...whole,
        'outbounds': [
          {'type': 'vless', 'tag': 'v', 'server': 'a.com', 'server_port': 443, 'uuid': 'u'},
          {'type': 'trojan', 'tag': 'lan-proxy', 'server': 'b.com', 'server_port': 443, 'password': 'p'},
        ],
      });
      expect(nodes, hasLength(3));
      final ts = nodes.whereType<TailscaleSpec>().single;
      // Записи взяты по явной ссылке на тег — те же критерии, что у одиночного.
      expect(ts.importedSections!.rules.single.ipCidrs, ['100.64.0.0/10']);
      expect(ts.importedSections!.dnsServers.map((x) => x.tag),
          ['@{self}-ts-dns', '@{self}-lan']);
      for (final n in nodes.where((n) => n is! TailscaleSpec)) {
        expect(n.importedSections, isNull);
      }
    });

    test('§437 многоузловой с явным sections → извлечения нет', () {
      final nodes = parseText({
        ...whole,
        'sections': {
          'rules': [
            {'kind': 'inline', 'name': 'only', 'body': {'outbound': '@self'}},
          ],
        },
        'outbounds': [
          {'type': 'vless', 'tag': 'v', 'server': 'a.com', 'server_port': 443, 'uuid': 'u'},
        ],
      });
      expect(nodes, hasLength(2));
      for (final n in nodes) {
        expect(n.importedSections, isNull);
      }
    });

    test('§437 два tailscale-узла: каждый получает свои записи', () {
      final nodes = parseText({
        'endpoints': [
          tsBody,
          {'type': 'tailscale', 'tag': 'work-ts', 'auth_key': 'tskey-auth-yyy'},
        ],
        'route': {
          'rules': [
            {'ip_cidr': ['100.64.0.0/10'], 'outbound': 'home-ts'},
            {'domain_suffix': ['.work'], 'outbound': 'work-ts'},
          ],
        },
      });
      final byTag = {for (final n in nodes) n.tag: n};
      expect(byTag['home-ts']!.importedSections!.rules.single.ipCidrs,
          ['100.64.0.0/10']);
      expect(byTag['work-ts']!.importedSections!.rules.single.domainSuffixes,
          ['.work']);
    });

    test('узел без связки в конфиге → секций нет', () {
      final node = parseText({
        'endpoints': [tsBody],
        'dns': {'servers': [{'type': 'udp', 'tag': 'cf', 'server': '1.1.1.1'}]},
        'route': {'rules': [{'domain': ['x'], 'outbound': 'direct'}]},
      }).single;
      expect(node.importedSections, isNull);
    });

    test('группа рядом не мешает: один payload-узел', () {
      final nodes = parseText({
        'endpoints': [tsBody],
        'outbounds': [
          {'type': 'selector', 'tag': 'sel', 'outbounds': ['home-ts']},
        ],
        'route': {
          'rules': [
            {'ip_cidr': ['100.64.0.0/10'], 'outbound': 'home-ts'},
          ],
        },
      });
      final ts = nodes.whereType<TailscaleSpec>().single;
      expect(ts.importedSections?.rules, hasLength(1));
    });

    test('документ с sections читается кодеком, dns/route не извлекаются', () {
      final node = parseText({
        'endpoints': [tsBody],
        'sections': {
          'rules': [
            {
              'kind': 'inline',
              'name': '@{self} network',
              'enabled': true,
              'num': 945,
              'body': {'ip_cidr': ['100.64.0.0/10'], 'outbound': '@self'},
            },
            {'kind': 'preset', 'name': 'bad', 'ref': 'p'},
          ],
        },
      }).single;
      final s = node.importedSections!;
      expect(s.rules.single.name, '@{self} network');
      expect(node.warnings.whereType<SectionsRecordDroppedWarning>(), hasLength(1));
      expect(node.warnings.whereType<SectionsConflictWarning>(), isEmpty);
    });

    test('sections И dns/route в одном документе → sections + warning конфликта', () {
      final node = parseText({
        ...whole,
        'sections': {
          'rules': [
            {'kind': 'inline', 'name': 'only', 'body': {'outbound': '@self'}},
          ],
        },
      }).single;
      expect(node.importedSections!.rules.single.name, 'only');
      expect(node.importedSections!.dnsServers, isEmpty);
      expect(node.warnings.whereType<SectionsConflictWarning>(), hasLength(1));
    });

    test('WireGuard-узел с подсетями за пиром — та же связка', () {
      final node = parseText({
        'endpoints': [
          {
            'type': 'wireguard',
            'tag': 'wg-home',
            'address': ['10.0.0.2/32'],
            'private_key': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA=',
            'peers': [
              {
                'address': 'example.com',
                'port': 51820,
                'public_key': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA=',
                'allowed_ips': ['192.168.1.0/24'],
              },
            ],
          },
        ],
        'route': {
          'rules': [
            {'ip_cidr': ['192.168.1.0/24'], 'outbound': 'wg-home'},
          ],
        },
      }).single;
      expect(node, isA<WireguardSpec>());
      expect(node.importedSections!.rules.single.ipCidrs, ['192.168.1.0/24']);
    });
  });
}

List<NodeSpec> parseText(Object json) => parseAll(decode(jsonEncode(json)));
