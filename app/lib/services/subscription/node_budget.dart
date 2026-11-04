/// Бюджет узлов приложения: сколько узлов держат ручные серверы, папки и
/// подписки вместе (задача 714).
///
/// Чистые функции без UI и ввода-вывода:
/// - [countManualBudgetNodes] — ручное, вычитается из бюджета первым и не
///   режется никогда;
/// - [splitNodeBudget] — раздача остатка между включёнными подписками
///   поровну с перераспределением (water-filling);
/// - [collectProtectedNodeTags] — узлы, на которые есть ссылки (Направление,
///   цепочка, правило): держатся сверх очереди внутри доли подписки;
/// - [cutNodesToQuota] — обрезка разобранной выдачи подписки до доли; зовётся
///   в воркере разбора (`cache_rehydrate.dart`).
///
/// В бюджет не входят Tailscale-узлы и auto-узлы групп (`AutoSelectSpec`);
/// цепочки — не узлы источников и сюда не попадают вовсе.
library;

import '../../models/custom_rule.dart';
import '../../models/direction.dart';
import '../../models/node_link.dart';
import '../../models/node_spec.dart';
import '../../models/server_list.dart';
import '../../models/source_chain.dart';
import '../safe_regex.dart';
import '../tag_resolver.dart';

/// Размер «без потолка» для подписки, чей размер ещё неизвестен (разбор
/// ответа сети): её доля тогда — максимум, что ей может достаться.
const int kNodeBudgetUnknownSize = 1 << 30;

/// Узел считается в бюджет: не группа и не Tailscale.
bool countsInNodeBudget(NodeSpec n) =>
    n is! AutoSelectSpec && n.protocol != 'tailscale';

/// Сколько узлов списка считается в бюджет.
int budgetNodeCount(Iterable<NodeSpec> nodes) =>
    nodes.where(countsInNodeBudget).length;

/// Ручное: узлы включённых одиночных серверов и включённые члены включённых
/// папок.
int countManualBudgetNodes(Iterable<ServerList> sources) {
  var n = 0;
  for (final s in sources) {
    if (!s.enabled) continue;
    switch (s) {
      case UserServer():
        n += budgetNodeCount(s.nodes);
      case FolderServers():
        for (final m in s.members) {
          final node = m.node;
          if (m.enabled && node != null && countsInNodeBudget(node)) n++;
        }
      case SubscriptionServers():
        break;
    }
  }
  return n;
}

/// Раздача бюджета между подписками. [sizes] — размеры включённых подписок
/// в порядке `sources` (число узлов после разбора и import-правил);
/// возвращает доли тем же порядком.
///
/// Ручное ([manual]) вычитается первым; если его не меньше [budget], все
/// доли 0. Остаток делится поровну; кому хватило меньше доли, берёт свой
/// размер, недобор делится между остальными, пока не кончатся бюджет или
/// подписки. Остаток от деления уходит подпискам по порядку списка.
List<int> splitNodeBudget({
  required int budget,
  required int manual,
  required List<int> sizes,
}) {
  final alloc = List<int>.filled(sizes.length, 0);
  var remaining = budget - manual;
  if (remaining <= 0) return alloc;
  var active = [
    for (var i = 0; i < sizes.length; i++)
      if (sizes[i] > 0) i,
  ];
  while (remaining > 0 && active.isNotEmpty) {
    final share = remaining ~/ active.length;
    final fits = [
      for (final i in active)
        if (sizes[i] - alloc[i] <= share) i,
    ];
    if (fits.isEmpty) {
      var extra = remaining - share * active.length;
      for (final i in active) {
        alloc[i] += share;
        if (extra > 0) {
          alloc[i]++;
          extra--;
        }
      }
      break;
    }
    for (final i in fits) {
      remaining -= sizes[i] - alloc[i];
      alloc[i] = sizes[i];
    }
    final done = fits.toSet();
    active = [
      for (final i in active)
        if (!done.contains(i)) i,
    ];
  }
  return alloc;
}

/// Размер подписки в узлах бюджета (после разбора и import-правил, до
/// обрезки). Группы не обрезаются и в бюджет не входят, поэтому их число
/// вычитается из хранимого полного размера.
int subscriptionBudgetSize(SubscriptionServers s) {
  final groups = s.nodes.length - budgetNodeCount(s.nodes);
  final n = s.nodeCountBeforeCut - groups;
  return n < 0 ? 0 : n;
}

/// Доли подписок по списку источников: `id` подписки → доля. Участвуют
/// включённые подписки и [includeId] (выключенная, которую сейчас
/// разбирают); выключенные прочие долю не получают и не отнимают. Размер
/// подписки — [sizeOf] (по умолчанию [subscriptionBudgetSize]).
Map<String, int> nodeBudgetQuotas({
  required int budget,
  required List<ServerList> sources,
  int Function(SubscriptionServers s)? sizeOf,
  String? includeId,
}) {
  final size = sizeOf ?? subscriptionBudgetSize;
  final ids = <String>[];
  final sizes = <int>[];
  for (final l in sources) {
    if (l is! SubscriptionServers) continue;
    if (!l.enabled && l.id != includeId) continue;
    ids.add(l.id);
    sizes.add(size(l));
  }
  final quotas = splitNodeBudget(
    budget: budget,
    manual: countManualBudgetNodes(sources),
    sizes: sizes,
  );
  return {for (var i = 0; i < ids.length; i++) ids[i]: quotas[i]};
}

/// Ссылки на узлы, которые обрезка обязана сохранить. Данные без
/// поведения — уходят в воркер разбора как есть.
final class ProtectedNodeTags {
  const ProtectedNodeTags({
    this.finalTags = const {},
    this.rawBySource = const {},
    this.defaultPatterns = const [],
  });

  static const empty = ProtectedNodeTags();

  /// Финальные теги конфига: outbound правил, корневые ссылки цепочек и
  /// detour.
  final Set<String> finalTags;

  /// `id` подписки → сырые теги её узлов (ссылки цепочек и detour с
  /// контейнером).
  final Map<String, Set<String>> rawBySource;

  /// `defaultFilter` включённых Направлений: первый подходящий узел
  /// подписки — закреплённый узел Направления.
  final List<String> defaultPatterns;

  /// Срез для одной подписки. К ссылкам добавляется выбранный член групп
  /// ручного рода подписки (`group_defaults`).
  SourceProtectedTags forSource(SubscriptionServers s) => SourceProtectedTags(
        tagPrefix: s.tagPrefix,
        finalTags: finalTags,
        rawTags: {
          ...?rawBySource[s.id],
          ...s.groupDefaults.values,
        },
        defaultPatterns: defaultPatterns,
      );
}

/// Защищённые узлы одной подписки (вход воркера разбора).
final class SourceProtectedTags {
  const SourceProtectedTags({
    this.tagPrefix = '',
    this.finalTags = const {},
    this.rawTags = const {},
    this.defaultPatterns = const [],
  });

  final String tagPrefix;
  final Set<String> finalTags;
  final Set<String> rawTags;
  final List<String> defaultPatterns;
}

/// Сборщик ссылок на узлы — одно место для обрезки по бюджету.
///
/// Ссылки: позиции цепочек, outbound правил, `defaultFilter` включённых
/// Направлений и detour — `overrideDetour` политики любого источника
/// (сервер, подписка, папка) и `detour` членов папок из [sources].
ProtectedNodeTags collectProtectedNodeTags({
  required List<Direction> directions,
  required List<SourceChain> chains,
  required List<CustomRule> rules,
  List<ServerList> sources = const [],
}) {
  final finalTags = <String>{};
  final raw = <String, Set<String>>{};
  void link(NodeLink l) {
    if (l.isEmpty) return;
    if (l.isRoot) {
      finalTags.add(l.tag);
    } else {
      (raw[l.folderId] ??= <String>{}).add(l.tag);
    }
  }

  for (final c in chains) {
    c.hops.forEach(link);
  }
  for (final s in sources) {
    link(s.detourPolicy.overrideDetour);
    if (s is FolderServers) {
      for (final m in s.members) {
        link(m.detour);
      }
    }
  }
  for (final r in rules) {
    final out = r.outbound;
    if (out.isNotEmpty) finalTags.add(out);
  }
  return ProtectedNodeTags(
    finalTags: finalTags,
    rawBySource: raw,
    defaultPatterns: [
      for (final d in directions)
        if (d.enabled && d.defaultFilter.isNotEmpty) d.defaultFilter,
    ],
  );
}

/// Итог обрезки выдачи подписки.
typedef NodeCut = ({List<NodeSpec> nodes, int total});

/// Обрезка выдачи до [quota] узлов бюджета. `null` — без обрезки.
///
/// Режутся только узлы, считаемые в бюджет; группы и Tailscale остаются.
/// Защищённые берутся первыми (все, даже сверх [quota]), затем добор по
/// порядку выдачи до [quota]. Порядок оставшихся — порядок выдачи.
/// `total` — размер выдачи до обрезки (`nodes.length`).
NodeCut cutNodesToQuota(
  List<NodeSpec> nodes,
  int? quota, [
  SourceProtectedTags protected = const SourceProtectedTags(),
]) {
  final total = nodes.length;
  if (quota == null) return (nodes: nodes, total: total);
  final counted = budgetNodeCount(nodes);
  if (counted <= quota) return (nodes: nodes, total: total);

  final keep = List<bool>.filled(nodes.length, false);
  var kept = 0;
  final patterns = <RegExp>[
    for (final p in protected.defaultPatterns)
      ?tryCompileRegex(p, caseSensitive: false),
  ];
  final patternHit = List<bool>.filled(patterns.length, false);
  for (var i = 0; i < nodes.length; i++) {
    final n = nodes[i];
    if (!countsInNodeBudget(n)) {
      keep[i] = true;
      continue;
    }
    final shown = TagResolver.displayTag(protected.tagPrefix, n.tag);
    var hit = protected.rawTags.contains(n.tag) ||
        protected.finalTags.contains(shown);
    for (var p = 0; p < patterns.length; p++) {
      if (!patternHit[p] && patterns[p].hasMatch(shown)) {
        patternHit[p] = true;
        hit = true;
      }
    }
    if (hit) {
      keep[i] = true;
      kept++;
    }
  }
  for (var i = 0; i < nodes.length && kept < quota; i++) {
    if (keep[i]) continue;
    keep[i] = true;
    kept++;
  }
  return (
    nodes: [
      for (var i = 0; i < nodes.length; i++)
        if (keep[i]) nodes[i],
    ],
    total: total,
  );
}
