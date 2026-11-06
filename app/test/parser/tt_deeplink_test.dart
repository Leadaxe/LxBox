// §717 — ссылки deep-link TrustTunnel (`tt://?<base64url TLV>`) → узел
// `trusttunnel`. Ссылки собираются тестовым энкодером ниже (зеркало
// `deeplink/src/encode.rs` референса), значения — из `deeplink/tests/
// roundtrip.rs`.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/services/parser/tt_deeplink.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';
import 'package:lxbox/services/subscription/input_helpers.dart';

import 'engine_test_setup.dart';

// ── тестовый энкодер (QUIC-varint, TLV) ──

List<int> _varint(int v) {
  if (v <= 0x3F) return [v];
  if (v <= 0x3FFF) return [0x40 | (v >> 8), v & 0xFF];
  return [0x80 | (v >> 24), (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];
}

List<int> _tlv(int tag, List<int> value) =>
    [..._varint(tag), ..._varint(value.length), ...value];

List<int> _str(int tag, String s) => _tlv(tag, utf8.encode(s));

String _link(List<List<int>> fields) => 'tt://?'
    '${base64Url.encode([for (final f in fields) ...f]).replaceAll('=', '')}';

final _version = _tlv(0x00, _varint(2));
final _hostname = _str(0x01, 'vpn.example.com');
final _addr = _str(0x02, '1.2.3.4:443');
final _user = _str(0x05, 'alice');
final _pass = _str(0x06, 's3cr3t');
final _name = _str(0x0C, 'Example VPN');

// Псевдо-DER длиннее 64 байт: длина значения уходит в двухбайтный varint.
final _der = List<int>.generate(100, (i) => (i * 7) & 0xFF);

Map<String, dynamic> _bodyOf(NodeSpec n) => (n as UnknownTypeSpec).body;

List<String> _codes(NodeSpec n) => [
      for (final w in n.warnings)
        if (w is RegistryWarning) w.code,
    ];

void main() {
  setUpAll(loadEngineSections);
  tearDownAll(unloadEngineSections);

  test('varint: QUIC-форма, чтение — зеркало записи', () {
    for (final v in [0, 63, 64, 16383, 16384, 1 << 29, (1 << 30) - 1]) {
      final enc = writeVarint(v);
      expect(readVarint(enc, 0), (v, enc.length));
    }
    expect(writeVarint(100), [0x40, 100]);
  });

  test('1. полный узел http2 без сертификата', () {
    final link = _link([_version, _hostname, _user, _pass, _addr, _name]);
    final node = parseUri(link);
    expect(node, isA<UnknownTypeSpec>());
    final n = node! as UnknownTypeSpec;
    expect(n.type, 'trusttunnel');
    final b = _bodyOf(n);
    expect(b['server'], '1.2.3.4');
    expect(b['server_port'], 443);
    expect(b['username'], 'alice');
    expect(b['password'], 's3cr3t');
    expect((b['tls'] as Map)['enabled'], true);
    expect((b['tls'] as Map)['server_name'], 'vpn.example.com');
    expect(b['quic'] ?? false, false);
    expect(n.tag, 'Example VPN');
    expect(n.server, '1.2.3.4');
    expect(n.port, 443);
    expect(_codes(n), isEmpty);
    expect(n.toUri(), link);
  });

  test('2. http3 + custom_sni + DER + skip_verification', () {
    final link = _link([
      _version, _hostname, _user, _pass, _addr,
      _str(0x03, 'sni.example.org'),
      _tlv(0x07, [1]),
      _tlv(0x08, _der),
      _tlv(0x09, [2]),
    ]);
    final n = parseUri(link)!;
    final b = _bodyOf(n);
    expect(b['quic'], true);
    final tls = (b['tls'] as Map).cast<String, dynamic>();
    expect(tls['server_name'], 'sni.example.org');
    expect(tls['insecure'], true);
    final cert = tls['certificate'];
    final pem = cert is List ? cert.join('\n') : cert as String;
    expect(pem, startsWith('-----BEGIN CERTIFICATE-----\n'));
    expect(pem.trimRight(), endsWith('-----END CERTIFICATE-----'));
    final body = pem.split('\n').where((l) => !l.startsWith('-----')).toList();
    expect(body.every((l) => l.length <= 64), isTrue);
    expect(base64.decode(body.join()), _der);
    expect(pemToDer(pem), _der);
    expect(_codes(n), isNot(contains('uri_param_unknown')));
  });

  test('3. лишние поля формата — мягкие коды, узел жив', () {
    final link = _link([
      _version, _hostname, _user, _pass, _addr,
      _str(0x02, '[2001:db8::1]:8443'),
      _tlv(0x0D, [..._varint(7), ...utf8.encode('8.8.8.8'),
        ..._varint(7), ...utf8.encode('1.1.1.1')]),
      _tlv(0x0A, [1]),
      _str(0x0B, 'aabb/ffff'),
    ]);
    final n = parseUri(link)!;
    final b = _bodyOf(n);
    expect(b['server'], '1.2.3.4');
    expect(b['server_port'], 443);
    final unread = [
      for (final w in n.warnings)
        if (w is RegistryWarning && w.code == 'uri_param_unknown')
          w.params['query_name'],
    ];
    expect(unread, containsAll(
        ['extra_addresses', 'dns_upstreams', 'anti_dpi', 'client_random_prefix']));
    for (final k in ['extra_addresses', 'dns_upstreams', 'anti_dpi']) {
      expect(b.containsKey(k), isFalse, reason: k);
    }
  });

  test('3a. IPv6 первым адресом — без скобок', () {
    expect(splitHostPort('[2001:db8::1]:8443'), ('2001:db8::1', 8443));
    expect(splitHostPort('host.example:443'), ('host.example', 443));
  });

  test('4. только subscription_url → узел снят', () {
    final link = _link([_version, _str(0x0E, 'https://sub.example.com/x')]);
    final dropped = XrayDropVerdict();
    expect(parseUri(link, dropped: dropped), isNull);
    expect(dropped.reason?.code, 'service_record_ignored');
  });

  test('4a. subscription_url при полном узле — мягкий код', () {
    final link = _link([
      _version, _hostname, _user, _pass, _addr,
      _str(0x0E, 'https://sub.example.com/x'),
    ]);
    final n = parseUri(link)!;
    expect(
        n.warnings.whereType<RegistryWarning>().map((w) => w.params['query_name']),
        contains('subscription_url'));
  });

  group('5. битая ссылка → снята', () {
    final cases = {
      'битый base64': 'tt://?@@@!!',
      'обрыв TLV': 'tt://?${base64Url.encode([0x01, 0x10, 0x61]).replaceAll('=', '')}',
      'version 3': _link([_tlv(0x00, _varint(3)), _hostname, _user, _pass, _addr]),
    };
    for (final e in cases.entries) {
      test(e.key, () {
        final dropped = XrayDropVerdict();
        expect(parseUri(e.value, dropped: dropped), isNull);
        expect(dropped.reason?.code, 'form_unrecognized');
      });
    }
  });

  test('6. без password → снят field_missing', () {
    final link = _link([_version, _hostname, _user, _addr]);
    final dropped = XrayDropVerdict();
    expect(parseUri(link, dropped: dropped), isNull);
    expect(dropped.reason?.code, 'field_missing');
  });

  test('7. ссылка распознаётся как прямая', () {
    expect(isDirectLink(_link([_version, _hostname, _user, _pass, _addr])),
        isTrue);
  });
}
