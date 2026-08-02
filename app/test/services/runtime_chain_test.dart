import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/channel.dart';
import 'package:lxbox/models/config_node.dart';
import 'package:lxbox/services/runtime_chain.dart';

/// §258 — рантайм-цепочка detour по собранному конфигу: порядок пакета,
/// продолжение через выбор селектора, каналы (tag/autoTag), гейты
/// (цикл/потолок/битый тег).

ParsedConfig _cfg(List<Map<String, dynamic>> outbounds) =>
    ParsedConfig.parse(jsonEncode({'outbounds': outbounds}));

Map<String, dynamic> _ob(String tag, String type,
        {String? detour, List<String>? members}) =>
    {
      'tag': tag,
      'type': type,
      'detour': ?detour,
      'outbounds': ?members,
    };

List<String> _tags(List<RuntimeHop> hops) => [for (final h in hops) h.tag];

void main() {
  group('channelForTag', () {
    const channels = [
      Channel(tag: 'vpn-4', label: 'Relay', isDetour: true),
      Channel(tag: 'vpn-2', label: 'Main'),
    ];

    test('тег канала → канал', () {
      expect(channelForTag('vpn-4', channels)?.label, 'Relay');
    });

    test('autoTag двойника → тот же канал', () {
      expect(channelForTag('vpn-2-auto', channels)?.label, 'Main');
    });

    test('не канал → null', () {
      expect(channelForTag('node-a', channels), isNull);
      expect(channelForTag('vpn-9', channels), isNull);
    });
  });

  group('runtimeChainOf — порядок пакета', () {
    test('без detour → только сам тег', () {
      final cfg = _cfg([_ob('a', 'vless')]);
      final hops = runtimeChainOf('a', cfg, channels: const []);
      expect(_tags(hops), ['a']);
      expect(hops.single.type, 'vless');
      expect(hops.single.isChannel, isFalse);
    });

    test('a→b→c: порядок пакета [c, b, a] (глубокий транспорт первым)', () {
      final cfg = _cfg([
        _ob('a', 'vless', detour: 'b'),
        _ob('b', 'trojan', detour: 'c'),
        _ob('c', 'wireguard'),
      ]);
      final hops = runtimeChainOf('a', cfg, channels: const []);
      expect(_tags(hops), ['c', 'b', 'a']);
      expect(hops.every((h) => !h.viaSelection), isTrue);
    });

    test('тег вне конфига → хоп isUnknown и обрыв', () {
      final cfg = _cfg([_ob('a', 'vless', detour: 'ghost')]);
      final hops = runtimeChainOf('a', cfg, channels: const []);
      expect(_tags(hops), ['ghost', 'a']);
      expect(hops.first.isUnknown, isTrue);
      expect(hops.first.type, '');
    });
  });

  group('runtimeChainOf — селекторы и каналы', () {
    const channels = [Channel(tag: 'vpn-4', label: 'Relay', isDetour: true)];

    test('detour в канал без выбора (туннель down) → обрыв на группе', () {
      final cfg = _cfg([
        _ob('a', 'vless', detour: 'vpn-4'),
        _ob('vpn-4', 'selector', members: ['x', 'y']),
      ]);
      final hops = runtimeChainOf('a', cfg,
          channels: channels, selectedOf: (_) => null);
      expect(_tags(hops), ['vpn-4', 'a']);
      expect(hops.first.isChannel, isTrue);
      expect(hops.first.isGroup, isTrue); // маркер обрыва для UI-эллипсиса
    });

    test('§344 — пустой выбор (round_robin) → обрыв, без призрачного хопа', () {
      // У балансировщика одного выбранного нет: ядро отдаёт selected==''.
      // Пустая строка НЕ тег — иначе в цепочку попадал бы хоп с пустым
      // заголовком и подписью «not in config · current pick».
      final cfg = _cfg([
        _ob('a', 'vless', detour: 'vpn-4'),
        _ob('vpn-4', 'urltest', members: ['x', 'y']),
      ]);
      final hops = runtimeChainOf('a', cfg,
          channels: channels, selectedOf: (_) => '');
      expect(_tags(hops), ['vpn-4', 'a']);
      expect(hops.any((h) => h.tag.isEmpty), isFalse);
      expect(hops.first.isGroup, isTrue);
    });

    test('выбор селектора продолжает цепочку (viaSelection)', () {
      final cfg = _cfg([
        _ob('a', 'vless', detour: 'vpn-4'),
        _ob('vpn-4', 'selector', members: ['x', 'y']),
        _ob('x', 'trojan'),
      ]);
      final hops = runtimeChainOf('a', cfg,
          channels: channels, selectedOf: (t) => t == 'vpn-4' ? 'x' : null);
      expect(_tags(hops), ['x', 'vpn-4', 'a']);
      expect(hops.first.viaSelection, isTrue); // pick глубже канала
      expect(hops[1].isChannel, isTrue);
      expect(hops.last.viaSelection, isFalse);
    });

    test('AUTO-двойник: канал → urltest → узел, оба хопа канальные', () {
      final cfg = _cfg([
        _ob('a', 'vless', detour: 'vpn-4'),
        _ob('vpn-4', 'selector', members: ['vpn-4-auto', 'x']),
        _ob('vpn-4-auto', 'urltest', members: ['x']),
        _ob('x', 'trojan'),
      ]);
      final selected = {'vpn-4': 'vpn-4-auto', 'vpn-4-auto': 'x'};
      final hops = runtimeChainOf('a', cfg,
          channels: channels, selectedOf: (t) => selected[t]);
      expect(_tags(hops), ['x', 'vpn-4-auto', 'vpn-4', 'a']);
      expect(hops[1].isChannel, isTrue); // autoTag тоже резолвится в канал
      expect(hops[1].channel?.tag, 'vpn-4');
    });

    test('выбранный узел продолжается своим detour (сага §254)', () {
      // IN → vpn-4 (выбрал BL), BL → vpn-5 (выбрал OUT):
      // пакет = OUT → vpn-5 → BL → vpn-4 → IN.
      final cfg = _cfg([
        _ob('IN', 'wireguard', detour: 'vpn-4'),
        _ob('vpn-4', 'selector', members: ['BL']),
        _ob('BL', 'vless', detour: 'vpn-5'),
        _ob('vpn-5', 'selector', members: ['OUT']),
        _ob('OUT', 'wireguard'),
      ]);
      final selected = {'vpn-4': 'BL', 'vpn-5': 'OUT'};
      final hops = runtimeChainOf('IN', cfg,
          channels: const [], selectedOf: (t) => selected[t]);
      expect(_tags(hops), ['OUT', 'vpn-5', 'BL', 'vpn-4', 'IN']);
    });

    test('сам тег — канал (View на строке группы): цепочка от селектора', () {
      final cfg = _cfg([
        _ob('vpn-4', 'selector', members: ['x']),
        _ob('x', 'trojan'),
      ]);
      final hops = runtimeChainOf('vpn-4', cfg,
          channels: channels, selectedOf: (t) => t == 'vpn-4' ? 'x' : null);
      expect(_tags(hops), ['x', 'vpn-4']);
    });
  });

  group('runtimeChainOf — гейты', () {
    test('цикл detour (страховка) → seen-set останавливает', () {
      final cfg = _cfg([
        _ob('a', 'vless', detour: 'b'),
        _ob('b', 'trojan', detour: 'a'),
      ]);
      final hops = runtimeChainOf('a', cfg, channels: const []);
      expect(_tags(hops), ['b', 'a']);
    });

    test('цикл через выбор селектора → останавливается', () {
      final cfg = _cfg([
        _ob('a', 'vless', detour: 's'),
        _ob('s', 'selector', members: ['a']),
      ]);
      final hops = runtimeChainOf('a', cfg,
          channels: const [], selectedOf: (t) => t == 's' ? 'a' : null);
      expect(_tags(hops), ['s', 'a']);
    });

    test('потолок kMaxRuntimeHops', () {
      // Цепочка длиной 20 > потолка 12.
      final obs = <Map<String, dynamic>>[
        for (var i = 0; i < 20; i++)
          _ob('n$i', 'vless', detour: i < 19 ? 'n${i + 1}' : null),
      ];
      final hops = runtimeChainOf('n0', _cfg(obs), channels: const []);
      expect(hops.length, kMaxRuntimeHops);
      // Порядок пакета: последний элемент — сам n0.
      expect(hops.last.tag, 'n0');
    });

    test('тег не найден вовсе → единственный unknown-хоп', () {
      final hops =
          runtimeChainOf('nope', _cfg([_ob('a', 'vless')]), channels: const []);
      expect(_tags(hops), ['nope']);
      expect(hops.single.isUnknown, isTrue);
    });
  });
}
