import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/screens/subscription_detail_screen.dart';
import 'package:lxbox/services/l10n/locale_controller.dart';

NodeSpec _node(String label) => VlessSpec(
      id: label,
      tag: label,
      label: label,
      server: 'example.com',
      port: 443,
      rawSource: '',
      uuid: '00000000-0000-0000-0000-000000000000',
    );

SubscriptionEntry _subEntry({List<NodeSpec>? nodes}) {
  final list = SubscriptionServers(
    id: 'sub-1',
    name: 'Sub',
    enabled: true,
    tagPrefix: '',
    detourPolicy: DetourPolicy.defaults,
    url: 'https://example.com/sub',
    nodes: nodes ?? [_node('A'), _node('B')],
  );
  return SubscriptionEntry(list: list);
}

Future<void> pumpScreen(WidgetTester tester, SubscriptionEntry entry) async {
  final c = SubscriptionController();
  c.debugSetEntries([entry]);
  await tester.pumpWidget(MaterialApp(
    home: SubscriptionDetailScreen(entry: entry, controller: c),
  ));
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() {
    LocaleController.I.setting = 'system';
  });

  group('§496 — probe bar bulk switch', () {
    testWidgets('в простое нет подписи Test servers', (tester) async {
      await pumpScreen(tester, _subEntry());

      expect(find.text('Test servers'), findsNothing);
      LocaleController.I.setting = 'ru';
      await tester.pump();
      expect(find.text('Тест серверов'), findsNothing);
    });

    testWidgets('bulk Switch того же размера, что Switch строки узла',
        (tester) async {
      await pumpScreen(tester, _subEntry());

      final switches = find.byType(Switch);
      expect(switches, findsNWidgets(3)); // bulk + 2 строки
      final bulkSize = tester.getSize(switches.first);
      final rowSize = tester.getSize(switches.at(1));
      expect(bulkSize, rowSize);
    });

    testWidgets('UserServer — bulk Switch нет', (tester) async {
      final entry = SubscriptionEntry(
        list: UserServer(
          id: 'u-1',
          name: 'Manual',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          rawBody: '',
          origin: UserSource.manual,
          nodes: [_node('M1')],
        ),
      );
      await pumpScreen(tester, entry);

      expect(find.byType(Switch), findsNothing);
      expect(find.text('Test servers'), findsNothing);
    });
  });
}
