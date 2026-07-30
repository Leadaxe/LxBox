import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/parser/transport.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §320 — двойное percent-кодирование пути. Агрегаторы отдают
/// `path=%2F%252Fassignment`: `Uri.queryParameters` декодит ровно один раз, и в
/// конфиг уезжало `/%2Fassignment` вместо `//assignment` → 404.
///
/// Тот же корень, что у §151 (ALPN `http%252F1.1`), но валидность здесь НЕ
/// проверяется: путь может содержать что угодно — эмодзи, `//`, `@`.
void main() {
  String pathOf(NodeSpec n) =>
      (n.emitRaw(const TemplateVars()).map['transport'] as Map)['path']
          as String;

  group('decodeResidualPercent', () {
    test('остаточное %2F снимается', () {
      expect(decodeResidualPercent('/%2Fassignment'), '//assignment');
    });

    test('уже декодированное не меняется', () {
      expect(decodeResidualPercent('//assignment'), '//assignment');
      expect(decodeResidualPercent('/assignment'), '/assignment');
    });

    test('эмодзи и юникод целы', () {
      expect(decodeResidualPercent('Telegram🇨🇳'), 'Telegram🇨🇳');
      expect(decodeResidualPercent('/путь'), '/путь');
    });

    test('битое кодирование не роняет и не портит', () {
      expect(decodeResidualPercent('/x%zz'), '/x%zz');
    });

    test('глубина ограничена 2 проходами', () {
      // %25252F = тройное кодирование `/`; после 2 проходов остаётся %2F.
      expect(decodeResidualPercent('/%25252F'), '/%2F');
    });
  });

  group('ws-путь в конфиге', () {
    test('двойное кодирование → корректный путь', () {
      final n = parseUri(
        'trojan://humanity@104.18.115.61:443?type=ws'
        '&path=%2F%252Fassignment&security=tls&host=www.gossipglove.com'
        '&sni=www.gossipglove.com#node',
      )!;
      expect(pathOf(n), '//assignment');
    });

    test('одиночный двойной слэш не схлопывается (валидная форма)', () {
      final n = parseUri(
        'trojan://pw@example.com:443?type=ws&path=%2F%2Fassignment'
        '&security=tls&sni=example.com#node',
      )!;
      expect(pathOf(n), '//assignment');
    });

    test('путь без ведущего слэша сохраняется дословно (слэш добавит ядро)',
        () {
      final n = parseUri(
        'trojan://521314@104.16.97.215:443?host=tjplay.lxdxo.kdns.fr'
        '&path=Telegram%F0%9F%87%A8%F0%9F%87%B3&sni=tjplay.lxdxo.kdns.fr'
        '&type=ws#node',
      )!;
      expect(pathOf(n), 'Telegram🇨🇳');
    });

    test('дважды закодированный ed-хвост: путь чист, early data распознана',
        () {
      final n = parseUri(
        'trojan://pw@example.com:443?type=ws&path=%2Fx%253Fed%253D2560'
        '&security=tls&sni=example.com#node',
      )!;
      final tr = n.emitRaw(const TemplateVars()).map['transport'] as Map;
      expect(tr['path'], '/x');
      expect(tr['max_early_data'], 2560);
    });

    test('httpupgrade — то же снятие кодирования', () {
      final n = parseUri(
        'trojan://pw@example.com:443?type=httpupgrade'
        '&path=%2F%252Fassignment&security=tls&sni=example.com#node',
      )!;
      expect(pathOf(n), '//assignment');
    });
  });
}
