import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/subscription_meta.dart' as model;
import 'package:lxbox/screens/subscription_detail_screen/widgets/subscription_meta.dart';

/// §648 — блок описания подписки (`announce`) в шапке.
void main() {
  SubscriptionEntry entryWith(String? announce) => SubscriptionEntry(
        list: SubscriptionServers(
          id: 's1',
          name: 'sub',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          url: 'https://example.com/sub',
          meta: model.SubscriptionMeta(announce: announce),
        ),
      );

  Future<void> pumpMeta(WidgetTester tester, SubscriptionEntry entry) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SubscriptionMeta(entry: entry, onOpenUrl: (_) async {}),
          ),
        ),
      ));

  int? maxLinesOf(WidgetTester tester, String text) =>
      tester.widget<Text>(find.text(text)).maxLines;

  testWidgets('поле есть — блок есть, нет поля — нет блока', (tester) async {
    await pumpMeta(tester, entryWith('Short legend'));
    expect(find.text('Short legend'), findsOneWidget);
    // Короткий текст на тап не реагирует.
    expect(
        find.ancestor(
            of: find.text('Short legend'), matching: find.byType(InkWell)),
        findsNothing);

    await pumpMeta(tester, entryWith(null));
    expect(find.text('Short legend'), findsNothing);
  });

  testWidgets('длинный текст свёрнут до 4 строк и раскрывается тапом',
      (tester) async {
    final long = List.generate(10, (i) => 'line $i').join('\n');
    await pumpMeta(tester, entryWith(long));
    expect(maxLinesOf(tester, long), 4);

    await tester.tap(find.text(long));
    await tester.pump();
    expect(maxLinesOf(tester, long), isNull);

    await tester.tap(find.text(long));
    await tester.pump();
    expect(maxLinesOf(tester, long), 4);
  });
}
