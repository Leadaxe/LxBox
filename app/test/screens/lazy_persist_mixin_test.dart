import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/screens/lazy_persist_mixin.dart';
import 'package:lxbox/services/settings_storage.dart';

/// §085 R4 / §107 — widget tests для LazyPersistMixin (staging core).
///
/// §107: markDirty стартует stageChanges сразу (буфер в _cache без диска);
/// dispose/paused — повторный stage (safety-net) + flushToDisk. В тестах
/// probe не трогает SettingsStorage (`_cache == null`) → flushToDisk no-op,
/// тесты герметичны.
class _Probe extends StatefulWidget {
  const _Probe({required this.controller, required this.onStage});
  final SubscriptionController controller;
  final VoidCallback onStage;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe>
    with WidgetsBindingObserver, LazyPersistMixin<_Probe> {
  @override
  SubscriptionController get lazyController => widget.controller;
  @override
  Future<void> stageChanges() async => widget.onStage();
  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  testWidgets('markDirty sets configDirty + pending sync, stage стартует',
      (tester) async {
    final ctrl = SubscriptionController();
    var staged = 0;
    await tester.pumpWidget(MaterialApp(
      home: _Probe(controller: ctrl, onStage: () => staged++),
    ));
    final state = tester.state<_ProbeState>(find.byType(_Probe));
    expect(state.hasPendingChanges, false);
    expect(ctrl.configDirty, false);

    state.markDirty();
    expect(state.hasPendingChanges, true);
    expect(ctrl.configDirty, true, reason: 'configDirty sync на markDirty');
    // `configDirty=` пишет в AppLog, а тот throttl'ит notifyListeners
    // 16-мс таймером (app_log.dart `_notifyWindow`). Голый pump() окно не
    // закрывает → таймер переживает тест и роняет его на !timersPending.
    await tester.pump(const Duration(milliseconds: 20));
    expect(staged, 1, reason: '§107: буфер staged в момент мутации');
  });

  testWidgets('§107: каждая мутация re-stage\'ит буфер', (tester) async {
    final ctrl = SubscriptionController();
    var staged = 0;
    await tester.pumpWidget(MaterialApp(
      home: _Probe(controller: ctrl, onStage: () => staged++),
    ));
    final state = tester.state<_ProbeState>(find.byType(_Probe));
    state.markDirty();
    state.markDirty();
    await tester.pump();
    expect(staged, 2, reason: 'два markDirty → два stage');
  });

  // §219 — этот набор проверяет КОНТРАКТ mixin'а (когда/сколько раз зовётся
  // stageChanges), а не фактическую запись на диск: flushToDisk — no-op в
  // тестах без инициализированного SettingsStorage._cache. Реальную запись
  // покрывают интеграционные storage-тесты. Разделение слоёв намеренное.
  testWidgets('flush on dispose когда pending (stage safety-net)',
      (tester) async {
    final ctrl = SubscriptionController();
    var staged = 0;
    await tester.pumpWidget(MaterialApp(
      home: _Probe(controller: ctrl, onStage: () => staged++),
    ));
    tester.state<_ProbeState>(find.byType(_Probe)).markDirty();

    // unmount → dispose → flush (await staging последней мутации + flushToDisk)
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    // §338 — dispose-flush НЕ перезапускает stageChanges: typed-саверы внутри
    // staging зовут markConfigDirty, и повторный вызов переподнимал флаг уже
    // после того, как rebuild его погасил. Теперь просто await последнего.
    expect(staged, 1, reason: 'stage только на markDirty, dispose лишь ждёт');
  });

  testWidgets('§338: dispose-flush НЕ переподнимает configDirty после rebuild',
      (tester) async {
    final ctrl = SubscriptionController();
    ctrl.configDirty = false; // статик — сброс от соседних тестов
    var staged = 0;
    await tester.pumpWidget(MaterialApp(
      home: _Probe(
          controller: ctrl,
          // как настоящие stageChanges: typed-saver внутри зовёт markConfigDirty
          onStage: () {
            staged++;
            SettingsStorage.markConfigDirty();
          }),
    ));
    tester.state<_ProbeState>(find.byType(_Probe)).markDirty();
    await tester.pump(const Duration(milliseconds: 20));
    expect(ctrl.configDirty, true);

    // Быстрая пересборка на возврате к home погасила флаг ДО dispose экрана
    // (exit-анимация ~300мс) — воспроизводим гонку.
    ctrl.configDirty = false;

    // dispose → flush. Раньше: повторный stageChanges → markConfigDirty →
    // флаг снова true → вечная синяя плашка при актуальном конфиге.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump(const Duration(milliseconds: 20));
    expect(ctrl.configDirty, false,
        reason: 'dispose-flush не должен трогать флаг — rebuild уже всё съел');
    expect(staged, 1);
  });

  testWidgets('НЕ flush на dispose если нет pending', (tester) async {
    final ctrl = SubscriptionController();
    var staged = 0;
    await tester.pumpWidget(MaterialApp(
      home: _Probe(controller: ctrl, onStage: () => staged++),
    ));
    // без markDirty
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    expect(staged, 0, reason: 'idempotent: clean exit без write');
  });

  testWidgets('flush на AppLifecycleState.paused', (tester) async {
    final ctrl = SubscriptionController();
    var staged = 0;
    await tester.pumpWidget(MaterialApp(
      home: _Probe(controller: ctrl, onStage: () => staged++),
    ));
    final state = tester.state<_ProbeState>(find.byType(_Probe));
    state.markDirty();
    // 20мс — закрыть 16мс-окно AppLog-throttle (§338-трассер в configDirty=
    // пишет лог; голый pump() оставил бы висящий таймер → !timersPending).
    await tester.pump(const Duration(milliseconds: 20));
    expect(staged, 1);
    state.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump(const Duration(milliseconds: 20));
    // §338 — flush ждёт staging мутации, не перезапуская его (см. dispose-тест).
    expect(staged, 1, reason: 'flush на paused не re-stage\'ит');
    // повторный paused — idempotent (pending уже сброшен)
    state.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump(const Duration(milliseconds: 20));
    expect(staged, 1, reason: 'idempotent — второй paused не пишет');
  });
}
