import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/subscription_detail_screen/widgets/subscription_source_tab.dart';

/// §650 — вкладка Source: `base64:`-заголовки расшифрованы, подпись `base64`
/// под именем переключает вид значения строки.
void main() {
  final title = 'Liberty VPN 🗽';
  final encoded = 'base64:${base64.encode(utf8.encode(title))}';
  const broken = 'base64:@@not-base64@@';
  const plain = 'upload=0; download=1';

  Future<void> pumpTab(WidgetTester tester, Map<String, String> headers) {
    final entries = headers.entries.toList();
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SubscriptionSourceTab(
            hasUrl: true,
            sourceLoading: false,
            sourceError: null,
            rawHeaders: headers,
            rawSource: '',
            showAllHeaders: false,
            importantHeaders: entries,
            moreHeaders: const [],
            onRefetch: () {},
            onToggleShowAll: () {},
          ),
        ),
      ),
    );
  }

  testWidgets('base64-значение расшифровано, тап по подписи — исходное', (
    tester,
  ) async {
    await pumpTab(tester, {'profile-title': encoded});
    expect(find.text(title), findsOneWidget);
    expect(find.text(encoded), findsNothing);
    expect(find.text('base64'), findsOneWidget);

    await tester.tap(find.text('base64'));
    await tester.pump();
    expect(find.text(encoded), findsOneWidget);
    expect(find.text(title), findsNothing);
    expect(find.text('base64'), findsOneWidget);

    await tester.tap(find.text('base64'));
    await tester.pump();
    expect(find.text(title), findsOneWidget);
    expect(find.text(encoded), findsNothing);
  });

  testWidgets('без префикса и битый base64 — как есть, без подписи', (
    tester,
  ) async {
    await pumpTab(tester, {'subscription-userinfo': plain, 'announce': broken});
    expect(find.text(plain), findsOneWidget);
    expect(find.text(broken), findsOneWidget);
    expect(find.text('base64'), findsNothing);
  });
}
