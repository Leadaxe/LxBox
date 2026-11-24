import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/vpn/cc_channel.dart';
import 'package:lxbox/widgets/pool_view_dialog.dart';

/// §759 — попап «View pool»: карантин, счётчики слота и шапка состояния
/// самовосстановления (ядро SPEC 138). Нулевое состояние ничего не рисует.
void main() {
  Future<void> open(WidgetTester tester, CcPoolState state) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => TextButton(
          onPressed: () => showPoolDialog(ctx,
              autoTag: 'vpn-1-auto',
              title: 'Auto',
              fetch: (_) async => state),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('здоровый пул — без шапки и вторых строк', (tester) async {
    await open(
        tester,
        const CcPoolState(slots: [
          CcPoolSlot(slot: 0, tag: 'node-de', delay: 12),
          CcPoolSlot(slot: 1, tag: 'node-fi', delay: 0),
        ]));
    expect(find.text('node-de'), findsOneWidget);
    expect(find.byKey(const ValueKey('pool-state-header')), findsNothing);
    expect(find.textContaining('quarantine'), findsNothing);
    expect(find.textContaining('conn'), findsNothing);
  });

  testWidgets('карантин, счётчики и шапка с остатком заморозки',
      (tester) async {
    await open(
        tester,
        const CcPoolState(
          shiftedKeys: 3,
          markedKeys: 1,
          frozen: true,
          frozenSeconds: 12,
          slots: [
            CcPoolSlot(
                slot: 0,
                tag: 'node-de',
                delay: 87,
                quarantined: true,
                connections: 40,
                confirmedFailures: 6),
            CcPoolSlot(slot: 1, tag: 'node-fi', delay: 20, connections: 7),
          ],
        ));
    expect(
        find.text('shifted keys: 3 · address problems: 1 · frozen for 12 s'),
        findsOneWidget);
    expect(find.text('quarantine · 40 conn · 6 fail'),
        findsOneWidget);
    expect(find.text('7 conn · 0 fail'), findsOneWidget);
    // Задержка узла в карантине остаётся на месте.
    expect(find.text('87 ms'), findsOneWidget);
  });

  testWidgets('заморозка без остатка — до конца проверки сети',
      (tester) async {
    await open(
        tester,
        const CcPoolState(frozen: true, slots: [
          CcPoolSlot(slot: 0, tag: 'node-de', delay: 12),
        ]));
    expect(find.text('frozen until the network check ends'), findsOneWidget);
  });
}
