import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';
import 'package:lxbox/services/parser/uri_utils.dart';

// §169 — валидный X25519 public key (43-симв base64url = 32 байта).
const _validPbk = 'AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw';

/// §343 — normalizeRealityShortId: битый sid (нечётный/не-hex/>16) роняет
/// ВЕСЬ конфиг у ядра (`decode short_id: encoding/hex: odd length hex
/// string`). Принцип §169: битое значение отбрасывается целиком (`''`),
/// не подгоняется — обрезка/дополнение дали бы чужой идентификатор.
void main() {
  group('§343 normalizeRealityShortId', () {
    test('валидные чётные проходят как есть (lower-case)', () {
      expect(normalizeRealityShortId('abcd1234'), 'abcd1234');
      expect(normalizeRealityShortId('ABCD1234'), 'abcd1234');
      expect(normalizeRealityShortId('0123456789abcdef'), '0123456789abcdef');
      expect(normalizeRealityShortId('00'), '00');
      expect(normalizeRealityShortId(''), '');
      expect(normalizeRealityShortId('  abcd  '), 'abcd');
    });

    test('БОЕВОЙ КЕЙС: нечётная длина → отброс целиком', () {
      // outbound[1543]: decode short_id: encoding/hex: odd length hex string
      expect(normalizeRealityShortId('abc'), '');
      expect(normalizeRealityShortId('12345'), '');
      expect(normalizeRealityShortId('0'), '');
    });

    test('нечётность ПОСЛЕ чистки non-hex мусора → отброс', () {
      // Разделители вычищаются: 'ab-cd-e' → 'abcde' (5) → битый.
      expect(normalizeRealityShortId('ab-cd-e'), '');
      // Мусорные буквы вычищаются: 'g1g2g3' → '123' (3) → битый.
      expect(normalizeRealityShortId('g1g2g3'), '');
    });

    test('длиннее 16 hex-символов → отброс (раньше — тихая обрезка)', () {
      // Ядро: decodedLen > 8 → invalid short_id. Обрезка до 16 давала бы
      // валидную форму с чужим идентификатором (сервер сверяет побайтово).
      expect(normalizeRealityShortId('0123456789abcdef0'), '');
      expect(normalizeRealityShortId('0123456789abcdef01'), '');
    });

    test('чистка non-hex при чётном остатке сохраняется (старое поведение)', () {
      expect(normalizeRealityShortId('0x1a2'), '01a2'); // 'x' вычищен
    });

    test('парсер: vless URI с нечётным sid → REALITY жив, sid пуст', () {
      final spec = parseVless(
        'vless://u@h:443?type=tcp&security=reality&pbk=$_validPbk&sid=abc&sni=w.example.com#L',
      );
      expect(spec, isNotNull);
      expect(spec!.tls.reality, isNotNull);
      expect(spec.tls.reality!.shortId, '',
          reason: 'битый sid отброшен, нода не роняет конфиг');
    });
  });
}
