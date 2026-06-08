import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/config_node.dart';

/// §091 — unit tests for ConfigNode / ParsedConfig (structural per-node meta).
void main() {
  String cfg(Map<String, dynamic> m) => jsonEncode(m);

  group('ParsedConfig.parse — per-node fields', () {
    final pc = ParsedConfig.parse(cfg({
      'outbounds': [
        {'tag': 'a', 'type': 'vless', 'server': 'x', 'detour': 'hop'},
        {'tag': 'hop', 'type': 'trojan'},
        {'tag': 'sel', 'type': 'selector'},
        {'tag': 'auto', 'type': 'urltest'},
      ],
      'endpoints': [
        {'tag': 'wg', 'type': 'wireguard'},
      ],
    }));

    test('type + raw captured by tag', () {
      expect(pc['a']?.type, 'vless');
      expect(pc['a']?.raw['server'], 'x');
      expect(pc['hop']?.type, 'trojan');
      expect(pc['wg']?.type, 'wireguard');
      expect(pc['missing'], isNull);
    });

    test('kind: outbound vs endpoint', () {
      expect(pc['a']?.kind, 'outbound');
      expect(pc['wg']?.kind, 'endpoint');
      expect(pc.kindOf('a'), 'outbound');
      expect(pc.kindOf('wg'), 'endpoint');
      expect(pc.kindOf('missing'), 'outbound'); // default
    });

    test('detour field (own hop-target)', () {
      expect(pc['a']?.detour, 'hop');
      expect(pc['hop']?.detour, isNull);
      expect(pc.detourOf('a'), 'hop');
    });

    test('isControl', () {
      expect(pc['a']?.isControl, false);
      expect(pc['wg']?.isControl, false); // wireguard endpoint = payload
      expect(pc['sel']?.isControl, true);
      expect(pc['auto']?.isControl, true);
    });

    test('rawOf', () {
      expect(pc.rawOf('hop')?['type'], 'trojan');
      expect(pc.rawOf('missing'), isNull);
    });
  });

  group('detourRefCount / isDetour', () {
    test('chain A→B→C: refCount B=1, C=1, A=0', () {
      final pc = ParsedConfig.parse(cfg({
        'outbounds': [
          {'tag': 'A', 'type': 'vless', 'detour': 'B'},
          {'tag': 'B', 'type': 'vless', 'detour': 'C'},
          {'tag': 'C', 'type': 'vless'},
        ],
      }));
      expect(pc['A']?.detourRefCount, 0);
      expect(pc['B']?.detourRefCount, 1);
      expect(pc['C']?.detourRefCount, 1);
      expect(pc['A']?.isDetour, false);
      expect(pc['B']?.isDetour, true);
      expect(pc['C']?.isDetour, true);
    });

    test('shared hop: two nodes → same detour target → refCount 2', () {
      final pc = ParsedConfig.parse(cfg({
        'outbounds': [
          {'tag': 'n1', 'type': 'vless', 'detour': 'hop'},
          {'tag': 'n2', 'type': 'vless', 'detour': 'hop'},
          {'tag': 'hop', 'type': 'vless'},
        ],
      }));
      expect(pc['hop']?.detourRefCount, 2);
      expect(pc['hop']?.isDetour, true);
    });
  });

  group('isMarkedDetour (⚙ marker)', () {
    final pc = ParsedConfig.parse(cfg({
      'outbounds': [
        {'tag': '⚙ Hop', 'type': 'vless'},
        {'tag': '🇷🇺 ⚙ MidHop', 'type': 'vless'},
        {'tag': 'Plain', 'type': 'vless'},
      ],
    }));

    test('leading + mid marker → true; plain → false', () {
      expect(pc['⚙ Hop']?.isMarkedDetour, true);
      expect(pc['🇷🇺 ⚙ MidHop']?.isMarkedDetour, true);
      expect(pc['Plain']?.isMarkedDetour, false);
    });
  });

  group('outboundChain / detourChain (parity with ConfigIntrospection)', () {
    final pc = ParsedConfig.parse(cfg({
      'outbounds': [
        {'tag': 'main', 'type': 'vless', 'detour': 'hop1'},
        {'tag': 'hop1', 'type': 'vless', 'detour': 'hop2'},
        {'tag': 'hop2', 'type': 'vless'},
        {'tag': 'solo', 'type': 'vless'},
      ],
    }));

    test('detourChain (tags, no self)', () {
      expect(pc.detourChain('main'), ['hop1', 'hop2']);
      expect(pc.detourChain('hop1'), ['hop2']);
      expect(pc.detourChain('solo'), isEmpty);
    });

    test('outboundChain (raw maps, with self)', () {
      expect(pc.outboundChain('main').map((o) => o['tag']).toList(),
          ['main', 'hop1', 'hop2']);
      expect(pc.outboundChain('solo').single['tag'], 'solo');
      expect(pc.outboundChain('missing'), isEmpty);
    });

    test('cycle-safe: detour loop does not hang', () {
      final c = ParsedConfig.parse(cfg({
        'outbounds': [
          {'tag': 'x', 'type': 'vless', 'detour': 'y'},
          {'tag': 'y', 'type': 'vless', 'detour': 'x'},
        ],
      }));
      expect(c.detourChain('x'), ['y']);
      expect(c.outboundChain('x').map((o) => o['tag']).toList(), ['x', 'y']);
    });
  });

  group('nodeCount + malformed/empty', () {
    test('counts non-control outbounds + endpoints', () {
      final pc = ParsedConfig.parse(cfg({
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
      expect(pc.nodeCount, 3); // n1 + n2 + wg1
    });

    test('malformed JSON → empty', () {
      final pc = ParsedConfig.parse('{not json');
      expect(pc.isEmpty, true);
      expect(pc['a'], isNull);
      expect(pc.nodeCount, 0);
    });

    test('empty string → empty', () {
      expect(ParsedConfig.parse('').isEmpty, true);
      expect(ParsedConfig.parse('').nodeCount, 0);
    });
  });
}
