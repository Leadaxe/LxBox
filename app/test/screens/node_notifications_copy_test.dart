import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/screens/subscription_detail_screen/widgets/node_notifications_view.dart';
import 'package:lxbox/services/contract/registry.dart';

/// §614 — кнопка копирования в карточке уведомления: в буфер уходит код,
/// заголовок, разбор и параметры записи. Реестр — зеркало `assets/contract`.
const _registryRoot = 'assets/contract';

const _warnTransport = RegistryWarning(
  code: 'transport_unsupported',
  path: 'transport.type',
  params: {'transport': 'quic', 'fallback': 'ws'},
);

void main() {
  setUpAll(() async {
    await ContractRegistry.I.loadFromDirectory(_registryRoot);
  });
  tearDownAll(ContractRegistry.I.resetForTesting);

  testWidgets('Copy кладёт в буфер код, заголовок, секции и params', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: NodeNotificationsView([_warnTransport]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final copy = find.byKey(const ValueKey('notification-copy'));
    expect(copy, findsOneWidget);
    await tester.tap(copy);
    await tester.pump();

    expect(copied, isNotNull);
    final text = copied!;
    expect(text.split('\n').first, 'transport_unsupported');
    expect(text, contains(_warnTransport.message()));
    expect(text, contains('What happened:'));
    expect(text, contains('What you can do:'));
    expect(text, contains('path = transport.type'));
    expect(text, contains('transport = quic'));
    expect(text, contains('fallback = ws'));
  });
}
