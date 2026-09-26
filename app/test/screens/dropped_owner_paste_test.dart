import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/screens/subscription_detail_screen/widgets/node_warnings_sheet.dart';
import 'package:lxbox/screens/subscriptions_screen/clipboard_analysis.dart';
import 'package:lxbox/screens/subscriptions_screen/paste_dialogs.dart';

import '../parser/engine_test_setup.dart';

/// §561 / задача 570 — шторка отбраковок называет запись источника
/// (`ownerTag`), диалог анализа вставки показывает отбраковки.
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

  testWidgets('шторка: запись-источник строкой под заголовком',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: NodeWarningsSheet([
          RegistryWarning(code: 'form_unrecognized', ownerTag: 'bad-entry'),
          RegistryWarning(code: 'form_unrecognized'),
        ]),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('notification-owner-bad-entry')),
        findsOneWidget);
  });

  test('анализ вставки несёт отбраковки разбора', () {
    final a = analyzeClipboard(body);
    expect(a.dropped, isNotEmpty);
  });

  testWidgets('диалог вставки: строка отбраковок открывает шторку',
      (tester) async {
    final a = analyzeClipboard(body);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => TextButton(
          onPressed: () => showConfirmAddDialog(ctx, a),
          child: const Text('go'),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('paste-dropped-row')));
    await tester.pumpAndSettle();
    expect(find.byType(NodeWarningsSheet), findsOneWidget);
  });
}
