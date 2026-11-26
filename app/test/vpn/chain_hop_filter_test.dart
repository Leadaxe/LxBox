import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/vpn/cc_channel.dart';
import 'package:lxbox/vpn/platform_channels.dart';

/// §761 — хопы цепочек (`chain-hop`, теги `<цепочка>#<i>`, ядро
/// v1.14.4-lx.37-rc.2) в списках узлов, групп и соединений не показываются.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  CcOutbound ob(String tag, String type) =>
      CcOutbound(tag: tag, type: type, urlTestDelay: 0, urlTestTime: 0);

  test('тип без учёта регистра; тег с # сам по себе не хоп', () {
    expect(isChainHopType('chain-hop'), isTrue);
    expect(isChainHopType('Chain-Hop'), isTrue);
    expect(isChainHopType('chain'), isFalse);
    final list = [ob('c#0', 'chain-hop'), ob('NL-FREE#114', 'wireguard')];
    expect(withoutChainHops(list).map((o) => o.tag), ['NL-FREE#114']);
    expect(chainHopTagsOf(list), {'c#0'});
    final clean = [ob('a', 'vless')];
    expect(identical(withoutChainHops(clean), clean), isTrue);
  });

  test('группы: члены-хопы сняты, прочее как было', () {
    const g = CcGroup(
      tag: 'sel',
      type: 'selector',
      selectable: true,
      selected: 'a',
      isExpand: false,
      items: [
        CcOutbound(tag: 'a', type: 'vless', urlTestDelay: 5, urlTestTime: 1),
        CcOutbound(tag: 'c#1', type: 'chain-hop', urlTestDelay: 0, urlTestTime: 0),
      ],
    );
    final out = groupsWithoutChainHops([g]).single;
    expect(out.items.map((o) => o.tag), ['a']);
    expect((out.tag, out.selected, out.selectable), ('sel', 'a', true));
  });

  test('соединение: теги хопов сняты из chains и detours', () {
    final m = connectionMapWithoutChainHops({
      'id': '1',
      'chains': ['vpn-1', 'c', 'c#1'],
      'detours': ['c#0', 'NL-FREE#114'],
    }, {'c#0', 'c#1'});
    expect(m['chains'], ['vpn-1', 'c']);
    expect(m['detours'], ['NL-FREE#114']);
    final same = {'id': '2', 'chains': ['a']};
    expect(identical(connectionMapWithoutChainHops(same, const {}), same), isTrue);
  });

  test('getOutbounds и getGroups ядра — без хопов', () async {
    const channel = MethodChannel(PlatformChannels.methods);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'ccGetOutbounds':
          return [
            {'tag': 'a', 'type': 'vless'},
            {'tag': 'c#0', 'type': 'chain-hop'},
          ];
        case 'ccGetGroups':
          return [
            {
              'tag': 'sel',
              'type': 'selector',
              'items': [
                {'tag': 'a', 'type': 'vless'},
                {'tag': 'c#0', 'type': 'chain-hop'},
              ],
            },
          ];
      }
      return null;
    });
    final obs = await CcChannel.instance.getOutbounds();
    expect(obs!.map((o) => o.tag), ['a']);
    final groups = await CcChannel.instance.getGroups();
    expect(groups!.single.items.map((o) => o.tag), ['a']);
  });
}
