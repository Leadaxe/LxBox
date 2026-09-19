import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/parser/engine/interpreter.dart';
import 'package:lxbox/services/parser/engine/section_loader.dart';
import 'package:lxbox/services/parser/engine/trace.dart';

import 'engine_test_setup.dart';

/// §480 — ТРАССА: формат согласован с лаунчером ради МЕХАНИЧЕСКОЙ СВЕРКИ
/// Go↔Dart обычным диффом (`MAPPER_ENGINE.md`, приложение «ТРАССА»).
///
/// Проверяется не «трасса есть», а именно то, на чём сверка ломается:
/// порядок ключей, отсутствие пробелов, отсутствие HTML-экранирования,
/// числа без экспоненты, не-ASCII как есть. Любая из этих мелочей даёт
/// ложное расхождение на каждой строке.
void main() {
  setUpAll(loadEngineSections);

  group('каноническая сериализация', () {
    test('без пробелов, ключи в порядке вставки', () {
      expect(MapperTrace.encode({'b': 1, 'a': 2}), '{"b":1,"a":2}');
    });

    test('свободный объект — лексикографически', () {
      expect(MapperTrace.encode({'b': 1, 'a': 2}, sortFree: true),
          '{"a":2,"b":1}');
    });

    // У Go это SetEscapeHTML(false); без него каждая строка с `&` расходится.
    test('БЕЗ HTML-экранирования', () {
      expect(MapperTrace.encode('a<b>&c'), '"a<b>&c"');
    });

    test('не-ASCII как есть, управляющие через \\u', () {
      expect(MapperTrace.encode('мир🇬🇧'), '"мир🇬🇧"');
      expect(MapperTrace.encode('ab'), '"a\\\\u0001b"'.replaceAll(r'\\', r'\'));
      expect(MapperTrace.encode('a\nb'), '"a\\\\nb"'.replaceAll(r'\\', r'\'));
    });

    test('числа без экспоненты', () {
      expect(MapperTrace.encode(2560), '2560');
      expect(MapperTrace.encode(1e21.toInt()), isNot(contains('e')));
      expect(MapperTrace.encode(30.0), '30');
    });

    test('вложенность и списки', () {
      expect(MapperTrace.encode({'a': [1, '2', null], 'b': {'c': true}}),
          '{"a":[1,"2",null],"b":{"c":true}}');
    });
  });

  group('события', () {
    test('ключи в фиксированном порядке, нумерация с 1', () {
      final t = MapperTrace()
        ..add(
          stage: TraceStage.field,
          mapper: 'probe.uri.url',
          entry: 'sni',
          src: 'query.sni',
          raw: 'x.com',
          val: 'x.com',
          path: 'tls.server_name',
        );
      expect(t.lines.single,
          '{"n":1,"stage":"field","mapper":"probe.uri.url","entry":"sni",'
          '"src":"query.sni","raw":"x.com","val":"x.com",'
          '"path":"tls.server_name","act":"write","why":"-"}');
    });

    test('опущенные поля — null и «-», а не пропуск ключа', () {
      final t = MapperTrace()
        ..add(stage: TraceStage.lex, mapper: 'probe.uri');
      expect(t.lines.single, contains('"raw":null'));
      expect(t.lines.single, contains('"path":null'));
      expect(t.lines.single, contains('"src":"-"'));
      expect(t.lines.single, contains('"why":"-"'));
    });

    test('номера идут подряд', () {
      final t = MapperTrace()
        ..add(stage: TraceStage.field, mapper: 'm')
        ..add(stage: TraceStage.field, mapper: 'm')
        ..add(stage: TraceStage.result, mapper: 'm');
      expect(t.lines.map((l) => l.substring(0, 7)).toList(),
          ['{"n":1,', '{"n":2,', '{"n":3,']);
    });
  });

  group('движок пишет трассу', () {
    test('живая ссылка: есть field, label и result последней строкой', () {
      final section = MapperSections.I.sectionFor('uri', 'trojan')!;
      final trace = MapperTrace();
      final res = runSection(
        section,
        'trojan://pw@example.com:443?security=tls&sni=s.example.com#name',
        trace: trace,
      );
      expect(res, isNotNull);

      final lines = trace.lines;
      expect(lines, isNotEmpty);
      expect(lines.last, contains('"stage":"result"'),
          reason: 'result обязан быть ПОСЛЕДНИМ — так сверка видит итог');
      expect(lines.last, contains('"body_source":"uri"'));
      expect(lines.any((l) => l.contains('"stage":"label"')), isTrue);
      expect(
          lines.any((l) =>
              l.contains('"path":"tls.server_name"') &&
              l.contains('"act":"write"')),
          isTrue,
          reason: 'запись поля обязана быть видна с путём и действием');
    });

    test('без коллектора движок не строит ни строки', () {
      final section = MapperSections.I.sectionFor('uri', 'trojan')!;
      // Коллектор опционален и выключен по умолчанию: проверяем, что путь
      // без него отрабатывает и даёт тот же результат.
      final withTrace = MapperTrace();
      final a = runSection(section, 'trojan://pw@h.com:443#n');
      final b = runSection(section, 'trojan://pw@h.com:443#n',
          trace: withTrace);
      expect(MapperTrace.encode(a!.body), MapperTrace.encode(b!.body),
          reason: 'сбор трассы не смеет менять разбор');
      expect(withTrace.lines, isNotEmpty);
    });

    test('порядок событий = порядок исполнения', () {
      final section = MapperSections.I.sectionFor('uri', 'trojan')!;
      final trace = MapperTrace();
      runSection(
        section,
        'trojan://pw@example.com:443?type=ws&security=tls&path=%2Fp'
        '&sni=s.example.com&zzz=1#n',
        trace: trace,
      );
      final stages = [
        for (final l in trace.lines)
          RegExp(r'"stage":"([a-z_]+)"').firstMatch(l)!.group(1)!,
      ];
      // `result` — в самом конце, `label` — прямо перед ним, а записи полей
      // идут раньше обоих. `unknown` в этом прогоне может и не появиться:
      // секция реестра сегодня не объявляет кода (наш оверлей его снял).
      expect(stages.last, 'result');
      expect(stages[stages.length - 2], 'label');
      expect(stages.indexOf('field'), lessThan(stages.indexOf('label')));
    });
  });
}
