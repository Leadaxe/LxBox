import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/widgets/mouse_drag_scroll_behavior.dart';
import 'package:lxbox/screens/app_picker_screen.dart';
import 'package:lxbox/services/app_info_cache.dart';
import 'package:lxbox/services/l10n/locale_controller.dart';

/// §736 / issue #220 — пикер приложений на Android TV:
/// - D-pad «вниз» из поля поиска уводит фокус в список (раньше поле
///   держало фокус навсегда);
/// - пульт в режиме «мышь» прокручивает список перетаскиванием
///   (PointerDeviceKind.mouse; раньше Flutter мышью список не тянул).
void main() {
  const channel = MethodChannel('com.leadaxe.lxbox/methods');

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    AppInfoCache.resetForTest();
    AppInfoCache.retryDelays = const [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getAppIcon') return '';
          if (call.method == 'getInstalledApps') {
            return <dynamic>[
              for (var i = 0; i < 60; i++)
                {
                  'packageName': 'com.app$i',
                  'appName': 'App ${i.toString().padLeft(2, '0')}',
                  'isSystem': false,
                },
            ];
          }
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
    scrollBehavior: const MouseDragScrollBehavior(),
    home: const AppPickerScreen(selected: {}),
  );

  /// Не pumpAndSettle: подгрузка иконок держит таймеры, settle не наступает.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
  }

  ScrollPosition listPosition(WidgetTester tester) => tester
      .state<ScrollableState>(
        find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        ),
      )
      .position;

  bool focusInSearch(WidgetTester tester) {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    return ctx.widget is EditableText ||
        ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  testWidgets('D-pad ↓ из поля поиска уводит фокус в список, ↑ возвращает', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await settle(tester);

    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(focusInSearch(tester), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      focusInSearch(tester),
      isFalse,
      reason: 'поле поиска отпускает фокус по «вниз»',
    );
    final ctx = FocusManager.instance.primaryFocus!.context!;
    expect(
      ctx.findAncestorWidgetOfExactType<ListView>(),
      isNotNull,
      reason: 'фокус — на элементе списка',
    );

    // Дальше по списку: фокус идёт вниз, список прокручивается за ним.
    for (var i = 0; i < 25; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    await settle(tester);
    expect(
      listPosition(tester).pixels,
      greaterThan(0),
      reason: 'D-pad дошёл до строк за краем экрана',
    );

    // Назад к полю — вверх до упора.
    for (var i = 0; i < 40 && !focusInSearch(tester); i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      await settle(tester);
    }
    expect(focusInSearch(tester), isTrue, reason: '«вверх» возвращает в поиск');
  });

  testWidgets('перетаскивание указателем-мышью прокручивает список', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await settle(tester);
    expect(listPosition(tester).pixels, 0);

    await tester.dragFrom(
      tester.getCenter(find.byType(ListView)),
      const Offset(0, -300),
      kind: PointerDeviceKind.mouse,
    );
    await settle(tester);
    expect(listPosition(tester).pixels, greaterThan(0));
  });

  testWidgets('палец по-прежнему тянет список', (tester) async {
    await tester.pumpWidget(host());
    await settle(tester);

    await tester.dragFrom(
      tester.getCenter(find.byType(ListView)),
      const Offset(0, -300),
    );
    await settle(tester);
    expect(listPosition(tester).pixels, greaterThan(0));
  });
}
