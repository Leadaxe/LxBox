import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/widgets/lx_code_editor.dart';

/// §649 — кому жест на поле редактора: правило по направлению и
/// распознаватель platform view против drag вкладок / страницы в арене
/// (`testWidgets` — часы сэмплинга жестов есть только внутри теста).
void main() {
  group('lxEditorOwnsDrag', () {
    bool owns(
      Offset d, {
      bool canScrollX = false,
      bool scrollable = true,
      bool scrollTop = false,
      bool scrollBottom = false,
    }) => lxEditorOwnsDrag(
      d,
      canScrollX: canScrollX,
      scrollable: scrollable,
      scrollTop: scrollTop,
      scrollBottom: scrollBottom,
    );

    test('вбок — редактору, только если есть куда вбок', () {
      expect(owns(const Offset(20, 5), canScrollX: true), isTrue);
      expect(owns(const Offset(-20, 5), canScrollX: true), isTrue);
      expect(owns(const Offset(20, 5)), isFalse);
    });

    test('вертикально — по краю в сторону движения', () {
      // Палец вниз — к началу текста.
      expect(owns(const Offset(0, 20)), isTrue);
      expect(owns(const Offset(0, 20), scrollTop: true), isFalse);
      expect(owns(const Offset(0, 20), scrollBottom: true), isTrue);
      // Палец вверх — к концу текста.
      expect(owns(const Offset(0, -20)), isTrue);
      expect(owns(const Offset(0, -20), scrollBottom: true), isFalse);
      expect(owns(const Offset(0, -20), scrollTop: true), isTrue);
    });

    test('текст помещается — вертикаль странице', () {
      expect(owns(const Offset(0, 20), scrollable: false), isFalse);
      expect(owns(const Offset(0, -20), scrollable: false), isFalse);
    });
  });

  group('LxEditorDragRecognizer в арене', () {
    var pointer = 100;

    /// Касание в (100, 100), сдвиг шагами [step] до [steps] раз. Возвращает
    /// (редактор принял, внешний drag стартовал).
    (bool, bool) run({
      required bool atDown,
      required bool ownsDrag,
      required Offset step,
      required DragGestureRecognizer outer,
      int steps = 3,
    }) {
      final arena = GestureBinding.instance.gestureArena;
      final router = GestureBinding.instance.pointerRouter;
      final p = pointer++;
      var accepted = false;
      var started = false;
      final editor = _Probe(
        onAccept: () => accepted = true,
        takesAtDown: () => atDown,
        takesDrag: (_) => ownsDrag,
        slop: () => kTouchSlop,
      );
      outer.onStart = (_) => started = true;
      var pos = const Offset(100, 100);
      final down = PointerDownEvent(pointer: p, position: pos);
      editor.addPointer(down);
      outer.addPointer(down);
      router.route(down);
      arena.close(p);
      for (var i = 0; i < steps; i++) {
        pos += step;
        router.route(
          PointerMoveEvent(
            pointer: p,
            position: pos,
            delta: step,
            buttons: kPrimaryButton,
          ),
        );
      }
      final up = PointerUpEvent(pointer: p, position: pos);
      router.route(up);
      arena.sweep(p);
      editor.dispose();
      outer.dispose();
      return (accepted, started);
    }

    testWidgets('выделение — редактор берёт касание сразу', (tester) async {
      final r = run(
        atDown: true,
        ownsDrag: false,
        step: const Offset(10, 0),
        outer: HorizontalDragGestureRecognizer(),
      );
      expect(r, (true, false));
    });

    testWidgets('вбок есть куда — редактор опережает свайп вкладок', (
      tester,
    ) async {
      final r = run(
        atDown: false,
        ownsDrag: true,
        step: const Offset(10, 1),
        outer: HorizontalDragGestureRecognizer(),
      );
      expect(r, (true, false));
    });

    testWidgets('вбок некуда — свайп у вкладок', (tester) async {
      final r = run(
        atDown: false,
        ownsDrag: false,
        step: const Offset(10, 1),
        outer: HorizontalDragGestureRecognizer(),
      );
      expect(r, (false, true));
    });

    testWidgets('вертикаль у края — прокрутка у страницы', (tester) async {
      final r = run(
        atDown: false,
        ownsDrag: false,
        step: const Offset(0, 10),
        outer: VerticalDragGestureRecognizer(),
      );
      expect(r, (false, true));
    });

    testWidgets('вертикаль есть куда — редактору', (tester) async {
      final r = run(
        atDown: false,
        ownsDrag: true,
        step: const Offset(0, -10),
        outer: VerticalDragGestureRecognizer(),
      );
      expect(r, (true, false));
    });
  });
}

class _Probe extends LxEditorDragRecognizer {
  _Probe({
    required this.onAccept,
    required super.takesAtDown,
    required super.takesDrag,
    required super.slop,
  });

  final void Function() onAccept;

  @override
  void acceptGesture(int pointer) {
    onAccept();
    super.acceptGesture(pointer);
  }
}
