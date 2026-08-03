import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/builder/post_steps.dart';

// §169 — валидный X25519 public key (43-симв base64url = 32 байта).
const _validPbk = 'AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw';

Map<String, dynamic> _vlessReality({
  String tag = 'node',
  String pbk = _validPbk,
  Object? shortId = 'abcd1234',
}) =>
    {
      'tag': tag,
      'type': 'vless',
      'tls': {
        'enabled': true,
        'server_name': 'w.example.com',
        'utls': {'enabled': true, 'fingerprint': 'chrome'},
        'reality': {
          'enabled': true,
          'public_key': pbk,
          if (shortId case final Object sid) 'short_id': sid,
        },
      },
    };

/// §343 — страховка от битого REALITY в собранном конфиге (пути мимо
/// парсера: raw JSON, §302 import rules). Битый short_id → '', битый
/// public_key → reality снят (plain TLS). Ядро иначе роняет ВЕСЬ конфиг.
void main() {
  group('healInvalidReality', () {
    test('БОЕВОЙ КЕЙС: нечётный short_id → очищен, нода и конфиг живы', () {
      // initialize outbound[1543]: decode short_id: encoding/hex: odd length
      final config = {
        'outbounds': [_vlessReality(tag: 'bad', shortId: 'abc')],
      };
      final healed = healInvalidReality(config);

      expect(healed, hasLength(1));
      expect(healed.single.owner, 'bad');
      expect(healed.single.field, 'short_id');
      expect(healed.single.original, 'abc');
      final reality =
          ((config['outbounds'] as List)[0] as Map)['tls']['reality'] as Map;
      expect(reality['short_id'], '', reason: 'битый sid отброшен');
      expect(reality['enabled'], true, reason: 'REALITY-блок сохранён');
    });

    test('short_id >16 hex / non-hex → очищен', () {
      final config = {
        'outbounds': [
          _vlessReality(tag: 'long', shortId: '0123456789abcdef01'),
          _vlessReality(tag: 'junk', shortId: 'xyz!'),
        ],
      };
      final healed = healInvalidReality(config);

      expect(healed.map((h) => h.owner), containsAll(['long', 'junk']));
      for (final o in (config['outbounds'] as List).cast<Map>()) {
        expect((o['tls']['reality'] as Map)['short_id'], '');
      }
    });

    test('не-строковый short_id (число из raw-JSON/§302-патча) → очищен', () {
      final config = {
        'outbounds': [_vlessReality(tag: 'num', shortId: 12)],
      };
      final healed = healInvalidReality(config);

      expect(healed, hasLength(1));
      expect(healed.single.owner, 'num');
      expect(healed.single.field, 'short_id');
      final reality =
          ((config['outbounds'] as List)[0] as Map)['tls']['reality'] as Map;
      expect(reality['short_id'], '',
          reason: 'тип-mismatch ядро тоже не декодирует — тот же fatal');
    });

    test('валидный short_id (чётный, ≤16, upper-case тоже) → НЕ трогаем', () {
      final config = {
        'outbounds': [
          _vlessReality(tag: 'a', shortId: 'abcd1234'),
          _vlessReality(tag: 'b', shortId: 'ABCD'),
          _vlessReality(tag: 'c', shortId: ''),
          _vlessReality(tag: 'd', shortId: null),
        ],
      };
      expect(healInvalidReality(config), isEmpty);
      expect(
          ((config['outbounds'] as List)[1] as Map)['tls']['reality']
              ['short_id'],
          'ABCD',
          reason: 'ядро принимает оба регистра — не мутируем без нужды');
    });

    test('битый public_key → reality снят целиком (plain TLS, зеркало §169)',
        () {
      final config = {
        'outbounds': [_vlessReality(tag: 'bad-pbk', pbk: 'enabled')],
      };
      final healed = healInvalidReality(config);

      expect(healed, hasLength(1));
      expect(healed.single.field, 'public_key');
      final tls = ((config['outbounds'] as List)[0] as Map)['tls'] as Map;
      expect(tls.containsKey('reality'), isFalse, reason: 'reality снят');
      expect(tls['enabled'], true, reason: 'plain TLS остаётся');
    });

    test('битый pbk + битый sid → снятие reality побеждает (одна запись)', () {
      final config = {
        'outbounds': [_vlessReality(tag: 'x', pbk: 'true', shortId: 'abc')],
      };
      final healed = healInvalidReality(config);
      expect(healed, hasLength(1));
      expect(healed.single.field, 'public_key');
    });

    test('ноды без tls/reality и не-Map мусор → не трогаем, не падаем', () {
      final config = {
        'outbounds': [
          {'tag': 'direct-out', 'type': 'direct'},
          {'tag': 'ss', 'type': 'shadowsocks', 'tls': 'oops'},
          _vlessReality(tag: 'ok'),
        ],
      };
      expect(healInvalidReality(config), isEmpty);
    });
  });
}
