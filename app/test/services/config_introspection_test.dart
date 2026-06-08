import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/config_introspection.dart';

/// §085 R2 — unit tests for ConfigIntrospection (unified config traversal).
void main() {
  String cfg(Map<String, dynamic> m) => jsonEncode(m);

  group('parse / outboundByTag / kindOf', () {
    test('outbound + endpoint indexed by tag', () {
      final i = ConfigIntrospection.parse(cfg({
        'outbounds': [
          {'tag': 'a', 'type': 'vless', 'server': 'x'},
        ],
        'endpoints': [
          {'tag': 'wg', 'type': 'wireguard'},
        ],
      }));
      expect(i.outboundByTag('a')?['server'], 'x');
      expect(i.kindOf('a'), 'outbound');
      expect(i.kindOf('wg'), 'endpoint');
      expect(i.outboundByTag('missing'), isNull);
      expect(i.kindOf('missing'), 'outbound'); // default
    });

    test('malformed JSON → empty', () {
      final i = ConfigIntrospection.parse('{not json');
      expect(i.outboundByTag('a'), isNull);
      expect(i.nodeCount, 0);
    });

    test('empty string → empty', () {
      final i = ConfigIntrospection.parse('');
      expect(i.nodeCount, 0);
    });
  });

  group('detourOf / detourChain / outboundChain', () {
    final i = ConfigIntrospection.parse(cfg({
      'outbounds': [
        {'tag': 'main', 'type': 'vless', 'detour': 'hop1'},
        {'tag': 'hop1', 'type': 'vless', 'detour': 'hop2'},
        {'tag': 'hop2', 'type': 'vless'},
        {'tag': 'solo', 'type': 'vless'},
      ],
    }));

    test('detourOf', () {
      expect(i.detourOf('main'), 'hop1');
      expect(i.detourOf('hop2'), isNull);
      expect(i.detourOf('solo'), isNull);
    });

    test('detourChain (tags, no self)', () {
      expect(i.detourChain('main'), ['hop1', 'hop2']);
      expect(i.detourChain('hop1'), ['hop2']);
      expect(i.detourChain('solo'), isEmpty);
    });

    test('outboundChain (maps, with self)', () {
      final chain = i.outboundChain('main');
      expect(chain.map((o) => o['tag']).toList(), ['main', 'hop1', 'hop2']);
      expect(i.outboundChain('solo').single['tag'], 'solo');
      expect(i.outboundChain('missing'), isEmpty);
    });

    test('cycle-safe: detour loop does not hang', () {
      final c = ConfigIntrospection.parse(cfg({
        'outbounds': [
          {'tag': 'x', 'type': 'vless', 'detour': 'y'},
          {'tag': 'y', 'type': 'vless', 'detour': 'x'},
        ],
      }));
      // x → y → (x seen, stop)
      expect(c.detourChain('x'), ['y']);
      expect(c.outboundChain('x').map((o) => o['tag']).toList(), ['x', 'y']);
    });
  });

  group('nodeCount', () {
    test('counts non-control outbounds + endpoints', () {
      final i = ConfigIntrospection.parse(cfg({
        'outbounds': [
          {'tag': 'n1', 'type': 'vless'},
          {'tag': 'n2', 'type': 'trojan'},
          {'tag': 'sel', 'type': 'selector'},
          {'tag': 'auto', 'type': 'urltest'},
          {'tag': 'direct', 'type': 'direct'},
          {'tag': 'block', 'type': 'block'},
          {'tag': 'dns', 'type': 'dns'},
        ],
        'endpoints': [
          {'tag': 'wg1', 'type': 'wireguard'},
        ],
      }));
      // 2 payload outbounds + 1 endpoint = 3
      expect(i.nodeCount, 3);
    });

    test('empty config → 0', () {
      expect(ConfigIntrospection.parse(cfg({})).nodeCount, 0);
    });
  });
}
