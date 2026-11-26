// §761 — плашка главного экрана «цепочка не собирается»: текст из той же
// проверки, что у редактора, кнопка ведёт в редактор цепочки, крестик
// скрывает.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/home_state.dart';
import 'package:lxbox/models/node_link.dart';
import 'package:lxbox/models/source_chain.dart';
import 'package:lxbox/screens/home/widgets/app_banner.dart';
import 'package:lxbox/services/chains/chain_trouble_state.dart';

void main() {
  final bodies = {
    for (final b in [
      {'tag': 'A', 'type': 'vless'},
      {'tag': 'X', 'type': 'vless'},
      {
        'tag': 'vpn-1',
        'type': 'selector',
        'outbounds': ['A', 'X'],
      },
    ])
      b['tag'] as String: (section: 'outbounds', body: b),
  };

  List<ChainTrouble> troubles(List<SourceChain> chains) =>
      findChainTroubles(chains: chains, bodies: bodies);

  SourceChain chain(String tag) => SourceChain(
      tag: tag, hops: const [NodeLink(tag: 'A'), NodeLink(tag: 'vpn-1')]);

  Future<({List<String> opened, List<int> dismissed})> pump(
      WidgetTester tester, List<ChainTrouble> t) async {
    final opened = <String>[];
    final dismissed = <int>[];
    final actions = BannerActions(
      onRebuild: () {},
      onConfirmStop: () {},
      onClearError: () {},
      onShareCrash: () {},
      onDismissCrash: () {},
      onShowCoreRejected: () {},
      onDismissCoreRejected: () {},
      onOpenChain: opened.add,
      onDismissChainTroubles: () => dismissed.add(1),
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BannerStack(
          banners: activeBanners(HomeState(),
              configDirty: false,
              busy: false,
              chainTroubles: t,
              actions: actions),
        ),
      ),
    ));
    return (opened: opened, dismissed: dismissed);
  }

  testWidgets('одна цепочка: заголовок, причина, кнопка и крестик',
      (tester) async {
    final r = await pump(tester, troubles([chain('old')]));
    expect(find.text('Hop chain "old" is not built'), findsOneWidget);
    expect(
        find.text('"A" is the entry and also inside "vpn-1" at position 2 — '
            'make a copy of "vpn-1" without "A" for this position.'),
        findsOneWidget);
    await tester.tap(find.text('Open chain'));
    expect(r.opened, ['old']);
    await tester.tap(find.byIcon(Icons.close));
    expect(r.dismissed, [1]);
  });

  testWidgets('несколько цепочек — одна плашка со счётчиком, кнопка у первой',
      (tester) async {
    final r = await pump(tester, troubles([chain('old'), chain('older')]));
    expect(find.text('Hop chain "old" is not built'), findsOneWidget);
    expect(find.textContaining('More chains are not built: 1.'), findsOneWidget);
    expect(find.text('Open chain'), findsOneWidget);
    await tester.tap(find.text('Open chain'));
    expect(r.opened, ['old']);
  });

  testWidgets('нет выпадающих цепочек — плашки нет', (tester) async {
    await pump(tester, const []);
    expect(find.byIcon(Icons.link_off), findsNothing);
  });
}
