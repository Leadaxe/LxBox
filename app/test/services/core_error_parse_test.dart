// Фича 478 — разбор строки отказа ядра, PARSING_PRINCIPLES §9.1–§9.2.
// Таблица примеров §9.2 взята дословно.
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/core_reject/core_error_parse.dart';

void main() {
  group('PARSING_PRINCIPLES §9.2 — таблица примеров дословно', () {
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

  // Д-1 — до Dart строка доходит обёрнутой: Go кладёт свою цепочку, Kotlin
  // сверху локализованный шаблон `stop_alert_start_failed`. Разбор не вправе
  // знать ни один текст обёртки — иначе страховка молчит на ru.
  group('Д-1 — обёртки перед грамматикой §9', () {
    // Дословно то, что пришло с эмулятора.
    const device = 'Failed to start service: start or reload service: '
        'initialize outbound[33] shadowsocks[⚡ c-ss2022-badkey]: '
        'bad key length, required 32, got 5';

    test('обёрнутая en — как на устройстве', () {
      final r = parseCoreRejection(device, {'⚡ c-ss2022-badkey'});
      expect(r, isNotNull);
      expect(r!.kind, 'outbound');
      expect(r.index, 33);
      expect(r.type, 'shadowsocks');
      expect(r.tag, '⚡ c-ss2022-badkey');
      expect(r.reason, 'bad key length, required 32, got 5');
    });

    test('обёрнутая ru — локализованный префикс Kotlin', () {
      final r = parseCoreRejection(
        'Не удалось запустить сервис: start or reload service: '
        'initialize endpoint[4] wireguard[🇩🇪 wg]: bad key',
        {'🇩🇪 wg'},
      );
      expect(r!.tag, '🇩🇪 wg');
      expect(r.reason, 'bad key');
    });

    test('двойная Go-обёртка', () {
      final r = parseCoreRejection(
        'start service: start or reload service: create service: '
        'initialize outbound[7] trojan[T]: bad password',
        {'T'},
      );
      expect(r!.tag, 'T');
      expect(r.index, 7);
      expect(r.reason, 'bad password');
    });

    test('голая строка разбирается по-прежнему', () {
      final r = parseCoreRejection(
        'initialize outbound[3] vless[Frankfurt]: parse encryption: bad',
        {'Frankfurt'},
      );
      expect(r!.tag, 'Frankfurt');
      expect(r.reason, 'parse encryption: bad');
    });

    test('обёртка + `: ` и `]` внутри тега', () {
      final r = parseCoreRejection(
        'Failed to start service: start or reload service: '
        'initialize outbound[0] vless[A]: B]]: c',
        {'A]: B]'},
      );
      expect(r!.tag, 'A]: B]');
      expect(r.reason, 'c');
    });

    test('слово initialize в обёртке не сбивает разбор', () {
      final r = parseCoreRejection(
        'initialize service: start or reload service: '
        'initialize outbound[2] vmess[N]: boom',
        {'N'},
      );
      expect(r!.tag, 'N');
      expect(r.type, 'vmess');
      expect(r.reason, 'boom');
    });

    test('обёрнутая форма без тега — узел по-прежнему не назван', () {
      expect(
        parseCoreRejection(
          'Failed to start service: start or reload service: '
          'initialize outbound[26]: unknown uTLS fingerprint',
          {'A', 'B'},
        ),
        isNull,
      );
    });

    test('обёрнутая ошибка не про узел — null', () {
      expect(
        parseCoreRejection(
          'Failed to start service: start or reload service: '
          'initialize inbound[0] tun: permission denied',
          {'A'},
        ),
        isNull,
      );
    });
  });
}
