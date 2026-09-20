// Фича 478 — автомат страховки на поддельном клиенте ядра.
// Сценарии — раздел 5 спеки.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/core_reject_verdict.dart';
import 'package:lxbox/services/core_reject/core_reject_guard.dart';

/// Поддельное ядро: список узлов с тегами, каждый — годный либо негодный.
/// `realStart`/`check` отвечают отказом на ПЕРВЫЙ негодный из ещё не
/// выключенных — ровно как ядро, которое проверяет конфиг целиком.
class FakeCore implements CoreRejectHost {
  FakeCore({
    required this.tags,
    this.bad = const {},
    this.runOnlyBad = const {},
    this.prompt = CoreRejectPrompt.keepChecking,
    this.rebuildFails = false,
  });

  /// Все теги конфига в порядке сборки.
  final List<String> tags;

  /// Тег → текст отказа. Ловится и стартом, и `check`.
  final Map<String, String> bad;

  /// Тег → текст отказа, который ловит ТОЛЬКО реальный старт (`check` его
  /// пропускает) — редкая ошибка из раздела 3 спеки.
  final Map<String, String> runOnlyBad;

  final CoreRejectPrompt prompt;
  final bool rebuildFails;

  final disabledTags = <String>[];
  final reasons = <String, String>{};
  var realStarts = 0;
  var checks = 0;
  var rebuilds = 0;
  var prompts = 0;
  final progress = <(CoreRejectPhase, int, int)>[];

  /// Теги, ещё не выключенные.
  List<String> get _live =>
      tags.where((t) => !disabledTags.contains(t)).toList();

  String? _firstBad({required bool runOnly}) {
    for (final t in _live) {
      final r = bad[t] ?? (runOnly ? runOnlyBad[t] : null);
      if (r != null) return 'initialize outbound[${tags.indexOf(t)}] vless[$t]: $r';
    }
    return null;
  }

  @override
  Future<CoreAttempt> realStart() async {
    realStarts++;
    final e = _firstBad(runOnly: true);
    return e == null ? const CoreAttempt.accepted() : CoreAttempt.rejected(e);
  }

  @override
  Future<RebuiltConfig?> rebuild() async {
    rebuilds++;
    if (rebuildFails) return null;
    return RebuiltConfig(configJson: '{}', tags: _live.toSet());
  }

  @override
  Future<CoreAttempt> check(String configJson) async {
    checks++;
    final e = _firstBad(runOnly: false);
    return e == null ? const CoreAttempt.accepted() : CoreAttempt.rejected(e);
  }

  @override
  Future<CoreRejectNodeRef?> disableNode(String tag, String reason) async {
    if (!tags.contains(tag)) return null;
    disabledTags.add(tag);
    reasons[tag] = reason;
    return CoreRejectNodeRef(sourceId: 'test', nodeKey: tag);
  }

  @override
  Future<CoreRejectPrompt> askKeepChecking(int disabledCount) async {
    prompts++;
    return prompt;
  }

  @override
  void onProgress(
    CoreRejectPhase phase,
    int round, {
    List<DisabledNode> disabledNodes = const [],
  }) =>
      progress.add((phase, disabledNodes.length, round));
}

void main() {
  group('дерево ветвлений раздела 3', () {
    test('старт чистый → ни одного checkConfig, ни одной пересборки', () async {
      final core = FakeCore(tags: ['A', 'B', 'C']);
      final run = await CoreRejectGuard(core).run();

      expect(run.outcome, CoreRejectOutcome.startedClean);
      expect(core.realStarts, 1);
      expect(core.checks, 0);
      expect(core.rebuilds, 0);
      expect(run.disabled, isEmpty);
    });

    test('один негодный → старт, check чисто, старт; два реальных старта',
        () async {
      final core = FakeCore(
        tags: ['A', 'B', 'C'],
        bad: {'B': 'parse encryption: unknown encryption appearance'},
      );
      final run = await CoreRejectGuard(core).run();

      expect(run.outcome, CoreRejectOutcome.startedWithDisabled);
      expect(core.realStarts, 2, reason: 'сигнальный + финальный, третьего нет');
      expect(core.checks, 1);
      expect(core.disabledTags, ['B']);
      expect(core.reasons['B'],
          'parse encryption: unknown encryption appearance');
      expect(run.disabled.single.tag, 'B');
      expect(run.rounds, 1);
    });

    test('три негодных → три круга, один финальный старт', () async {
      final core = FakeCore(
        tags: ['A', 'B', 'C', 'D', 'E'],
        bad: {'B': 'bad b', 'C': 'bad c', 'E': 'bad e'},
      );
      final run = await CoreRejectGuard(core).run();

      expect(run.outcome, CoreRejectOutcome.startedWithDisabled);
      expect(core.disabledTags, ['B', 'C', 'E']);
      expect(core.realStarts, 2);
      // Первый негодный ловит сигнальный старт; остальные — круги check.
      expect(core.checks, 3, reason: 'два отказа check + один чистый');
      expect(run.rounds, 3);
      expect(run.disabled.map((d) => d.tag), ['B', 'C', 'E']);
    });

    test('ошибка не про узел → ошибка как сейчас, без автоматики', () async {
      final core = _ScriptedCore(
        starts: ['initialize inbound[0] tun: permission denied'],
      );
      final run = await CoreRejectGuard(core).run();

      expect(run.outcome, CoreRejectOutcome.failed);
      expect(run.error, 'initialize inbound[0] tun: permission denied');
      expect(core.checks, 0);
      expect(run.disabled, isEmpty);
    });

    test('тег не сопоставился с конфигом → без автоматики', () async {
      final core = FakeCore(tags: ['A']);
      // Ядро назвало тег, которого в конфиге нет (служебная запись).
      final scripted = _ScriptedCore(
        starts: ['initialize outbound[0] direct[direct-out]: boom'],
        tags: core.tags.toSet(),
      );
      final run = await CoreRejectGuard(scripted).run();

      expect(run.outcome, CoreRejectOutcome.failed);
      expect(scripted.checks, 0);
    });

    test('тот же тег назван повторно → цикл прерван (CANON §9.5)', () async {
      // Ядро упрямо называет A, а выключение его не убирает.
      final core = _StubbornCore();
      final run = await CoreRejectGuard(core).run();

      expect(run.outcome, CoreRejectOutcome.failed);
      expect(core.disabledTags, ['A'],
          reason: 'выключен ровно один раз, второго круга по нему нет');
      expect(run.rounds, 1);
    });
  });

  group('предел кругов и диалог', () {
    test('одиннадцать негодных → диалог; Keep checking доводит до конца',
        () async {
      final tags = [for (var i = 0; i < 15; i++) 'N$i'];
      final core = FakeCore(
        tags: tags,
        bad: {for (var i = 0; i < 11; i++) 'N$i': 'bad $i'},
        prompt: CoreRejectPrompt.keepChecking,
      );
      final run = await CoreRejectGuard(core).run();

      expect(core.prompts, 1, reason: 'предел снят до конца этого Start');
      expect(run.outcome, CoreRejectOutcome.startedWithDisabled);
      expect(core.disabledTags.length, 11);
      expect(run.disabled.length, 11);
    });

    test('Stop → VPN не поднят, выключенные остаются выключенными', () async {
      final tags = [for (var i = 0; i < 15; i++) 'N$i'];
      final core = FakeCore(
        tags: tags,
        bad: {for (var i = 0; i < 12; i++) 'N$i': 'bad $i'},
        prompt: CoreRejectPrompt.stop,
      );
      final run = await CoreRejectGuard(core).run();

      expect(run.outcome, CoreRejectOutcome.stoppedByUser);
      expect(core.realStarts, 1, reason: 'финального старта не было');
      // Предел считает КРУГИ check: вопрос встаёт после десятого. Выключенных
      // к этому моменту одиннадцать — узел сигнального старта плюс десять
      // кругов; число в диалоге берётся из счётчика выключенных.
      expect(core.disabledTags.length, 11);
      expect(run.disabled.length, 11);
      expect(run.rounds, 10);
    });

    test('ровно десять негодных — диалога нет', () async {
      final tags = [for (var i = 0; i < 12; i++) 'N$i'];
      final core = FakeCore(
        tags: tags,
        bad: {for (var i = 0; i < 10; i++) 'N$i': 'bad $i'},
      );
      final run = await CoreRejectGuard(core).run();

      expect(core.prompts, 0);
      expect(run.outcome, CoreRejectOutcome.startedWithDisabled);
      expect(core.disabledTags.length, 10);
    });

    test('предел настраиваемый — константа не зашита в автомат', () async {
      final tags = [for (var i = 0; i < 8; i++) 'N$i'];
      final core = FakeCore(
        tags: tags,
        bad: {for (var i = 0; i < 6; i++) 'N$i': 'bad $i'},
        prompt: CoreRejectPrompt.stop,
      );
      final run = await CoreRejectGuard(core, roundLimit: 3).run();

      expect(core.prompts, 1);
      expect(run.outcome, CoreRejectOutcome.stoppedByUser);
    });
  });

  group('финальный старт', () {
    test('run-only ошибка → узел выключен, третьего старта нет, ошибка видна',
        () async {
      final core = FakeCore(
        tags: ['A', 'B', 'C'],
        bad: {'B': 'bad b'},
        runOnlyBad: {'C': 'runtime only'},
      );
      final run = await CoreRejectGuard(core).run();

      expect(run.outcome, CoreRejectOutcome.failed);
      expect(run.error, contains('runtime only'));
      expect(core.realStarts, 2, reason: 'третьего старта нет');
      expect(core.disabledTags, ['B', 'C'],
          reason: 'названный финальным стартом узел тоже выключен');
    });
  });

  group('вырожденные случаи', () {
    test('мост недоступен на сигнальном старте → обычная ошибка', () async {
      final core = _ScriptedCore(starts: const [null]);
      final run = await CoreRejectGuard(core).run();

      expect(run.outcome, CoreRejectOutcome.failed);
      expect(core.checks, 0, reason: 'проверять нечем');
    });

    test('пересобрать нечем → конец без финального старта', () async {
      final core = FakeCore(
        tags: ['A', 'B'],
        bad: {'B': 'bad b'},
        rebuildFails: true,
      );
      final run = await CoreRejectGuard(core).run();

      expect(run.outcome, CoreRejectOutcome.failed);
      expect(core.realStarts, 1);
    });

    test('фазы приходят в порядке дерева', () async {
      final core = FakeCore(tags: ['A', 'B'], bad: {'B': 'bad b'});
      await CoreRejectGuard(core).run();

      final phases = core.progress.map((p) => p.$1).toList();
      expect(phases.first, CoreRejectPhase.signalStart);
      expect(phases, contains(CoreRejectPhase.checking));
      expect(phases, contains(CoreRejectPhase.finalStart));
      expect(phases.last, CoreRejectPhase.done);
      expect(phases, isNot(contains(CoreRejectPhase.awaitingPrompt)));
    });

    test('отмена после успешного check не поднимает VPN', () async {
      final core = _DeferredCheckCore(
        tags: ['A', 'B'],
        bad: {'A': 'bad a'},
      );
      final guard = CoreRejectGuard(core);
      final fut = guard.run();
      await core.checkGate.future;
      guard.cancel();
      final run = await fut;

      expect(run.outcome, CoreRejectOutcome.stoppedByUser);
      expect(core.realStarts, 1, reason: 'финального старта не было');
    });

    test('отмена во время цикла → stoppedByUser с уже выключенными', () async {
      final tags = [for (var i = 0; i < 6; i++) 'N$i'];
      final core = FakeCore(
        tags: tags,
        bad: {for (var i = 0; i < 5; i++) 'N$i': 'bad $i'},
      );
      final guard = CoreRejectGuard(core);
      // Отмена сразу после первого выключения.
      core.progress.clear();
      final fut = guard.run();
      guard.cancel();
      final run = await fut;

      expect(run.outcome, CoreRejectOutcome.stoppedByUser);
      expect(core.realStarts, 1);
    });
  });
}

/// Ядро, у которого `check` ждёт внешний сигнал — для отмены после check.
class _DeferredCheckCore implements CoreRejectHost {
  _DeferredCheckCore({required this.tags, required this.bad});

  final List<String> tags;
  final Map<String, String> bad;
  final checkGate = Completer<void>();
  final disabledTags = <String>[];
  var realStarts = 0;

  @override
  Future<CoreAttempt> realStart() async {
    realStarts++;
    if (realStarts == 1) {
      final t = tags.firstWhere((t) => bad.containsKey(t));
      return CoreAttempt.rejected('initialize outbound[0] vless[$t]: ${bad[t]}');
    }
    return const CoreAttempt.accepted();
  }

  @override
  Future<RebuiltConfig?> rebuild() async =>
      RebuiltConfig(configJson: '{}', tags: tags.toSet());

  @override
  Future<CoreAttempt> check(String configJson) async {
    if (!checkGate.isCompleted) checkGate.complete();
    await Future<void>.delayed(Duration.zero);
    return const CoreAttempt.accepted();
  }

  @override
  Future<CoreRejectNodeRef?> disableNode(String tag, String reason) async {
    disabledTags.add(tag);
    return CoreRejectNodeRef(sourceId: 'test', nodeKey: tag);
  }

  @override
  Future<CoreRejectPrompt> askKeepChecking(int disabledCount) async =>
      CoreRejectPrompt.stop;

  @override
  void onProgress(
    CoreRejectPhase phase,
    int round, {
    List<DisabledNode> disabledNodes = const [],
  }) {}
}

/// Клиент со сценарием ответов: `null` — мост недоступен.
class _ScriptedCore implements CoreRejectHost {
  _ScriptedCore({this.starts = const [], this.tags = const {'A', 'B'}});

  final List<String?> starts;
  final Set<String> tags;
  var _i = 0;
  var checks = 0;
  final disabledTags = <String>[];

  @override
  Future<CoreAttempt> realStart() async {
    final e = _i < starts.length ? starts[_i++] : null;
    if (e == null) return const CoreAttempt.unavailable();
    return CoreAttempt.rejected(e);
  }

  @override
  Future<RebuiltConfig?> rebuild() async =>
      RebuiltConfig(configJson: '{}', tags: tags);

  @override
  Future<CoreAttempt> check(String configJson) async {
    checks++;
    return const CoreAttempt.accepted();
  }

  @override
  Future<CoreRejectNodeRef?> disableNode(String tag, String reason) async {
    disabledTags.add(tag);
    return CoreRejectNodeRef(sourceId: 'test', nodeKey: tag);
  }

  @override
  Future<CoreRejectPrompt> askKeepChecking(int n) async =>
      CoreRejectPrompt.stop;

  @override
  void onProgress(
    CoreRejectPhase phase,
    int round, {
    List<DisabledNode> disabledNodes = const [],
  }) {}
}

/// Ядро, упрямо называющее один и тот же тег: выключение его не лечит.
class _StubbornCore implements CoreRejectHost {
  final disabledTags = <String>[];
  var checks = 0;

  static const _err = 'initialize outbound[0] vless[A]: bad';

  @override
  Future<CoreAttempt> realStart() async => const CoreAttempt.rejected(_err);

  @override
  Future<RebuiltConfig?> rebuild() async =>
      const RebuiltConfig(configJson: '{}', tags: {'A', 'B'});

  @override
  Future<CoreAttempt> check(String configJson) async {
    checks++;
    return const CoreAttempt.rejected(_err);
  }

  @override
  Future<CoreRejectNodeRef?> disableNode(String tag, String reason) async {
    disabledTags.add(tag);
    return CoreRejectNodeRef(sourceId: 'test', nodeKey: tag);
  }

  @override
  Future<CoreRejectPrompt> askKeepChecking(int n) async =>
      CoreRejectPrompt.keepChecking;

  @override
  void onProgress(
    CoreRejectPhase phase,
    int round, {
    List<DisabledNode> disabledNodes = const [],
  }) {}
}
