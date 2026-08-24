// ignore_for_file: depend_on_referenced_packages

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/probe/chain_layer_probe.dart';
import 'package:lxbox/widgets/chain_positions_block.dart';

/// Прогон-заглушка: отдаёт заданный отчёт (или бросает) и позволяет держать
/// прогон незавершённым, чтобы проверить busy-состояние без сна.
class _StubProbe extends ChainLayerProbe {
  _StubProbe({this.report, this.error, this.gate});

  final ChainProbeReport? report;
  final ChainProbeUnavailable? error;

  /// Пока не завершён — прогон «идёт». Тест завершает его сам, вместо того
  /// чтобы ждать фиксированный интервал.
  final Completer<void>? gate;

  int runs = 0;
  bool cancelled = false;

  @override
  void cancel() => cancelled = true;

  @override
  Future<ChainProbeReport> run(
    String chainTag, {
    required List<String> hops,
    String? url,
    int? timeoutMs,
  }) async {
    runs++;
    if (gate != null) await gate!.future;
    if (error != null) throw error!;
    return report!;
  }
}

/// §394 — блок «Chain positions»: ЛОГИКА состояний (что показано при каком
/// отчёте), без проверки вёрстки и подписей-констант.
void main() {
  ChainProbeReport reportOf(List<ChainLayerResult> layers) => ChainProbeReport(
        chainTag: 'chain-1',
        layers: layers,
        url: 'https://probe.example/generate_204',
        timeoutMs: 4000,
      );

  Future<void> pump(
    WidgetTester tester,
    ChainLayerProbe Function() factory, {
    List<String> hops = const ['warp', 'al-france', 'masque'],
  }) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ChainPositionsBlock(
              chainTag: 'chain-1',
              hops: hops,
              probeFactory: factory,
            ),
          ),
        ),
      ));

  /// Единственная кнопка блока — она же «пробить»/«пробить снова».
  final probeButton = find.byType(OutlinedButton);

  testWidgets('до прогона: позиции видны, замеров нет', (tester) async {
    await pump(tester, () => _StubProbe(report: reportOf(const [])));
    for (final tag in ['warp', 'al-france', 'masque']) {
      expect(find.text(tag), findsOneWidget);
    }
    // Прочерк на каждую позицию — замера ещё не было. Это СОСТОЯНИЕ («цифр
    // нет»), а не проверка подписи: пустая строка вместо прочерка выглядела
    // бы как «замер прошёл и дал ничего».
    expect(find.text('—'), findsNWidgets(3));
  });

  testWidgets('успешный прогон: у каждой позиции появился замер',
      (tester) async {
    await pump(
      tester,
      () => _StubProbe(
          report: reportOf(const [
        ChainLayerResult(
            pos: 0, tag: 'warp', probeTag: 'chain-1#0', cumulativeMs: 127),
        ChainLayerResult(
            pos: 1,
            tag: 'al-france',
            probeTag: 'chain-1#1',
            cumulativeMs: 316),
        ChainLayerResult(
            pos: 2, tag: 'masque', probeTag: 'chain-1#2', cumulativeMs: 675),
      ])),
    );
    await tester.tap(probeButton);
    await tester.pumpAndSettle();

    // Прочерков не осталось: измерены все три. Сами цифры и дельты — предмет
    // теста сервиса (`chain_layer_probe_test`), не вёрстки.
    expect(find.text('—'), findsNothing);
    expect(find.text('error'), findsNothing);
    expect(find.text('not reached'), findsNothing);
  });

  testWidgets('обрыв слоя: ошибка вместо мс, следующие — not reached',
      (tester) async {
    await pump(
      tester,
      () => _StubProbe(
          report: reportOf(const [
        ChainLayerResult(
            pos: 0, tag: 'warp', probeTag: 'chain-1#0', cumulativeMs: 127),
        ChainLayerResult(
            pos: 1,
            tag: 'al-france',
            probeTag: 'chain-1#1',
            error: 'position 1 (al-france): dial: i/o timeout'),
        ChainLayerResult(
            pos: 2, tag: 'masque', probeTag: 'chain-1#2', notReached: true),
      ])),
    );
    await tester.tap(probeButton);
    await tester.pumpAndSettle();

    expect(find.text('127 ms'), findsOneWidget);
    expect(find.text('error'), findsOneWidget);
    expect(find.text('not reached'), findsOneWidget);
    // Текст ЯДРА показывается целиком и не переписывается.
    expect(find.text('position 1 (al-france): dial: i/o timeout'),
        findsOneWidget);
  });

  testWidgets('VPN выключен: объяснение вместо замеров, строки остаются',
      (tester) async {
    await pump(tester,
        () => _StubProbe(error: const ChainProbeUnavailable('vpn_down')));
    await tester.tap(probeButton);
    await tester.pumpAndSettle();

    expect(
        find.textContaining('Start the VPN to probe this chain'), findsOneWidget);
    // Состав маршрута виден и без замеров — он не зависит от туннеля.
    expect(find.text('warp'), findsOneWidget);
    expect(find.text('—'), findsNWidgets(3));
  });

  testWidgets('busy: кнопка заперта на время прогона и отпускается после',
      (tester) async {
    final gate = Completer<void>();
    final stub = _StubProbe(report: reportOf(const []), gate: gate);
    await pump(tester, () => stub);

    await tester.tap(probeButton);
    await tester.pump();
    expect(tester.widget<OutlinedButton>(probeButton).onPressed, isNull);
    // Повторный тап во время прогона второго прогона НЕ запускает.
    await tester.tap(probeButton, warnIfMissed: false);
    await tester.pump();
    expect(stub.runs, 1);

    gate.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<OutlinedButton>(probeButton).onPressed, isNotNull);
  });

  testWidgets('повторный прогон запускается заново', (tester) async {
    final stub = _StubProbe(report: reportOf(const [
      ChainLayerResult(
          pos: 0, tag: 'warp', probeTag: 'chain-1#0', cumulativeMs: 10),
    ]));
    await pump(tester, () => stub);

    await tester.tap(probeButton);
    await tester.pumpAndSettle();
    await tester.tap(probeButton);
    await tester.pumpAndSettle();
    expect(stub.runs, 2);
  });

  testWidgets('уход с экрана во время прогона отменяет его', (tester) async {
    final gate = Completer<void>();
    final stub = _StubProbe(report: reportOf(const []), gate: gate);
    await pump(tester, () => stub);
    await tester.tap(probeButton);
    await tester.pump();

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(stub.cancelled, isTrue);
    gate.complete();
    await tester.pumpAndSettle();
  });
}
