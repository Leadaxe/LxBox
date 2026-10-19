// Фича 478 — разбор строки отказа ядра, PARSING_PRINCIPLES §9.1–§9.2.
// Таблица примеров §9.2 взята дословно.
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/core_reject/core_error_parse.dart';

/// Форма `initialize`: нужен только набор финальных тегов.
CoreRejection? _parse(String line, Set<String> tags) =>
    parseCoreRejection(line, CoreConfigTags(all: tags));

/// §653: конфиг с порядком массивов — 5 outbound'ов, 1 endpoint.
CoreConfigTags _ordered() => CoreConfigTags.fromConfigJson(
  '{"outbounds":['
  '{"type":"direct","tag":"direct-out"},'
  '{"type":"vless","tag":"🇩🇪 Frankfurt"},'
  '{"type":"selector","tag":"proxy-out"},'
  '{"type":"masque","tag":"m1"},'
  '{"type":"block"}'
  '],"endpoints":[{"type":"wireguard","tag":"wg home"}]}',
  all: const {'direct-out', '🇩🇪 Frankfurt', 'proxy-out', 'm1', 'wg home'},
);

void main() {
  group('PARSING_PRINCIPLES §9.2 — таблица примеров дословно', () {
    test('эмодзи в теге, `: ` в тексте', () {
      final r = _parse(
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
      final r = _parse('initialize outbound[0] vless[A]: B]: c', {'A]: B'});
      expect(r!.tag, 'A]: B');
      expect(r.reason, 'c');
    });

    test('тот же вход при коротком теге в конфиге — побеждает короткий', () {
      final r = _parse('initialize outbound[0] vless[A]: B]: c', {'A'});
      expect(r!.tag, 'A');
      expect(r.reason, 'B]: c');
    });

    test('endpoint + двоеточие в теге', () {
      final r = _parse('initialize endpoint[1] wireguard[wg: home]: bad key', {
        'wg: home',
      });
      expect(r!.kind, 'endpoint');
      expect(r.type, 'wireguard');
      expect(r.tag, 'wg: home');
      expect(r.reason, 'bad key');
    });

    test('форма без тега (ядро < lx.7) — узел не назван', () {
      expect(
        _parse('initialize outbound[26]: unknown uTLS fingerprint', {'A', 'B'}),
        isNull,
      );
    });

    test('ошибка не про узел (inbound) — узел не назван', () {
      expect(
        _parse('initialize inbound[0] tun: permission denied', {'A'}),
        isNull,
      );
    });
  });

  group('§9.3 — сопоставление обязательно', () {
    test('тег не найден в конфиге → null, перебором не гадаем', () {
      expect(
        _parse('initialize outbound[3] vless[Frankfurt]: bad', {
          'Amsterdam',
          'Berlin',
        }),
        isNull,
      );
    });

    test('пустой набор тегов → null', () {
      expect(_parse('initialize outbound[0] vless[A]: bad', const {}), isNull);
    });

    test('при обоих кандидатах в конфиге побеждает правый (длинный)', () {
      final r = _parse('initialize outbound[0] vless[A]: B]: c', {
        'A',
        'A]: B',
      });
      expect(r!.tag, 'A]: B');
      expect(r.reason, 'c');
    });
  });

  group('форма строки', () {
    test('чужой префикс — null', () {
      expect(_parse('start service: boom', {'A'}), isNull);
      expect(_parse('initialize dns[0] local: bad', {'A'}), isNull);
      expect(_parse('', {'A'}), isNull);
    });

    test('нецифровой индекс — null', () {
      expect(_parse('initialize outbound[x] vless[A]: bad', {'A'}), isNull);
    });

    test('обрамляющие пробелы снимаются', () {
      final r = _parse('  initialize outbound[7] trojan[T]: bad password  ', {
        'T',
      });
      expect(r!.tag, 'T');
      expect(r.index, 7);
    });

    test('скобки в теге', () {
      final r = _parse('initialize outbound[2] vmess[node [eu] #1]: parse: x', {
        'node [eu] #1',
      });
      expect(r!.tag, 'node [eu] #1');
      expect(r.reason, 'parse: x');
    });

    test('многоуровневая обёртка текста через `: `', () {
      final r = _parse(
        'initialize outbound[9] vless[N]: parse encryption: '
        'unknown encryption appearance',
        {'N'},
      );
      expect(r!.reason, 'parse encryption: unknown encryption appearance');
    });

    test('тег, кончающийся на `]`', () {
      final r = _parse('initialize outbound[1] vless[tag]]: boom', {'tag]'});
      expect(r!.tag, 'tag]');
      expect(r.reason, 'boom');
    });

    test('пустой тег в конфиге не сопоставляется (тега не бывает пустым)', () {
      expect(_parse('initialize outbound[0] vless[]: bad', {'A'}), isNull);
    });
  });

  // Д-1 — до Dart строка доходит обёрнутой: Go кладёт свою цепочку, Kotlin
  // сверху локализованный шаблон `stop_alert_start_failed`. Разбор не вправе
  // знать ни один текст обёртки — иначе страховка молчит на ru.
  group('Д-1 — обёртки перед грамматикой §9', () {
    // Дословно то, что пришло с эмулятора.
    const device =
        'Failed to start service: start or reload service: '
        'initialize outbound[33] shadowsocks[⚡ c-ss2022-badkey]: '
        'bad key length, required 32, got 5';

    test('обёрнутая en — как на устройстве', () {
      final r = _parse(device, {'⚡ c-ss2022-badkey'});
      expect(r, isNotNull);
      expect(r!.kind, 'outbound');
      expect(r.index, 33);
      expect(r.type, 'shadowsocks');
      expect(r.tag, '⚡ c-ss2022-badkey');
      expect(r.reason, 'bad key length, required 32, got 5');
    });

    test('обёрнутая ru — локализованный префикс Kotlin', () {
      final r = _parse(
        'Не удалось запустить сервис: start or reload service: '
        'initialize endpoint[4] wireguard[🇩🇪 wg]: bad key',
        {'🇩🇪 wg'},
      );
      expect(r!.tag, '🇩🇪 wg');
      expect(r.reason, 'bad key');
    });

    test('двойная Go-обёртка', () {
      final r = _parse(
        'start service: start or reload service: create service: '
        'initialize outbound[7] trojan[T]: bad password',
        {'T'},
      );
      expect(r!.tag, 'T');
      expect(r.index, 7);
      expect(r.reason, 'bad password');
    });

    test('голая строка разбирается по-прежнему', () {
      final r = _parse(
        'initialize outbound[3] vless[Frankfurt]: parse encryption: bad',
        {'Frankfurt'},
      );
      expect(r!.tag, 'Frankfurt');
      expect(r.reason, 'parse encryption: bad');
    });

    test('обёртка + `: ` и `]` внутри тега', () {
      final r = _parse(
        'Failed to start service: start or reload service: '
        'initialize outbound[0] vless[A]: B]]: c',
        {'A]: B]'},
      );
      expect(r!.tag, 'A]: B]');
      expect(r.reason, 'c');
    });

    test('слово initialize в обёртке не сбивает разбор', () {
      final r = _parse(
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
        _parse(
          'Failed to start service: start or reload service: '
          'initialize outbound[26]: unknown uTLS fingerprint',
          {'A', 'B'},
        ),
        isNull,
      );
    });

    test('обёрнутая ошибка не про узел — null', () {
      expect(
        _parse(
          'Failed to start service: start or reload service: '
          'initialize inbound[0] tun: permission denied',
          {'A'},
        ),
        isNull,
      );
    });
  });

  group('§9.1 форма декодирования (§653)', () {
    test('таблица §A: outbounds[i].path → тег i-го outbound', () {
      final r = parseCoreRejection(
        'decode config: outbounds[3].network: json: unknown field "network"',
        _ordered(),
      );
      expect(r, isNotNull);
      expect(r!.kind, 'outbound');
      expect(r.index, 3);
      expect(r.tag, 'm1');
      expect(r.type, 'masque');
      expect(r.reason, 'network: json: unknown field "network"');
    });

    test('таблица §A: endpoints[0] с вложенным путём', () {
      final r = parseCoreRejection(
        'decode config: endpoints[0].peers[1].public_key: '
        'json: cannot unmarshal string',
        _ordered(),
      );
      expect(r!.kind, 'endpoint');
      expect(r.index, 0);
      expect(r.tag, 'wg home');
      expect(r.type, 'wireguard');
      expect(r.reason, 'peers[1].public_key: json: cannot unmarshal string');
    });

    test('таблица §A: route.rules[3].outbound — не про узел', () {
      expect(
        parseCoreRejection(
          'decode config: route.rules[3].outbound: json: bad',
          _ordered(),
        ),
        isNull,
      );
    });

    test('таблица §A: индекс вне массива — null', () {
      expect(
        parseCoreRejection(
          'decode config: outbounds[99].foo: json: unknown field "foo"',
          _ordered(),
        ),
        isNull,
      );
    });

    test('без пути — reason = текст', () {
      final r = parseCoreRejection(
        'decode config: outbounds[1]: json: cannot unmarshal array',
        _ordered(),
      );
      expect(r!.tag, '🇩🇪 Frankfurt');
      expect(r.reason, 'json: cannot unmarshal array');
    });

    test('обёртки Go и Kotlin перед decode config:', () {
      final r = parseCoreRejection(
        'Не удалось запустить сервис: start or reload service: '
        'decode config: outbounds[3].network: json: unknown field "network"',
        _ordered(),
      );
      expect(r!.tag, 'm1');
      expect(r.reason, 'network: json: unknown field "network"');
    });

    test('outbounds[ внутри тега формы initialize — побеждает initialize', () {
      final cfg = CoreConfigTags.fromConfigJson(
        '{"outbounds":[{"type":"vless","tag":"a"},'
        '{"type":"vless","tag":"x outbounds[0]: y"}]}',
        all: const {'a', 'x outbounds[0]: y'},
      );
      final r = parseCoreRejection(
        'initialize outbound[1] vless[x outbounds[0]: y]: bad key',
        cfg,
      );
      expect(r!.tag, 'x outbounds[0]: y');
      expect(r.index, 1);
      expect(r.reason, 'bad key');
    });

    test('ведущие нули и нецифры в индексе — null', () {
      for (final i in ['01', '003', 'x', '1a', '-1', '']) {
        expect(
          parseCoreRejection(
            'decode config: outbounds[$i].network: json: bad',
            _ordered(),
          ),
          isNull,
          reason: i,
        );
      }
    });

    test('пустой тег в массиве по индексу — null', () {
      expect(
        parseCoreRejection(
          'decode config: outbounds[4].foo: json: unknown field "foo"',
          _ordered(),
        ),
        isNull,
      );
    });

    test('вложенный путь чужого объекта (….outbounds[) не считается', () {
      expect(
        parseCoreRejection(
          'decode config: foo.outbounds[1].bar: json: bad',
          _ordered(),
        ),
        isNull,
      );
    });

    test('набор тегов без порядка массивов — форма декодирования молчит', () {
      expect(
        _parse('decode config: outbounds[0].network: json: bad', {
          'direct-out',
        }),
        isNull,
      );
    });
  });

  group('CoreConfigTags.fromConfigJson (§653)', () {
    test('запись без строкового tag не сдвигает индексы', () {
      final c = CoreConfigTags.fromConfigJson(
        '{"outbounds":[{"type":"direct"},{"tag":5},"junk",'
        '{"type":"vless","tag":"N"}]}',
        all: const {'N'},
      );
      expect(c.outbounds.map((e) => e.tag), ['', '', '', 'N']);
      expect(c.outbounds[3].type, 'vless');
      expect(c.endpoints, isEmpty);
    });

    test('битый JSON — пустые массивы', () {
      final c = CoreConfigTags.fromConfigJson('{oops', all: const {'A'});
      expect(c.outbounds, isEmpty);
      expect(c.endpoints, isEmpty);
      expect(c.all, {'A'});
    });
  });
}
