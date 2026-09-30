import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';

import '../contract_paths.dart';

/// §595 — целое, записанное дробью (`0.0`), в эмите становится целым;
/// детектор `field_conflict` xmux видит в нём ноль.

/// Строка 8 корпуса `73-github-full` (`shprcdn.homes:7443`), `extra`
/// подставляется параметром.
String _link(String extra) =>
    'vless://65cd649c-f2f5-49c4-8f57-94d9b706e846@shprcdn.homes:7443'
    '?encryption=none&security=reality&sni=shprcdn.homes&fp=random'
    '&pbk=ypzgxQ7VhTlTqjT0pAzWBIyotcG7SYqMpErwMBDci0g&type=xhttp'
    '&path=/content/dash/segments/&mode=stream-one'
    '&extra=${Uri.encodeQueryComponent(extra)}#t';

const _corpusExtra =
    '{"xmux":{"cMaxReuseTimes":"256-512","hKeepAlivePeriod":0.0,'
    '"hMaxReusableSecs":"900-1500","maxConcurrency":"16-32",'
    '"maxConnections":0.0},"xPaddingBytes":"50-150"}';

List<String> _codes(NodeSpec n) =>
    [for (final w in n.warnings) if (w is RegistryWarning) w.code];

void main() {
  setUpAll(loadTestRegistry);

  group('integralDoublesToInt', () {
    test('целое дробью → int, дробь не трогается', () {
      expect(integralDoublesToInt(0.0), isA<int>().having((v) => v, 'v', 0));
      expect(integralDoublesToInt(2.0), isA<int>().having((v) => v, 'v', 2));
      expect(integralDoublesToInt(-3.0), isA<int>().having((v) => v, 'v', -3));
      expect(integralDoublesToInt(0.5), 0.5);
      expect(integralDoublesToInt('0.0'), '0.0');
      expect(integralDoublesToInt(7), 7);
      expect(integralDoublesToInt(double.infinity), double.infinity);
    });

    test('рекурсивно по вложенным map/list', () {
      final got = integralDoublesToInt({
        'a': 1.0,
        'b': {'c': 0.0, 'd': 0.5, 'e': 'x'},
        'l': [2.0, 1.5, {'f': -3.0}, [4.0]],
      }) as Map;
      expect(got['a'], isA<int>());
      final b = got['b'] as Map;
      expect(b['c'], isA<int>());
      expect(b['d'], 0.5);
      expect(b['e'], 'x');
      final l = got['l'] as List;
      expect(l[0], isA<int>());
      expect(l[1], 1.5);
      expect((l[2] as Map)['f'], isA<int>());
      expect((l[3] as List)[0], isA<int>());
    });

    test('без дробей возвращается тот же объект, исходник не мутируется', () {
      final clean = {'a': 1, 'b': {'c': 'x'}, 'l': [1, 2]};
      expect(identical(integralDoublesToInt(clean), clean), isTrue);
      final dirty = {'a': 1, 'b': {'c': 0.0}};
      final got = integralDoublesToInt(dirty) as Map;
      expect((got['b'] as Map)['c'], isA<int>());
      expect((dirty['b']! as Map)['c'], isA<double>());
    });
  });

  group('xhttp xmux из extra (корпус 73-github-full, строка 8)', () {
    test('maxConnections 0.0 → 0, max_concurrency сохранён, конфликта нет', () {
      final node = parseAll(decode(_link(_corpusExtra))).single;
      final t = node.emit(TemplateVars.empty).map['transport'] as Map;
      final xmux = t['xmux'] as Map;
      expect(xmux['max_concurrency'], '16-32');
      // Поле `XmuxRange` реестр объявляет строкой: `0.0` из `extra` едет
      // строкой `"0"` (ядро: `Atoi("0")`), а не `"0.0"`.
      expect(xmux['max_connections'], '0');
      expect(_codes(node), isNot(contains('field_conflict')));
    });

    test('maxConnections 2.0 → 2', () {
      final node = parseAll(decode(_link(
              '{"xmux":{"maxConnections":2.0,"cMaxReuseTimes":"256-512"}}')))
          .single;
      final xmux = (node.emit(TemplateVars.empty).map['transport']
          as Map)['xmux'] as Map;
      expect(xmux['max_connections'], '2');
    });
  });

  test('sing-box JSON: целое дробью в int-поле эмитится целым', () {
    final node = parseAll(decode('{"type":"vless","tag":"j",'
            '"server":"1.2.3.4","server_port":443.0,'
            '"uuid":"65cd649c-f2f5-49c4-8f57-94d9b706e846",'
            '"transport":{"type":"xhttp","path":"/p",'
            '"xmux":{"max_connections":0.0,"max_concurrency":"16-32",'
            '"h_keep_alive_period":30.0}}}'))
        .single;
    final m = node.emit(TemplateVars.empty).map;
    expect(m['server_port'], isA<int>());
    final xmux = (m['transport'] as Map)['xmux'] as Map;
    expect(xmux['max_concurrency'], '16-32');
    for (final v in xmux.values) {
      expect(v is double, isFalse, reason: 'дробь в эмите: $xmux');
    }
    expect(_codes(node), isNot(contains('field_conflict')));
  });
}
