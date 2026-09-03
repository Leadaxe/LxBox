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

  // §404 / D-086 — дедуп по ПОДПИСИ ЗАПИСИ: каноническая эмиссия узла без
  // tag/detour плюс подпись пути дозвона, рекурсивно по хопам. Прежний
  // грубый ключ `protocol|server|port|credential` считался по СЫРОМУ JSON и
  // не видел ни транспорта, ни TLS, ни релея — два намеренно разных узла
  // схлопывались в один молча.
  group('P4/D-086 — дедуп по подписи записи', () {
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

    test('D-086: разный SNI → ДВА узла (прежний ключ их схлопывал)', () {
      // Инверсия trade-off'а P4. Провайдер прислал две записи намеренно:
      // один сервер под двумя SNI — это два пути, и второй проваливался в
      // `continue` молча.
      final labels = labelsOf([
        element('первый', [vless('1.1.1.1', sni: 'a.com')]),
        element('второй', [vless('1.1.1.1', sni: 'b.com')]),
      ]);
      expect(labels, ['первый', 'второй']);
    });

    test('D-086: байтовый дубль по-прежнему ОДИН узел', () {
      // Подпись обязана схлопывать настоящие дубли — иначе 64 записи
      // Liberty приехали бы 64 узлами вместо 37.
      final labels = labelsOf([
        element('первый', [vless('1.1.1.1', sni: 'a.com')]),
        element('второй', [vless('1.1.1.1', sni: 'a.com', tag: 'other-tag')]),
      ]);
      expect(labels, ['первый'],
          reason: 'тег в подпись не входит: та же запись под другим именем');
    });

    test('D-086: разный ТРАНСПОРТ → два узла', () {
      final tcp = vless('1.1.1.1', sni: 'a.com');
      final ws = vless('1.1.1.1', sni: 'a.com');
      (ws['streamSettings'] as Map)['network'] = 'ws';
      (ws['streamSettings'] as Map)['wsSettings'] = {'path': '/w'};
      expect(labelsOf([element('tcp', [tcp]), element('ws', [ws])]),
          ['tcp', 'ws']);
    });

    test('D-086: прямая запись и BYPASS того же сервера → два узла', () {
      // BYPASS — это другой МАРШРУТ, а не резерв: там, где прямой путь
      // зарезан, схлопывание оставляло пользователя без рабочего варианта.
      final direct = vless('1.1.1.1', sni: 'a.com');
      final viaRelay = vless('1.1.1.1', sni: 'a.com');
      ((viaRelay['streamSettings'] as Map)['sockopt'] =
          <String, dynamic>{'dialerProxy': 'relay'});
      final relay = {
        'tag': 'relay',
        'protocol': 'socks',
        'settings': {
          'servers': [
            {'address': '192.0.2.10', 'port': 61000},
          ],
        },
      };
      final labels = labelsOf([
        element('прямой', [direct]),
        element('через релей', [viaRelay, relay]),
      ]);
      expect(labels, ['прямой', 'через релей'],
          reason: 'путь дозвона входит в подпись — записи не одинаковы');
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
      // Имена — по приоритету P2 (1.1.1.1 назван «Германией», не пулом),
      // а ПОРЯДОК — авторский (§342): пул в файле первый, значит и в списке
      // первым идёт его уникальный член.
      expect(labels, ['🇪🇺 Авто proxy-9-9-9-9', '🇩🇪 Германия']);
    });

    test('сортировка стабильная: равные длины сохраняют порядок файла', () {
      final labels = labelsOf([
        element('первый', [vless('1.1.1.1')]),
        element('второй', [vless('2.2.2.2')]),
        element('третий', [vless('3.3.3.3')]),
      ]);
      expect(labels, ['первый', 'второй', 'третий']);
    });

    test('сортировка стабильна и за порогом quicksort (>32 элементов)', () {
      // List.sort в Dart стабилен лишь до ~32 элементов (insertion sort),
      // дальше dual-pivot quicksort перемешивает связки — а спека §321 требует
      // стабильность (боевая подписка §342 — 37 элементов). Пары ниже
      // описывают один сервер дважды: имя обязано достаться ПЕРВОМУ по файлу.
      final els = <Map<String, dynamic>>[];
      for (var i = 0; i < 18; i++) {
        els.add(element('first-$i', [vless('10.0.0.$i')]));
        els.add(element('second-$i', [vless('10.0.0.$i', tag: 'proxy-alt')]));
      }
      final labels = labelsOf(els);
      expect(labels, [for (var i = 0; i < 18; i++) 'first-$i']);
    });
  });

  group('§342 — порядок файла сохраняется', () {
    test('пул первым в файле остаётся первым в списке, имена от одиночных',
        () {
      // Ровно раскладка Liberty: пул сверху, одиночные ниже. До §342
      // сортировка P2 была единственным проходом и выкидывала пул в конец —
      // автор ставит рекомендуемый узел первым, и это терялось.
      final labels = labelsOf([
        element('🇪🇺 Авто', [
          vless('1.1.1.1', tag: 'proxy-1-1-1-1'),
          vless('2.2.2.2', tag: 'proxy-2-2-2-2'),
        ]),
        element('🇩🇪 Германия', [vless('1.1.1.1')]),
        element('🇫🇷 Франция', [vless('2.2.2.2')]),
      ]);
      // Оба сервера принадлежат одиночным элементам (имена оттуда), пул
      // уникальных членов не имеет и узлов не даёт — но порядок остальных
      // остаётся файловым.
      expect(labels, ['🇩🇪 Германия', '🇫🇷 Франция']);
    });

    test('одиночный после пула не всплывает наверх', () {
      final labels = labelsOf([
        element('🇳🇱 Нидерланды', [vless('5.5.5.5')]),
        element('🇪🇺 Авто', [
          vless('5.5.5.5', tag: 'proxy-5-5-5-5'),
          vless('9.9.9.9', tag: 'proxy-9-9-9-9'),
        ]),
        element('🇩🇪 Германия', [vless('3.3.3.3')]),
      ]);
      // Порядок ровно как в файле: Нидерланды → уникальный член пула →
      // Германия. Приоритет имён при этом соблюдён (5.5.5.5 = «Нидерланды»).
      expect(labels, ['🇳🇱 Нидерланды', '🇪🇺 Авто proxy-9-9-9-9', '🇩🇪 Германия']);
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
