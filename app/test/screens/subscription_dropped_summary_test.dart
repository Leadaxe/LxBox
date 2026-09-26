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

  test('dropped едет в copyWith и не входит в равенство записи', () {
    final entry = entryFor([const RegistryWarning(code: 'form_unrecognized')]);
    final list = entry.list as SubscriptionServers;
    final renamed = list.copyWith(name: 'other');
    expect(renamed.dropped, list.dropped);
    expect(list.copyWith(dropped: const []), list,
        reason: 'производное разбора, в значение подписки не входит');
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
}
