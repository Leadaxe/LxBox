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
