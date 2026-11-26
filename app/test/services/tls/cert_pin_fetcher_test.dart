import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/tls/cert_pin_fetcher.dart';

import '../../contract_paths.dart';

/// `pattern` поля `peer_fingerprint` из реестра OpenConnect (поиск по
/// дереву JSON).
String? _peerFingerprintPattern(Object? node) {
  if (node is Map) {
    final pf = node['peer_fingerprint'];
    if (pf is Map && pf['pattern'] is String) return pf['pattern'] as String;
    for (final v in node.values) {
      final r = _peerFingerprintPattern(v);
      if (r != null) return r;
    }
  } else if (node is List) {
    for (final v in node) {
      final r = _peerFingerprintPattern(v);
      if (r != null) return r;
    }
  }
  return null;
}

/// Ожидаемое: `openssl x509 -pubkey -noout | openssl pkey -pubin -outform DER
/// | openssl dgst -sha256 -binary | base64` по тем же сертификатам.
const _rsaPin = 'pin-sha256:WxPVOGb+KBXAuC9HHRQs1Tur5aTEqLxlmJQpJ93j614=';
const _ecPin = 'pin-sha256:Id6/u8jZC7lBwUdab+osmzfJV4r8u+xHmZFewkqVM7Q=';

void main() {
  group('pinFromCertificateDer', () {
    test('RSA и EC — как у openssl', () {
      final rsa = File('test/fixtures/cert_pin_rsa.der').readAsBytesSync();
      final ec = File('test/fixtures/cert_pin_ec.der').readAsBytesSync();
      expect(pinFromCertificateDer(rsa), _rsaPin);
      expect(pinFromCertificateDer(ec), _ecPin);
    });

    test('pin проходит pattern реестра для tls.peer_fingerprint', () {
      final json = jsonDecode(
        File(
          '$kRegistryRoot/registry/protocols/openconnect.json',
        ).readAsStringSync(),
      );
      final pattern = RegExp(_peerFingerprintPattern(json)!);
      expect(pattern.hasMatch(_rsaPin), isTrue);
      expect(pattern.hasMatch(_ecPin), isTrue);
    });

    test('не DER — FormatException', () {
      expect(
        () => pinFromCertificateDer(Uint8List.fromList([1, 2, 3])),
        throwsFormatException,
      );
      final rsa = File('test/fixtures/cert_pin_rsa.der').readAsBytesSync();
      expect(
        () => pinFromCertificateDer(Uint8List.sublistView(rsa, 0, 200)),
        throwsFormatException,
      );
    });
  });

  group('parseCertPinTarget', () {
    test('форматы поля server', () {
      expect(parseCertPinTarget('vpn.example.com'), (
        host: 'vpn.example.com',
        port: 443,
      ));
      expect(parseCertPinTarget(' vpn.example.com:8443 '), (
        host: 'vpn.example.com',
        port: 8443,
      ));
      expect(parseCertPinTarget('https://fw.example.com:42319/remote/login'), (
        host: 'fw.example.com',
        port: 42319,
      ));
      expect(parseCertPinTarget('https://fw.example.com/path'), (
        host: 'fw.example.com',
        port: 443,
      ));
      expect(parseCertPinTarget('[2001:db8::1]:8443'), (
        host: '2001:db8::1',
        port: 8443,
      ));
      expect(parseCertPinTarget('https://[2001:db8::1]'), (
        host: '2001:db8::1',
        port: 443,
      ));
      expect(parseCertPinTarget('2001:db8::1'), (
        host: '2001:db8::1',
        port: 443,
      ));
      expect(parseCertPinTarget('10.0.0.1:444'), (host: '10.0.0.1', port: 444));
    });

    test('пусто и мусор — null', () {
      expect(parseCertPinTarget(''), isNull);
      expect(parseCertPinTarget('   '), isNull);
      expect(parseCertPinTarget('https://'), isNull);
      expect(parseCertPinTarget('host:99999'), isNull);
      expect(parseCertPinTarget('a:b:c'), isNull);
    });
  });

  test('distinguishedNameCn', () {
    expect(distinguishedNameCn('/C=US/O=Org/CN=vpn.example.com'), 'vpn.example.com');
    expect(distinguishedNameCn('CN=ca.example, O=Org'), 'ca.example');
    expect(distinguishedNameCn('/O=Only Org'), '/O=Only Org');
  });
}
