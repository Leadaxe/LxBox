import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/widgets/lx_code_editor.dart';

/// §624 — Dart-логика нативного редактора без нативного view: канал
/// подключается к заглушке (`debugAttachChannel`), натив изображают
/// сообщения через тестовый messenger.
void main() {
  const id = 7;
  const channel = MethodChannel('com.leadaxe.lxbox/sora_editor_$id');

  late List<MethodCall> calls;
  String nativeText = '';

  setUp(() {
    calls = [];
    nativeText = '';
  });

  Future<void> fromNative(
      WidgetTester tester, String method, [Object? args]) async {
    final data =
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, args));
    await tester.binding.defaultBinaryMessenger
        .handlePlatformMessage(channel.name, data, (_) {});
    await tester.pump();
  }

  Future<LxCodeEditorState> attach(WidgetTester tester) async {
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'getText') return nativeText;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final state = tester.state<LxCodeEditorState>(find.byType(LxCodeEditor));
    state.debugAttachChannel(id);
    await tester.pump();
    return state;
  }

  Widget field(
    TextEditingController c, {
    List<String>? changes,
    bool readOnly = false,
    LxCodeLanguage? language = LxCodeLanguage.json,
  }) =>
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: LxTextCodeField(
              controller: c,
              minLines: 6,
              maxLines: 20,
              readOnly: readOnly,
              language: language,
              onChanged: changes?.add,
            ),
          ),
        ),
      );

  testWidgets('запись из кода → setText; правка в нативе → контроллер и '
      'onChanged, без эха', (tester) async {
    final c = TextEditingController(text: '{}');
    addTearDown(c.dispose);
    final changes = <String>[];
    await tester.pumpWidget(field(c, changes: changes));
    await attach(tester);

    c.text = '{"a": 1}';
    await tester.pump();
    expect(calls.single.method, 'setText');
    expect((calls.single.arguments as Map)['text'], '{"a": 1}');
    expect(changes, isEmpty, reason: 'запись из кода — не правка');

    calls.clear();
    await fromNative(tester, 'changed',
        {'text': '{"b": 2}', 'lines': 1, 'rowHeight': 48, 'textOffsetX': 0});
    expect(c.text, '{"b": 2}');
    expect(changes, ['{"b": 2}']);
    expect(calls, isEmpty, reason: 'текст из натива обратно не уходит');
  });

  testWidgets('рост поля по метрикам натива, потолок maxLines',
      (tester) async {
    final c = TextEditingController(text: '{}');
    addTearDown(c.dispose);
    await tester.pumpWidget(field(c));
    await attach(tester);
    final dpr = tester.view.devicePixelRatio;
    double h() => tester.getSize(find.byType(LxCodeEditor)).height;

    await fromNative(tester, 'changed',
        {'lines': 3, 'rowHeight': 20 * dpr, 'textOffsetX': 0});
    final minH = h();
    await fromNative(tester, 'changed',
        {'lines': 10, 'rowHeight': 20 * dpr, 'textOffsetX': 0});
    expect(h() - minH, closeTo(4 * 20, 0.01), reason: '6 → 10 строк');
    await fromNative(tester, 'changed',
        {'lines': 400, 'rowHeight': 20 * dpr, 'textOffsetX': 0});
    expect(h() - minH, closeTo(14 * 20, 0.01), reason: 'не выше 20 строк');
  });

  testWidgets('changed без текста не трогает контроллер; flush забирает '
      'задержанный текст', (tester) async {
    final c = TextEditingController(text: 'old');
    addTearDown(c.dispose);
    final changes = <String>[];
    await tester.pumpWidget(field(c, changes: changes));
    final state = await attach(tester);

    await fromNative(
        tester, 'changed', {'lines': 2, 'rowHeight': 48, 'textOffsetX': 0});
    expect(c.text, 'old');
    expect(changes, isEmpty);

    nativeText = 'long edited text';
    await state.flush();
    await tester.pump();
    expect(calls.map((e) => e.method), contains('getText'));
    expect(c.text, 'long edited text');
    expect(changes, ['long edited text']);
  });

  testWidgets('readOnly и язык меняются без пересоздания view',
      (tester) async {
    final c = TextEditingController(text: '{}');
    addTearDown(c.dispose);
    await tester.pumpWidget(field(c));
    await attach(tester);

    await tester.pumpWidget(
        field(c, readOnly: true, language: LxCodeLanguage.ini));
    final byMethod = {for (final call in calls) call.method: call.arguments};
    expect((byMethod['setReadOnly'] as Map)['readOnly'], isTrue);
    expect((byMethod['setLanguage'] as Map)['language'], 'ini');

    calls.clear();
    await tester.pumpWidget(field(c, readOnly: true, language: null));
    expect((calls.single.arguments as Map)['language'], isNull);
  });

  testWidgets('финальный changed после ухода виджета ложится в контроллер',
      (tester) async {
    final c = TextEditingController(text: 'before');
    addTearDown(c.dispose);
    await tester.pumpWidget(field(c));
    await attach(tester);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await fromNative(tester, 'changed',
        {'text': 'after', 'lines': 1, 'rowHeight': 48, 'textOffsetX': 0});
    expect(c.text, 'after');
    await fromNative(tester, 'disposed');
  });
}
