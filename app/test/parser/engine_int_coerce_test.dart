import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

import 'engine_test_setup.dart';

/// `_coerceType` для `type: int`: JSON-число должно быть математически
/// целым. Дробный порт в контейнере v2rayN иначе молча становился 443.
String _vmess(Object port) {
  final cfg = jsonEncode({
    'v': '2',
    'ps': 'N',
    'add': 'h.example',
    'port': port,
    'id': '11111111-2222-3333-4444-555555555555',
    'aid': '0',
    'net': 'tcp',
  });
  return 'vmess://${base64.encode(utf8.encode(cfg))}';
}

void main() {
  setUpAll(loadEngineSections);

  test('vmess v2rayN JSON: port 443.9 — узла нет', () {
    expect(parseUri(_vmess(443.9)), isNull);
  });

  test('vmess v2rayN JSON: port 443.0 и 443 — один и тот же узел', () {
    final fromDot = parseUri(_vmess(443.0)) as VmessSpec;
    final fromInt = parseUri(_vmess(443)) as VmessSpec;
    expect(fromDot.port, 443);
    expect(fromInt.port, 443);
    expect(fromDot.server, fromInt.server);
    expect(fromDot.uuid, fromInt.uuid);
  });
}
