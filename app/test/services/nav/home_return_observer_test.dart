import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/nav/home_return_observer.dart';

/// §076F — возврат на главный: обработчик пересборки срабатывает ровно
/// тогда, когда после pop'а наверху оказывается корневой (home) маршрут,
/// и не срабатывает на pop'ах внутри стека настроек.
class _FakeRoute extends PageRoute<void> {
  _FakeRoute({required this.first});

  final bool first;

  @override
  bool get isFirst => first;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
          Animation<double> secondaryAnimation) =>
      const SizedBox.shrink();
}

void main() {
  late HomeReturnObserver observer;
  late int calls;

  setUp(() {
    observer = HomeReturnObserver();
    calls = 0;
    observer.setHandler(() => calls++);
  });

  test('pop на корневой маршрут → обработчик вызван', () {
    observer.didPop(_FakeRoute(first: false), _FakeRoute(first: true));
    expect(calls, 1);
  });

  test('pop внутри стека настроек → обработчик не вызван', () {
    observer.didPop(_FakeRoute(first: false), _FakeRoute(first: false));
    expect(calls, 0);
  });

  test('pop без предыдущего маршрута → обработчик не вызван', () {
    observer.didPop(_FakeRoute(first: false), null);
    expect(calls, 0);
  });

  test('цепочка pop-ов: срабатывает только финальный на home', () {
    observer.didPop(_FakeRoute(first: false), _FakeRoute(first: false));
    observer.didPop(_FakeRoute(first: false), _FakeRoute(first: true));
    expect(calls, 1);
  });

  test('clearHandler снимает обработчик; повторные set/clear безопасны', () {
    observer.clearHandler();
    observer.clearHandler();
    observer.didPop(_FakeRoute(first: false), _FakeRoute(first: true));
    expect(calls, 0);

    observer.setHandler(() => calls++);
    observer.setHandler(() => calls++);
    observer.didPop(_FakeRoute(first: false), _FakeRoute(first: true));
    expect(calls, 1, reason: 'один обработчик, а не два');
  });
}
