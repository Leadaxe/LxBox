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

  // ------------------------------------------------------------------
  // §521 — меню не пропадало при снятии выделения и копилось экземплярами.
  //
  // Причина накопления: `LxCodeEditor` был `StatelessWidget` и собирал
  // `LxSelectionToolbarController()` прямо в `build()`. re_editor читает
  // `widget.toolbarController` в момент каждого показа
  // (`code_editor.dart:395,409`), а в `didUpdateWidget` (`:447-490`) это поле
  // не сверяет и старому контроллеру `hide()` не зовёт. Любой `setState`
  // родителя (в `config_screen` — `_loading`/`_readOnly`, в мастере — поля
  // формы) подменял экземпляр: у нового `_entry == null`, снять вставленный
  // прежним оверлей он не мог, и меню оставались на экране штабелем.
  // Владелец видел на скриншоте три сразу.
  //
  // Стало: `State` владеет одним контроллером на весь срок жизни редактора
  // плюс явные триггеры `hide` — схлопывание выделения, тап вне, `deactivate`,
  // `dispose`.
  //
  // Что репродуцируется, а что нет (проверено прогонами на `origin/develop`):
  // падает на старом коде ровно тест «setState родителя …» — он и есть
  // репродукция. Остальные новые тесты на старом коде зелёные: жесты (тап
  // мимо, тап по пустому месту, скролл, уход с экрана) там закрыты штатным
  // путём пакета. Они оставлены как страховка от регрессии добавленных
  // триггеров, и у каждого это сказано в докблоке — чтобы следующий не принял
  // их за репродукцию.
  // ------------------------------------------------------------------

  testWidgets('§521 тап по пустому месту рядом с редактором снимает меню',
      (tester) async {
    // Дефект со скриншота: меню оставалось висеть после снятия выделения.
    //
    // ЧЕСТНО О ПОКРЫТИИ: этот тест зелёный и на коде до §521 — в
    // widget-харнессе тап мимо редактора уже снимает меню штатным путём
    // пакета (`_code_editable.dart:266-269` — `onTapOutside` → `unfocus`, и
    // дальше `_onFocusChanged` (`:318-331`) зовёт `hideToolbar`). Тап внутри
    // редактора снимает меню тем же путём (`_code_selection.dart:172-176,
    // 188-192`). То есть жест сам по себе НЕ репродуцирует дефект: в харнессе
    // всегда оставался ровно один живой экземпляр контроллера, и `hide`
    // доходил до него.
    //
    // Дефект со скриншота репродуцирует тест «setState родителя …» ниже:
    // копились ЭКЗЕМПЛЯРЫ контроллера, и `hide` штатного пути приходил не
    // тому, кто держит оверлей. Этот же тест — страховка от регрессии:
    // добавленный в §521 `CodeEditorTapRegion.onTapOutside` вокруг редактора
    // не должен ни ломать штатный путь, ни считать тап по кнопке меню «тапом
    // вне» (последнее проверяет тест Copy выше — буфер получает 'alpha').
    //
    // `Stack` с подложкой на весь экран — чтобы было куда тапнуть «мимо»:
    // редактор занимает только верхние 200 px.
    final controller = CodeLineEditingController.fromText(text);
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: Color(0xFFEEEEEE))),
            Positioned(
              left: 0,
              top: 0,
              child: SizedBox(
                width: 400,
                height: 200,
                child: LxCodeEditor(controller: controller),
              ),
            ),
          ],
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));

    await longPressWord(tester);
    expect(item('Copy'), findsOneWidget, reason: 'меню не показалось');

    // Мимо редактора — по подложке ниже него.
    await tester.tapAt(const Offset(200, 400));
    await tester.pump(const Duration(milliseconds: 200));

    expect(item('Copy'), findsNothing,
        reason: 'меню осталось висеть после тапа вне редактора');
  });

  testWidgets('§521 тап по пустому месту внутри редактора: выделение снято '
      'и меню скрыто', (tester) async {
    // Тот же жест, но внутри редактора — ниже последней строки. Здесь работает
    // штатный путь re_editor; тест закрепляет, что §521 его не сломал и что
    // оба условия выполняются ВМЕСТЕ (выделение снято И меню скрыто).
    // Тоже зелёный до §521 — см. оговорку о покрытии в тесте выше.
    final controller = await pumpEditor(tester);
    await longPressWord(tester);
    expect(item('Copy'), findsOneWidget);

    await tester.tapAt(const Offset(200, 250));
    await tester.pump(const Duration(milliseconds: 200));

    expect(controller.selection.isCollapsed, isTrue,
        reason: 'тап по пустому месту не снял выделение');
    expect(item('Copy'), findsNothing, reason: 'меню осталось висеть');
  });

  testWidgets('§521 два долгих тапа в разных местах: ровно одно меню',
      (tester) async {
    final controller = await pumpEditor(tester);

    // Второе слово первой строки.
    await tester.longPressAt(const Offset(120, 20));
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.selectedText, 'bravo');
    expect(item('Copy'), findsOneWidget);

    // Другое место — второе слово ДРУГОЙ строки: нужен полный цикл
    // «выделить заново → показать заново», то есть второй проход через `show`
    // с уже живым оверлеем от первого. Пауза между жестами — чтобы второй
    // longPress не склеился с первым в double-tap
    // (`_code_selection.dart:178-181`, окно `kDoubleTapTimeout`).
    await tester.pump(const Duration(milliseconds: 700));
    await tester.longPressAt(const Offset(40, 36));
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.selectedText, 'second',
        reason: 'второй долгий тап не выделил слово на второй строке');

    expect(item('Copy').evaluate().length, 1,
        reason: 'на экране не ровно одно меню — оверлей утёк');
    expect(item('Select all').evaluate().length, 1);
  });

  testWidgets(
      '§521 подмена экземпляра контроллера меню на живом редакторе '
      'не оставляет висячий оверлей', (tester) async {
    // Прямая репродукция скриншота владельца (три меню сразу) и то, ЧЕМ
    // именно §521 отличается от §517. §517 научил один экземпляр не плодить
    // оверлеи; здесь экземпляров ДВА, и второй физически не может снять
    // запись первого — у него `_entry == null`.
    //
    // Почему это был не гипотетический случай: `LxCodeEditor` был
    // `StatelessWidget` и собирал `LxSelectionToolbarController()` прямо в
    // `build()`. re_editor читает `widget.toolbarController` в момент показа
    // (`code_editor.dart:395,409`), а в `didUpdateWidget` (`:447-490`) это
    // поле не сверяет и старому контроллеру `hide()` не зовёт. Любой
    // `setState` родителя (`config_screen`: `_loading`/`_readOnly`; мастер:
    // поля формы) подменял экземпляр.
    //
    // Тест держит `CodeEditor` напрямую — так подмена видна детерминированно,
    // без зависимости от порядка кадров внутри жеста. Инвариант фикса:
    // экземпляр один на весь срок жизни редактора, поэтому подменить его
    // снаружи больше нечем — за это и отвечает `_LxCodeEditorState`.
    final controller = CodeLineEditingController.fromText(text);
    addTearDown(controller.dispose);
    final first = LxSelectionToolbarController();
    final second = LxSelectionToolbarController();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    late StateSetter setOuter;
    var useSecond = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(builder: (context, setState) {
          setOuter = setState;
          return SizedBox(
            width: 400,
            height: 300,
            child: CodeEditor(
              controller: controller,
              toolbarController: useSecond ? second : first,
            ),
          );
        }),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));

    await tester.longPressAt(const Offset(40, 20));
    await tester.pump(const Duration(milliseconds: 400));
    expect(item('Copy'), findsOneWidget);
    expect(first.isShown, isTrue);

    // Подмена экземпляра, затем новый показ уже через второй.
    setOuter(() => useSecond = true);
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.longPressAt(const Offset(120, 20));
    await tester.pump(const Duration(milliseconds: 400));

    // Вот он, дефект: на экране ДВА меню, и первый экземпляр всё ещё держит
    // свою запись. На `StatelessWidget`-версии `LxCodeEditor` это и копилось.
    expect(item('Copy').evaluate().length, 2,
        reason: 'репродукция сломалась: подмена экземпляра больше не течёт, '
            'значит тест ниже проверяет не то');
    expect(first.isShown && second.isShown, isTrue);

    // Фикс: этот экземпляр теперь недосягаем снаружи — им владеет
    // `_LxCodeEditorState`, он один на весь срок жизни редактора. Проверка
    // самого `LxCodeEditor` под подменяющим родителем — в тесте ниже.
  });

  testWidgets('§521 setState родителя при открытом меню не плодит оверлеи',
      (tester) async {
    // Тот же сценарий, но через `LxCodeEditor`: родитель дёргает `setState`
    // (как `config_screen` на `_loading`/`_readOnly` и мастер на полях формы),
    // и виджет пересобирается с открытым меню. `State` обязан выжить, а с ним
    // и единственный контроллер меню.
    final controller = CodeLineEditingController.fromText(text);
    addTearDown(controller.dispose);
    late StateSetter setOuter;
    var bump = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(builder: (context, setState) {
          setOuter = setState;
          return SizedBox(
            width: 400,
            height: 300,
            // Меняется только не влияющий на идентичность параметр.
            child: LxCodeEditor(controller: controller, hint: 'hint $bump'),
          );
        }),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));

    await tester.longPressAt(const Offset(40, 20));
    await tester.pump(const Duration(milliseconds: 400));
    expect(item('Copy'), findsOneWidget);

    for (var i = 0; i < 3; i++) {
      setOuter(() => bump++);
      await tester.pump(const Duration(milliseconds: 30));
      await tester.pump(const Duration(milliseconds: 700));
      await tester.longPressAt(Offset(40 + 40.0 * i, 36));
      await tester.pump(const Duration(milliseconds: 400));
      expect(item('Copy').evaluate().length, lessThanOrEqualTo(1),
          reason: 'после setState родителя меню размножились — дефект §521');
    }
  });

  testWidgets('§521 скролл при открытом меню прячет меню', (tester) async {
    await pumpEditor(tester);
    await longPressWord(tester);
    expect(item('Copy'), findsOneWidget);

    // Выбран вариант «прятать»: следовать за скроллом оверлей не должен —
    // anchors посчитаны в глобальных координатах на момент показа.
    await tester.drag(find.byType(CodeEditor), const Offset(0, -40));
    await tester.pump(const Duration(milliseconds: 100));

    expect(item('Copy'), findsNothing, reason: 'меню уехало вместе со скроллом');
  });

  testWidgets('§521 уход с экрана при открытом меню: без исключений',
      (tester) async {
    final controller = CodeLineEditingController.fromText(text);
    addTearDown(controller.dispose);
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: nav,
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => Scaffold(
                body: SizedBox(
                  width: 400,
                  height: 300,
                  child: LxCodeEditor(controller: controller),
                ),
              ),
            )),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    // Транзишн маршрута — несколько кадров; `pumpAndSettle` тут нельзя
    // (анимация каретки редактора), поэтому прокручиваем кадры вручную.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(CodeEditor), findsOneWidget,
        reason: 'маршрут с редактором не открылся');

    // Координаты — от левого верхнего угла САМОГО редактора: на втором
    // маршруте он стоит не в начале экрана, абсолютные (40,20) промахиваются
    // мимо текста и меню не появляется вовсе.
    final origin = tester.getTopLeft(find.byType(CodeEditor));
    await tester.longPressAt(origin + const Offset(40, 20));
    await tester.pump(const Duration(milliseconds: 400));
    expect(item('Copy'), findsOneWidget, reason: 'меню не показалось');

    // Уход с маршрута при живом оверлее. Оверлей живёт в root-overlay и
    // переживает уход поддерева — без `deactivate`/`dispose` здесь либо
    // «setState after dispose», либо меню остаётся поверх прошлого экрана.
    nav.currentState!.pop();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull,
        reason: 'исключение при снятии OverlayEntry на уходе с экрана');
    expect(item('Copy'), findsNothing,
        reason: 'меню осталось поверх предыдущего экрана');
  });
}
