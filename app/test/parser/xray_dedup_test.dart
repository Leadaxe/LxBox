import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';

/// §321 P2+P4 — порядок обработки и дедуп по идентичности.
///
/// Провайдеры описывают один физический сервер многократно: Xray-элемент —
/// автономный конфиг со своим `routing`, и чтобы сервер участвовал в трёх
/// сценариях, его вписывают трижды. У Liberty 64 записи описывают 37 серверов.
void main() {
  Map<String, dynamic> vless(String addr, {String uuid = 'u-1', int port = 443, String? tag, String? sni}) => {
        'tag': tag ?? 'proxy',
        'protocol': 'vless',
        'settings': {
          'vnext': [
            {
              'address': addr,
              'port': port,
              'users': [
                {'id': uuid, 'encryption': 'none'}
              ],
            }
          ],
        },
        'streamSettings': {
          'network': 'tcp',
          'security': sni == null ? 'none' : 'tls',
          if (sni != null) 'tlsSettings': {'serverName': sni},
        },
      };

  Map<String, dynamic> element(String remarks, List<Map<String, dynamic>> obs) => {
        'remarks': remarks,
        'outbounds': [
          ...obs,
          {'tag': 'direct', 'protocol': 'freedom'},
          {'tag': 'block', 'protocol': 'blackhole'},
        ],
      };

  List<String> labelsOf(List<Map<String, dynamic>> elements) =>
      parseAll(decode(jsonEncode(elements))).map((n) => n.label).toList();

  group('P4 — дедуп по (protocol, server, port, credential)', () {
    test('один сервер в двух элементах → один узел', () {
      final labels = labelsOf([
        element('🇩🇪 Германия', [vless('1.1.1.1')]),
        element('🇪🇺 Авто', [vless('1.1.1.1', tag: 'proxy-1-1-1-1')]),
      ]);
      expect(labels, ['🇩🇪 Германия']);
    });

    test('разный uuid при том же addr:port → два узла', () {
      final labels = labelsOf([
        element('A', [vless('1.1.1.1', uuid: 'u-1')]),
        element('B', [vless('1.1.1.1', uuid: 'u-2')]),
      ]);
      expect(labels, hasLength(2));
    });

    test('разный порт → два узла', () {
      final labels = labelsOf([
        element('A', [vless('1.1.1.1', port: 443)]),
        element('B', [vless('1.1.1.1', port: 8443)]),
      ]);
      expect(labels, hasLength(2));
    });

    test('разный SNI при том же ключе → ОДИН узел (trade-off P4)', () {
      // Ключ намеренно не включает TLS/транспорт (решение 30.07.2026).
      // Следствие задокументировано: берётся первый по порядку P2.
      final labels = labelsOf([
        element('первый', [vless('1.1.1.1', sni: 'a.com')]),
        element('второй', [vless('1.1.1.1', sni: 'b.com')]),
      ]);
      expect(labels, ['первый']);
    });
  });

  group('P2 — от одиночных к многоузловым', () {
    test('имя даёт одиночный элемент, а не пул', () {
      // В файле пул идёт ПЕРВЫМ — как у Liberty. Без сортировки сервер
      // получил бы имя «Авто proxy-1-1-1-1».
      final labels = labelsOf([
        element('🇪🇺 Авто', [
          vless('1.1.1.1', tag: 'proxy-1-1-1-1'),
          vless('2.2.2.2', tag: 'proxy-2-2-2-2'),
        ]),
        element('🇩🇪 Германия', [vless('1.1.1.1')]),
        element('🇫🇷 Франция', [vless('2.2.2.2')]),
      ]);
      expect(labels, ['🇩🇪 Германия', '🇫🇷 Франция']);
    });

    test('уникальный член пула выживает под именем пула', () {
      final labels = labelsOf([
        element('🇪🇺 Авто', [
          vless('1.1.1.1', tag: 'proxy-1-1-1-1'),
          vless('9.9.9.9', tag: 'proxy-9-9-9-9'), // только здесь
        ]),
        element('🇩🇪 Германия', [vless('1.1.1.1')]),
      ]);
      expect(labels, ['🇩🇪 Германия', '🇪🇺 Авто proxy-9-9-9-9']);
    });

    test('сортировка стабильная: равные длины сохраняют порядок файла', () {
      final labels = labelsOf([
        element('первый', [vless('1.1.1.1')]),
        element('второй', [vless('2.2.2.2')]),
        element('третий', [vless('3.3.3.3')]),
      ]);
      expect(labels, ['первый', 'второй', 'третий']);
    });
  });

  group('P3 — индекс имени не съезжает при пропуске дубля', () {
    test('выживший второй член не занимает имя первого', () {
      final labels = labelsOf([
        element('🇩🇪 Германия', [vless('1.1.1.1')]),
        element('Пул', [
          vless('1.1.1.1', tag: 'proxy-dup'), // дубль → пропуск
          vless('7.7.7.7', tag: 'proxy-new'), // i=1 → суффикс сохраняется
        ]),
      ]);
      // Если бы индекс считался после дедупа, второй стал бы просто «Пул».
      expect(labels, ['🇩🇪 Германия', 'Пул proxy-new']);
    });
  });

  test('дедуп не пересекает границы подписок', () {
    // Два ОТДЕЛЬНЫХ вызова парсера = две подписки. У них разные
    // tag_prefix/detour_policy, схлопывать нельзя.
    final a = labelsOf([
      element('A', [vless('1.1.1.1')])
    ]);
    final b = labelsOf([
      element('B', [vless('1.1.1.1')])
    ]);
    expect(a, ['A']);
    expect(b, ['B']);
  });
}
