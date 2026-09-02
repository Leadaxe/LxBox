import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/config_node.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/source_chain.dart';
import 'package:lxbox/screens/chain_edit/chain_hop_candidate.dart';
import 'package:lxbox/screens/chain_edit/chain_hop_targets.dart';

// §393 C7 — что можно поставить позицией цепочки. Позиция это ссылка на тег
// СОБРАННОГО конфига: предлагать имена, которых в конфиге не будет, значило бы
// вести пользователя к ссылке в никуда, на которой ядро не стартует.

ParsedConfig _config(List<Map<String, dynamic>> outbounds) =>
    ParsedConfig.parse(jsonEncode({'outbounds': outbounds}));

void main() {
  group('collectChainHopTargets', () {
    test('сама цепочка в кандидаты не попадает: ядро самоссылку отвергает', () {
      final cands = collectChainHopTargets(
        config: _config([
          {'tag': 'de-exit', 'type': 'vless'},
        ]),
        directions: const [],
        chains: const [SourceChain(tag: 'via-de')],
        selfTag: 'via-de',
      );
      expect(cands.map((c) => c.tag), isNot(contains('via-de')));
    });

    test('цепочка НИЖЕ редактируемой помечена below, ВЫШЕ — нет', () {
      final cands = collectChainHopTargets(
        config: _config(const []),
        directions: const [],
        chains: const [
          SourceChain(tag: 'first'),
          SourceChain(tag: 'self'),
          SourceChain(tag: 'later'),
        ],
        selfTag: 'self',
      );
      final byTag = chainHopLookup(cands);
      expect(byTag['first']!.below, isFalse);
      expect(byTag['later']!.below, isTrue);
    });

    test('выключенная цепочка позицией не предлагается', () {
      final cands = collectChainHopTargets(
        config: _config(const []),
        directions: const [],
        chains: const [
          SourceChain(tag: 'off', enabled: false),
          SourceChain(tag: 'self'),
        ],
        selfTag: 'self',
      );
      expect(cands.map((c) => c.tag), isNot(contains('off')));
    });

    test('выключенное Направление не предлагается: его тега в конфиге не будет',
        () {
      final cands = collectChainHopTargets(
        config: _config(const []),
        directions: [
          const Direction(tag: 'vpn-1', label: 'vpn-1'),
          const Direction(tag: 'vpn-2', label: 'vpn-2', enabled: false),
        ],
        chains: const [],
        selfTag: 'chain-1',
      );
      final tags = cands.map((c) => c.tag);
      expect(tags, contains('vpn-1'));
      expect(tags, isNot(contains('vpn-2')));
    });

    test('служебный direct-out предлагается, block/dns — нет', () {
      final cands = collectChainHopTargets(
        config: _config([
          {'tag': 'block-out', 'type': 'block'},
          {'tag': 'dns-out', 'type': 'dns'},
        ]),
        directions: const [],
        chains: const [],
        selfTag: 'chain-1',
      );
      final tags = cands.map((c) => c.tag).toSet();
      expect(tags, contains(kChainBuiltinDirect));
      expect(tags, isNot(contains('block-out')));
      expect(tags, isNot(contains('dns-out')));
    });

    test('группа отличается видом от узла', () {
      final cands = collectChainHopTargets(
        config: _config([
          {'tag': 'sub-group', 'type': 'selector', 'outbounds': <String>[]},
          {'tag': 'node-a', 'type': 'vless'},
        ]),
        directions: const [],
        chains: const [],
        selfTag: 'chain-1',
      );
      final byTag = chainHopLookup(cands);
      expect(byTag['sub-group']!.kind, ChainHopKind.group);
      expect(byTag['node-a']!.kind, ChainHopKind.node);
    });

    test('reality и detour приезжают из собранного outbound\'а', () {
      final cands = collectChainHopTargets(
        config: _config([
          {
            'tag': 'reality-node',
            'type': 'vless',
            'tls': {
              'enabled': true,
              'reality': {'enabled': true},
            },
          },
          {'tag': 'relay', 'type': 'vless'},
          {'tag': 'detoured', 'type': 'vless', 'detour': 'relay'},
        ]),
        directions: const [],
        chains: const [],
        selfTag: 'chain-1',
      );
      final byTag = chainHopLookup(cands);
      expect(byTag['reality-node']!.reality, isTrue);
      expect(byTag['relay']!.reality, isFalse);
      expect(byTag['detoured']!.detour, isTrue);
      expect(byTag['relay']!.detour, isFalse);
    });

    test('уже эмитированная цепочка из конфига дублем не приезжает', () {
      // Цепочки берутся из списка источников — там известен ещё и порядок
      // объявления, решающий, на кого можно сослаться.
      final cands = collectChainHopTargets(
        config: _config([
          {'tag': 'other-chain', 'type': 'chain', 'outbounds': ['a', 'b']},
        ]),
        directions: const [],
        chains: const [SourceChain(tag: 'other-chain')],
        selfTag: 'self',
      );
      final matches = cands.where((c) => c.tag == 'other-chain').toList();
      expect(matches, hasLength(1));
      expect(matches.single.kind, ChainHopKind.chain);
    });

    test('узлы идут по алфавиту, Направления — в порядке объявления', () {
      final cands = collectChainHopTargets(
        config: _config([
          {'tag': 'zz', 'type': 'vless'},
          {'tag': 'aa', 'type': 'vless'},
        ]),
        directions: [
          const Direction(tag: 'vpn-2', label: 'vpn-2'),
          const Direction(tag: 'vpn-1', label: 'vpn-1'),
        ],
        chains: const [],
        selfTag: 'chain-1',
      );
      final tags = cands.map((c) => c.tag).toList();
      expect(tags.indexOf('vpn-2'), lessThan(tags.indexOf('vpn-1')));
      expect(tags.indexOf('aa'), lessThan(tags.indexOf('zz')));
      // Направления — раньше узлов: пользователь думает о маршруте в них.
      expect(tags.indexOf('vpn-1'), lessThan(tags.indexOf('aa')));
    });
  });

  group('describeChainHop', () {
    test('пропавший тег при готовом снимке — unknown, а не выброшен молча', () {
      final c = describeChainHop('gone', const {}, targetsKnown: true);
      expect(c.kind, ChainHopKind.unknown);
      expect(c.tag, 'gone');
    });

    test('пока снимок не готов — pending, а не «потеряна»', () {
      final c = describeChainHop('maybe', const {}, targetsKnown: false);
      expect(c.kind, ChainHopKind.pending);
    });
  });

  group('chainTargetsKnown', () {
    test('пустой конфиг = снимок не готов', () {
      expect(chainTargetsKnown(const ParsedConfig.empty()), isFalse);
    });

    test('собранный конфиг = снимок готов', () {
      expect(
          chainTargetsKnown(_config([
            {'tag': 'a', 'type': 'vless'}
          ])),
          isTrue);
    });
  });
}
