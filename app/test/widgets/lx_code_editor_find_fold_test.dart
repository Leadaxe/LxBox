import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/config/config_parse.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/widgets/lx_code_editor.dart';

/// §614/§624 — поиск в LxCodeEditor (панель — Flutter-виджет, сам поиск —
/// в нативе) и синхронизация LxTextCodeField с `TextEditingController` на
/// заглушке (`flutter test` не Android — нативного view нет). Свёртка
/// снята §624.
void main() {
  const json = '{\n  "a": {\n    "b": 1\n  },\n  "c": [1, 2]\n}';

  Future<void> pump(WidgetTester tester, {bool showLineNumbers = false}) async {
    final controller = TextEditingController(text: json);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 300,
            child: LxCodeEditor(
              controller: controller,
              showLineNumbers: showLineNumbers,
              language: LxCodeLanguage.json,
            ),
          ),
        ),
      ),
    );
  }

  const findIcon = ValueKey('lx-code-editor-find');
  const findPanel = ValueKey('lx-code-editor-find-panel');
  const findClose = ValueKey('lx-code-editor-find-close');

  testWidgets('без номеров строк — без поиска', (tester) async {
    await pump(tester);
    expect(find.byKey(findIcon), findsNothing);
  });

  testWidgets('с номерами строк — иконка открывает панель, крестик закрывает', (
    tester,
  ) async {
    await pump(tester, showLineNumbers: true);
    expect(find.byKey(findIcon), findsOneWidget);

    await tester.tap(find.byKey(findIcon));
    await tester.pump();
    expect(find.byKey(findPanel), findsOneWidget);
    expect(find.byKey(findIcon), findsNothing);
    expect(find.text('0/0'), findsOneWidget);

    await tester.tap(find.byKey(findClose));
    await tester.pump();
    expect(find.byKey(findPanel), findsNothing);
    expect(find.byKey(findIcon), findsOneWidget);
  });

  testWidgets('LxTextCodeField: синхронизация с TextEditingController', (
    tester,
  ) async {
    final text = TextEditingController(text: '{"a": 1}');
    addTearDown(text.dispose);
    final changes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            child: LxTextCodeField(
              controller: text,
              minLines: 6,
              onChanged: changes.add,
            ),
          ),
        ),
      ),
    );
    final field = find.descendant(
      of: find.byType(LxCodeEditor),
      matching: find.byType(EditableText),
    );
    String shown() => tester.widget<EditableText>(field).controller.text;
    expect(shown(), '{"a": 1}');

    // Запись из кода в TextEditingController → поле, без onChanged.
    text.text = '{"b": 2}';
    await tester.pump();
    expect(shown(), '{"b": 2}');
    expect(changes, isEmpty);

    // Правка в поле → TextEditingController и onChanged.
    await tester.enterText(field, '{"c": 3}');
    await tester.pump();
    expect(text.text, '{"c": 3}');
    expect(changes, ['{"c": 3}']);
  });

  // §624 доработка 2 — кнопки над рамкой, подпись слева; §660 — Format в
  // меню ⋮.
  const formatBtn = ValueKey('lx-code-editor-format');
  const menuBtn = ValueKey('lx-code-editor-menu');
  const bar = ValueKey('lx-code-editor-bar');

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byKey(menuBtn));
    await tester.pumpAndSettle();
  }

  Future<void> tapFormat(WidgetTester tester) async {
    await openMenu(tester);
    await tester.tap(find.byKey(formatBtn));
  }

  Future<TextEditingController> pumpField(
    WidgetTester tester,
    String text, {
    List<String>? changes,
    bool readOnly = false,
  }) async {
    final c = TextEditingController(text: text);
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            child: LxTextCodeField(
              key: UniqueKey(),
              controller: c,
              minLines: 6,
              readOnly: readOnly,
              onChanged: changes?.add,
              header: const Text('caption'),
            ),
          ),
        ),
      ),
    );
    return c;
  }

  testWidgets('строка кнопок над рамкой: подпись слева, поиск и ⋮ справа', (
    tester,
  ) async {
    await pumpField(tester, '{"a":1}');
    Finder inBar(Finder f) => find.descendant(of: find.byKey(bar), matching: f);
    expect(inBar(find.text('caption')), findsOneWidget);
    expect(inBar(find.byKey(findIcon)), findsOneWidget);
    expect(inBar(find.byKey(menuBtn)), findsOneWidget);
    expect(find.byKey(formatBtn), findsNothing, reason: 'Format — в меню');
    final barBottom = tester.getBottomLeft(find.byKey(bar)).dy;
    final fieldTop = tester.getTopLeft(find.byType(TextField)).dy;
    expect(
      fieldTop,
      greaterThanOrEqualTo(barBottom),
      reason: 'кнопки не внутри рамки',
    );
    expect(
      tester.getTopLeft(find.byKey(menuBtn)).dx,
      greaterThan(tester.getTopLeft(find.text('caption')).dx),
    );

    // Поиск открыт — панель вместо строки кнопок, подпись остаётся.
    await tester.tap(find.byKey(findIcon));
    await tester.pump();
    expect(find.byKey(bar), findsNothing);
    expect(find.byKey(findPanel), findsOneWidget);
    expect(find.byKey(menuBtn), findsNothing);
    expect(find.text('caption'), findsOneWidget);
  });

  testWidgets('свои actions — в строке над рамкой (Copy LxJsonView)', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: LxJsonView(
            text: '{"a": 1}',
            height: 200,
            actions: [Icon(Icons.copy, key: ValueKey('copy'))],
          ),
        ),
      ),
    );
    expect(
      find.descendant(
        of: find.byKey(bar),
        matching: find.byKey(const ValueKey('copy')),
      ),
      findsOneWidget,
    );
    // ⋮ — последним справа, после actions.
    expect(
      tester.getTopLeft(find.byKey(menuBtn)).dx,
      greaterThan(tester.getTopLeft(find.byKey(const ValueKey('copy'))).dx),
    );
  });

  testWidgets('Format не виден: не JSON или format: false; меню есть', (
    tester,
  ) async {
    await pumpField(tester, 'vless://x@h:1#n');
    await openMenu(tester);
    expect(find.byKey(formatBtn), findsNothing);
    expect(
      find.byKey(const ValueKey('lx-code-editor-magnifier')),
      findsOneWidget,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LxTextCodeField(
            key: UniqueKey(),
            controller: TextEditingController(text: '{"a":1}'),
            minLines: 6,
            format: false,
          ),
        ),
      ),
    );
    await openMenu(tester);
    expect(find.byKey(formatBtn), findsNothing);
  });

  testWidgets('меню есть и без подписи, кнопок и actions', (tester) async {
    await pump(tester);
    expect(find.byKey(bar), findsOneWidget);
    expect(find.byKey(menuBtn), findsOneWidget);
  });

  testWidgets('только чтение: Format ↔ Show original меняют показ, не '
      'контроллер; новый текст сверху сбрасывает показ', (tester) async {
    Widget view(String text) => MaterialApp(
      home: Scaffold(body: LxJsonView(text: text, height: 200)),
    );
    await tester.pumpWidget(view('{"a":1,"b":[1]}'));
    final field = find.descendant(
      of: find.byType(LxCodeEditor),
      matching: find.byType(EditableText),
    );
    String shown() => tester.widget<EditableText>(field).controller.text;
    TextEditingController source() =>
        tester.widget<LxCodeEditor>(find.byType(LxCodeEditor)).controller;

    await tapFormat(tester);
    await tester.pumpAndSettle();
    const pretty = '{\n  "a": 1,\n  "b": [\n    1\n  ]\n}';
    expect(shown(), pretty);
    expect(source().text, '{"a":1,"b":[1]}', reason: 'хранимое не трогаем');

    await openMenu(tester);
    expect(find.text('Show original'), findsOneWidget);
    await tester.tap(find.byKey(formatBtn));
    await tester.pumpAndSettle();
    expect(shown(), '{"a":1,"b":[1]}');

    await tapFormat(tester);
    await tester.pumpAndSettle();
    expect(shown(), pretty);
    await tester.pumpWidget(view('{"c":2}'));
    await tester.pump();
    expect(shown(), '{"c":2}');
    await openMenu(tester);
    expect(find.text('Format'), findsOneWidget);
  });

  testWidgets('только чтение: битый JSON — снек, показ не меняется', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: LxJsonView(text: '{"a": 1,, }', height: 200)),
      ),
    );
    await tapFormat(tester);
    await tester.pump();
    expect(find.textContaining('Failed to parse JSON: '), findsOneWidget);
  });

  testWidgets('Magnifier: снимает галку, шлёт setMagnifier и пишет '
      'настройку', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('lxbox_magnifier_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathChannel, (_) async => tmp.path);
    addTearDown(() => messenger.setMockMethodCallHandler(pathChannel, null));
    SettingsStorage.resetCacheForTesting();
    addTearDown(SettingsStorage.resetCacheForTesting);
    // Кэш хранилища прогрет вне fake async: дальше чтение без диска.
    await tester.runAsync(SettingsStorage.getEditorMagnifier);
    LxCodeEditorState.debugResetMagnifier();
    addTearDown(LxCodeEditorState.debugResetMagnifier);

    await pumpField(tester, '{"a":1}');
    const channel = MethodChannel('com.leadaxe.lxbox/sora_editor_12');
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    tester
        .state<LxCodeEditorState>(find.byType(LxCodeEditor))
        .debugAttachChannel(12);

    const item = ValueKey('lx-code-editor-magnifier');
    bool checked() =>
        tester.widget<CheckedPopupMenuItem<Object?>>(find.byKey(item)).checked;
    await openMenu(tester);
    expect(checked(), isTrue, reason: 'по умолчанию включена');
    await tester.tap(find.byKey(item));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'setMagnifier').single.arguments, {
      'enabled': false,
    });
    expect(await SettingsStorage.getEditorMagnifier(), isFalse);
    await openMenu(tester);
    expect(checked(), isFalse);
  });

  testWidgets('Format: JSON5 → JSON с отступом 2, в контроллер и onChanged', (
    tester,
  ) async {
    final changes = <String>[];
    final c = await pumpField(tester, '{a: 1, b: [1, 2,],}', changes: changes);
    await tapFormat(tester);
    await tester.pumpAndSettle();
    const want = '{\n  "a": 1,\n  "b": [\n    1,\n    2\n  ]\n}';
    expect(c.text, want);
    expect(changes, [want]);
  });

  testWidgets('Format: битый JSON — снек, текст не меняется', (tester) async {
    final changes = <String>[];
    final c = await pumpField(tester, '{"a": 1,, }', changes: changes);
    await tapFormat(tester);
    await tester.pump();
    expect(find.textContaining('Failed to parse JSON: '), findsOneWidget);
    expect(c.text, '{"a": 1,, }');
    expect(changes, isEmpty);
  });

  testWidgets('Format: комментарии — диалог; Cancel не трогает, Format '
      'форматирует', (tester) async {
    const src = '{\n  // note\n  "a": 1\n}';
    final c = await pumpField(tester, src);
    await tapFormat(tester);
    await tester.pumpAndSettle();
    expect(find.text('Comments will be removed'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(c.text, src);

    await tapFormat(tester);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('lx-code-editor-format-confirm')),
    );
    await tester.pumpAndSettle();
    expect(c.text, '{\n  "a": 1\n}');
  });

  // §649 — кнопка переноса строк у просмотрщика JSON с липкими заголовками.
  const wrapBtn = ValueKey('lx-code-editor-wrap');
  String? wrapTooltip(WidgetTester tester) =>
      tester.widget<IconButton>(find.byKey(wrapBtn)).tooltip;
  // Включённый перенос — тональная подложка (secondaryContainer).
  Color? wrapBackground(WidgetTester tester) {
    final b = tester.widget<IconButton>(find.byKey(wrapBtn));
    expect(b.isSelected, b.style != null);
    return b.style?.backgroundColor?.resolve(const {WidgetState.selected});
  }

  testWidgets('перенос: кнопка у LxJsonView со sticky JSON, после поиска; '
      'нажатие переключает и зовёт setWordWrap', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: LxJsonView(
            text: '{"a": 1}',
            height: 200,
            showLineNumbers: true,
            stickyHeaders: true,
            actions: [Icon(Icons.copy, key: ValueKey('copy'))],
          ),
        ),
      ),
    );
    expect(find.byKey(wrapBtn), findsOneWidget);
    double x(Finder f) => tester.getTopLeft(f).dx;
    expect(x(find.byKey(wrapBtn)), greaterThan(x(find.byKey(findIcon))));
    expect(
      x(find.byKey(const ValueKey('copy'))),
      greaterThan(x(find.byKey(wrapBtn))),
    );
    expect(wrapTooltip(tester), 'Wrap lines', reason: 'по умолчанию выключен');
    expect(wrapBackground(tester), isNull);
    final cs = Theme.of(tester.element(find.byKey(wrapBtn))).colorScheme;

    const channel = MethodChannel('com.leadaxe.lxbox/sora_editor_9');
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    tester
        .state<LxCodeEditorState>(find.byType(LxCodeEditor))
        .debugAttachChannel(9);
    await tester.pump();
    calls.clear();

    await tester.tap(find.byKey(wrapBtn));
    await tester.pump();
    expect(wrapTooltip(tester), 'Unwrap lines');
    expect(wrapBackground(tester), cs.secondaryContainer);
    final wrapCalls = calls.where((c) => c.method == 'setWordWrap').toList();
    expect(wrapCalls.map((c) => c.arguments), [
      {'wordWrap': true},
    ]);

    await tester.tap(find.byKey(wrapBtn));
    await tester.pump();
    expect(wrapTooltip(tester), 'Wrap lines');
    expect(wrapBackground(tester), isNull);
    expect(calls.where((c) => c.method == 'setWordWrap').last.arguments, {
      'wordWrap': false,
    });

    // Панель поиска прячет кнопку вместе с остальными.
    await tester.tap(find.byKey(findIcon));
    await tester.pump();
    expect(find.byKey(wrapBtn), findsNothing);
  });

  testWidgets('перенос и Format: «занят» до ответа натива — обе кнопки '
      'недоступны, повторные нажатия не проходят', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: LxJsonView(text: '{"a": 1}', height: 200, stickyHeaders: true),
        ),
      ),
    );
    const channel = MethodChannel('com.leadaxe.lxbox/sora_editor_13');
    final messenger = tester.binding.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    var reply = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'setWordWrap' ||
          (call.arguments as Map?)?['waitLayout'] == true) {
        await reply.future;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    tester
        .state<LxCodeEditorState>(find.byType(LxCodeEditor))
        .debugAttachChannel(13);
    await tester.pump();

    bool wrapEnabled() =>
        tester.widget<IconButton>(find.byKey(wrapBtn)).onPressed != null;
    bool menuEnabled() =>
        tester.widget<PopupMenuButton<Object?>>(find.byKey(menuBtn)).enabled;
    const wrapBusy = ValueKey('lx-code-editor-wrap-busy');
    const menuBusy = ValueKey('lx-code-editor-menu-busy');

    await tester.tap(find.byKey(wrapBtn));
    await tester.pump();
    expect(wrapEnabled(), isFalse);
    expect(menuEnabled(), isFalse);
    expect(find.byKey(wrapBusy), findsOneWidget, reason: 'сразу, без задержки');
    expect(find.byKey(menuBusy), findsOneWidget);
    await tester.tap(find.byKey(wrapBtn));
    await tester.pump();
    expect(calls.where((c) => c.method == 'setWordWrap'), hasLength(1));

    reply.complete();
    await tester.pump();
    expect(wrapEnabled(), isTrue);
    expect(menuEnabled(), isTrue);
    expect(find.byKey(wrapBusy), findsNothing);

    // Format показа: «занят», пока натив раскладывает новый текст.
    reply = Completer<void>();
    await tapFormat(tester);
    await tester.pump();
    await tester.pump();
    expect(calls.where((c) => c.method == 'setText').last.arguments, {
      'text': '{\n  "a": 1\n}',
      'waitLayout': true,
    });
    expect(wrapEnabled(), isFalse);
    expect(find.byKey(menuBusy), findsOneWidget);
    reply.complete();
    await tester.pumpAndSettle();
    expect(wrapEnabled(), isTrue);
    expect(find.byKey(menuBusy), findsNothing);
  });

  testWidgets('раскладка: полоса прогресса только если натив считает '
      'дольше 300 мс', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: LxJsonView(text: '{"a": 1}', height: 200, stickyHeaders: true),
        ),
      ),
    );
    const channel = MethodChannel('com.leadaxe.lxbox/sora_editor_11');
    tester
        .state<LxCodeEditorState>(find.byType(LxCodeEditor))
        .debugAttachChannel(11);
    Future<void> busy(bool on) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('layoutBusy', {'busy': on}),
        ),
        (_) {},
      );
      await tester.pump();
    }

    const bar = ValueKey('lx-code-editor-layout-busy');
    // Быстрый пересчёт — полосы нет.
    await busy(true);
    await tester.pump(const Duration(milliseconds: 200));
    await busy(false);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(bar), findsNothing);

    // Долгий — полоса после задержки, снимается концом раскладки.
    await busy(true);
    expect(find.byKey(bar), findsNothing);
    await tester.pump(const Duration(milliseconds: 301));
    expect(find.byKey(bar), findsOneWidget);
    await busy(false);
    expect(find.byKey(bar), findsNothing);
  });

  testWidgets('перенос: кнопки нет у редактируемого поля и у просмотрщика '
      'без sticky JSON', (tester) async {
    await pumpField(tester, '{"a":1}');
    expect(find.byKey(wrapBtn), findsNothing);
    for (final view in const [
      LxJsonView(text: '{"a": 1}', height: 200),
      LxJsonView(
        text: 'vless://x',
        height: 200,
        stickyHeaders: true,
        language: null,
      ),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: KeyedSubtree(key: UniqueKey(), child: view),
          ),
        ),
      );
      expect(find.byKey(wrapBtn), findsNothing);
    }
  });

  testWidgets('перенос: кнопка у редактора Config (wrapToggle)', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LxCodeEditor(
            controller: TextEditingController(text: '{"a": 1}'),
            showLineNumbers: true,
            language: LxCodeLanguage.json,
            stickyHeaders: true,
            wordWrap: false,
            wrapToggle: true,
          ),
        ),
      ),
    );
    expect(find.byKey(wrapBtn), findsOneWidget);
    expect(wrapTooltip(tester), 'Wrap lines', reason: 'по умолчанию выключен');
    await tester.tap(find.byKey(wrapBtn));
    await tester.pump();
    expect(wrapTooltip(tester), 'Unwrap lines');
  });

  test('hasJson5Comments: только вне строк', () {
    expect(hasJson5Comments('{"u": "http://x/*y"}'), isFalse);
    expect(hasJson5Comments(r"{'a': 'b\\'} // c"), isTrue);
    expect(hasJson5Comments(r'{"a": "\"//"}'), isFalse);
    expect(hasJson5Comments('{/* c */ "a": 1}'), isTrue);
  });
}
