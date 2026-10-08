import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/subscription/user_agent.dart';
import 'package:lxbox/widgets/user_agent_dialog.dart';

/// §610 — общий диалог Custom User-Agent с пресетами клиентов.
void main() {
  late String? result;
  late bool closed;

  Future<void> open(WidgetTester tester, {String initial = ''}) async {
    closed = false;
    result = null;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              result = await showUserAgentDialog(context,
                  initial: initial, hint: 'LxBox-android/0.0.0');
              closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> pickPreset(WidgetTester tester, String label) async {
    await tester.tap(find.byKey(const ValueKey('user_agent_presets')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  String fieldText(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(const ValueKey('user_agent_field')))
      .controller!
      .text;

  testWidgets('выбор пресета подставляет его строку', (tester) async {
    await open(tester);
    await pickPreset(tester, 'Happ');
    expect(fieldText(tester), 'Happ/3.5.0');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(result, 'Happ/3.5.0');
  });

  testWidgets('строку пресета можно дописать руками', (tester) async {
    await open(tester);
    await pickPreset(tester, 'Streisand');
    await tester.enterText(
        find.byKey(const ValueKey('user_agent_field')), 'Streisand/2  ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result, 'Streisand/2');
  });

  testWidgets('ручной ввод сохраняется как есть (trim)', (tester) async {
    await open(tester);
    await tester.enterText(
        find.byKey(const ValueKey('user_agent_field')), '  MyClient/1.0 ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result, 'MyClient/1.0');
  });

  testWidgets('«LxBox (default)» очищает поле → пустая строка',
      (tester) async {
    await open(tester, initial: 'Happ/3.5.0');
    expect(fieldText(tester), 'Happ/3.5.0');
    await pickPreset(tester, kUserAgentPresets.first.label);
    expect(fieldText(tester), isEmpty);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result, '');
  });

  testWidgets('Cancel → null', (tester) async {
    await open(tester, initial: 'Happ/3.5.0');
    await pickPreset(tester, 'Karing');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(result, isNull);
  });
}
