import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';

import '../contract_paths.dart';

/// §598 — пустые и неприменимые ключи v2rayN-ссылки vmess не дают
/// предупреждений; один ключ — не больше одного предупреждения.
///
/// Входы повторяют оба vmess-узла подписки `73-github-full` (OVI-vpn), uuid
/// заменён тестовым.
const _uuid = '11111111-1111-1111-1111-111111111111';

const _unknownCodes = {'uri_param_unknown', 'unknown_key'};

Map<String, String> _node1() => {
      'v': '2', 'ps': 'AetrisVPN', 'add': '45.32.57.118', 'port': '4433',
      'id': _uuid, 'aid': '0', 'scy': 'auto', 'net': 'tcp', 'type': 'none',
      'host': '', 'path': '', 'tls': 'none', 'sni': '', 'alpn': '', 'cs': '',
      'fp': '', 'insecure': '',
    };

Map<String, String> _node2() => {
      'v': '2', 'ps': 'AetrisVPN', 'add': '112.132.215.108', 'port': '50002',
      'id': _uuid, 'aid': '64', 'scy': 'auto', 'net': 'tcp', 'type': 'none',
      'host': '', 'path': '', 'tls': '', 'sni': '', 'alpn': '', 'cs': '',
      'fp': '', 'insecure': '0',
    };

NodeSpec _parse(Map<String, String> j) {
  final raw = 'vmess://${base64.encode(utf8.encode(jsonEncode(j)))}';
  final nodes = parseAll(decode(raw));
  expect(nodes, hasLength(1));
  return nodes.single;
}

List<RegistryWarning> _unknown(NodeSpec n) => n.warnings
    .whereType<RegistryWarning>()
    .where((w) => _unknownCodes.contains(w.code))
    .toList();

void main() {
  setUpAll(loadTestRegistry);

  group('§598 пустые поля v2rayN', () {
    test('узел 1 (tls: none): ни одного unknown, эмит прежний', () {
      final n = _parse(_node1());
      expect(_unknown(n), isEmpty);
      expect(n.emit(TemplateVars.empty).map, {
        'type': 'vmess',
        'tag': 'AetrisVPN',
        'server': '45.32.57.118',
        'server_port': 4433,
        'uuid': _uuid,
        'security': 'auto',
      });
    });

    test('узел 2 (tls: "", insecure: "0", aid: 64): ни одного unknown', () {
      final n = _parse(_node2());
      expect(_unknown(n), isEmpty);
      final body = n.emit(TemplateVars.empty).map;
      expect(body['type'], 'vmess');
      expect(body['server'], '112.132.215.108');
      expect(body['alter_id'], 64);
      expect(body.containsKey('tls'), isFalse);
      expect(body.containsKey('transport'), isFalse);
    });

    test('null у ключа контейнера = ключа нет', () {
      final j = <String, Object?>{..._node1(), 'cs': null, 'zzz': null};
      final raw = 'vmess://${base64.encode(utf8.encode(jsonEncode(j)))}';
      final n = parseAll(decode(raw)).single;
      expect(_unknown(n), isEmpty);
    });
  });

  group('§598 известный, но неприменимый ключ — не «неизвестный»', () {
    test('sni при tls: none и path/host при net: tcp молчат', () {
      final n = _parse({
        ..._node1(),
        'sni': 'a.example',
        'path': '/ws',
        'host': 'h.example',
        'alpn': 'h2',
        'fp': 'chrome',
        'insecure': '1',
      });
      expect(_unknown(n), isEmpty);
      final body = n.emit(TemplateVars.empty).map;
      for (final k in ['sni', 'path', 'host', 'alpn', 'fp', 'insecure']) {
        expect(body.containsKey(k), isFalse, reason: k);
      }
      expect(body.containsKey('tls'), isFalse);
    });
  });

  group('§598 один ключ — не больше одного предупреждения', () {
    test('непустой cs — ровно одно', () {
      final n = _parse({..._node1(), 'cs': 'aes-128-gcm'});
      final ws = _unknown(n);
      expect(ws, hasLength(1));
      expect(ws.single.code, 'uri_param_unknown');
      expect(ws.single.path, 'cs');
      expect(n.emit(TemplateVars.empty).map.containsKey('cs'), isFalse);
    });

    test('непустой по-настоящему неизвестный ключ — ровно одно', () {
      final n = _parse({..._node1(), 'zzz': '1'});
      final ws = _unknown(n);
      expect(ws, hasLength(1));
      expect(ws.single.code, 'uri_param_unknown');
      expect(ws.single.path, 'zzz');
    });
  });
}
