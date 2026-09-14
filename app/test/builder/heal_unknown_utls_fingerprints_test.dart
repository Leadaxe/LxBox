import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/builder/post_steps.dart';

/// §281 — страховочный post-step: fingerprint вне словаря ядра заменяется
/// на chrome (мусор — с записью для emitWarnings, псевдонимы — молча),
/// а не роняет весь конфиг «unknown uTLS fingerprint» на старте.
void main() {
  group('healUnknownUtlsFingerprints', () {
    Map<String, dynamic> outbound(String tag, String fp) => {
          'tag': tag,
          'type': 'vless',
          'tls': {
            'enabled': true,
            'utls': {'enabled': true, 'fingerprint': fp},
          },
        };

    Map utlsOf(Map<String, dynamic> config, int i) =>
        ((config['outbounds'] as List)[i] as Map)['tls']['utls'] as Map;

    test('мусор → chrome + запись (owner/original)', () {
      final config = {
        'outbounds': [outbound('node-a', 'garbage')],
      };
      final healed = healUnknownUtlsFingerprints(config);

      expect(healed, hasLength(1));
      expect(healed.single.owner, 'node-a');
      expect(healed.single.original, 'garbage');
      expect(utlsOf(config, 0)['fingerprint'], 'chrome');
    });

    test('xray-псевдоним → канонизирован МОЛЧА (без записи)', () {
      final config = {
        'outbounds': [outbound('node-a', 'hellochrome_120')],
      };
      final healed = healUnknownUtlsFingerprints(config);

      expect(healed, isEmpty, reason: 'синоним — не warning');
      expect(utlsOf(config, 0)['fingerprint'], 'chrome');
    });

    test('регистр канонизируется молча', () {
      final config = {
        'outbounds': [outbound('node-a', 'QQ')],
      };
      final healed = healUnknownUtlsFingerprints(config);

      expect(healed, isEmpty);
      expect(utlsOf(config, 0)['fingerprint'], 'qq');
    });

    test('валидные значения словаря не тронуты', () {
      final config = {
        'outbounds': [
          outbound('a', 'chrome'),
          outbound('b', 'randomized'),
          outbound('c', 'chrome_psk_shuffle'),
        ],
      };
      final healed = healUnknownUtlsFingerprints(config);

      expect(healed, isEmpty);
      expect(utlsOf(config, 0)['fingerprint'], 'chrome');
      expect(utlsOf(config, 1)['fingerprint'], 'randomized');
      expect(utlsOf(config, 2)['fingerprint'], 'chrome_psk_shuffle');
    });

    test('пробельный fingerprint → поле снято, utls остаётся', () {
      final config = {
        'outbounds': [outbound('node-a', '  ')],
      };
      final healed = healUnknownUtlsFingerprints(config);

      expect(healed, isEmpty);
      expect(utlsOf(config, 0).containsKey('fingerprint'), isFalse);
      expect(utlsOf(config, 0)['enabled'], true);
    });

    test('outbound без tls/utls и не-Map значения → no-op', () {
      final config = {
        'outbounds': [
          {'tag': 'direct-out', 'type': 'direct'},
          {'tag': 'x', 'type': 'vless', 'tls': 'oops'},
          {
            'tag': 'y',
            'type': 'vless',
            'tls': {'enabled': true},
          },
        ],
      };
      expect(healUnknownUtlsFingerprints(config), isEmpty);
    });

    // SPEC 083 (ядро) — Xray ≥ v26.9.8 принимает REALITY только с
    // chrome-семейством (key_share X25519MLKEM768); подмена на выходе, молча.
    Map<String, dynamic> realityOutbound(String tag, String fp) => {
          'tag': tag,
          'type': 'vless',
          'tls': {
            'enabled': true,
            'utls': {'enabled': true, 'fingerprint': fp},
            'reality': {'enabled': true, 'public_key': 'pk'},
          },
        };

    test('SPEC 083: REALITY + firefox/random/randomized → chrome, молча', () {
      final config = {
        'outbounds': [
          realityOutbound('ff', 'firefox'),
          realityOutbound('rnd', 'random'),
          realityOutbound('rz', 'randomized'),
          realityOutbound('junk', 'garbage'),
        ],
      };
      final healed = healUnknownUtlsFingerprints(config);
      for (var i = 0; i < 4; i++) {
        expect(utlsOf(config, i)['fingerprint'], 'chrome', reason: 'i=$i');
      }
      expect(healed.map((h) => h.owner), ['junk'],
          reason: 'запись только про мусор, подмена под REALITY — молча');
    });

    test('SPEC 083: REALITY + chrome-семейство и plain TLS + firefox → no-op',
        () {
      final config = {
        'outbounds': [
          realityOutbound('c', 'chrome'),
          realityOutbound('cpq', 'chrome_pq'),
          outbound('tls-ff', 'firefox'),
        ],
      };
      expect(healUnknownUtlsFingerprints(config), isEmpty);
      expect(utlsOf(config, 0)['fingerprint'], 'chrome');
      expect(utlsOf(config, 1)['fingerprint'], 'chrome_pq');
      expect(utlsOf(config, 2)['fingerprint'], 'firefox',
          reason: 'без REALITY отпечаток пользователя не трогаем');
    });

    test('SPEC 083: REALITY + reality.enabled=false + firefox → no-op', () {
      final config = {
        'outbounds': [
          {
            'tag': 'off',
            'type': 'vless',
            'tls': {
              'enabled': true,
              'utls': {'enabled': true, 'fingerprint': 'firefox'},
              'reality': {'enabled': false, 'public_key': 'pk'},
            },
          },
        ],
      };
      expect(healUnknownUtlsFingerprints(config), isEmpty);
      expect(utlsOf(config, 0)['fingerprint'], 'firefox');
    });

    test('пустой конфиг → no-op', () {
      expect(healUnknownUtlsFingerprints({}), isEmpty);
    });

    test('РЕВЬЮ §281: REALITY без utls-блока → минимальный блок восстановлен',
        () {
      final config = {
        'outbounds': [
          {
            'tag': 'r',
            'type': 'vless',
            'tls': {
              'enabled': true,
              'reality': {'enabled': true, 'public_key': 'pk'},
            },
          },
        ],
      };
      final healed = healUnknownUtlsFingerprints(config);

      expect(healed, isEmpty, reason: 'восстановление — молча');
      expect(utlsOf(config, 0)['enabled'], true,
          reason: 'без uTLS ядро отвергает reality-outbound на старте');
      expect(utlsOf(config, 0)['fingerprint'], 'chrome',
          reason: 'D-104: chrome ЯВНО, не дефолт ядра');
    });

    test('D-104: REALITY + пустой/пробельный fingerprint → chrome ЯВНО', () {
      final config = {
        'outbounds': [
          realityOutbound('empty', ''),
          realityOutbound('blank', '  '),
        ],
      };
      final healed = healUnknownUtlsFingerprints(config);

      expect(healed, isEmpty);
      expect(utlsOf(config, 0)['fingerprint'], 'chrome');
      expect(utlsOf(config, 1)['fingerprint'], 'chrome');
    });

    test(
        'РЕВЬЮ §282: QUIC (hysteria2/tuic) → utls И reality СНЯТЫ, '
        'НЕ восстановлены (иначе воскрешение мёртвой QUIC-ноды)', () {
      for (final type in ['hysteria2', 'tuic']) {
        final config = {
          'outbounds': [
            {
              'tag': 'q',
              'type': type,
              'tls': {
                'enabled': true,
                'server_name': 'x.com',
                'reality': {'enabled': true, 'public_key': 'pk'},
                'utls': {'enabled': true, 'fingerprint': 'garbage'},
              },
            },
          ],
        };
        final healed = healUnknownUtlsFingerprints(config);

        expect(healed, isEmpty, reason: '$type: срез — молча');
        final tls = ((config['outbounds'] as List)[0] as Map)['tls'] as Map;
        expect(tls.containsKey('utls'), isFalse, reason: '$type utls снят');
        expect(tls.containsKey('reality'), isFalse,
            reason: '$type reality снят');
        expect(tls['server_name'], 'x.com', reason: '$type остальное цело');
      }
    });

    test('РЕВЬЮ §281: REALITY + utls.enabled=false → включён', () {
      final config = {
        'outbounds': [
          {
            'tag': 'r',
            'type': 'vless',
            'tls': {
              'enabled': true,
              'utls': {'enabled': false, 'fingerprint': 'chrome'},
              'reality': {'enabled': true, 'public_key': 'pk'},
            },
          },
        ],
      };
      final healed = healUnknownUtlsFingerprints(config);

      expect(healed, isEmpty);
      expect(utlsOf(config, 0)['enabled'], true);
      expect(utlsOf(config, 0)['fingerprint'], 'chrome');
    });
  });
}
