import 'package:flutter_test/flutter_test.dart';

/// Один шаг ожидания экрана, который ждёт реального ввода-вывода (файлы
/// хранилища, изоляты) внутри fake-async зоны `testWidgets`.
///
/// Продолжение каждого `await` после реального I/O попадает в fake-зону
/// микрозадачей, а её снимает только `pump`. Цепочка из N последовательных
/// await требует N таких шагов. Прежний шаг «`runAsync` 10–20 мс + `pump`»
/// рисовал кадр на каждое звено, а кадр экрана дорог: крупный viewport и
/// индикатор загрузки, который планирует кадр каждый раз. Загрузка Routing
/// шла 79 шагов по ~100 мс.
///
/// Здесь звеньев на кадр [_hops]: реальному I/O даётся та же сумма живого
/// времени (по 2 мс), микрозадачи и таймеры fake-зоны снимаются
/// `binding.delayed` без кадра, в конце рисуется один кадр. Фиктивного времени
/// за шаг проходит [fakeTime] — столько же, сколько давал прежний
/// `pump(fakeTime)`.
Future<void> realIoStep(
  WidgetTester tester, {
  Duration fakeTime = Duration.zero,
}) async {
  final slice = fakeTime ~/ _hops;
  for (var j = 0; j < _hops; j++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)));
    await tester.binding.delayed(slice);
  }
  await tester.pump();
}

const _hops = 10;
