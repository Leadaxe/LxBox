import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/parser/json_parsers.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';
import 'package:lxbox/services/parser/utls_fingerprint.dart';

// §169 — валидный X25519 public key (43-симв base64url = 32 байта).
const _validPbk = 'AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw';

/// §281 — uTLS fingerprint вне словаря ядра = fatal ВСЕГО конфига на старте
/// («unknown uTLS fingerprint»). Xray-псевдонимы канонизируются молча,
/// неопознанный мусор → chrome + UnknownFingerprintWarning.
void main() {
  group('normalizeUtlsFingerprintValue (чистая функция)', () {
    test('значения словаря проходят как есть', () {
      for (final fp in kUtlsFingerprints) {
        final n = normalizeUtlsFingerprintValue(fp);
        expect(n.value, fp);
        expect(n.junk, isFalse);
      }
    });

    test('регистр и пробелы канонизируются', () {
      expect(normalizeUtlsFingerprintValue('QQ'), (value: 'qq', junk: false));
      expect(normalizeUtlsFingerprintValue(' Chrome '),
          (value: 'chrome', junk: false));
    });

    test('xray-псевдонимы hello* → семейство, НЕ junk', () {
      const cases = {
        'hellochrome_120': 'chrome',
        'hellochrome_106_shuffle': 'chrome',
        'hellochrome_auto': 'chrome',
        'HelloChrome_120': 'chrome',
        'hellofirefox_auto': 'firefox',
        'helloedge_85': 'edge',
        'hellosafari_auto': 'safari',
        'hello360_auto': '360',
        'helloqq_auto': 'qq',
        'helloios_auto': 'ios',
        'helloandroid_11_okhttp': 'android',
        'hellorandomized': 'randomized',
        'hellorandomizedalpn': 'randomized',
        'hellorandomizednoalpn': 'randomized',
      };
      cases.forEach((raw, want) {
        final n = normalizeUtlsFingerprintValue(raw);
        expect(n.value, want, reason: raw);
        expect(n.junk, isFalse, reason: raw);
      });
    });

    test('неопознанный мусор → chrome + junk', () {
      for (final raw in ['garbage', 'hellogolang', 'hellocustom', 'none']) {
        final n = normalizeUtlsFingerprintValue(raw);
        expect(n.value, 'chrome', reason: raw);
        expect(n.junk, isTrue, reason: raw);
      }
    });

    test('пустая/пробельная строка → пустая, НЕ junk', () {
      expect(normalizeUtlsFingerprintValue(''), (value: '', junk: false));
      expect(normalizeUtlsFingerprintValue('  '), (value: '', junk: false));
    });
  });

  group('VLESS (реальный кейс подписки)', () {
    test('REALITY + fp=hellochrome_120 → chrome, МОЛЧА, reality на месте', () {
      final spec = parseVless(
          'vless://u@h:443?type=tcp&security=reality&encryption=none'
          '&flow=xtls-rprx-vision&fp=hellochrome_120&pbk=$_validPbk#L')!;
      expect(spec.tls.fingerprint, 'chrome');
      expect(spec.tls.reality, isNotNull, reason: 'REALITY не потерян');
      expect(spec.warnings.whereType<UnknownFingerprintWarning>(), isEmpty,
          reason: 'псевдоним = синоним, не warning');
    });

    test('fp=QQ → qq (регистр)', () {
      final spec = parseVless(
          'vless://u@h:443?type=grpc&security=reality&fp=QQ&pbk=$_validPbk#L')!;
      expect(spec.tls.fingerprint, 'qq');
      expect(spec.warnings.whereType<UnknownFingerprintWarning>(), isEmpty);
    });

    test('мусор → chrome + UnknownFingerprintWarning', () {
      final spec =
          parseVless('vless://u@h:443?security=tls&fp=garbage&sni=x.com#L')!;
      expect(spec.tls.fingerprint, 'chrome');
      expect(spec.warnings, contains(const UnknownFingerprintWarning('garbage')));
    });

    test('emit отдаёт канонизированный utls.fingerprint', () {
      final spec = parseVless(
          'vless://u@h:443?security=tls&fp=hellochrome_120&sni=x.com#L')!;
      final out = spec.emit(TemplateVars.empty).map;
      final utls = (out['tls'] as Map)['utls'] as Map;
      expect(utls['fingerprint'], 'chrome');
    });

    test('пустой fp → существующий дефолт random (не тронут)', () {
      final spec = parseVless('vless://u@h:443?security=tls&fp=&sni=x.com#L')!;
      expect(spec.tls.fingerprint, 'random');
    });
  });

  group('остальные URI-парсеры', () {
    test('trojan: псевдоним молча', () {
      final spec = parseTrojan(
          'trojan://p@h:443?security=tls&fp=hellofirefox_auto&sni=x.com#L')!;
      expect(spec.tls.fingerprint, 'firefox');
      expect(spec.warnings.whereType<UnknownFingerprintWarning>(), isEmpty);
    });

    test('trojan: мусор → chrome + warning', () {
      final spec =
          parseTrojan('trojan://p@h:443?security=tls&fp=bogus&sni=x.com#L')!;
      expect(spec.tls.fingerprint, 'chrome');
      expect(spec.warnings, contains(const UnknownFingerprintWarning('bogus')));
    });

    test('trojan: пустой fp → null (без utls-блока)', () {
      final spec = parseTrojan('trojan://p@h:443?security=tls&sni=x.com#L')!;
      expect(spec.tls.fingerprint, isNull);
    });

    test('vmess: мусор в fp из base64-JSON → chrome + warning', () {
      final cfg = {
        'v': '2',
        'ps': 'L',
        'add': 'h',
        'port': '443',
        'id': '0aa41f0a-6d92-4f74-8b13-4d0d5b6cbb6c',
        'net': 'ws',
        'tls': 'tls',
        'fp': 'wat',
        'host': 'x.com',
        'path': '/',
      };
      final uri = 'vmess://${base64Encode(utf8.encode(jsonEncode(cfg)))}';
      final spec = parseVmess(uri)!;
      expect(spec.tls.fingerprint, 'chrome');
      expect(spec.warnings, contains(const UnknownFingerprintWarning('wat')));
    });

    test('anytls: псевдоним молча (через VLESS-конвенцию)', () {
      final spec =
          parseAnyTls('anytls://p@h:443?fp=hellochrome_131&sni=x.com#L')!;
      expect(spec.tls.fingerprint, 'chrome');
      expect(spec.warnings.whereType<UnknownFingerprintWarning>(), isEmpty);
    });

    test('hysteria2: мусор → chrome + warning (тот же tls.NewClient ядра)',
        () {
      final spec =
          parseHysteria2('hysteria2://p@h:443?fp=bogus&sni=x.com#L')!;
      expect(spec.tls.fingerprint, 'chrome');
      expect(spec.warnings, contains(const UnknownFingerprintWarning('bogus')));
    });

    test('proxy-https: псевдоним молча', () {
      final spec = parseHttpProxy(
          'proxy-https://u:p@h:443?fp=hellochrome_120&sni=x.com#L')!;
      expect(spec.tls.fingerprint, 'chrome');
      expect(spec.warnings.whereType<UnknownFingerprintWarning>(), isEmpty);
    });
  });

  group('JSON-парсеры', () {
    test('xray streamSettings: псевдоним в reality.fingerprint → chrome', () {
      final spec = parseXrayOutbound(<String, dynamic>{
        'remarks': 'L',
        'outbounds': [
          {
            'protocol': 'vless',
            'tag': 'proxy',
            'settings': {
              'vnext': [
                {
                  'address': 'h',
                  'port': 443,
                  'users': [
                    {'id': '0aa41f0a-6d92-4f74-8b13-4d0d5b6cbb6c'}
                  ],
                }
              ],
            },
            'streamSettings': {
              'network': 'tcp',
              'security': 'reality',
              'realitySettings': {
                'publicKey': _validPbk,
                'fingerprint': 'hellochrome_120',
                'serverName': 'x.com',
              },
            },
          },
        ],
      })! as VlessSpec;
      expect(spec.tls.fingerprint, 'chrome');
      expect(spec.warnings.whereType<UnknownFingerprintWarning>(), isEmpty);
    });

    test('raw sing-box entry: псевдоним и мусор канонизируются молча', () {
      VlessSpec entryWithFp(String fp) => parseSingboxEntry({
            'type': 'vless',
            'tag': 't',
            'server': 'h',
            'server_port': 443,
            'uuid': '0aa41f0a-6d92-4f74-8b13-4d0d5b6cbb6c',
            'tls': {
              'enabled': true,
              'server_name': 'x.com',
              'utls': {'enabled': true, 'fingerprint': fp},
            },
          })! as VlessSpec;
      expect(entryWithFp('HelloChrome_120').tls.fingerprint, 'chrome');
      expect(entryWithFp('garbage').tls.fingerprint, 'chrome');
    });

    test(
        'РЕВЬЮ §281: REALITY + пустой/пробельный fingerprint → chrome '
        '(иначе toSingbox не эмитит utls, а ядру uTLS при reality обязателен)',
        () {
      for (final fp in ['', '  ']) {
        final spec = parseSingboxEntry({
          'type': 'vless',
          'tag': 't',
          'server': 'h',
          'server_port': 443,
          'uuid': '0aa41f0a-6d92-4f74-8b13-4d0d5b6cbb6c',
          'tls': {
            'enabled': true,
            'server_name': 'x.com',
            'utls': {'enabled': true, 'fingerprint': fp},
            'reality': {'enabled': true, 'public_key': _validPbk},
          },
        })! as VlessSpec;
        expect(spec.tls.fingerprint, 'chrome', reason: 'fp="$fp"');
        expect(spec.tls.reality, isNotNull);
        final utls =
            (spec.emit(TemplateVars.empty).map['tls'] as Map)['utls'] as Map;
        expect(utls['fingerprint'], 'chrome');
      }
    });

    test('РЕВЬЮ §281: xray reality с пустым fingerprint → chrome', () {
      final spec = parseXrayOutbound(<String, dynamic>{
        'remarks': 'L',
        'outbounds': [
          {
            'protocol': 'vless',
            'tag': 'proxy',
            'settings': {
              'vnext': [
                {
                  'address': 'h',
                  'port': 443,
                  'users': [
                    {'id': '0aa41f0a-6d92-4f74-8b13-4d0d5b6cbb6c'}
                  ],
                }
              ],
            },
            'streamSettings': {
              'network': 'tcp',
              'security': 'reality',
              'realitySettings': {
                'publicKey': _validPbk,
                'fingerprint': '',
                'serverName': 'x.com',
              },
            },
          },
        ],
      })! as VlessSpec;
      expect(spec.tls.fingerprint, 'chrome');
      expect(spec.tls.reality, isNotNull);
    });

    test(
        'РЕВЬЮ §281: naive-entry срезает TLS до enabled/server_name '
        '(alpn/utls/insecure/reality для naive = fatal у ядра)', () {
      final spec = parseSingboxEntry({
        'type': 'naive',
        'tag': 't',
        'server': 'h',
        'server_port': 443,
        'username': 'u',
        'password': 'p',
        'tls': {
          'enabled': true,
          'server_name': 'x.com',
          'insecure': true,
          'alpn': ['h2'],
          'utls': {'enabled': true, 'fingerprint': 'chrome'},
          'reality': {'enabled': true, 'public_key': _validPbk},
        },
      })! as NaiveSpec;
      expect(spec.tls.enabled, isTrue);
      expect(spec.tls.serverName, 'x.com');
      expect(spec.tls.fingerprint, isNull);
      expect(spec.tls.alpn, isEmpty);
      expect(spec.tls.insecure, isFalse);
      expect(spec.tls.reality, isNull);
    });
  });
}
