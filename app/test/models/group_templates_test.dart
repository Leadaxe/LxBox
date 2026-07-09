import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/config/consts.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/template_loader.dart' show assertMagicNodeMirrors;

/// §267 — парсинг `group_templates` + `magic_nodes` + `default_channels`,
/// хелпер `resolveTpl`, инвариант зеркал `assertMagicNodeMirrors`.
void main() {
  group('GroupTemplates.fromJson', () {
    final gtJson = <String, dynamic>{
      'magic_nodes': {
        'auto': {
          'title': 'Auto',
          'source': 'generate',
          'tpl': '{parent_tag}-auto',
        },
        'direct': {'title': 'Direct', 'source': 'preset', 'tag': 'direct-out'},
        'block': {'title': 'Block', 'source': 'preset', 'tag': 'block'},
      },
      'channel': {
        'type': 'selector',
        'include': ['direct', 'auto'],
        'options': {'interrupt_exist_connections': true},
      },
      'auto': {
        'type': 'urltest',
        'options': {'url': '@urltest_url', 'interval': '@urltest_interval'},
      },
    };
    final dcJson = <dynamic>[
      {'tag': 'vpn-1', 'label': 'VPN ①', 'default_enabled': true},
      {'tag': 'vpn-2', 'label': 'VPN ②', 'default_enabled': false},
    ];

    test('magic_nodes: role-ключи, title/source', () {
      final gt = GroupTemplates.fromJson(gtJson, dcJson);
      expect(gt.magicNodes.keys.toSet(), {'auto', 'direct', 'block'});
      expect(gt.magicNodes['direct']!.title, 'Direct');
      expect(gt.magicNodes['direct']!.source, 'preset');
      expect(gt.magicNodes['auto']!.source, 'generate');
    });

    test('generate-нода: tpl задан, tag == null', () {
      final gt = GroupTemplates.fromJson(gtJson, dcJson);
      final auto = gt.magicNodes['auto']!;
      expect(auto.tpl, '{parent_tag}-auto');
      expect(auto.tag, isNull);
    });

    test('preset-нода: tag задан, tpl == null', () {
      final gt = GroupTemplates.fromJson(gtJson, dcJson);
      expect(gt.magicNodes['direct']!.tag, 'direct-out');
      expect(gt.magicNodes['direct']!.tpl, isNull);
      expect(gt.magicNodes['block']!.tag, 'block');
      expect(gt.magicNodes['block']!.tpl, isNull);
    });

    test('channel: type/include/options', () {
      final gt = GroupTemplates.fromJson(gtJson, dcJson);
      expect(gt.channel.type, 'selector');
      expect(gt.channel.include, ['direct', 'auto']);
      expect(gt.channel.options['interrupt_exist_connections'], true);
    });

    test('auto-шаблон: сырые @-плейсхолдеры сохраняются (не резолвены)', () {
      final gt = GroupTemplates.fromJson(gtJson, dcJson);
      expect(gt.auto.options['url'], '@urltest_url');
    });

    test('default_channels: tag/label/default_enabled', () {
      final gt = GroupTemplates.fromJson(gtJson, dcJson);
      expect(gt.defaultChannels.map((d) => d.tag), ['vpn-1', 'vpn-2']);
      expect(gt.defaultChannels[0].defaultEnabled, true);
      expect(gt.defaultChannels[1].defaultEnabled, false);
    });

    test('пустой JSON → безопасные дефолты', () {
      final gt = GroupTemplates.fromJson(const {}, const []);
      expect(gt.magicNodes, isEmpty);
      expect(gt.channel.include, isEmpty);
      expect(gt.defaultChannels, isEmpty);
    });
  });

  group('resolveTpl', () {
    test('{parent_tag} → tag канала', () {
      expect(resolveTpl('{parent_tag}-auto', 'vpn-1'), 'vpn-1-auto');
      expect(resolveTpl('{parent_tag}-auto', 'vpn-10'), 'vpn-10-auto');
    });

    test('без плейсхолдера — as-is', () {
      expect(resolveTpl('fixed', 'vpn-1'), 'fixed');
    });
  });

  group('assertMagicNodeMirrors (инвариант §267)', () {
    GroupTemplates gtWith({String? direct, String? block}) => GroupTemplates(
          magicNodes: {
            'direct': MagicNode(
                role: 'direct', title: 'Direct', source: 'preset', tag: direct),
            'block': MagicNode(
                role: 'block', title: 'Block', source: 'preset', tag: block),
          },
        );

    test('совпадение с consts → не бросает', () {
      expect(
        () => assertMagicNodeMirrors(
            gtWith(direct: kDirectOutboundTag, block: kBlockOutboundTag)),
        returnsNormally,
      );
    });

    test('подмена direct tag → StateError', () {
      expect(
        () => assertMagicNodeMirrors(
            gtWith(direct: 'renamed', block: kBlockOutboundTag)),
        throwsStateError,
      );
    });

    test('подмена block tag → StateError', () {
      expect(
        () => assertMagicNodeMirrors(
            gtWith(direct: kDirectOutboundTag, block: 'renamed')),
        throwsStateError,
      );
    });
  });
}
