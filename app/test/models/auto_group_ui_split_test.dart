import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/auto_select.dart';
import 'package:lxbox/models/home_state.dart';
import 'package:lxbox/screens/home/node_list_presenter.dart';
import 'package:lxbox/vpn/cc_channel.dart';

/// §322 — ядру и auto-двойник Направления, и узел автовыбора приходят одинаковым
/// `urltest`. Спец-обращение (подмена имени на «✨ Auto», пин в верхнюю
/// секцию) положено ТОЛЬКО двойнику; различитель — его тег (`vpn-N-auto`,
/// генерит билдер Направления), а не тип.
void main() {
  CcGroup ccGroup(String tag, String type, {String selected = ''}) => CcGroup(
        tag: tag,
        type: type,
        selectable: type == 'selector',
        selected: selected,
        isExpand: false,
        items: const [],
      );

  /// Узлы + их типы: всё, что похоже на группу, объявляем `urltest`.
  HomeState stateWith({
    required List<String> nodes,
    required Set<String> autoTags,
    Set<String> directionAutoTags = const {},
    bool pinAuto = true,
  }) =>
      HomeState(
        nodes: nodes,
        directionAutoTags: directionAutoTags,
        pinAuto: pinAuto,
        // Пин смотрит ТИП из конфига (§311 activeModel), не из ccGroups.
        configRaw: jsonEncode({
          'outbounds': [
            for (final n in nodes)
              {'tag': n, 'type': autoTags.contains(n) ? 'urltest' : 'vless'},
          ],
        }),
        ccGroups: [
          for (final n in nodes)
            ccGroup(n, autoTags.contains(n) ? 'urltest' : 'vless'),
        ],
      );

  group('пин в верхнюю секцию', () {
    test('auto-двойник Направления пинится', () {
      final s = stateWith(
        nodes: ['DE-1', 'vpn-1-auto'],
        autoTags: {'vpn-1-auto'},
        directionAutoTags: {'vpn-1-auto'},
      );
      expect(s.pinnedNodeCount, 1);
      expect(s.sortedNodes.first, 'vpn-1-auto');
    });

    test('узел автовыбора §322 НЕ пинится', () {
      // Тип тот же `urltest`, но тега нет среди Направлений.
      final s = stateWith(
        nodes: ['DE-1', 'L: 🇪🇺 Авто'],
        autoTags: {'L: 🇪🇺 Авто'},
        directionAutoTags: {'vpn-1-auto'},
      );
      expect(s.pinnedNodeCount, 0);
      // Остаётся на своём месте, а не уезжает наверх.
      expect(s.sortedNodes, ['DE-1', 'L: 🇪🇺 Авто']);
    });

    test('оба вместе: пинится только двойник', () {
      final s = stateWith(
        nodes: ['DE-1', 'L: 🇪🇺 Авто', 'vpn-1-auto'],
        autoTags: {'L: 🇪🇺 Авто', 'vpn-1-auto'},
        directionAutoTags: {'vpn-1-auto'},
      );
      expect(s.pinnedNodeCount, 1);
      expect(s.sortedNodes.first, 'vpn-1-auto');
    });

    test('pinAuto=false — не пинится даже двойник', () {
      final s = stateWith(
        nodes: ['vpn-1-auto', 'DE-1'],
        autoTags: {'vpn-1-auto'},
        directionAutoTags: {'vpn-1-auto'},
        pinAuto: false,
      );
      expect(s.pinnedNodeCount, 0);
    });
  });

  group('подзаголовок «→ выбранный»', () {
    test('urltestNowOf работает и для группы §322', () {
      final s = HomeState(
        nodes: const ['L: 🇪🇺 Авто'],
        ccGroups: [
          ccGroup('L: 🇪🇺 Авто', 'urltest', selected: 'L: 🇩🇪 Германия'),
        ],
      );
      expect(s.urltestNowOf('L: 🇪🇺 Авто'), 'L: 🇩🇪 Германия');
    });

    test('у обычного узла выбранного нет', () {
      final s = HomeState(
        nodes: const ['DE-1'],
        ccGroups: [ccGroup('DE-1', 'vless')],
      );
      expect(s.urltestNowOf('DE-1'), isNull);
    });
  });

  group('метка режима в подзаголовке', () {
    Map<String, dynamic> ut(int members, {int? pool}) => {
          'tag': 'g',
          'type': 'urltest',
          'outbounds': [for (var i = 0; i < members; i++) 'n$i'],
          if (pool != null) 'balancer': {'pool': pool},
        };

    test('least_test → 🎯 [состав]', () {
      expect(autoGroupLabel(ut(3)), '🎯 [3]');
    });

    test('round_robin → 🔀 [всего/пул]', () {
      expect(autoGroupLabel(ut(15, pool: 7)), '🔀 [15/7]');
    });

    test('пул больше состава показываем как есть', () {
      // Ядро схлопнет до доступных; врать «7 из 3» не наше дело.
      expect(autoGroupLabel(ut(3, pool: 7)), '🔀 [3/7]');
    });

    test('balancer без pool → пул = состав', () {
      final raw = ut(5)..['balancer'] = <String, dynamic>{};
      expect(autoGroupLabel(raw), '🔀 [5/5]');
    });

    test('не urltest → null (обычный узел показывает протокол)', () {
      expect(autoGroupLabel({'tag': 'n', 'type': 'vless'}), isNull);
      expect(autoGroupLabel(null), isNull);
    });

    test('пустой пул не роняет метку', () {
      expect(autoGroupLabel({'tag': 'g', 'type': 'urltest'}), '🎯 [0]');
    });
  });

  group('значки пула (§322 poolBadge)', () {
    const flag = kDefaultPoolBadge;

    test('флаги из имён членов, повторы с числом', () {
      expect(
        poolBadges(const [
          'L: 🇩🇪⚡Германия',
          'L: 🇫🇮⚡Финляндия',
          'L: 🇫🇮⚡Финляндия 2',
          'L: 🇳🇱⚡Нидерланды',
        ], flag),
        '🇩🇪, 🇫🇮[2], 🇳🇱',
      );
    });

    test('узлы без флага просто не дают значка', () {
      expect(poolBadges(const ['proxy-1', 'L: 🇩🇪 DE'], flag), '🇩🇪');
    });

    test('ни одного совпадения → пусто', () {
      expect(poolBadges(const ['proxy-1', 'proxy-2'], flag), isEmpty);
    });

    test('пустой regexp = значки выключены', () {
      expect(poolBadges(const ['L: 🇩🇪 DE'], ''), isEmpty);
    });

    test('битый regexp не роняет строку', () {
      expect(poolBadges(const ['L: 🇩🇪 DE'], '[unclosed'), isEmpty);
    });

    test('произвольный regexp пользователя', () {
      // Не только флаги: например, код страны в скобках.
      expect(
        poolBadges(const ['Node (DE)', 'Node (NL)', 'Node (DE)'],
            r'\(([A-Z]{2})\)'),
        '(DE)[2], (NL)',
      );
    });

    test('порядок — как в пуле, не алфавитный', () {
      expect(poolBadges(const ['🇳🇱 A', '🇩🇪 B'], flag), '🇳🇱, 🇩🇪');
    });

    test('пустой пул → пусто', () {
      expect(poolBadges(const [], flag), isEmpty);
    });
  });

  test('balancer в конфиге — гейт «View pool» для группы §322', () {
    // round_robin эмитит `balancer{}`; least_test — нет (ядро SPEC 019).
    final pc = ParsedConfig.parse(jsonEncode({
      'outbounds': [
        {
          'tag': 'L: 🇪🇺 Авто',
          'type': 'urltest',
          'mode': 'round_robin',
          'balancer': {'pool': 7},
        },
        {'tag': 'L: БС', 'type': 'urltest'},
      ],
    }));
    expect(pc.rawOf('L: 🇪🇺 Авто')?['balancer'], isNotNull);
    expect(pc.rawOf('L: БС')?['balancer'], isNull);
  });
}
