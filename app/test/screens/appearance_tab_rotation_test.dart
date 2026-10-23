// §679 — переключатель «Allow rotation» на TV скрыт, на телефоне есть.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/app_settings_screen/widgets/appearance_tab.dart';

void main() {
  Future<void> pump(WidgetTester tester, {required bool show}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AppearanceTab(
          loaded: true,
          allowRotation: false,
          showAllowRotation: show,
          nodeListTwoColumns: true,
          padding: EdgeInsets.zero,
          onAllowRotationChanged: (_) {},
          onNodeListTwoColumnsChanged: (_) {},
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('phone: Allow rotation shown', (tester) async {
    await pump(tester, show: true);
    expect(find.byIcon(Icons.screen_rotation), findsOneWidget);
  });

  testWidgets('TV: Allow rotation hidden, Two columns stays', (tester) async {
    await pump(tester, show: false);
    expect(find.byIcon(Icons.screen_rotation), findsNothing);
    expect(find.byIcon(Icons.view_column_outlined), findsOneWidget);
  });
}
