/// Фича 478 — автомат страховки «узел, который не приняло ядро, выключается
/// сам». Дерево ветвлений — раздел 3 спеки, дословно:
///
/// ```
/// Start
/// └─ реальный старт ядра (первый, сигнальный)
///    ├─ принято → VPN поднят → конец
///    └─ отказ
///       ├─ ошибка не про узел / без тега / тег не сопоставился → ошибка → конец
///       └─ ошибка называет узел → выключить узел + причина
///          └─ цикл check (тихо, без туннеля): пересобрать конфиг → checkConfig
///             ├─ назван узел → выключить + причина → следующий круг
///             │  └─ после 10 кругов → диалог
///             │     ├─ Keep checking → следующий круг, дальше без предела
///             │     └─ Stop → конец, VPN не поднят, выключенные остаются
///             ├─ ошибка не про узел / тот же тег повторно → ошибка → конец
///             └─ чисто → реальный старт ядра (второй, финальный)
///                ├─ принято → VPN поднят → плашка «выключено N» → конец
///                └─ отказ → ошибка → конец
///                   (названный узел выключается, но третьего старта нет)
/// ```
///
/// Реальных стартов на одно нажатие — ДВА: сигнальный и финальный. Цикл
/// конечен по построению: каждый круг выключает один узел; круг, на котором
/// выключить нечего, цикл прерывает (CANON §9.5 запрет 3).
///
/// Автомат чистый: ядро, сборка конфига и хранение приходят в него
/// интерфейсом [CoreRejectHost]. Ни туннеля, ни контроллеров он не знает —
/// поэтому его целиком закрывают юниты на поддельном клиенте.
library;

import 'core_error_parse.dart';

/// Предел кругов, после которого автомат спрашивает человека (решение
/// владельца: подписка на 500 узлов с пачкой негодных — норма, но длинный
/// старт решает человек). Число подставляется в текст диалога.
const kCoreRejectRoundLimit = 10;

/// Ответ человека на диалог предела.
enum CoreRejectPrompt {
  /// Остановить: VPN не поднимается, выключенные остаются выключенными.
  stop,

  /// Проверять дальше — предел снимается до конца этого Start.
  keepChecking,
}

/// Фаза автомата — её отдаёт Debug API и по ней UI рисует кнопку Start.
enum CoreRejectPhase {
  /// Страховка не работает.
  idle,

  /// Идёт первый (сигнальный) реальный старт.
  signalStart,

  /// Тихий цикл `checkConfig` без туннеля.
  checking,

  /// Висит вопрос человеку после предела кругов.
  awaitingPrompt,

  /// Идёт второй (финальный) реальный старт.
  finalStart,

  /// Автомат отработал.
  done,
}

/// Чем кончился прогон.
enum CoreRejectOutcome {
  /// Ядро приняло конфиг, VPN поднят. Ни одного узла не выключено.
  startedClean,

  /// VPN поднят, но по дороге выключено [CoreRejectRun.disabled] узлов —
  /// показать плашку.
  startedWithDisabled,

  /// Ошибка, как сейчас: не про узел, тег не сопоставился, тот же тег
  /// повторно, либо отказ финального старта. Текст — [CoreRejectRun.error].
  failed,

  /// Человек нажал Stop. VPN не поднят, выключенные остаются выключенными.
  stoppedByUser,
}

/// Один выключенный узел прогона — для плашки и Debug API.
final class DisabledNode {
  const DisabledNode({required this.tag, required this.reason});

  /// Финальный тег собранного конфига, который назвало ядро.
  final String tag;

  /// Дословный текст ядра без префикса — он же `params.reason` вердикта.
  final String reason;

  Map<String, dynamic> toJson() => {'tag': tag, 'reason': reason};

  @override
  String toString() => 'DisabledNode($tag: $reason)';
}

/// Итог прогона.
final class CoreRejectRun {
  const CoreRejectRun({
    required this.outcome,
    this.disabled = const [],
    this.error = '',
    this.rounds = 0,
  });

  final CoreRejectOutcome outcome;

  /// Узлы, выключенные ЭТИМ прогоном, в порядке отказов ядра.
  final List<DisabledNode> disabled;

  /// Текст ошибки для показа человеку; пусто у успеха.
  final String error;

  /// Сколько кругов `checkConfig` отработано.
  final int rounds;

  bool get started =>
      outcome == CoreRejectOutcome.startedClean ||
      outcome == CoreRejectOutcome.startedWithDisabled;
}

/// Исход одной попытки ядра — реального старта либо `checkConfig`.
final class CoreAttempt {
  const CoreAttempt.accepted()
      : ok = true,
        error = '',
        bridgeDown = false;

  const CoreAttempt.rejected(this.error)
      : ok = false,
        bridgeDown = false;

  /// Моста нет (юнит, старый native, таймаут): ответить нечем. Автомат
  /// деградирует консервативно — обычная ошибка, без автоматики.
  const CoreAttempt.unavailable()
      : ok = false,
        error = '',
        bridgeDown = true;

  final bool ok;
  final String error;
  final bool bridgeDown;
}

/// Один пересобранный конфиг: текст для ядра и теги для сопоставления.
final class RebuiltConfig {
  const RebuiltConfig({required this.configJson, required this.tags});

  final String configJson;

  /// Финальные теги собранного конфига — против них проверяются кандидаты
  /// разбора (CANON §9.2 шаг 3).
  final Set<String> tags;
}

/// Всё, что автомату нужно снаружи. Реализуется контроллером; в тестах —
/// поддельным клиентом ядра.
abstract interface class CoreRejectHost {
  /// Реальный старт ядра. Результат — принято/отказ с текстом.
  Future<CoreAttempt> realStart();

  /// Пересобрать конфиг из текущего состояния (узлы уже выключены) и отдать
  /// его текст вместе с финальными тегами.
  Future<RebuiltConfig?> rebuild();

  /// Тихая проверка ядром без туннеля (`Libbox.checkConfig`).
  Future<CoreAttempt> check(String configJson);

  /// Выключить узел с тегом [tag] и записать рядом вердикт [reason].
  /// `false` — узла по этому тегу нет (служебная запись приложения) либо
  /// выключить его нечем: автоматики нет, цикл прерывается.
  Future<bool> disableNode(String tag, String reason);

  /// Спросить человека после предела кругов. Реализация без UI (§428,
  /// сторож, плитка QS) возвращает [CoreRejectPrompt.stop] — диалога там
  /// нет, и предел остаётся пределом.
  Future<CoreRejectPrompt> askKeepChecking(int disabledCount);

  /// Уведомить о смене фазы: кнопка Start, плашка и Debug API. Выключенные
  /// отдаются СПИСКОМ, а не счётчиком — Debug API показывает теги с
  /// причинами, и по числу их не восстановить.
  void onProgress(
    CoreRejectPhase phase,
    int round, {
    List<DisabledNode> disabledNodes,
  });
}

/// Прогон страховки на одно нажатие Start.
final class CoreRejectGuard {
  CoreRejectGuard(this._host, {this.roundLimit = kCoreRejectRoundLimit});

  final CoreRejectHost _host;
  final int roundLimit;

  final _disabled = <DisabledNode>[];
  final _seenTags = <String>{};
  var _phase = CoreRejectPhase.idle;
  var _round = 0;
  var _unlimited = false;
  var _cancelled = false;

  CoreRejectPhase get phase => _phase;
  int get round => _round;
  List<DisabledNode> get disabled => List.unmodifiable(_disabled);

  /// Отмена доступна всегда (спека раздел 3). Круг доигрывает до конца, но
  /// следующий не начинается.
  void cancel() => _cancelled = true;

  void _to(CoreRejectPhase p) {
    _phase = p;
    _host.onProgress(p, _round, disabledNodes: List.unmodifiable(_disabled));
  }

  CoreRejectRun _finish(CoreRejectOutcome outcome, {String error = ''}) {
    _to(CoreRejectPhase.done);
    return CoreRejectRun(
      outcome: outcome,
      disabled: List.unmodifiable(_disabled),
      error: error,
      rounds: _round,
    );
  }

  Future<CoreRejectRun> run() async {
    // ── реальный старт ядра (первый, сигнальный) ────────────────────────
    _to(CoreRejectPhase.signalStart);
    final first = await _host.realStart();
    if (first.ok) return _finish(CoreRejectOutcome.startedClean);
    if (first.bridgeDown) return _finish(CoreRejectOutcome.failed);

    // Ошибка называет узел?
    final hit = await _consume(first.error);
    if (hit == null) {
      return _finish(CoreRejectOutcome.failed, error: first.error);
    }

    // ── тихий цикл check ────────────────────────────────────────────────
    _to(CoreRejectPhase.checking);
    while (true) {
      if (_cancelled) return _finish(CoreRejectOutcome.stoppedByUser);

      // Предел: спросить человека. `Keep checking` снимает предел до конца
      // этого Start; `Stop` — конец, VPN не поднят.
      if (!_unlimited && _round >= roundLimit) {
        _to(CoreRejectPhase.awaitingPrompt);
        // Число в диалоге — ИЗ КОНСТАНТЫ ПРЕДЕЛА (спека раздел 3): тексты
        // владельца говорят «10 servers disabled», и счётчик выключенных
        // (на единицу больше — узел сигнального старта) их бы расходил.
        final answer = await _host.askKeepChecking(roundLimit);
        if (answer == CoreRejectPrompt.stop) {
          return _finish(CoreRejectOutcome.stoppedByUser);
        }
        _unlimited = true;
        _to(CoreRejectPhase.checking);
      }

      final built = await _host.rebuild();
      if (built == null) {
        // Пересобрать нечем — дальше проверять нечего.
        return _finish(CoreRejectOutcome.failed);
      }

      _round++;
      final verdict = await _host.check(built.configJson);
      _host.onProgress(CoreRejectPhase.checking, _round,
          disabledNodes: List.unmodifiable(_disabled));

      if (_cancelled) return _finish(CoreRejectOutcome.stoppedByUser);

      if (verdict.ok) break; // чисто → финальный старт

      if (verdict.bridgeDown) {
        // Моста нет: проверять нечем. Финальный старт всё равно даём —
        // узлы уже выключены, и ядро скажет своё слово само.
        break;
      }

      final next = await _consume(verdict.error, tags: built.tags);
      if (next == null) {
        return _finish(CoreRejectOutcome.failed, error: verdict.error);
      }
    }

    // ── реальный старт ядра (второй, финальный) ─────────────────────────
    if (_cancelled) return _finish(CoreRejectOutcome.stoppedByUser);
    _to(CoreRejectPhase.finalStart);
    final last = await _host.realStart();
    if (last.ok) {
      return _finish(_disabled.isEmpty
          ? CoreRejectOutcome.startedClean
          : CoreRejectOutcome.startedWithDisabled);
    }
    // Редкая ошибка, которую check пропускает, а старт ловит: названный узел
    // тоже выключается с причиной, но ТРЕТЬЕГО старта нет — следующее
    // нажатие Start начнёт заново и уже пройдёт дальше.
    if (!last.bridgeDown) await _consume(last.error);
    return _finish(CoreRejectOutcome.failed, error: last.error);
  }

  /// Разобрать строку отказа и выключить названный узел.
  ///
  /// `null` — автоматики нет: ошибка не про узел, тег не сопоставился, тег
  /// назван ПОВТОРНО (CANON §9.5 запрет 3 — иначе цикл перестаёт быть
  /// конечным) либо выключить узел нечем.
  Future<DisabledNode?> _consume(String error, {Set<String>? tags}) async {
    final built = tags ?? await _tagsOfCurrentConfig();
    if (built == null) return null;
    final hit = parseCoreRejection(error, built);
    if (hit == null) return null;
    if (!_seenTags.add(hit.tag)) return null; // тот же тег повторно
    if (!await _host.disableNode(hit.tag, hit.reason)) return null;
    final d = DisabledNode(tag: hit.tag, reason: hit.reason);
    _disabled.add(d);
    _host.onProgress(_phase, _round,
        disabledNodes: List.unmodifiable(_disabled));
    return d;
  }

  /// Теги конфига, на котором ядро только что отказало: у сигнального старта
  /// своего набора нет — берём его пересборкой (узлы ещё не выключены, набор
  /// тот же).
  Future<Set<String>?> _tagsOfCurrentConfig() async =>
      (await _host.rebuild())?.tags;
}
