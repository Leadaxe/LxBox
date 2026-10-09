import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';
import 'package:lxbox/services/wireguard/masquerade_source.dart';

import '../contract_paths.dart';
import '../parser/engine_test_setup.dart';

/// §623 — запись маскировки `ip`/`id`/`ib` в три формы источника.
void main() {
  setUpAll(loadEngineSections);

  WireguardSpec parseOne(String text) {
    final nodes = parseAll(decode(text), own: true);
    expect(nodes, hasLength(1), reason: text);
    return nodes.single as WireguardSpec;
  }

  Masquerade modelOf(String text) =>
      Masquerade.fromFields(parseOne(text).awg?.fields);

  const quic = Masquerade(ip: 'quic', id: 'www.example.org', ib: 'firefox');
  const dns = Masquerade(ip: 'dns', id: 'mask.example.net');

  const ini =
      '# head comment\n'
      '[Interface]\n'
      'PrivateKey = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA=\n'
      'Address = 10.0.0.2/32\n'
      'Jc = 3\n'
      '\n'
      '# peer comment\n'
      '[Peer]\n'
      'PublicKey = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA=\n'
      'Endpoint = masq.example.com:51820\n'
      'AllowedIPs = 0.0.0.0/0\n';

  group('INI', () {
    test('keys go into [Interface]; [Peer] and comments untouched', () {
      final out = withMasquerade(ini, quic);
      expect(
        out,
        ini.replaceFirst(
          'Jc = 3\n',
          'Jc = 3\nIp = quic\nId = www.example.org\nIb = firefox\n',
        ),
      );
    });

    test('existing keys in another case are replaced', () {
      final src = ini.replaceFirst(
        'Jc = 3\n',
        'IP = DNS\nJc = 3\nid=old.example\n',
      );
      final out = withMasquerade(src, quic);
      expect(out, isNot(contains('IP = DNS')));
      expect(out, isNot(contains('id=old.example')));
      expect('Ip = quic'.allMatches(out), hasLength(1));
      expect(out, contains('Jc = 3\nIp = quic\nId = www.example.org\n'));
    });

    test('Off removes all three', () {
      final withKeys = withMasquerade(ini, quic);
      expect(withMasquerade(withKeys, Masquerade.off), ini);
    });

    test(r'\r\n is kept', () {
      final crlf = ini.replaceAll('\n', '\r\n');
      final out = withMasquerade(crlf, dns);
      expect(out.replaceAll('\r\n', ''), isNot(contains('\n')));
      expect(out, contains('Jc = 3\r\nIp = dns\r\nId = mask.example.net\r\n'));
      expect(withMasquerade(out, Masquerade.off), crlf);
    });

    test('[Peer] keys named like masquerade keys are not touched', () {
      final src = '${ini}Ip = stray\n';
      final out = withMasquerade(src, Masquerade.off);
      expect(out, src);
    });
  });

  group('link', () {
    const link =
        'awg://AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=@host.example.com:9494'
        '?address=10.200.0.6%2F32&h1=11758-81984'
        '&i2=%3Cb+0xc3%3E%3Cr+32%3E&jc=5&ip=stun'
        '&publickey=AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=#DE+node%20x';

    test('other params byte for byte, fragment kept', () {
      final out = withMasquerade(link, quic);
      expect(
        out,
        link
            .replaceFirst('&ip=stun', '&ip=quic')
            .replaceFirst('#DE', '&id=www.example.org&ib=firefox#DE'),
      );
    });

    test('rewrite is idempotent', () {
      final once = withMasquerade(link, quic);
      expect(withMasquerade(once, quic), once);
    });

    test('Off removes the pairs; no query left → no "?"', () {
      expect(
        withMasquerade(link, Masquerade.off),
        link.replaceFirst('&ip=stun', ''),
      );
      expect(
        withMasquerade('wg://k@h.example:1?ip=dns#t', Masquerade.off),
        'wg://k@h.example:1#t',
      );
    });

    test('a link without query gets one', () {
      expect(
        withMasquerade('wg://k@h.example:1#t', dns),
        'wg://k@h.example:1?ip=dns&id=mask.example.net#t',
      );
    });
  });

  group('JSON', () {
    final body = {
      'type': 'wireguard',
      'tag': 'wg-json',
      'private_key': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA=',
      'address': ['10.0.0.2/32'],
      'ip': 'sip',
      'peers': [
        {
          'address': '192.0.2.1',
          'port': 51820,
          'public_key': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA=',
          'allowed_ips': ['0.0.0.0/0'],
        },
      ],
    };
    final src = const JsonEncoder.withIndent('  ').convert(body);

    test('keys at the body root, null removes', () {
      final out = jsonDecode(withMasquerade(src, quic)) as Map;
      expect(out['ip'], 'quic');
      expect(out['id'], 'www.example.org');
      expect(out['ib'], 'firefox');
      final off = jsonDecode(withMasquerade(src, Masquerade.off)) as Map;
      expect(off.keys, isNot(contains('ip')));
      expect(off.keys, isNot(contains('id')));
      expect(off.keys, isNot(contains('ib')));
    });

    test('round trip through the parser', () {
      expect(modelOf(withMasquerade(src, quic)), quic);
      expect(modelOf(withMasquerade(src, dns)), dns);
    });
  });

  group('round trip on corpus samples', () {
    final iniPath = '$kVendorRoot/corpus/body/wgconf/ini_masquerade_sugar.body';
    final uriPath =
        '$kVendorRoot/corpus/uri/wireguard/warp_masquerade_ip_id_ib.uri';
    String sample(String path) => File(
      path,
    ).readAsLinesSync().where((l) => !l.startsWith('#')).join('\n');

    test('INI', () {
      final src = sample(iniPath);
      for (final m in [quic, dns, const Masquerade(ip: 'stun')]) {
        expect(modelOf(withMasquerade(src, m)), m);
      }
      expect(modelOf(withMasquerade(src, Masquerade.off)).isOff, isTrue);
    }, skip: corpusTestSkip('masquerade_source_test'));

    test('link', () {
      final src = sample(uriPath).trim();
      for (final m in [quic, dns, const Masquerade(ip: 'sip')]) {
        expect(modelOf(withMasquerade(src, m)), m);
      }
      expect(modelOf(withMasquerade(src, Masquerade.off)).isOff, isTrue);
    }, skip: corpusTestSkip('masquerade_source_test'));
  });

  group('masqueradeWritability', () {
    test('awg:// base64 and vpn:// are packed', () {
      final b64 = base64.encode(utf8.encode(ini));
      expect(
        masqueradeWritability('awg://$b64'),
        MasqueradeWritability.packedLink,
      );
      expect(
        masqueradeWritability('vpn://AAAAeJzLSM3JyQcABiwCFQ'),
        MasqueradeWritability.packedLink,
      );
    });

    test('link, INI and sing-box body are writable', () {
      expect(
        masqueradeWritability('wg://k@h.example:1?ip=dns#t'),
        MasqueradeWritability.writable,
      );
      expect(masqueradeWritability(ini), MasqueradeWritability.writable);
      expect(
        masqueradeWritability(
          '{"type":"wireguard","tag":"x","private_key":"k"}',
        ),
        MasqueradeWritability.writable,
      );
    });

    test('Xray outbound is not supported', () {
      const xray =
          '{"protocol":"wireguard","tag":"x",'
          '"settings":{"secretKey":"k","peers":[{"endpoint":"h:1",'
          '"publicKey":"p"}]}}';
      expect(
        masqueradeWritability(xray),
        MasqueradeWritability.unsupportedFormat,
      );
      expect(withMasquerade(xray, quic), xray);
    });
  });

  group('masqueradeKeysPresent', () {
    test('per form', () {
      expect(masqueradeKeysPresent(ini), isFalse);
      expect(
        masqueradeKeysPresent(ini.replaceFirst('Jc', 'IB = chrome\nJc')),
        isTrue,
      );
      expect(masqueradeKeysPresent('wg://k@h.example:1?IP=dns#t'), isTrue);
      expect(masqueradeKeysPresent('wg://k@h.example:1?jc=1#t'), isFalse);
      expect(masqueradeKeysPresent('{"type":"wireguard","id":"a.b"}'), isTrue);
    });
  });

  group('protocol transitions (revision 1)', () {
    const q = Masquerade(ip: 'quic', id: 'a.example', ib: 'chrome');
    String pool() => 'pool.example';

    test('QUIC with an empty domain gets one from the pool', () {
      expect(
        Masquerade.off.withProtocol('quic', randomDomain: pool),
        const Masquerade(ip: 'quic', id: 'pool.example'),
      );
      expect(
        const Masquerade(ip: 'stun').withProtocol('quic'),
        const Masquerade(ip: 'quic'),
      );
      expect(
        const Masquerade(
          ip: 'dns',
          id: 'd.example',
        ).withProtocol('quic', randomDomain: pool),
        const Masquerade(ip: 'quic', id: 'd.example'),
      );
    });

    test('leaving QUIC drops ib', () {
      expect(
        q.withProtocol('dns'),
        const Masquerade(ip: 'dns', id: 'a.example'),
      );
      expect(
        q.withProtocol('sip'),
        const Masquerade(ip: 'sip', id: 'a.example'),
      );
    });

    test('STUN drops id, Off drops everything', () {
      expect(q.withProtocol('stun'), const Masquerade(ip: 'stun'));
      expect(q.withProtocol(''), Masquerade.off);
    });
  });

  group('form and domain checks', () {
    test('fromForm drops keys the form does not show', () {
      expect(
        Masquerade.fromForm('stun', 'a.example', 'chrome'),
        const Masquerade(ip: 'stun'),
      );
      expect(
        Masquerade.fromForm('dns', '', 'chrome'),
        const Masquerade(ip: 'dns'),
      );
      expect(Masquerade.fromForm('', 'a.example', 'chrome'), Masquerade.off);
      expect(
        Masquerade.fromForm('quic', ' a.example ', ''),
        const Masquerade(ip: 'quic', id: 'a.example'),
      );
    });

    test('domain errors', () {
      expect(masqueradeDomainError('quic', ''), MasqueradeDomainError.required);
      expect(masqueradeDomainError('quic', '', emptyAllowed: true), isNull);
      expect(masqueradeDomainError('dns', ''), isNull);
      expect(
        masqueradeDomainError('sip', 'bad domain'),
        MasqueradeDomainError.invalid,
      );
      expect(
        masqueradeDomainError('quic', '-a.example'),
        MasqueradeDomainError.invalid,
      );
      expect(
        masqueradeDomainError('quic', '${'a' * 60}.' * 5),
        MasqueradeDomainError.invalid,
      );
      expect(masqueradeDomainError('quic', 'www.example.org'), isNull);
    });
  });
}
