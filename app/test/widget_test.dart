import 'package:flutter_test/flutter_test.dart';

import 'package:boxvpn_app/main.dart';

void main() {
  testWidgets('BoxVPN home loads', (WidgetTester tester) async {
    await tester.pumpWidget(const BoxVpnApp());
    expect(find.text('BoxVPN'), findsOneWidget);
    expect(find.text('Read'), findsOneWidget);
  });
}
