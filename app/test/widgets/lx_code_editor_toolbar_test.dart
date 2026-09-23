import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/widgets/lx_code_editor.dart';
import 'package:re_editor/re_editor.dart';

/// §517 часть F — контекстное меню редактора не схлопывает выделение.
///
/// Было: `showMenu` = `Navigator.push` модального `PopupRoute`. Маршрут
/// забирал фокус и ставил барьер, re_editor снимал выделение на тапе вне
/// текста (`_code_selection.dart:172-176,188-192`), а `onTap` у
/// `PopupMenuItem` срабатывал ПОСЛЕ закрытия маршрута — `controller.copy`
/// копировал уже схлопнутое выделение. Пользователи с форума: «долгий тап
/// показывает меню, выделение слетает; строку ещё можно копирнуть».
///
/// Стало: `OverlayEntry` + `CompositedTransformFollower(link: layerLink)`,
/// меню обёрнуто в `CodeEditorTapRegion` — тап по кнопке не считается тапом
/// вне текста, выделение живо, действия работают с настоящим диапазоном.
///
/// Путь теста — ШТАТНЫЙ: долгий тап по тексту, как на устройстве. Дёргать
/// `toolbarController.show` напрямую бессмысленно: без настоящего (связанного
/// с редактором) `layerLink` follower садится в начало координат поверх самого
/// редактора, и тап по «кнопке» уходит в текст. Именно связанный link и делает
/// оверлей рабочим, поэтому проверять надо сквозь редактор.
///
/// Без `pumpAndSettle`: у редактора бесконечная анимация каретки — settle не
/// сойдётся. Везде `pump(Duration)`.
void main() {
  // `alpha` — первое слово первой строки, цель долгого тапа.
  const text = 'alpha bravo charlie\nsecond line here\n';

  /// Перехват `Clipboard.setData` — на нём видно, что реально скопировано.
  late List<String> copied;

  setUp(() {
    copied = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
        return null;
      }
      if (call.method == 'Clipboard.getData') {
        return <String, dynamic>{'text': 'PASTED'};
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<CodeLineEditingController> pumpEditor(WidgetTester tester) async {
    final controller = CodeLineEditingController.fromText(text);
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 300,
          child: LxCodeEditor(controller: controller),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    return controller;
  }

  /// Долгий тап по слову `alpha` — re_editor выделяет слово и зовёт
  /// `SelectionToolbarController.show` со своим `layerLink`.
  Future<void> longPressWord(WidgetTester tester) async {
    await tester.longPressAt(const Offset(40, 20));
    await tester.pump(const Duration(milliseconds: 400));
  }

  Finder item(String label) => find.widgetWithText(TextButton, label);

  testWidgets('долгий тап: меню показано, выделение не схлопнуто',
      (tester) async {
    final controller = await pumpEditor(tester);
    await longPressWord(tester);

    expect(item('Copy'), findsOneWidget, reason: 'меню не показалось');
    expect(item('Cut'), findsOneWidget);
    expect(item('Paste'), findsOneWidget);
    expect(item('Select all'), findsOneWidget);

    expect(controller.selection.isCollapsed, isFalse,
        reason: 'показ меню схлопнул выделение — регрессия §517');
    expect(controller.selectedText, 'alpha');
  });

  testWidgets('тап Copy кладёт в буфер выделенный фрагмент', (tester) async {
    final controller = await pumpEditor(tester);
    await longPressWord(tester);
    expect(controller.selectedText, 'alpha');

    await tester.tap(item('Copy'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(copied, ['alpha'],
        reason: 'copy сработал по схлопнутому выделению — регрессия §517');
    // Само выделение copy не трогает: оно живо и после действия.
    expect(controller.selectedText, 'alpha');
    // И меню ушло — `hide()` больше не пустой.
    expect(item('Copy'), findsNothing);
  });

  testWidgets('тап Cut забирает выделенный фрагмент и вырезает его',
      (tester) async {
    final controller = await pumpEditor(tester);
    await longPressWord(tester);

    await tester.tap(item('Cut'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(copied, ['alpha'], reason: 'cut взял не выделенное');
    expect(controller.text, startsWith(' bravo charlie'),
        reason: 'из текста ушло ровно выделенное слово');
  });

  testWidgets('тап Select all выделяет весь текст', (tester) async {
    final controller = await pumpEditor(tester);
    await longPressWord(tester);

    await tester.tap(item('Select all'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(controller.selection.isCollapsed, isFalse);
    expect(controller.selectedText, text);
  });

  testWidgets('тап Paste заменяет выделение содержимым буфера', (tester) async {
    final controller = await pumpEditor(tester);
    await longPressWord(tester);

    await tester.tap(item('Paste'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(controller.text, startsWith('PASTED bravo charlie'),
        reason: 'paste подставился не на место выделения');
  });

  testWidgets('hide снимает оверлей (было: пустое тело метода)',
      (tester) async {
    await pumpEditor(tester);
    await longPressWord(tester);
    expect(item('Copy'), findsOneWidget);

    // Скролл — штатный триггер `hideToolbar` у re_editor
    // (`_code_editable.dart:270-276`).
    await tester.drag(find.byType(CodeEditor), const Offset(0, -40));
    await tester.pump(const Duration(milliseconds: 100));

    expect(item('Copy'), findsNothing,
        reason: 'оверлей остался на экране после hide');
  });

  testWidgets('повторный показ не плодит оверлеи', (tester) async {
    await pumpEditor(tester);
    await longPressWord(tester);
    expect(item('Copy'), findsOneWidget);

    // Второй долгий тап по тому же слову. re_editor на tap-down зовёт
    // `hideToolbar`, а затем показывает меню снова — то есть через наш `show`
    // проходит второй `OverlayEntry`. Если бы `show` не снимал предыдущий
    // (или `hide` оставался пустым, как было до §517), меню наложились бы.
    // Инвариант: сколько бы циклов ни прошло, на экране НЕ больше одного.
    await longPressWord(tester);
    expect(item('Copy').evaluate().length, lessThanOrEqualTo(1),
        reason: 'на экране больше одного меню — оверлей утёк');

    await longPressWord(tester);
    expect(item('Copy').evaluate().length, lessThanOrEqualTo(1),
        reason: 'на экране больше одного меню — оверлей утёк');
  });
}
