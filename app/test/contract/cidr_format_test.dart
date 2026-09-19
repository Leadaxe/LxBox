import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/services/contract/body_sanitizer.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

import '../parser/engine_test_setup.dart';

/// format `cidr`: адрес строгим парсером, префикс по семейству.
///
/// Негодное значение идёт обычным `on_invalid` поля (у `wireguard.address` —
/// `drop` / `type_invalid`; поле обязательное, поэтому узел уходит).
const _core = '1.14.1-lx.4';
const _priv = 'ccccccccccccccccccccccccccccccccccccccccccA=';
const _pub = 'ddddddddddddddddddddddddddddddddddddddddddA=';

SanitizeResult _san(List<String> address) => RegistrySanitizer.sanitize(
      {
        'type': 'wireguard',
        'tag': 'wg',
        'private_key': _priv,
        'address': address,
        'peers': [
          {
            'public_key': _pub,
            'address': 'h.example',
            'port': 51820,
            'allowed_ips': ['0.0.0.0/0'],
          }
        ],
      },
      scheme: 'wireguard',
      coreVersion: _core,
    );

WireguardSpec? _parseAddress(String address) => parseUri(
      'wireguard://$_priv@h.example:51820?publickey=$_pub&address=$address',
    ) as WireguardSpec?;

void main() {
  setUpAll(loadEngineSections);

  group('format cidr — негодное снимается on_invalid', () {
    const bad = [
      '1.2.3.4/64',
      '::::/128',
      '01.2.3.4/24',
      '1.2.3.4/33',
    ];
    for (final cidr in bad) {
      test('$cidr → type_invalid, узла нет', () {
        final r = _san([cidr]);
        expect(r.body, isNull, reason: 'обязательный address снят');
        expect(r.warnings.map((w) => w.code), contains('type_invalid'));
        expect(_parseAddress(cidr), isNull);
      });
    }
  });

  group('format cidr — годное проходит', () {
    const good = {
      '10.0.0.2/32': ['10.0.0.2/32'],
      'fd00::2/128': ['fd00::2/128'],
      '0.0.0.0/0': ['0.0.0.0/0'],
      '::/0': ['::/0'],
    };
    for (final e in good.entries) {
      test('${e.key} остаётся как есть', () {
        final r = _san([e.key]);
        expect(r.body, isNotNull);
        expect(r.body!['address'], e.value);
        expect(r.warnings.map((w) => w.code), isNot(contains('type_invalid')));
        expect(_parseAddress(e.key)!.localAddresses, e.value);
      });
    }
  });

  group('normalize cidr_prefix — голый IP дописывает маску-хост', () {
    test('IPv4 без префикса → /32', () {
      final r = _san(['10.0.0.2']);
      expect(r.body!['address'], ['10.0.0.2/32']);
      expect(_parseAddress('10.0.0.2')!.localAddresses, ['10.0.0.2/32']);
    });

    test('IPv6 без префикса → /128', () {
      final r = _san(['fd00::2']);
      expect(r.body!['address'], ['fd00::2/128']);
      expect(_parseAddress('fd00::2')!.localAddresses, ['fd00::2/128']);
    });
  });
}
