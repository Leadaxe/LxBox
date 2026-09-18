// Фича 478 — разбор строки отказа ядра, CANON §9.1–§9.2.
// Таблица примеров §9.2 взята дословно.
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/core_reject/core_error_parse.dart';

void main() {
  group('CANON §9.2 — таблица примеров дословно', () {
    test('эмодзи в теге, `: ` в тексте', () {
      final r = parseCoreRejection(
        'initialize outbound[3] vless[🇩🇪 Frankfurt]: parse encryption: bad',
        {'🇩🇪 Frankfurt'},
      );
      expect(r, isNotNull);
      expect(r!.kind, 'outbound');
      expect(r.index, 3);
      expect(r.type, 'vless');
      expect(r.tag, '🇩🇪 Frankfurt');
      expect(r.reason, 'parse encryption: bad');
    });

    test('`]: ` ВНУТРИ тега — побеждает длинный кандидат', () {
      final r = parseCoreRejection(
        'initialize outbound[0] vless[A]: B]: c',
        {'A]: B'},
      );
      expect(r!.tag, 'A]: B');
      expect(r.reason, 'c');
    });

    test('тот же вход при коротком теге в конфиге — побеждает короткий', () {
      final r = parseCoreRejection(
        'initialize outbound[0] vless[A]: B]: c',
        {'A'},
      );
      expect(r!.tag, 'A');
      expect(r.reason, 'B]: c');
    });

    test('endpoint + двоеточие в теге', () {
      final r = parseCoreRejection(
        'initialize endpoint[1] wireguard[wg: home]: bad key',
        {'wg: home'},
      );
      expect(r!.kind, 'endpoint');
      expect(r.type, 'wireguard');
      expect(r.tag, 'wg: home');
      expect(r.reason, 'bad key');
    });

    test('форма без тега (ядро < lx.7) — узел не назван', () {
      expect(
        parseCoreRejection(
          'initialize outbound[26]: unknown uTLS fingerprint',
          {'A', 'B'},
        ),
        isNull,
      );
    });

    test('ошибка не про узел (inbound) — узел не назван', () {
      expect(
        parseCoreRejection('initialize inbound[0] tun: permission denied', {'A'}),
        isNull,
      );
    });
  });

  group('§9.3 — сопоставление обязательно', () {
    test('тег не найден в конфиге → null, перебором не гадаем', () {
      expect(
        parseCoreRejection(
          'initialize outbound[3] vless[Frankfurt]: bad',
          {'Amsterdam', 'Berlin'},
        ),
        isNull,
      );
    });

    test('пустой набор тегов → null', () {
      expect(
        parseCoreRejection('initialize outbound[0] vless[A]: bad', const {}),
        isNull,
      );
    });

    test('при обоих кандидатах в конфиге побеждает правый (длинный)', () {
      final r = parseCoreRejection(
        'initialize outbound[0] vless[A]: B]: c',
        {'A', 'A]: B'},
      );
      expect(r!.tag, 'A]: B');
      expect(r.reason, 'c');
    });
  });

  group('форма строки', () {
    test('чужой префикс — null', () {
      expect(parseCoreRejection('start service: boom', {'A'}), isNull);
      expect(parseCoreRejection('initialize dns[0] local: bad', {'A'}), isNull);
      expect(parseCoreRejection('', {'A'}), isNull);
    });

    test('нецифровой индекс — null', () {
      expect(
        parseCoreRejection('initialize outbound[x] vless[A]: bad', {'A'}),
        isNull,
      );
    });

    test('обрамляющие пробелы снимаются', () {
      final r = parseCoreRejection(
        '  initialize outbound[7] trojan[T]: bad password  ',
        {'T'},
      );
      expect(r!.tag, 'T');
      expect(r.index, 7);
    });

    test('скобки в теге', () {
      final r = parseCoreRejection(
        'initialize outbound[2] vmess[node [eu] #1]: parse: x',
        {'node [eu] #1'},
      );
      expect(r!.tag, 'node [eu] #1');
      expect(r.reason, 'parse: x');
    });

    test('многоуровневая обёртка текста через `: `', () {
      final r = parseCoreRejection(
        'initialize outbound[9] vless[N]: parse encryption: '
        'unknown encryption appearance',
        {'N'},
      );
      expect(r!.reason,
          'parse encryption: unknown encryption appearance');
    });

    test('тег, кончающийся на `]`', () {
      final r = parseCoreRejection(
        'initialize outbound[1] vless[tag]]: boom',
        {'tag]'},
      );
      expect(r!.tag, 'tag]');
      expect(r.reason, 'boom');
    });

    test('пустой тег в конфиге не сопоставляется (тега не бывает пустым)', () {
      expect(
        parseCoreRejection('initialize outbound[0] vless[]: bad', {'A'}),
        isNull,
      );
    });
  });
}
