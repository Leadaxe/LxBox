// Фича 478 — single-flight прогона страховки (ревью №1).
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/core_reject/core_reject_guard.dart';
import 'package:lxbox/services/core_reject/core_reject_state.dart';

void main() {
  setUp(() => CoreRejectState.I.resetForTest());

  test('guardActive true на signalStart', () {
    CoreRejectState.I.beginRun();
    expect(CoreRejectState.I.guardActive, isTrue);
    expect(CoreRejectState.I.checking, isFalse);
  });

  test('queuePromptAnswer до askPrompt отдаёт keep', () async {
    CoreRejectState.I.queuePromptAnswer(CoreRejectPrompt.keepChecking);
    final answer = await CoreRejectState.I.askPrompt(10);
    expect(answer, CoreRejectPrompt.keepChecking);
    expect(CoreRejectState.I.promptPending, isFalse);
  });

  test('очередь keep переживает beginRun (Debug API до старта прогона)',
      () async {
    CoreRejectState.I.queuePromptAnswer(CoreRejectPrompt.keepChecking);
    CoreRejectState.I.beginRun();
    final answer = await CoreRejectState.I.askPrompt(10);
    expect(answer, CoreRejectPrompt.keepChecking);
  });

  test('finish сбрасывает неиспользованную очередь keep', () async {
    CoreRejectState.I.queuePromptAnswer(CoreRejectPrompt.keepChecking);
    CoreRejectState.I.beginRun();
    CoreRejectState.I.finish(const CoreRejectRun(
      outcome: CoreRejectOutcome.startedClean,
      rounds: 0,
    ));
    final pending = CoreRejectState.I.askPrompt(10);
    expect(CoreRejectState.I.promptPending, isTrue);
    CoreRejectState.I.answerPrompt(CoreRejectPrompt.stop);
    expect(await pending, CoreRejectPrompt.stop);
  });
}
