import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/screens/lazy_persist_mixin.dart';

/// §085 R4 — widget tests для LazyPersistMixin (lazy write-on-exit core).
/// Раньше lazy-persist логика была не покрыта (дублировалась по 4 экранам).

class _Probe extends StatefulWidget {
  const _Probe({required this.controller, required this.onPersist});
  final SubscriptionController controller;
  final VoidCallback onPersist;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe>
    with WidgetsBindingObserver, LazyPersistMixin<_Probe> {
  @override
  SubscriptionController get lazyController => widget.controller;
  @override
  Future<void> persistChanges() async => widget.onPersist();
  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  testWidgets('markDirty sets configDirty + pending sync', (tester) async {
    final ctrl = SubscriptionController();
    await tester.pumpWidget(MaterialApp(
      home: _Probe(controller: ctrl, onPersist: () {}),
    ));
    final state = tester.state<_ProbeState>(find.byType(_Probe));
    expect(state.hasPendingChanges, false);
    expect(ctrl.configDirty, false);

    state.markDirty();
    expect(state.hasPendingChanges, true);
    expect(ctrl.configDirty, true, reason: 'configDirty sync на markDirty');
  });

  testWidgets('flush on dispose когда pending', (tester) async {
    final ctrl = SubscriptionController();
    var persisted = 0;
    await tester.pumpWidget(MaterialApp(
      home: _Probe(controller: ctrl, onPersist: () => persisted++),
    ));
    tester.state<_ProbeState>(find.byType(_Probe)).markDirty();

    // unmount → dispose → flush
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    expect(persisted, 1, reason: 'persistChanges вызван на dispose');
  });

  testWidgets('НЕ flush на dispose если нет pending', (tester) async {
    final ctrl = SubscriptionController();
    var persisted = 0;
    await tester.pumpWidget(MaterialApp(
      home: _Probe(controller: ctrl, onPersist: () => persisted++),
    ));
    // без markDirty
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    expect(persisted, 0, reason: 'idempotent: clean exit без write');
  });

  testWidgets('flush на AppLifecycleState.paused', (tester) async {
    final ctrl = SubscriptionController();
    var persisted = 0;
    await tester.pumpWidget(MaterialApp(
      home: _Probe(controller: ctrl, onPersist: () => persisted++),
    ));
    final state = tester.state<_ProbeState>(find.byType(_Probe));
    state.markDirty();
    state.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump();
    expect(persisted, 1, reason: 'flush на paused (app backgrounded)');
    // повторный paused — idempotent (pending уже сброшен)
    state.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump();
    expect(persisted, 1, reason: 'idempotent — второй paused не пишет');
  });
}
