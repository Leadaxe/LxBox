import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/screens/subscription_detail_screen/widgets/node_warnings_sheet.dart';
import 'package:lxbox/screens/subscription_detail_screen/widgets/subscription_meta.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';

import '../parser/engine_test_setup.dart';

/// §561 — отбраковка разбора живёт в `dropped[]` подписки и показывается в
/// сводке источника (строка + шторка), а не на соседнем узле.
/// §589 итер. 2 — строка «duplicates merged» открывает ту же шторку.
void main() {
  setUpAll(loadEngineSections);
  tearDownAll(unloadEngineSections);

  // Элемент Xray: рабочий узел и запись с протоколом вне реестра.
  const body = '[{"remarks": "unsup", "outbounds": ['
      '{"tag": "proxy", "protocol": "vless", "settings": {"vnext": [{'
      '"address": "a.example", "port": 443, "users": [{'
      '"id": "11111111-2222-3333-4444-555555555555"}]}]}, '
      '"streamSettings": {"network": "tcp", "security": "none"}}, '
      '{"tag": "x", "protocol": "trojan-go", "settings": {}}]}]';

  SubscriptionEntry entryFor(List<NodeWarning> dropped) {
    final nodes = parseAll(decode(body));
    return SubscriptionEntry(
      list: SubscriptionServers(
        id: 's1',
        name: 'sub',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        url: 'https://example.com/sub',
        nodes: nodes,
        dropped: summaryDropped(dropped),
      ),
      nodeCount: nodes.length,
    );
  }

  Future<void> pumpMeta(WidgetTester tester, SubscriptionEntry entry) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SubscriptionMeta(entry: entry, onOpenUrl: (_) async {}),
        ),
      ));

  test('разбор: сосед чист, причина в dropped', () {
    final dropped = <NodeWarning>[];
    final nodes = parseAll(decode(body), dropped: dropped);
    expect(nodes, hasLength(1));
    expect(nodes.single.warnings, isEmpty);
    expect(dropped, hasLength(1));
  });

  testWidgets('сводка: строка отбраковки открывает шторку причин',
      (tester) async {
    final dropped = <NodeWarning>[];
    parseAll(decode(body), dropped: dropped);
    await pumpMeta(tester, entryFor(dropped));

    final row = find.byIcon(Icons.error_outline);
    expect(row, findsOneWidget);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.byType(NodeWarningsSheet), findsOneWidget);
    final sheet = tester.widget<NodeWarningsSheet>(find.byType(NodeWarningsSheet));
    expect(sheet.warnings, hasLength(1));
  });

  testWidgets('сводка без отбраковки — строки нет', (tester) async {
    await pumpMeta(tester, entryFor(const []));
    expect(find.byIcon(Icons.error_outline), findsNothing);
  });

  group('§589 итер. 2 — строка дублей', () {
    const pbk = 'Lx2TnXgn4YbYp6h6rVr3m2DkQnq1Yl7yY0pYf0bR3X0';
    String vless(int n, String name) =>
        'vless://0000000$n-0000-4000-8000-000000000000@${n == 1 ? 'a' : 'b'}'
        '.example.com:443?type=tcp&security=reality&pbk=$pbk&fp=chrome'
        '&sni=www.example.org&sid=ab12&flow=xtls-rprx-vision'
        '#${Uri.encodeComponent(name)}';

    SubscriptionEntry dupEntry(String text) {
      final nodes = parseAll(decode(text));
      return SubscriptionEntry(
        list: SubscriptionServers(
          id: 's2',
          name: 'sub',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          url: 'https://example.com/sub',
          nodes: nodes,
        ),
        nodeCount: nodes.length,
      );
    }

    testWidgets('тап открывает шторку: карточка на выжившего', (tester) async {
      final entry = dupEntry([
        vless(1, 'AT'),
        vless(2, 'PL'),
        vless(1, 'DE'),
        vless(2, 'PL2'),
        vless(1, 'RU'),
      ].join('\n'));
      await pumpMeta(tester, entry);

      final row = find.byIcon(Icons.merge_type);
      expect(row, findsOneWidget);
      await tester.tap(row);
      await tester.pumpAndSettle();
      final sheet =
          tester.widget<NodeWarningsSheet>(find.byType(NodeWarningsSheet));
      final cards = sheet.warnings.cast<RegistryWarning>();
      expect(cards.map((w) => w.ownerTag), ['AT', 'PL']);
      expect(cards.map((w) => w.params['names']), ['DE, RU', 'PL2']);
      expect(cards.every((w) => w.code == kDuplicatesCollapsedCode), isTrue);
    });

    // §589 итер. 3 — шторка не сворачивает карточки разных выживших в одну
    // группу (§572): у каждой своё число и свои имена, «…» нет.
    testWidgets('шторка: карточка на каждый выживший, без «…»',
        (tester) async {
      final entry = dupEntry([
        vless(1, 'AT'),
        vless(2, 'PL'),
        vless(1, 'DE'),
        vless(2, 'PL2'),
        vless(1, 'RU'),
      ].join('\n'));
      await pumpMeta(tester, entry);
      await tester.tap(find.byIcon(Icons.merge_type));
      await tester.pumpAndSettle();

      final sheet = find.byType(NodeWarningsSheet);
      expect(find.byKey(const ValueKey('notification-owner-AT')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('notification-owner-PL')),
          findsOneWidget);
      expect(
          find.descendant(
              of: sheet, matching: find.textContaining('subscription: 2')),
          findsOneWidget);
      expect(
          find.descendant(
              of: sheet, matching: find.textContaining('subscription: 1')),
          findsOneWidget);

      for (final owner in ['AT', 'PL']) {
        final tile = find.byKey(ValueKey('notification-owner-$owner'));
        await tester.ensureVisible(tile);
        await tester.pumpAndSettle();
        await tester.tap(tile);
        await tester.pumpAndSettle();
      }
      expect(find.descendant(of: sheet, matching: find.textContaining('DE, RU')),
          findsWidgets);
      expect(find.descendant(of: sheet, matching: find.textContaining('PL2')),
          findsWidgets);
      expect(find.descendant(of: sheet, matching: find.textContaining('…')),
          findsNothing);
    });

    testWidgets('без повторов — строки нет', (tester) async {
      await pumpMeta(tester, dupEntry('${vless(1, 'a')}\n${vless(2, 'b')}'));
      expect(find.byIcon(Icons.merge_type), findsNothing);
    });
  });
}
