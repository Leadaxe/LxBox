import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import '../contract_paths.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/singbox_entry.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/contract/body_sanitizer.dart'
    show exitCapableByRegistry;
import 'package:lxbox/services/node_identity.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/json_parsers.dart';
import 'package:lxbox/services/parser/parse_all.dart';

/// §435 — узел Tailscale; §575 — из целого конфига берутся только узлы.
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

    test('тег пустой → tailscale', () {
      final a = parseSingboxEntry({'type': 'tailscale'})! as TailscaleSpec;
      expect(a.tag, 'tailscale');
    });

    test('контракт 1.1.63: выход — по exit_capable_when реестра', () async {
      await loadTestRegistry();
      bool exit(Map<String, dynamic> body) => exitCapableByRegistry(
          parseSingboxEntry(body)!.emit(TemplateVars.empty).map);
      expect(exit({'type': 'tailscale', 'tag': 'x', 'exit_node': 'srv'}),
          isTrue);
      expect(exit({'type': 'tailscale', 'tag': 'x'}), isFalse);
      expect(exit({'type': 'tailscale', 'tag': 'x', 'exit_node': ''}),
          isFalse);
    });

    test('принимается из outbounds[] и endpoints[]', () {
      final fromOut = parseAll(decode(jsonEncode({'outbounds': [tsBody]})));
      final fromEp = parseAll(decode(jsonEncode({'endpoints': [tsBody]})));
      expect(fromOut.single, isA<TailscaleSpec>());
      expect(fromEp.single, isA<TailscaleSpec>());
    });

    test('toUri — JSON-текст с tag, парсится обратно как одиночный outbound',
        () {
      final ts = parseSingboxEntry(tsBody)! as TailscaleSpec;
      final text = ts.toUri();
      final decoded = decode(text);
      expect((decoded as JsonConfig).source.kind, SourceKind.singboxOutbound);
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

  // §575 — секции узла упразднены: `dns`, `route`, `sections` документа
  // отбрасываются, связка Tailscale не извлекается.
  group('§575 целый конфиг: берутся только узлы', () {
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

    test('один узел: из целого конфига берётся только узел', () {
      final nodes = parseText(whole);
      expect(nodes.single, isA<TailscaleSpec>());
      expect(nodes.single.tag, 'home-ts');
      expect(nodes.single.warnings, isEmpty);
    });

    test('документ с sections и dns/route: узел, без предупреждений', () {
      final node = parseText({
        ...whole,
        'sections': {
          'rules': [
            {'kind': 'inline', 'name': 'only', 'body': {'outbound': '@self'}},
          ],
        },
      }).single;
      expect(node, isA<TailscaleSpec>());
      expect(node.warnings, isEmpty);
    });

    test('многоузловой конфиг: все узлы, связки нет ни у кого', () {
      final nodes = parseText({
        ...whole,
        'outbounds': [
          {
            'type': 'socks',
            'tag': 'proxy',
            'server': '1.2.3.4',
            'server_port': 1080,
          },
        ],
      });
      expect(nodes.map((n) => n.tag), containsAll(['home-ts', 'proxy']));
      for (final n in nodes) {
        expect(n.warnings, isEmpty, reason: n.tag);
      }
    });
  });
}

List<NodeSpec> parseText(Object json) => parseAll(decode(jsonEncode(json)));
