// §393 C6 — валидация формы цепочки (SPEC 110).
//
// ЭТО ЕДИНСТВЕННЫЙ РУБЕЖ (§393 L4). `sing-box check` НЕ ловит ошибки старта:
// конфиг с `strip tls.utls` на reality-узле или с вложенной цепочкой на
// позиции ≥1 проверку ПРОХОДИТ и падает только на `run`. Ядро при этом
// отвергает конфиг ЦЕЛИКОМ — пользователь остаётся без VPN, а не без одного
// маршрута. Поэтому форма обязана не дать СОБРАТЬ такую цепочку, а не ловить
// последствия в рантайме.
//
// Порт `conflicts()` лаунчера (`ui/configurator/tabs/source_chain_tab.go`),
// плюс инварианты ядра из `chainEmitError` — форме они нужны РАНЬШЕ сборки.
//
// Модуль чистый: ни виджетов, ни BuildContext, ни storage. Он и есть предмет
// тестов C6 — вёрстка и тексты не тестируются (AGENTS.md).

import '../../models/source_chain.dart';
import '../../services/l10n/locale_controller.dart';
import 'chain_hop_candidate.dart';

/// Насколько серьёзна находка формы.
enum ChainIssueLevel {
  /// Ядро не стартует / цепочка не доедет до конфига. СОХРАНЕНИЕ ЗАБЛОКИРОВАНО.
  blocking,

  /// Собрать можно, но получится не то, что нарисовано. Сохранять разрешено:
  /// «путь длиннее показанного» — это осознанный выбор пользователя, а не
  /// сломанный конфиг.
  warning,

  /// Всё работает ровно как показано, но какая-то настройка узла здесь не
  /// действует. Ни запрещать, ни пугать нечем — только сообщить.
  info,
}

/// Код находки — стабильный машинный идентификатор.
///
/// Тексты меняются, коды нет: на коды опираются тесты C6 и диагностика, и
/// сверять UI-строку с ожиданием теста значило бы ломать тест на каждой
/// правке подписи (AGENTS.md — тестов на формат строк не писать).
enum ChainIssueCode {
  /// Меньше двух позиций: ядро односкачковую цепочку отвергает.
  tooFewHops,

  /// Позиция повторяется.
  duplicateHop,

  /// Позиция ссылается на саму цепочку.
  selfReference,

  /// Позиция пуста. Формой такое не набрать (позиции выбираются из списка),
  /// но приехать может из restore / Debug API — а ядро на пустой позиции
  /// конфиг отвергает.
  emptyHop,

  /// Вложенная цепочка НЕ на позиции 0.
  nestedNotFirst,

  /// Позиция — цепочка, объявленная НИЖЕ по списку (ссылка вперёд).
  forwardChainReference,

  /// Снят `tls.utls`, а среди звеньев есть reality-узел.
  realityUtlsStripped,

  /// Позиция 0 со своим detour: реальный путь ДЛИННЕЕ показанного.
  detourAtEntry,

  /// Позиции ≥1 со своим detour: ядро перезапишет его безусловно.
  detourIgnoredOnLink,

  /// Позиции, которых больше нет среди целей.
  missingHops,

  /// Имя цепочки занято другим outbound'ом / Направлением / цепочкой.
  tagTaken,

  /// Имя цепочки пустое.
  tagEmpty,
}

/// Одна находка формы.
class ChainFormIssue {
  const ChainFormIssue({
    required this.code,
    required this.level,
    required this.message,
    this.hops = const [],
  });

  final ChainIssueCode code;
  final ChainIssueLevel level;

  /// Готовый EN-текст для показа (уже локализован через [getLocalText]).
  final String message;

  /// Теги позиций, о которых речь. Пусто, если находка не про позиции.
  final List<String> hops;

  bool get blocks => level == ChainIssueLevel.blocking;
}

/// Что форма знает об окружении цепочки на момент проверки.
class ChainFormContext {
  const ChainFormContext({
    this.candidates = const {},
    this.targetsKnown = false,
    this.takenTags = const {},
    this.originalTag = '',
  });

  /// Кандидаты по тегу (см. [chainHopLookup]).
  final Map<String, ChainHopCandidate> candidates;

  /// Разобран ли снимок конфига. Пока нет, позиция, которой не видно среди
  /// кандидатов, — «ещё не знаем», а не «потеряна»: объявить рабочую цепочку
  /// битой до загрузки целей хуже, чем промолчать один раз.
  final bool targetsKnown;

  /// Занятые теги: другие цепочки, Направления, узлы. Совпадение даёт два
  /// outbound'а с одним именем — ядро отвергает такой конфиг целиком.
  final Set<String> takenTags;

  /// Имя цепочки на момент открытия формы. Совпадение с ним конфликтом не
  /// считается: цепочка занимает своё же имя.
  final String originalTag;
}

/// Снимок редактируемого состояния — ровно то, из чего складывается решение.
class ChainFormState {
  const ChainFormState({
    required this.tag,
    required this.hops,
    this.stripEvasion,
    this.strip = const {},
  });

  ChainFormState.of(SourceChain c)
      : tag = c.tag,
        hops = c.hops,
        stripEvasion = c.stripEvasion,
        strip = c.strip;

  final String tag;
  final List<String> hops;
  final bool? stripEvasion;
  final Map<String, bool> strip;

  /// Снимается ли отпечаток ClientHello при текущих галках.
  ///
  /// Три источника, в порядке убывания старшинства: точечная галка каталога,
  /// общий `strip_evasion` (выключен → не снимается ничего), умолчание
  /// каталога ядра. Ровно та же лестница, что у `transform.go` ядра, — иначе
  /// форма предупреждала бы о конфликте, которого нет, или молчала о том,
  /// который есть.
  bool get stripsUtls {
    final explicit = strip[kChainStripTlsUtls];
    if (explicit != null) return explicit;
    if (stripEvasion == false) return false;
    return kChainStripDefault[kChainStripTlsUtls] ?? false;
  }
}

/// §393 C6 — всё, что форма нашла в [state], в порядке показа.
///
/// Блокирующие идут ПЕРВЫМИ: сначала то, из-за чего кнопка «сохранить»
/// заперта, потом то, о чём стоит знать. Порядок внутри уровня — от инварианта
/// ядра к обстоятельствам окружения.
List<ChainFormIssue> validateChainForm(
  ChainFormState state,
  ChainFormContext ctx,
) {
  final blocking = <ChainFormIssue>[];
  final soft = <ChainFormIssue>[];
  final hops = state.hops;

  // ── инварианты ядра (`protocol/chain/chain.go:85-100`) ───────────────────
  // Каждый из них не даёт стартовать ВСЕМУ конфигу.

  if (hops.length < 2) {
    blocking.add(ChainFormIssue(
      code: ChainIssueCode.tooFewHops,
      level: ChainIssueLevel.blocking,
      message: getLocalText.s("At least two positions are needed: the core rejects a single-hop chain."),
    ));
  }

  // Пустая позиция. Формой её не набрать, но она приезжает из restore или
  // Debug API, и `chainEmitError` уронил бы на ней ВСЮ цепочку уже на сборке.
  // Показать её здесь — единственный способ дать пользователю починить то,
  // что он в форме даже не видит как проблему.
  final empties = <int>[
    for (var i = 0; i < hops.length; i++)
      if (hops[i].trim().isEmpty) i + 1,
  ];
  if (empties.isNotEmpty) {
    blocking.add(ChainFormIssue(
      code: ChainIssueCode.emptyHop,
      level: ChainIssueLevel.blocking,
      message: getLocalText.s(
          "Positions %s are empty — remove them: the core rejects a chain with a blank position.",
          empties.join(', ')),
    ));
  }

  // Самоссылка — до дублей: «позиция ссылается на саму цепочку» точнее, чем
  // «позиция повторяется», если пользователь вписал тег дважды.
  final selfRefs = [
    for (final h in hops)
      if (h == state.tag && h.isNotEmpty) h,
  ];
  if (selfRefs.isNotEmpty) {
    blocking.add(ChainFormIssue(
      code: ChainIssueCode.selfReference,
      level: ChainIssueLevel.blocking,
      message: getLocalText.s("Position %s references this chain itself — the core rejects that.", _list(selfRefs.toSet().toList())),
      hops: selfRefs.toSet().toList(),
    ));
  }

  final dupes = <String>[];
  final seen = <String>{};
  for (final h in hops) {
    if (!seen.add(h) && !dupes.contains(h)) dupes.add(h);
  }
  if (dupes.isNotEmpty) {
    blocking.add(ChainFormIssue(
      code: ChainIssueCode.duplicateHop,
      level: ChainIssueLevel.blocking,
      message: getLocalText.s("Position %s is used more than once — the core rejects a chain with repeats.", _list(dupes)),
      hops: dupes,
    ));
  }

  // Вложенная цепочка законна ТОЛЬКО позицией 0: звено — это «узел через
  // предыдущую позицию», а цепочка не узел и под чужой диалер не
  // пересобирается (`protocol/chain/chain.go:279`).
  final nested = <String>[];
  for (var i = 1; i < hops.length; i++) {
    if (ctx.candidates[hops[i]]?.kind == ChainHopKind.chain) {
      nested.add(hops[i]);
    }
  }
  if (nested.isNotEmpty) {
    blocking.add(ChainFormIssue(
      code: ChainIssueCode.nestedNotFirst,
      level: ChainIssueLevel.blocking,
      message: getLocalText.s("A nested chain (%s) is only allowed at the first position — "
        "move it to the top or remove it.", _list(nested)),
      hops: nested,
    ));
  }

  // Ссылка «вперёд»: сборка разрешает цепочку-позицию, только если та
  // объявлена ВЫШЕ по списку, — этим порядком исключены циклы между
  // цепочками. Позиция ниже деградирует всю цепочку на сборке
  // (`chain_hop_missing`), и узнать об этом здесь дешевле.
  final forward = <String>[];
  for (final h in hops) {
    final c = ctx.candidates[h];
    if (c != null && c.kind == ChainHopKind.chain && c.below) forward.add(h);
  }
  if (forward.isNotEmpty) {
    blocking.add(ChainFormIssue(
      code: ChainIssueCode.forwardChainReference,
      level: ChainIssueLevel.blocking,
      message: getLocalText.s("Chains %s are declared below this one — a chain may only reference "
        "chains above it. Move them up, or this chain will not build.", _list(forward)),
      hops: forward,
    ));
  }

  // T4 — снятый отпечаток ClientHello на reality-узле. Проверяются позиции с
  // индексом ≥1: strip применяется к ЗВЕНЬЯМ, первая позиция идёт в сеть как
  // есть. Это ровно тот случай, который `check` пропускает, а `run` роняет.
  if (state.stripsUtls) {
    final bad = <String>[];
    for (var i = 1; i < hops.length; i++) {
      if (ctx.candidates[hops[i]]?.reality ?? false) bad.add(hops[i]);
    }
    if (bad.isNotEmpty) {
      blocking.add(ChainFormIssue(
        code: ChainIssueCode.realityUtlsStripped,
        level: ChainIssueLevel.blocking,
        message: getLocalText.s("ClientHello fingerprint is stripped, but these positions are reality nodes "
        "that need it: %s. The core will not start — untick tls.utls.", _list(bad)),
        hops: bad,
      ));
    }
  }

  // Имя: пустое или занятое — два outbound'а с одним тегом ядро не принимает.
  final tag = state.tag.trim();
  if (tag.isEmpty) {
    blocking.add(ChainFormIssue(
      code: ChainIssueCode.tagEmpty,
      level: ChainIssueLevel.blocking,
      message: getLocalText.s("A chain needs a name — it becomes its tag in the config."),
    ));
  } else if (tag != ctx.originalTag && ctx.takenTags.contains(tag)) {
    blocking.add(ChainFormIssue(
      code: ChainIssueCode.tagTaken,
      level: ChainIssueLevel.blocking,
      message: getLocalText.s("The name \"%s\" is already taken by another node, direction or chain — "
        "two outbounds with one tag cannot coexist.", tag),
    ));
  }

  // ── мягкие находки ───────────────────────────────────────────────────────

  // Потерянные позиции. НЕ блокирующие: тег мог исчезнуть, пока подписка
  // обновлялась, и запереть форму значило бы не дать пользователю починить
  // ровно ту цепочку, которую он пришёл чинить. Сборка её всё равно
  // деградирует (`chain_hop_missing`) — здесь важно ПОКАЗАТЬ, что пропало.
  //
  // Только при готовом снимке целей: пока он не разобран, «позиций больше
  // нет» было бы приговором рабочей цепочке.
  if (ctx.targetsKnown) {
    final missing = [
      for (final h in hops)
        if (h.isNotEmpty && !ctx.candidates.containsKey(h) && h != state.tag) h,
    ];
    if (missing.isNotEmpty) {
      soft.add(ChainFormIssue(
        code: ChainIssueCode.missingHops,
        level: ChainIssueLevel.warning,
        message: getLocalText.s("These positions are no longer among the available targets: %s. "
        "A chain with such a reference will not reach the config.", _list(missing)),
        hops: missing,
      ));
    }
  }

  // T7 — узел со своим detour. Что произойдёт, зависит от ПОЗИЦИИ, и сказать
  // одно и то же про обе значило бы соврать про одну из них (проверено на
  // ядре 1.14.0-lx.27-rc.5):
  //
  //   позиция 0 (вход) — узел идёт в сеть как есть, вместе со своим детуром.
  //     Реальный путь ДЛИННЕЕ показанного: перед первым хопом добавляется ещё
  //     один, которого в списке нет → ПРЕДУПРЕЖДЕНИЕ (маршрут не тот, что
  //     нарисован), но не запрет: он работает, и пользователь вправе его
  //     хотеть;
  //   позиции ≥1 (звенья) — detour перезаписывается безусловно
  //     (`protocol/chain/transform.go:110`): поле одно, и именно им цепочка
  //     выражает «через предыдущий хоп». Путь ровно такой, как нарисован →
  //     СПРАВКА. Советовать «уберите detour» бессмысленно, он и так не
  //     применяется.
  if (hops.isNotEmpty && (ctx.candidates[hops[0]]?.detour ?? false)) {
    soft.add(ChainFormIssue(
      code: ChainIssueCode.detourAtEntry,
      level: ChainIssueLevel.warning,
      message: getLocalText.s("The first position (%s) dials through its own detour — the real path "
        "is longer than shown: one more hop precedes it that is not in this list.", hops[0]),
      hops: [hops[0]],
    ));
  }
  final detoured = <String>[];
  for (var i = 1; i < hops.length; i++) {
    if ((ctx.candidates[hops[i]]?.detour ?? false) && !detoured.contains(hops[i])) {
      detoured.add(hops[i]);
    }
  }
  if (detoured.isNotEmpty) {
    soft.add(ChainFormIssue(
      code: ChainIssueCode.detourIgnoredOnLink,
      level: ChainIssueLevel.info,
      message: getLocalText.s("Positions %s have their own detour — it does not apply inside a chain: "
        "a link always dials through the previous position. The path is exactly "
        "as shown.", _list(detoured)),
      hops: detoured,
    ));
  }

  return [...blocking, ...soft];
}

/// Можно ли сохранять: ни одной блокирующей находки.
///
/// Предупреждения и справки сохранению не мешают — они про маршрут, который
/// ядро примет; запрещать пользователю осознанный выбор форма не вправе.
bool chainFormCanSave(List<ChainFormIssue> issues) =>
    !issues.any((i) => i.blocks);

String _list(List<String> tags) => tags.join(', ');
