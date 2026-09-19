/// Фича 478 — наблюдаемое состояние страховки: то, что видят UI и Debug API.
///
/// Почему отдельный синглтон, а не поле контроллера: сам [CoreRejectGuard] —
/// чистый автомат, живущий ровно один прогон (спека раздел 3), и после
/// `run()` он выбрасывается. Плашка «выключено N» и вопрос про предел кругов
/// переживают прогон: плашку человек закрывает сам, а вопрос висит, пока на
/// него не ответили. Класть это в автомат значило бы дать ему жизнь дольше
/// прогона, а в `HomeState` — смешать с проекцией туннеля, к которой оно
/// отношения не имеет (та же причина, что у `CrashBannerState`).
///
/// Связь одностороняя: хост автомата пишет сюда через [onProgress]/[finish],
/// а читают отсюда UI (слушая [ChangeNotifier]) и Debug API (`/core_reject`).
/// Сам автомат этот класс не знает и знать не должен — иначе его перестанут
/// закрывать юниты на поддельном клиенте.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'core_reject_guard.dart';

class CoreRejectState extends ChangeNotifier {
  CoreRejectState._();

  static final CoreRejectState I = CoreRejectState._();

  // ── прогон ────────────────────────────────────────────────────────────
  CoreRejectPhase _phase = CoreRejectPhase.idle;
  int _round = 0;
  List<DisabledNode> _disabled = const [];
  CoreRejectOutcome? _lastOutcome;
  String _lastError = '';

  /// Фаза последнего (или идущего) прогона.
  CoreRejectPhase get phase => _phase;

  /// Круг тихой проверки; 0 — цикл ещё не начинался.
  int get round => _round;

  /// Узлы, выключенные ТЕКУЩИМ прогоном, в порядке отказов ядра.
  List<DisabledNode> get disabled => List.unmodifiable(_disabled);

  /// Чем кончился последний прогон; `null` — ни одного ещё не было.
  CoreRejectOutcome? get lastOutcome => _lastOutcome;

  /// Текст ошибки последнего прогона; пусто у успеха.
  String get lastError => _lastError;

  // ── плашка «выключено N» ──────────────────────────────────────────────
  bool _bannerVisible = false;
  List<DisabledNode> _bannerNodes = const [];

  /// Показывать ли плашку. Поднимается [finish] на исходе
  /// [CoreRejectOutcome.startedWithDisabled] — VPN поднят, но не целиком тем
  /// составом, который человек задавал.
  bool get bannerVisible => _bannerVisible;

  /// Узлы плашки. Это снимок ПРОГОНА, а не список стоящих вердиктов:
  /// плашка говорит «вот что выключилось сейчас», а всё стоящее видно в
  /// списке узлов.
  List<DisabledNode> get bannerNodes => List.unmodifiable(_bannerNodes);

  /// Человек закрыл плашку. Вердикты остаются — закрыли сообщение, а не
  /// отменили решение.
  void dismissBanner() {
    if (!_bannerVisible) return;
    _bannerVisible = false;
    _bannerNodes = const [];
    notifyListeners();
  }

  // ── отмена идущего прогона ────────────────────────────────────────────
  VoidCallback? _cancel;

  /// Есть ли кого отменять. Кнопка Start в фазе тихого цикла рисуется как
  /// Stop именно по [checking], а не по этому флагу: связка с автоматом —
  /// деталь, а человек видит фазу.
  bool get cancellable => _cancel != null;

  /// Прогон отдаёт сюда свой `cancel()`: сам автомат живёт один прогон и
  /// снаружи его не удержать, а кнопка и Debug API должны до него дотянуться.
  /// [finish] связь рвёт — отменять завершённый прогон нечего.
  void bindCancel(VoidCallback cancel) {
    _cancel = cancel;
    notifyListeners();
  }

  /// Отмена (кнопка в фазе цикла либо `POST /core_reject/cancel`). Итог тот
  /// же, что у Stop в диалоге предела: VPN не поднимается, выключенные
  /// остаются выключенными. Круг доигрывает до конца — прерывать ядро на
  /// середине `checkConfig` нечем.
  ///
  /// Висящий вопрос про предел закрывается тем же нажатием: иначе автомат
  /// остался бы ждать ответа на диалог, который человек уже перекрыл
  /// отменой. `false` — отменять нечего.
  bool cancelRun() {
    final c = _cancel;
    if (c == null) return false;
    c();
    if (_promptPending) answerPrompt(CoreRejectPrompt.stop);
    notifyListeners();
    return true;
  }

  // ── вопрос про предел кругов ──────────────────────────────────────────
  bool _promptPending = false;
  int _promptCount = 0;
  Completer<CoreRejectPrompt>? _promptCompleter;
  CoreRejectPrompt? _queuedPromptAnswer;

  /// Висит ли сейчас вопрос человеку.
  bool get promptPending => _promptPending;

  /// Число из текста вопроса — предел кругов, а не счётчик выключенных
  /// (спека раздел 3: тексты владельца говорят «10 servers disabled»).
  int get promptCount => _promptCount;

  /// Задать вопрос и ждать ответа. Вызывается хостом автомата из
  /// `askKeepChecking`. Повторный вызов при уже висящем вопросе отдаёт ТУ ЖЕ
  /// future — иначе первый ожидающий остался бы висеть навсегда.
  /// Ответ на вопрос предела ДО того, как он повис (Debug API:
  /// `POST /core_reject/prompt?answer=keep` заранее).
  void queuePromptAnswer(CoreRejectPrompt answer) {
    _queuedPromptAnswer = answer;
    if (_promptPending) answerPrompt(answer);
    notifyListeners();
  }

  Future<CoreRejectPrompt> askPrompt(int count) {
    final pending = _promptCompleter;
    if (pending != null && !pending.isCompleted) return pending.future;
    final queued = _queuedPromptAnswer;
    if (queued != null) {
      _queuedPromptAnswer = null;
      return Future.value(queued);
    }
    final c = Completer<CoreRejectPrompt>();
    _promptCompleter = c;
    _promptPending = true;
    _promptCount = count;
    notifyListeners();
    return c.future;
  }

  /// Ответ человека (диалог UI либо `POST /core_reject/prompt`). Без висящего
  /// вопроса — no-op: отвечать не на что, и ронять на этом нечего.
  void answerPrompt(CoreRejectPrompt p) {
    final c = _promptCompleter;
    _promptCompleter = null;
    _promptPending = false;
    if (c != null && !c.isCompleted) c.complete(p);
    notifyListeners();
  }

  // ── запись из хоста автомата ──────────────────────────────────────────

  /// Новый прогон: старое состояние прогона стирается, плашка — нет
  /// (её закрывает человек, а не следующее нажатие Start).
  void beginRun() {
    _phase = CoreRejectPhase.signalStart;
    _round = 0;
    _disabled = const [];
    _lastOutcome = null;
    _lastError = '';
    // Очередь `answer=keep` с Debug API ставится ДО beginRun — не стирать.
    notifyListeners();
  }

  /// Идёт ли прогон страховки (любая фаза, кроме idle/done). Кнопка Start
  /// занята на всём этом интервале — иначе повторный тап затирает ожидание
  /// вердикта (фича 478, ревью guard_builder_api №1).
  bool get guardActive =>
      _phase != CoreRejectPhase.idle && _phase != CoreRejectPhase.done;

  /// Идёт ли тихий цикл (кнопка Start показывает «Checking servers…»).
  bool get checking =>
      _phase == CoreRejectPhase.checking ||
      _phase == CoreRejectPhase.awaitingPrompt;

  /// Зеркало `CoreRejectHost.onProgress`: сигнатура один в один, чтобы
  /// связка звала его без переходника.
  ///
  /// Выключенные приходят СПИСКОМ, а не счётчиком: Debug API отдаёт теги с
  /// причинами, и по одному числу их не восстановить. Второго источника
  /// правды (отдельного `trackDisabled`) нет намеренно — два счётчика одного
  /// множества расходятся на первом же пропущенном вызове.
  void onProgress(
    CoreRejectPhase phase,
    int round, {
    List<DisabledNode> disabledNodes = const [],
  }) {
    _phase = phase;
    _round = round;
    _disabled = List.unmodifiable(disabledNodes);
    notifyListeners();
  }

  /// Итог прогона. Плашку поднимаем только на «поднялся, но не весь состав» —
  /// на чистом старте говорить не о чем, а на отказе человек и так видит
  /// ошибку.
  void finish(CoreRejectRun run) {
    _phase = CoreRejectPhase.done;
    _cancel = null;
    _round = run.rounds;
    _disabled = List.unmodifiable(run.disabled);
    _lastOutcome = run.outcome;
    _lastError = run.error;
    _queuedPromptAnswer = null;
    if (run.outcome == CoreRejectOutcome.startedWithDisabled &&
        run.disabled.isNotEmpty) {
      _bannerVisible = true;
      _bannerNodes = List.unmodifiable(run.disabled);
    }
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _phase = CoreRejectPhase.idle;
    _round = 0;
    _disabled = const [];
    _lastOutcome = null;
    _lastError = '';
    _bannerVisible = false;
    _bannerNodes = const [];
    _promptPending = false;
    _promptCount = 0;
    _promptCompleter = null;
    _queuedPromptAnswer = null;
    _cancel = null;
  }
}
