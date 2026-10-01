/// §589 (контракт 1.1.102, §99) — схлопнутые повторы видны на выжившем узле
/// кодом `duplicates_collapsed`: форма `count`/`names`, оба пути схлопывания
/// (дедуп записей тела и владение сервером в Xray-массиве §342), сохранение
/// кода при штампах вердикта ядра, итог для сводки подписки.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller/core_reject_ops.dart'
    show stampNodeWarnings, unstampCoreRejected;
import 'package:lxbox/models/core_reject_verdict.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';

import '../contract_paths.dart';
import 'engine_test_setup.dart';

const _pbk = 'Lx2TnXgn4YbYp6h6rVr3m2DkQnq1Yl7yY0pYf0bR3X0';

String _vless(int n, String name) =>
    'vless://0000000$n-0000-4000-8000-000000000000@${n == 1 ? 'a' : 'b'}'
    '.example.com:443?type=tcp&security=reality&pbk=$_pbk&fp=chrome'
    '&sni=www.example.org&sid=ab12&flow=xtls-rprx-vision'
    '#${Uri.encodeComponent(name)}';

Map<String, dynamic> _xrayVless(String tag, int n) => {
      'tag': tag,
      'protocol': 'vless',
      'settings': {
        'vnext': [
          {
            'address': '${n == 1 ? 'a' : 'b'}.example.com',
            'port': 443,
            'users': [
              {
                'id': '0000000$n-0000-4000-8000-000000000000',
                'encryption': 'none',
                'flow': 'xtls-rprx-vision',
              },
            ],
          },
        ],
      },
      'streamSettings': {
        'network': 'tcp',
        'security': 'reality',
        'realitySettings': {
          'serverName': 'www.example.org',
          'publicKey': _pbk,
          'shortId': 'ab12',
          'fingerprint': 'chrome',
        },
      },
    };

Map<String, dynamic> _solo(String remarks, int n) => {
      'remarks': remarks,
      'outbounds': [
        _xrayVless('proxy', n),
        {'tag': 'direct', 'protocol': 'freedom'},
      ],
    };

/// Зеркало `body/xray/duplicates_collapsed_owner`: сервер a — у пула «Авто»,
/// у «Австрии» и у «Германии»; сервер b — у пула и у «Польши».
String _xrayOwnerBody() => jsonEncode([
      {
        'remarks': 'Авто',
        'outbounds': [
          _xrayVless('bridge', 1),
          _xrayVless('bridge-2', 2),
          {'tag': 'direct', 'protocol': 'freedom'},
        ],
        'routing': {
          'balancers': [
            {
              'tag': 'Balancer',
              'selector': ['bridge'],
              'strategy': {'type': 'leastLoad'},
            },
          ],
        },
      },
      _solo('🇦🇹 Австрия', 1),
      _solo('🇵🇱 Польша', 2),
      _solo('🇩🇪 Германия', 1),
    ]);

RegistryWarning? _collapsedOf(NodeSpec n) {
  for (final w in n.warnings) {
    if (w is RegistryWarning && w.code == kDuplicatesCollapsedCode) return w;
  }
  return null;
}

Map<String, Map<String, String>> _collapsedByTag(List<NodeSpec> nodes) => {
      for (final n in nodes)
        if (_collapsedOf(n) case final w?) n.tag: w.params,
    };

void main() {
  setUpAll(loadEngineSections);

  group('форма count/names', () {
    test('порядок тела, без повторов, без имени выжившего', () {
      final w = duplicatesCollapsedWarning(
          'A', ['B', 'A', 'C', 'B', ' ', 'D']);
      expect(w.code, 'duplicates_collapsed');
      expect(w.params, {'count': '6', 'names': 'B, C, D'});
    });

    test('все повторы под тем же именем — имя выжившего', () {
      final w = duplicatesCollapsedWarning('A', ['A', ' A ', '']);
      expect(w.params, {'count': '3', 'names': 'A'});
    });

    test('больше десяти имён — обрезка с «, …»', () {
      final names = [for (var i = 1; i <= 12; i++) 'n$i'];
      final w = duplicatesCollapsedWarning('own', names);
      expect(w.params['count'], '12');
      expect(w.params['names'],
          '${[for (var i = 1; i <= 10; i++) 'n$i'].join(', ')}, …');
    });

    test('ровно десять — без многоточия', () {
      final names = [for (var i = 1; i <= 10; i++) 'n$i'];
      final w = duplicatesCollapsedWarning('own', names);
      expect(w.params['names'], names.join(', '));
    });
  });

  group('дедуп записей тела', () {
    test('код на выжившем, в dropped[] пусто', () {
      final dropped = <NodeWarning>[];
      final nodes = parseAll(
          decode([
            _vless(1, '🇦🇹 Австрия'),
            _vless(2, '🇵🇱 Польша'),
            _vless(1, '🇩🇪 Германия'),
            _vless(2, '🇵🇱 Польша'),
            _vless(1, '🇷🇺 Россия'),
          ].join('\n')),
          dropped: dropped);

      expect(nodes.map((n) => n.tag), ['🇦🇹 Австрия', '🇵🇱 Польша']);
      expect(dropped, isEmpty);
      expect(_collapsedByTag(nodes), {
        '🇦🇹 Австрия': {'count': '2', 'names': '🇩🇪 Германия, 🇷🇺 Россия'},
        '🇵🇱 Польша': {'count': '1', 'names': '🇵🇱 Польша'},
      });
      expect(duplicatesMergedOf(nodes), (merged: 3, into: 2));
    });

    test('без повторов — кода нет, итог нулевой', () {
      final nodes = parseAll(
          decode('${_vless(1, 'a')}\n${_vless(2, 'b')}'));
      expect(_collapsedByTag(nodes), isEmpty);
      expect(duplicatesMergedOf(nodes), (merged: 0, into: 0));
    });
  });

  test('Xray-массив: владение сервером, член пула имён не даёт', () {
    final dropped = <NodeWarning>[];
    final nodes = parseAll(decode(_xrayOwnerBody()), dropped: dropped);

    expect(dropped, isEmpty);
    expect(_collapsedByTag(nodes), {
      '🇦🇹 Австрия': {'count': '1', 'names': '🇩🇪 Германия'},
    });
  });

  group('сохранение кода', () {
    List<NodeSpec> parsed() => parseAll(decode(
        '${_vless(1, 'first')}\n${_vless(1, 'second')}'));

    test('повторный разбор тела воспроизводит код', () {
      final a = parsed().single;
      final b = parsed().single;
      expect(_collapsedOf(b), _collapsedOf(a));
      expect(_collapsedOf(b), isNotNull);
    });

    test('штамп и снятие вердикта ядра код не трогают', () {
      final node = parsed().single;
      final before = _collapsedOf(node);
      stampNodeWarnings(node, [StoredWarning.coreRejected('boom')]);
      expect(_collapsedOf(node), before);
      expect(
          node.warnings.whereType<RegistryWarning>().map((w) => w.code),
          containsAll([kCoreRejectedCode, kDuplicatesCollapsedCode]));
      unstampCoreRejected(node);
      expect(_collapsedOf(node), before);
    });

    test('повторная постановка заменяет прежний код, а не копит', () {
      final node = parsed().single;
      markDuplicatesCollapsed(node, ['x', 'y']);
      final all = node.warnings
          .whereType<RegistryWarning>()
          .where((w) => w.code == kDuplicatesCollapsedCode)
          .toList();
      expect(all, hasLength(1));
      expect(all.single.params, {'count': '2', 'names': 'x, y'});
    });
  });

  // Эталон контракта: на каких узлах стоит код. Корпус лежит в
  // `app/contract/` (gitignored) — на CI его нет, кейс пропускается.
  group('корпус контракта', () {
    for (final name in const [
      'uri_list/duplicates_collapsed',
      'xray/duplicates_collapsed_owner',
    ]) {
      test(name, () {
        final body = File('$kVendorRoot/corpus/body/$name.body');
        final want = File('$kVendorRoot/corpus/body/$name.expected.json');
        if (!body.existsSync() || !want.existsSync()) {
          markTestSkipped('нет корпуса контракта');
          return;
        }
        final text = body
            .readAsLinesSync()
            .skipWhile((l) => l.trimLeft().startsWith('#'))
            .join('\n');
        final nodes = parseAll(decode(text));
        final expected = jsonDecode(want.readAsStringSync()) as Map;
        final wantLabels = <String>{
          for (final n in (expected['nodes'] as List).cast<Map>())
            if (((n['warnings'] as List?) ?? const [])
                .any((w) => (w is Map ? w['code'] : w) ==
                    kDuplicatesCollapsedCode))
              '${n['label']}',
        };
        final gotLabels = <String>{
          for (final n in nodes)
            if (_collapsedOf(n) != null) n.label,
        };
        expect(gotLabels, wantLabels);
      });
    }
  });
}
