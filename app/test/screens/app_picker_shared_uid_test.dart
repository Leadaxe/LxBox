import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/app_picker_screen.dart';
import 'package:lxbox/services/app_info_cache.dart';
import 'package:lxbox/services/l10n/locale_controller.dart';

/// §693 — пикер показывает UID пакета и подсказку, если UID общий с другими
/// установленными пакетами (системные считаются, даже если скрыты). Выбор
/// подсказка не трогает: пакеты группы автоматически не отмечаются.
void main() {
  const channel = MethodChannel('com.leadaxe.lxbox/methods');
  late List<dynamic> installed;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    AppInfoCache.resetForTest();
    AppInfoCache.retryDelays = const [];
    installed = <dynamic>[
      {'packageName': 'com.a', 'appName': 'Alpha', 'isSystemApp': false, 'uid': 1000},
      {'packageName': 'com.b', 'appName': 'Beta', 'isSystemApp': false, 'uid': 1000},
      {'packageName': 'com.c', 'appName': 'Gamma', 'isSystemApp': true, 'uid': 1000},
      {'packageName': 'com.d', 'appName': 'Delta', 'isSystemApp': false, 'uid': 10050},
    ];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getAppIcon') return '';
      if (call.method == 'getInstalledApps') return installed;
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    AppInfoCache.resetForTest();
  });

  Widget host() => MaterialApp(
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: LocaleController.supportedLocales,
        home: const AppPickerScreen(selected: {'com.a'}),
      );

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
  }

  Checkbox checkboxOf(WidgetTester tester, String title) => tester.widget(
        find.descendant(
          of: find.ancestor(
              of: find.text(title), matching: find.byType(ListTile)),
          matching: find.byType(Checkbox),
        ),
      );

  const hint2 = 'Shared with 2 other apps — they are routed together';

  testWidgets('UID в подзаголовке, подсказка только у общего UID',
      (tester) async {
    await tester.pumpWidget(host());
    await settle(tester);

    expect(find.text('com.a · UID 1000'), findsOneWidget);
    expect(find.text('com.d · UID 10050'), findsOneWidget);
    // Alpha и Beta видны (Gamma системный, скрыт) — у обоих по 2 соседа.
    expect(find.text(hint2), findsNWidgets(2));
    expect(find.text('Shared with 1 other apps — they are routed together'),
        findsNothing);
  });

  testWidgets('тап по подсказке — диалог со списком, выбор не меняется',
      (tester) async {
    await tester.pumpWidget(host());
    await settle(tester);

    await tester.tap(find.text(hint2).first);
    await settle(tester);

    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    expect(find.descendant(of: dialog, matching: find.text('UID 1000')),
        findsOneWidget);
    expect(find.descendant(of: dialog, matching: find.text('com.b')),
        findsOneWidget);
    expect(find.descendant(of: dialog, matching: find.text('com.c')),
        findsOneWidget);

    await tester.tap(find.text('Close'));
    await settle(tester);

    expect(checkboxOf(tester, 'Alpha').value, isTrue);
    expect(checkboxOf(tester, 'Beta').value, isFalse,
        reason: 'пакеты группы общего UID автоматически не выбираются');
  });

  testWidgets('native без uid — без UID и без подсказки', (tester) async {
    installed = <dynamic>[
      {'packageName': 'com.a', 'appName': 'Alpha', 'isSystemApp': false},
      {'packageName': 'com.b', 'appName': 'Beta', 'isSystemApp': false},
    ];
    await tester.pumpWidget(host());
    await settle(tester);

    expect(find.text('com.a'), findsOneWidget);
    expect(find.textContaining('UID'), findsNothing);
    expect(find.textContaining('Shared with'), findsNothing);
  });
}
