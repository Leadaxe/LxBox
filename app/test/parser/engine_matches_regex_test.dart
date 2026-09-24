import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/parser/engine/interpreter.dart';
import 'package:lxbox/services/parser/engine/section.dart';

/// Ревью после v2.25.1 (движок), m2 — `matches` / `not_matches` в условиях
/// компилируются общим `_regex`, как прочие регулярки реестра.
///
/// Реестр пишется у лаунчера в Go-написании: именованная группа там —
/// `(?P<name>…)`, а Dart понимает только `(?<name>…)`. Перевод делает
/// `_regex`; условия его обходили и на такой записи падали
/// `FormatException` на каждом узле, где условие срабатывало.
///
/// Секция синтетическая (`probe`): имени схемы в тестах движка нет.
Map<String, dynamic>? _run(Map<String, dynamic> when, String uri) =>
    runSection(
      MapperSection.fromJson('uri', 'probe', {
        'body_source': 'uri',
        'params': {
          'server': {'source': 'host', 'maps_to': 'server'},
          'server_port':
              {'source': 'port', 'maps_to': 'server_port', 'type': 'int'},
          'a': {'source': 'query.a', 'maps_to': 'a', 'when': when},
        },
      }),
      uri,
    )?.body;

void main() {
  group('m2 — matches / not_matches в Go-написании', () {
    test('matches с (?P<name>…) исполняется', () {
      const when = {
        'query.h': {'matches': r'^(?P<host>[^:]+)$'},
      };
      expect(_run(when, 'x://h.com:443?a=1&h=example.com')!['a'], '1');
      expect(_run(when, 'x://h.com:443?a=1&h=example.com:80')!['a'], isNull);
    });

    test('not_matches с (?P<name>…) исполняется', () {
      const when = {
        'query.h': {'not_matches': r'^(?P<port>\d+)$'},
      };
      expect(_run(when, 'x://h.com:443?a=1&h=example.com')!['a'], '1');
      expect(_run(when, 'x://h.com:443?a=1&h=8080')!['a'], isNull);
    });
  });
}
