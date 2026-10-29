import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/screens/subscriptions_screen/entry_context_menu.dart';
import 'package:lxbox/services/subscription/auto_updater.dart';

// §686 — меню долгого тапа в списке Servers: у одиночного сервера нет
// «Update» и «Edit source…» (это действия над источником подписки, сервер
// правят в карточке); у подписки оба пункта на месте.

Future<void> _openMenu(WidgetTester tester, SubscriptionEntry entry) async {
  final sub = SubscriptionController();
  sub.debugSetEntries([entry]);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showEntryContextMenu(context, 0, entry,
              subController: sub, autoUpdater: AutoUpdater(sub)),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('одиночный сервер — без Update и Edit source…', (tester) async {
    await _openMenu(
      tester,
      SubscriptionEntry(
        list: UserServer(
          id: 'srv-1',
          name: '',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          rawBody: '{"type":"direct","tag":"d"}',
          nodes: const [],
        ),
      ),
    );
    expect(find.text('Delete'), findsOneWidget);
    expect(find.text('Move to folder…'), findsOneWidget);
    expect(find.text('Update'), findsNothing);
    expect(find.text('Edit source…'), findsNothing);
  });

  testWidgets('подписка — Update и Edit source… на месте', (tester) async {
    await _openMenu(
      tester,
      SubscriptionEntry(
        list: SubscriptionServers(
          id: 'sub-1',
          name: 'sub',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          url: 'https://example.com/sub',
          nodes: const [],
        ),
      ),
    );
    expect(find.text('Update'), findsOneWidget);
    expect(find.text('Edit source…'), findsOneWidget);
  });
}
