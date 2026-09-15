import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/builder/post_steps.dart';
import 'package:lxbox/services/core_duration.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';

/// §442 — пара `interval`/`idle_timeout` у urltest (эталон — SPEC 128
/// лаунчера). Ядро достраивает пропуски до 3m/30m и падает на
/// `interval > idle_timeout` в конструкторе группы; санитайзер поднимает
/// `idle_timeout` до `interval` и никогда не трогает сам `interval`.
void main() {
  group('parseCoreDurationNanos — правила ядра', () {
    const s = 1000000000;
    test('суффикс d, которого нет у time.ParseDuration', () {
      expect(parseCoreDurationNanos('1d'), 24 * 3600 * s);
      expect(parseCoreDurationNanos('1d12h'), 36 * 3600 * s);
      expect(parseCoreDurationNanos('0.5d'), 12 * 3600 * s);
    });

    test('обычные единицы, дроби, знак, голый ноль', () {
      expect(parseCoreDurationNanos('3m'), 180 * s);
      expect(parseCoreDurationNanos('1h30m'), 5400 * s);
      expect(parseCoreDurationNanos('1.5h'), 5400 * s);
      expect(parseCoreDurationNanos('300ms'), 300000000);
      expect(parseCoreDurationNanos('2µs'), 2000);
      expect(parseCoreDurationNanos('0'), 0);
      expect(parseCoreDurationNanos('+0'), 0);
      expect(parseCoreDurationNanos('-1m'), -60 * s);
    });

    test('то, что ядро отвергает', () {
      for (final bad in [
        '',
        ' 1h', // пробелы ядро не срезает
        '30', // число без единицы
        '1ds', // «d» только как единица
        '1w',
        'fast',
        '.s',
        '-',
        '99999999999999999999h', // переполнение
      ]) {
        expect(parseCoreDurationNanos(bad), isNull, reason: bad);
      }
    });
  });

  group('правило 8 санитайзера', () {
    Map<String, dynamic> config(Map<String, dynamic> group) => {
          'outbounds': [
            {'tag': 'a', 'type': 'vless'},
            {'tag': 'g', 'outbounds': ['a'], ...group},
          ],
        };
    Map<String, dynamic> g(Map<String, dynamic> c) =>
        (c['outbounds'] as List)[1] as Map<String, dynamic>;

    /// Санитайзер не нашёл чего чинить: ни warning'а, ни байта разницы.
    void untouched(Map<String, dynamic> group) {
      final c = config(group);
      final before = jsonEncode(c);
      expect(sanitizeOutboundGraph(c), isEmpty, reason: before);
      expect(jsonEncode(c), before);
    }

    test('interval без idle_timeout сверх умолчания 30m → idle_timeout = interval',
        () {
      final c = config({'type': 'urltest', 'interval': '3h'});
      final warnings = sanitizeOutboundGraph(c);
      expect(g(c)['interval'], '3h');
      expect(g(c)['idle_timeout'], '3h');
      expect(warnings, hasLength(1));
      expect(warnings.single, allOf(contains('"g"'), contains('3h'), contains('30m')));
    });

    test('заданная пара не сходится → idle_timeout поднят, interval прежний', () {
      final c = config(
          {'type': 'urltest', 'interval': '2h', 'idle_timeout': '10m'});
      final warnings = sanitizeOutboundGraph(c);
      expect(g(c)['interval'], '2h');
      expect(g(c)['idle_timeout'], '2h');
      expect(warnings.single, allOf(contains('2h'), contains('10m')));
    });

    test('1d без idle_timeout → idle_timeout 1d', () {
      final c = config({'type': 'urltest', 'interval': '1d'});
      sanitizeOutboundGraph(c);
      expect(g(c)['interval'], '1d');
      expect(g(c)['idle_timeout'], '1d');
    });

    test('без interval, но idle_timeout меньше умолчания 3m → поднят до 3m', () {
      final c = config({'type': 'urltest', 'idle_timeout': '1m'});
      final warnings = sanitizeOutboundGraph(c);
      expect(g(c).containsKey('interval'), isFalse);
      expect(g(c)['idle_timeout'], '3m');
      expect(warnings, hasLength(1));
    });

    test('round_robin идёт тем же правилом', () {
      final c = config({
        'type': 'urltest',
        'interval': '3h',
        'mode': 'round_robin',
        'balancer': {'pool': 3},
      });
      sanitizeOutboundGraph(c);
      expect(g(c)['idle_timeout'], '3h');
    });

    test('короткий interval без idle_timeout → байт-в-байт', () {
      untouched({'type': 'urltest', 'interval': '5m'});
      untouched({'type': 'urltest', 'interval': '30m'});
      untouched({'type': 'urltest'});
    });

    test('сходящаяся пара → байт-в-байт', () {
      untouched({'type': 'urltest', 'interval': '3h', 'idle_timeout': '3h'});
      untouched({'type': 'urltest', 'interval': '1d', 'idle_timeout': '48h'});
      untouched({'type': 'urltest', 'interval': '15m', 'idle_timeout': '30m'});
    });

    test('мусорный interval / idle_timeout → не тронуты', () {
      untouched({'type': 'urltest', 'interval': 'fast'});
      untouched({'type': 'urltest', 'interval': ''});
      untouched({'type': 'urltest', 'interval': 3600});
      untouched({'type': 'urltest', 'interval': '3h', 'idle_timeout': 'never'});
    });

    test('selector не трогается', () {
      untouched({'type': 'selector', 'interval': '3h'});
      untouched({'type': 'selector', 'interval': '3h', 'idle_timeout': '1m'});
    });
  });

  group('через buildConfig', () {
    WizardTemplate template() => WizardTemplate(
          parserConfig: ParserConfigBlock(),
          groupTemplates: GroupTemplates(),
          vars: const [],
          varSections: const [],
          config: {
            'outbounds': [
              {'tag': 'direct-out', 'type': 'direct'},
              {'tag': 'block', 'type': 'block'},
            ],
            'route': {'rules': []},
          },
          selectableRules: const [],
          dnsOptions: const {},
          pingOptions: const {},
          speedTestOptions: const {},
        );

    UserServer list(List<NodeSpec> nodes) => UserServer(
          id: 'sub',
          name: 'Sub',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          origin: UserSource.paste,
          nodes: nodes,
        );

    Future<BuildResult> build(List<NodeSpec> nodes,
            {List<Direction> directions = const [
              Direction(tag: 'vpn-1', label: 'X'),
            ]}) =>
        buildConfig(
          lists: [list(nodes)],
          template: template(),
          settings: BuildSettings(directions: directions),
        );

    Map<String, dynamic> byTag(BuildResult r, String tag) =>
        (r.config['outbounds'] as List)
            .cast<Map<String, dynamic>>()
            .firstWhere((o) => o['tag'] == tag);

    Map<String, dynamic> vlessXray(String addr, String tag) => {
          'tag': tag,
          'protocol': 'vless',
          'settings': {
            'vnext': [
              {
                'address': addr,
                'port': 443,
                'users': [
                  {'id': 'u-$tag', 'encryption': 'none'}
                ],
              }
            ],
          },
          'streamSettings': {'network': 'tcp', 'security': 'none'},
        };

    test('Xray-балансер с pingConfig.interval 3h → idle_timeout 3h, warning',
        () async {
      final nodes = parseAll(decode(jsonEncode([
        {
          'remarks': 'Pool',
          'outbounds': [
            vlessXray('1.1.1.1', 'proxy-1'),
            vlessXray('2.2.2.2', 'proxy-2'),
            {'tag': 'direct', 'protocol': 'freedom'},
          ],
          'routing': {
            'balancers': [
              {
                'tag': 'B',
                'selector': ['proxy'],
                'strategy': {
                  'type': 'leastLoad',
                  'settings': {'expected': 2},
                },
              }
            ],
          },
          'burstObservatory': {
            'pingConfig': {
              'destination': 'http://www.gstatic.com/generate_204',
              'interval': '3h',
            },
            'subjectSelector': ['proxy'],
          },
        }
      ])));
      final auto = nodes.whereType<AutoSelectSpec>().single;
      // Вход действительно расходится: парсер оставляет умолчание 30m.
      expect(auto.params.interval, '3h');
      expect(auto.params.idleTimeout, '30m');

      final r = await build(nodes);
      expect(r.validation.isOk, isTrue, reason: r.validation.issues.join('\n'));
      final g = byTag(r, auto.tag);
      expect(g['mode'], 'round_robin');
      expect(g['interval'], '3h');
      expect(g['idle_timeout'], '3h');
      expect(
          r.emitWarnings.where((w) =>
              w.contains('"${auto.tag}"') && w.contains('idle_timeout')),
          hasLength(1));
    });

    test('группа sing-box подписки: interval 1d без idle_timeout → 1d',
        () async {
      final nodes = parseAll(decode(jsonEncode({
        'outbounds': [
          {
            'type': 'vless',
            'tag': 'a',
            'server': 'a.com',
            'server_port': 443,
            'uuid': 'u-a',
          },
          {
            'type': 'vless',
            'tag': 'b',
            'server': 'b.com',
            'server_port': 443,
            'uuid': 'u-b',
          },
          {
            'type': 'urltest',
            'tag': 'auto',
            'outbounds': ['a', 'b'],
            'interval': '1d',
          },
        ],
      })));
      final auto = nodes.whereType<AutoSelectSpec>().single;

      final r = await build(nodes);
      expect(r.validation.isOk, isTrue, reason: r.validation.issues.join('\n'));
      final g = byTag(r, auto.tag);
      expect(g['interval'], '1d');
      expect(g['idle_timeout'], '1d');
    });

    test('Направление из хранения с interval > idle_timeout → поднято',
        () async {
      final direction = Direction.fromJson({
        'tag': 'vpn-1',
        'label': 'X',
        'auto': {'interval': '2h', 'idle_timeout': '30m'},
      });
      final nodes = parseAll(decode(
          'vless://u1@h1.com:443?type=ws&security=tls#A\n'
          'vless://u2@h2.com:443?type=ws&security=tls#B'));

      final r = await build(nodes, directions: [direction]);
      expect(r.validation.isOk, isTrue, reason: r.validation.issues.join('\n'));
      final g = byTag(r, 'vpn-1-auto');
      expect(g['interval'], '2h');
      expect(g['idle_timeout'], '2h');
      expect(r.emitWarnings.where((w) => w.contains('"vpn-1-auto"')),
          hasLength(1));
    });

    test('Направление с умолчаниями → пара как была, без warning', () async {
      final nodes = parseAll(decode(
          'vless://u1@h1.com:443?type=ws&security=tls#A'));
      final r = await build(nodes, directions: const [
        Direction(tag: 'vpn-1', label: 'X', auto: DirectionAuto()),
      ]);
      final g = byTag(r, 'vpn-1-auto');
      expect(g['interval'], '15m');
      expect(g['idle_timeout'], '30m');
      expect(r.emitWarnings.where((w) => w.contains('idle_timeout')), isEmpty);
    });
  });
}
