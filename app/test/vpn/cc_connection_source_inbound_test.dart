import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/vpn/cc_channel.dart';

/// §661 — источник и вход соединения: метка `source / inbound` только для
/// входа не через `tun-in` (эндпоинт или локальный прокси — мы шлюз).
void main() {
  CcConnection parse(Map<String, dynamic> extra) => CcConnection.fromMap({
        'id': 'c1',
        'network': 'tcp',
        'destination': '1.1.1.1:443',
        ...extra,
      });

  test('fromMap reads source, inbound, inboundType', () {
    final c = parse({
      'source': '192.168.1.7:51514',
      'inbound': 'wg-in',
      'inboundType': 'wireguard',
    });
    expect(c.source, '192.168.1.7:51514');
    expect(c.inbound, 'wg-in');
    expect(c.inboundType, 'wireguard');
    expect(c.isStandardInbound, isFalse);
    expect(c.sourceLabel, '192.168.1.7:51514 / wg-in');
  });

  test('tun-in is standard: no label', () {
    final c = parse({'source': '172.19.0.1:40000', 'inbound': 'tun-in'});
    expect(c.isStandardInbound, isTrue);
    expect(c.sourceLabel, '');
  });

  test('old native without keys: standard, empty fields', () {
    final c = parse({});
    expect(c.source, '');
    expect(c.inbound, '');
    expect(c.sourceLabel, '');
  });

  test('local proxy is non-standard; empty source shows inbound only', () {
    expect(
      parse({'source': '127.0.0.1:38211', 'inbound': 'mixed-in'}).sourceLabel,
      '127.0.0.1:38211 / mixed-in',
    );
    expect(parse({'inbound': 'mixed-in'}).sourceLabel, 'mixed-in');
  });
}
