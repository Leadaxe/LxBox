import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart';
import 'package:lxbox/screens/config_screen.dart';
import 'package:lxbox/widgets/lx_code_editor.dart';

// §624 (доработка после rc.2) — Back с несохранённой правкой на Config
// спрашивает общий диалог Unsaved changes, как соседние экраны правки.
// Под `flutter test` редактор — заглушка на TextField.

/// Шов: Save экрана идёт в [HomeController.saveConfigRaw]; настоящий путь
/// уходит в native `saveConfig`. Здесь — разбор JSON и запись вызовов.
class _FakeHome extends HomeController {
  final saved = <String>[];

  @override
  Future<bool> saveConfigRaw(String raw) async {
    try {
      jsonDecode(raw);
    } on FormatException {
      return false;
    }
    saved.add(raw);
    return true;
  }
}

class _Host {
  bool closed = false;
}

Future<(_FakeHome, _Host)> _open(WidgetTester tester, String raw) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final home = _FakeHome()..debugSetConfigRaw(raw);
  addTearDown(home.dispose);
  final host = _Host();
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () async {
            await Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => ConfigScreen(controller: home)));
            host.closed = true;
          },
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  // LinearProgressIndicator крутится бесконечно — pumpAndSettle не дождётся.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  // pretty-print идёт в изоляте (compute) — ждём реальным временем.
  for (var i = 0;
      i < 500 && find.byType(LinearProgressIndicator).evaluate().isNotEmpty;
      i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
  expect(find.byType(LinearProgressIndicator), findsNothing);
  await tester.pumpAndSettle();
  return (home, host);
}

TextEditingController _code(WidgetTester tester) =>
    tester.widget<LxCodeEditor>(find.byType(LxCodeEditor)).controller;

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(
    find.descendant(
        of: find.byType(LxCodeEditor), matching: find.byType(EditableText)),
    text,
  );
  await tester.pump();
}

Future<void> _back(WidgetTester tester) async {
  await tester.pageBack();
  await tester.pumpAndSettle();
}

Finder get _dialog => find.byType(AlertDialog);

Future<void> _choose(WidgetTester tester, String label) async {
  await tester.tap(find.descendant(of: _dialog, matching: find.text(label)));
  await tester.pumpAndSettle();
}

void main() {
  const raw = '{"log":{"level":"info"}}';
  const edited = '{"log":{"level":"debug"}}';

  testWidgets('без правок — выход без диалога', (tester) async {
    final (_, host) = await _open(tester, raw);
    await _back(tester);
    expect(_dialog, findsNothing);
    expect(host.closed, isTrue);
  });

  testWidgets('правка → Back → диалог; Discard закрывает без сохранения',
      (tester) async {
    final (home, host) = await _open(tester, raw);
    await _type(tester, edited);
    await _back(tester);
    expect(_dialog, findsOneWidget);
    await _choose(tester, 'Discard');
    expect(host.closed, isTrue);
    expect(home.saved, isEmpty);
  });

  testWidgets('Keep — экран остаётся, правка на месте', (tester) async {
    final (_, host) = await _open(tester, raw);
    await _type(tester, edited);
    await _back(tester);
    await _choose(tester, 'Keep');
    expect(_dialog, findsNothing);
    expect(host.closed, isFalse);
    expect(find.byType(ConfigScreen), findsOneWidget);
    expect(_code(tester).text, edited);
  });

  testWidgets('Save с валидным JSON — сохранено и закрыто', (tester) async {
    final (home, host) = await _open(tester, raw);
    await _type(tester, edited);
    await _back(tester);
    await _choose(tester, 'Save');
    expect(home.saved, [edited]);
    expect(host.closed, isTrue);
  });

  testWidgets('Save с битым JSON — экран открыт, правка на месте',
      (tester) async {
    final (home, host) = await _open(tester, raw);
    await _type(tester, '{"log":');
    await _back(tester);
    await _choose(tester, 'Save');
    expect(home.saved, isEmpty);
    expect(host.closed, isFalse);
    expect(find.byType(ConfigScreen), findsOneWidget);
    expect(_code(tester).text, '{"log":');
  });

  testWidgets('после Save кнопкой — Back без диалога', (tester) async {
    final (home, host) = await _open(tester, raw);
    await _type(tester, edited);
    await tester.tap(find.descendant(
        of: find.byType(AppBar), matching: find.text('Save')));
    await tester.pumpAndSettle();
    expect(home.saved, [edited]);
    await _back(tester);
    expect(_dialog, findsNothing);
    expect(host.closed, isTrue);
  });

  testWidgets('только чтение (конфиг сверх лимита) — выход без диалога',
      (tester) async {
    // Не JSON: разбор падает на первом символе (pretty-print отдаёт текст
    // как есть) — иначе json5 мегабайта под тестом идёт десятки секунд.
    final big = '#${'${'a' * 79}\n' * (kConfigEditMaxChars ~/ 80 + 1)}';
    final (_, host) = await _open(tester, big);
    await _back(tester);
    expect(_dialog, findsNothing);
    expect(host.closed, isTrue);
  });
}
