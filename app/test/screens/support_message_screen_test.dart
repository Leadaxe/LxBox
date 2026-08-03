import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/home/support_message_screen.dart';
import 'package:lxbox/services/support/support_message.dart';
import 'package:lxbox/services/support/support_nav.dart';

/// §357 — полноэкранный показ сообщения ленты: таймер «Got it», видимость
/// кнопок (https / незнакомое действие / route с гейтом), навигация route.
/// Все тесты в dryRun — state/IO не трогаются.
void main() {
  SupportMessage msg({
    int delay = 0,
    List<SupportLinkSpec> links = const [],
  }) =>
      SupportMessage(
        id: 'a',
        sinceVersion: '1.0.0',
        skip: false,
        minActiveHours: 0,
        minSessionMinutes: 0,
        readDelaySeconds: delay,
        i18n: {
          'en': SupportContent(title: 'T-title', message: 'M-body', links: links),
        },
      );

  const feed = SupportFeed(snoozeActiveHours: 10, messages: []);

  Future<void> pumpScreen(
    WidgetTester tester,
    SupportMessage m, {
    Widget? Function(SupportLinkAction)? build,
  }) =>
      tester.pumpWidget(MaterialApp(
        home: SupportMessageScreen(
          feed: feed,
          message: m,
          dryRun: true,
          buildScreen: build ?? (_) => null,
        ),
      ));

  testWidgets('таймер: «Got it (N)» disabled → тикает → активна', (tester) async {
    await pumpScreen(tester, msg(delay: 3));
    final counting = find.widgetWithText(FilledButton, 'Got it (3)');
    expect(counting, findsOneWidget);
    expect(tester.widget<FilledButton>(counting).onPressed, isNull);

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Got it (2)'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    final active = find.widgetWithText(FilledButton, 'Got it');
    expect(tester.widget<FilledButton>(active).onPressed, isNotNull);
  });

  testWidgets('delay=0 → «Got it» активна сразу; «Later» активна всегда',
      (tester) async {
    await pumpScreen(tester, msg(delay: 0));
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Got it'))
            .onPressed,
        isNotNull);
    expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Later'))
            .onPressed,
        isNotNull);
  });

  testWidgets('кнопки: https видна; будущее действие скрыто; route — по гейту',
      (tester) async {
    final m = msg(links: const [
      SupportLinkSpec('ext-btn', 'https://example.com'),
      SupportLinkSpec('future-btn', 'lxbox://teleport:mars'),
      SupportLinkSpec('dns-btn', 'lxbox://route:dns'),
      SupportLinkSpec('stats-btn', 'lxbox://route:stats'),
    ]);
    await pumpScreen(
      tester,
      m,
      // dns резолвится, stats — нет (гейт «туннель опущен» вернул null).
      build: (a) => routeSegments(a).first == 'dns' ? const SizedBox() : null,
    );
    expect(find.text('ext-btn'), findsOneWidget);
    expect(find.text('future-btn'), findsNothing,
        reason: 'forward-compat: незнакомое действие прячется');
    expect(find.text('dns-btn'), findsOneWidget);
    expect(find.text('stats-btn'), findsNothing,
        reason: 'buildScreen вернул null — гейт экрана');
  });

  testWidgets('тап route-кнопки заменяет экран сообщения целевым',
      (tester) async {
    final m = msg(links: const [SupportLinkSpec('go', 'lxbox://route:dns')]);
    await pumpScreen(tester, m,
        build: (_) => const Scaffold(body: Text('TARGET')));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('TARGET'), findsOneWidget);
    expect(find.text('T-title'), findsNothing,
        reason: 'pushReplacement: сообщение ушло из стека');
  });
}
