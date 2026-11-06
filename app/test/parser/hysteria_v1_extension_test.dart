import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/services/contract/warning_codes.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';

import 'engine_test_setup.dart';

/// Контракт 1.1.118 (§591 п.4) — Hysteria v1 у LxBox не поддержан
/// (`extension: desktop`), и отказ называется явно: код
/// `protocol_extension_unsupported` с `alternative` из поля секции
/// `extension_alternative` (`hysteria2`), на всех входах.
void main() {
  setUpAll(loadEngineSections);

  ({List<NodeSpec> nodes, List<NodeWarning> dropped}) parse(String raw,
      {bool own = false}) {
    final dropped = <NodeWarning>[];
    final nodes = parseAll(decode(raw), dropped: dropped, own: own);
    return (nodes: nodes, dropped: dropped);
  }

  void expectRejected(String raw, String ref, {bool own = false}) {
    final r = parse(raw, own: own);
    expect(r.nodes, isEmpty);
    expect(r.dropped, hasLength(1));
    final w = r.dropped.single as RegistryWarning;
    expect(w.code, 'protocol_extension_unsupported');
    expect(w.params, {'scheme': 'hysteria', 'alternative': 'hysteria2'});
    expect(w.severity, WarningSeverity.error);
    expect(w.ownerTag, ref);
  }

  const link = 'hysteria://h.example:443?auth=x&upmbps=10&downmbps=50#hy1';
  final body = {
    'type': 'hysteria',
    'tag': 'h1',
    'server': 'h.example',
    'server_port': 443,
    'auth_str': 'x',
    'up_mbps': 10,
    'down_mbps': 50,
  };

  test('ссылка hysteria:// и алиас hy://', () {
    expectRejected(link, link);
    const alias = 'hy://h.example:443?auth=x#hy1';
    expectRejected(alias, alias);
  });

  test('тело sing-box: конфиг и своё голое тело', () {
    expectRejected(
        jsonEncode({
          'outbounds': [body]
        }),
        'h1');
    expectRejected(jsonEncode(body), 'h1', own: true);
  });

  test('Xray: protocol hysteria, version 1 и без version', () {
    Map<String, dynamic> element(Map<String, dynamic> settings,
            Map<String, dynamic> hy) =>
        {
          'remarks': 'r',
          'outbounds': [
            {
              'protocol': 'hysteria',
              'tag': 'p',
              'settings': {'address': 'h.example', 'port': 443, ...settings},
              'streamSettings': {
                'network': 'hysteria',
                'hysteriaSettings': {'auth': 'x', ...hy},
              },
            }
          ],
        };
    expectRejected(
        jsonEncode([
          element({'version': 1}, {'version': 1})
        ]),
        'p');
    expectRejected(jsonEncode([element({}, {})]), 'p');
  });

  test('хоп hysteria в цепочке sing-box — цель, не ставшая узлом', () {
    final r = parse(jsonEncode({
      'outbounds': [
        {
          'type': 'vless',
          'tag': 'a',
          'server': 'a.example',
          'server_port': 443,
          'uuid': 'u-a',
          'detour': 'h1',
        },
        body,
      ]
    }));
    expect(r.nodes, isEmpty);
    expect(r.dropped.map(warningCodeOf),
        containsAll(['detour_target_missing']));
  });

  test('hysteria2 не задет', () {
    final r = parse('hysteria2://pw@h.example:443?sni=h.example#hy2');
    expect(r.nodes, hasLength(1));
    expect(r.dropped, isEmpty);
  });
}
