// §393 C6/C7 — кандидаты позиций цепочки (SPEC 110).
//
// Порт `ui/configurator/tabs/source_chain_hops.go` лаунчера.
//
// Позиция цепочки — это тег ЛЮБОГО outbound'а: узла подписки, группы,
// Направления, другой цепочки или служебного тега шаблона. Вписывать теги
// руками нельзя (как участники группы и detour-мишень): имена приходят из
// шаблона и подписок, и опечатка в теге — это ссылка в никуда, на которой
// ядро не стартует ВОВСЕ, а не роняет одну цепочку.
//
// Для чтения списка важен не только тег, но и ЧТО за ним стоит: группа
// выбирает участника на лету, а вложенная цепочка законна только позицией 0.
// Поэтому у каждого кандидата есть вид, и он показан в строке.

/// Вид позиции — определяет подпись в строке списка и правила валидации.
enum ChainHopKind {
  /// Узел подписки или пользовательский сервер.
  node,

  /// Группа, экспортированная подпиской (`selector`/`urltest` из тела).
  group,

  /// Направление (тег группы Направления).
  direction,

  /// Другая цепочка. Законна ТОЛЬКО позицией 0 (SPEC 110 T5) и только
  /// объявленная ВЫШЕ по списку — см. [ChainHopCandidate.below].
  chain,

  /// Служебный тег шаблона (`direct-out` и т. п.).
  builtin,

  /// Тега больше нет среди целей: подписка обновилась, узел исчез.
  unknown,

  /// Снимок конфига ещё не готов — судить о потере рано.
  pending,
}

/// Возможная позиция цепочки.
class ChainHopCandidate {
  const ChainHopCandidate({
    required this.tag,
    required this.kind,
    this.below = false,
    this.reality = false,
    this.detour = false,
    this.outboundType = '',
  });

  /// Тег outbound'а — то, что уедет в `outbounds[]` цепочки.
  final String tag;

  final ChainHopKind kind;

  /// Цепочка объявлена НИЖЕ редактируемой по списку цепочек.
  ///
  /// Сборка разрешает ссылку только на цепочку ВЫШЕ (`chain_nodes.dart`:
  /// тега ещё нет в `knownTags`), и этим порядком исключены циклы. Форма
  /// обязана предупредить, а не дать молча собрать позицию, которая
  /// деградирует всю цепочку на сборке.
  final bool below;

  /// Узел поднимает reality: снятый `tls.utls` не даст ядру стартовать
  /// (SPEC 110 T4, §393 L4 — `check` этого НЕ ловит).
  final bool reality;

  /// У узла есть собственный `detour`. Что он значит внутри цепочки —
  /// зависит от ПОЗИЦИИ (см. `chain_form_validation.dart`).
  final bool detour;

  /// `type` outbound'а (`vless`, `wireguard`, …) — подсказка для таблицы
  /// `rewrite`, ключ которой это тип протокола, и опечатка в нём означает
  /// правило, которое молча не применяется.
  final String outboundType;
}

/// Быстрый доступ к кандидату по тегу.
Map<String, ChainHopCandidate> chainHopLookup(
        Iterable<ChainHopCandidate> cands) =>
    {for (final c in cands) c.tag: c};

/// Вид позиции, УЖЕ лежащей в цепочке.
///
/// Тег, которого больше нет среди кандидатов, помечается [ChainHopKind.unknown],
/// а не выбрасывается молча: цепочка со ссылкой в никуда не соберётся, и
/// пользователь должен увидеть, ЧТО именно пропало, — иначе позиция просто
/// исчезнет из списка и маршрут поменяется без его ведома.
///
/// [targetsKnown] = false («снимок конфига ещё не готов») даёт
/// [ChainHopKind.pending]: объявить позицию потерянной, пока цели не
/// загружены, значило бы покрасить красным рабочую цепочку.
ChainHopCandidate describeChainHop(
  String tag,
  Map<String, ChainHopCandidate> lookup, {
  required bool targetsKnown,
}) {
  final found = lookup[tag];
  if (found != null) return found;
  return ChainHopCandidate(
    tag: tag,
    kind: targetsKnown ? ChainHopKind.unknown : ChainHopKind.pending,
  );
}
