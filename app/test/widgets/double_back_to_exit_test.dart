import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/widgets/double_back_to_exit.dart';

/// Задача 583 — выход с главного экрана по двойному нажатию «назад».
void main() {
  late int exits;

  setUp(() {
    exits = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.pop') exits++;
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  const message = 'Press back again to exit';
  final scaffoldKey = GlobalKey<ScaffoldState>();

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: DoubleBackToExit(
        builder: (_, onDrawerChanged) => Scaffold(
          key: scaffoldKey,
          onDrawerChanged: onDrawerChanged,
          drawer: const Drawer(child: Text('menu')),
          body: const Text('home'),
        ),
      ),
    ));
  }

  Future<void> back(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pump();
  }

  testWidgets('первое нажатие: сообщение, выхода нет', (tester) async {
    await pump(tester);
    await back(tester);
    expect(find.text(message), findsOneWidget);
    expect(exits, 0);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('второе нажатие в пределах 2 секунд: выход', (tester) async {
    await pump(tester);
    await back(tester);
    await tester.pump(const Duration(milliseconds: 1500));
    await back(tester);
    expect(exits, 1);
  });

  testWidgets('второе нажатие после 2 секунд: снова сообщение, выхода нет',
      (tester) async {
    await pump(tester);
    await back(tester);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    // Окно истекло, сообщение ушло.
    await tester.pump(const Duration(milliseconds: 2100));
    await tester.pumpAndSettle();
    expect(find.text(message), findsNothing);
    await back(tester);
    expect(exits, 0);
    expect(find.text(message), findsOneWidget);
  });

  testWidgets('открыто боковое меню: «назад» закрывает меню, сообщения нет',
      (tester) async {
    await pump(tester);
    scaffoldKey.currentState!.openDrawer();
    await tester.pumpAndSettle();
    expect(scaffoldKey.currentState!.isDrawerOpen, isTrue);
    await back(tester);
    await tester.pumpAndSettle();
    expect(scaffoldKey.currentState!.isDrawerOpen, isFalse);
    expect(find.text(message), findsNothing);
    expect(exits, 0);
    // Меню закрыто — правило снова действует.
    await back(tester);
    expect(find.text(message), findsOneWidget);
    expect(exits, 0);
  });
}
