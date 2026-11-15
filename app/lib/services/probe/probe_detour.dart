/// §730 — detour источника в «Тесте серверов» (probe-сессия без VPN).
///
/// Боевая сборка ведёт узлы источника через `DetourPolicy.overrideDetour`
/// (ссылка D-112, разрешается вторым проходом сборки), а probe-конфиг
/// собирается без политики. Здесь — чистая классификация: по источнику и
/// списку всех источников решить для каждого тестируемого узла, можно ли
/// пройти тот же путь в пробе.
///
/// Правило владельца (15.11.2026): статический detour (ссылка на конкретный
/// узел) учитываем; динамический (Направление и его `-auto`, служебный
/// outbound шаблона, цепочка, узел-группа) не учитываем и явно пишем это на
/// экране. Один уровень: цель, у которой свой override, — «не учтён».
///
/// Индекс плана = индекс [ProbeController.probeNodesOf]: у папки — члены
/// (без фильтра enabled), у подписки и сервера — `nodes`.
library;

import '../../models/node_link.dart';
import '../../models/node_spec.dart';
import '../../models/server_list.dart';
import '../../models/tls_policy.dart';
import '../builder/server_list_build.dart' show FolderDetourPlan;
import '../node_hash.dart' show sourceNodeIdentities;
import '../node_link_address.dart' show containerRawTags;
import '../tag_resolver.dart';

/// Исход для одного узла.
enum ProbeDetourKind {
  /// detour не задан (или снят `useDetourServers=false` без replace).
  none,

  /// Узел в пробе идёт через цель — как в туннеле.
  applied,

  /// detour задан, но в пробе не воспроизводится: узел проверяется напрямую.
  unapplied,
}

/// Маршрут одного узла в пробе.
final class ProbeDetourRoute {
  const ProbeDetourRoute.none()
      : kind = ProbeDetourKind.none,
        target = null,
        replace = false,
        targetSkipChain = false,
        targetTls = const TlsLayers(),
        targetLabel = '';

  const ProbeDetourRoute.unapplied()
      : kind = ProbeDetourKind.unapplied,
        target = null,
        replace = false,
        targetSkipChain = false,
        targetTls = const TlsLayers(),
        targetLabel = '';

  const ProbeDetourRoute.applied({
    required NodeSpec this.target,
    required this.replace,
    required this.targetLabel,
    this.targetSkipChain = false,
    this.targetTls = const TlsLayers(),
  }) : kind = ProbeDetourKind.applied;

  final ProbeDetourKind kind;

  /// Цель (только [ProbeDetourKind.applied]).
  final NodeSpec? target;

  /// REPLACE (§073): родная цепочка узла не эмитится; иначе APPEND — цель
  /// хвостом родной цепочки.
  final bool replace;

  /// У источника цели `useDetourServers=false`: её родная цепочка в боевой
  /// сборке снята — снимаем и в пробе.
  final bool targetSkipChain;

  /// §636 — уровни TLS-политики цели (как у её источника в туннеле).
  final TlsLayers targetTls;

  /// Тег цели для пометки «Tested through %s.» (префикс источника + сырой
  /// тег; уникализацию сборки не воспроизводим).
  final String targetLabel;
}

/// План по индексам пробы. Узлы без detour в карте отсутствуют.
final class ProbeDetourPlan {
  const ProbeDetourPlan(this.byIndex);

  static const empty = ProbeDetourPlan({});

  /// План одного узла (диагностика узла: в пробе он под индексом 0).
  factory ProbeDetourPlan.single(ProbeDetourRoute route) =>
      ProbeDetourPlan(route.kind == ProbeDetourKind.none ? const {} : {0: route});

  final Map<int, ProbeDetourRoute> byIndex;

  ProbeDetourRoute at(int i) => byIndex[i] ?? const ProbeDetourRoute.none();

  /// Ни у одного узла detour не задан — пометки нет, проба прежняя.
  bool get isEmpty => byIndex.isEmpty;

  int get appliedCount =>
      byIndex.values.where((r) => r.kind == ProbeDetourKind.applied).length;

  int get unappliedCount =>
      byIndex.values.where((r) => r.kind == ProbeDetourKind.unapplied).length;

  /// Различные цели учтённых узлов, в порядке первого появления.
  List<String> get appliedLabels => [
        ...{
          for (final r in byIndex.values)
            if (r.kind == ProbeDetourKind.applied) r.targetLabel,
        },
      ];
}

/// Политика активна так же, как в боевой сборке (`server_list_build.dart`):
/// REPLACE применяет ссылку и при `useDetourServers=false`, APPEND — нет.
bool _linkActive(DetourPolicy p) =>
    p.overrideDetour.isNotEmpty &&
    (p.useDetourServers || p.replaceDetourChain);

/// План для источника [source]; [all] — все источники (как
/// `SubscriptionController.entries`), среди них ищется цель ссылки.
ProbeDetourPlan probeDetourPlanOf(ServerList source, List<ServerList> all) {
  final out = <int, ProbeDetourRoute>{};
  switch (source) {
    case FolderServers(:final members):
      if (source.detourPolicy.overrideDetour.isEmpty &&
          members.every((m) => m.detour.isEmpty)) {
        break;
      }
      // Эффективная политика члена — та же, что у боевой сборки
      // (`FolderDetourPlan.policyFor`: личный detour, exempt, папочный
      // replace). Проба тестирует и выключенных членов, поэтому план
      // считается над папкой «как если бы все были включены»: индекс
      // плана = порядковый номер среди членов с узлом.
      final whole = source.copyWith(members: [
        for (final m in members) m.enabled ? m : m.copyWith(enabled: true),
      ]);
      final plan = FolderDetourPlan(whole);
      var k = 0;
      for (var i = 0; i < members.length; i++) {
        final node = members[i].node;
        if (node == null) continue;
        final policy = plan.policyFor(k++, source.detourPolicy);
        final r = _routeFor(node, policy, all);
        if (r.kind != ProbeDetourKind.none) out[i] = r;
      }
    default:
      final policy = source.detourPolicy;
      if (!_linkActive(policy)) break;
      for (var i = 0; i < source.nodes.length; i++) {
        final r = _routeFor(source.nodes[i], policy, all);
        if (r.kind != ProbeDetourKind.none) out[i] = r;
      }
  }
  return ProbeDetourPlan(out);
}

ProbeDetourRoute _routeFor(
  NodeSpec node,
  DetourPolicy policy,
  List<ServerList> all,
) {
  if (!_linkActive(policy)) return const ProbeDetourRoute.none();
  // Узел, который проба не тестирует (группа §336, Tailscale §435), пометки
  // не требует: вердикт у него свой.
  if (node.isGroup || node is TailscaleSpec) {
    return const ProbeDetourRoute.none();
  }
  final found = _findTarget(policy.overrideDetour, all);
  if (found == null) return const ProbeDetourRoute.unapplied();
  final (:target, :source, :index, :label) = found;
  if (identical(target, node)) return const ProbeDetourRoute.unapplied();
  if (target.isGroup || target is TailscaleSpec) {
    return const ProbeDetourRoute.unapplied();
  }
  // Цель, которой нет в туннеле, — боевая сборка уронит узлы (fail-closed),
  // проба через неё вводила бы в заблуждение.
  if (!_targetEnabled(source, target, index)) {
    return const ProbeDetourRoute.unapplied();
  }
  // Прокси за прокси — один уровень (решение владельца 15.11.2026).
  final targetPolicy = _effectivePolicy(source, index);
  if (_linkActive(targetPolicy)) return const ProbeDetourRoute.unapplied();
  return ProbeDetourRoute.applied(
    target: target,
    replace: policy.replaceDetourChain,
    targetLabel: label,
    targetSkipChain: !targetPolicy.useDetourServers,
    targetTls: _tlsOf(source, index),
  );
}

/// Цель ссылки [link]: узел, его источник, индекс в `containerNodes`
/// источника (у папки — среди членов с узлом), тег для пометки. `null` —
/// ссылка не на конкретный узел или неоднозначна.
({NodeSpec target, ServerList source, int index, String label})? _findTarget(
  NodeLink link,
  List<ServerList> all,
) {
  if (link.isRoot) {
    // Корневая ссылка: финальный тег. Конкретный узел — только узел
    // одиночного сервера; иначе это Направление, служебный outbound,
    // цепочка — динамика.
    ({NodeSpec target, ServerList source, int index, String label})? hit;
    var count = 0;
    for (final l in all) {
      if (l is! UserServer) continue;
      for (var i = 0; i < l.nodes.length; i++) {
        final n = l.nodes[i];
        if (TagResolver.displayTag(l.tagPrefix, n.tag) != link.tag) continue;
        count++;
        hit = (target: n, source: l, index: i, label: link.tag);
      }
    }
    return count == 1 ? hit : null;
  }
  final container = all.where((l) => l.id == link.folderId).firstOrNull;
  if (container == null || container is UserServer) return null;
  final raw = containerRawTags(container);
  final nodes = _containerNodes(container);
  for (var i = 0; i < nodes.length; i++) {
    if (raw[nodes[i]] == link.tag) {
      return (
        target: nodes[i],
        source: container,
        index: i,
        label: TagResolver.displayTag(container.tagPrefix, link.tag),
      );
    }
  }
  return null;
}

/// Узлы контейнера в порядке, к которому привязан индекс цели: у папки —
/// члены с узлом (выключенные тоже), иначе `nodes`.
List<NodeSpec> _containerNodes(ServerList l) => switch (l) {
      FolderServers(:final members) => [
          for (final m in members)
            if (m.node != null) m.node!,
        ],
      _ => l.nodes,
    };

FolderMember? _memberAt(FolderServers f, int index) {
  var k = 0;
  for (final m in f.members) {
    if (m.node == null) continue;
    if (k++ == index) return m;
  }
  return null;
}

bool _targetEnabled(ServerList source, NodeSpec target, int index) {
  if (!source.enabled) return false;
  return switch (source) {
    SubscriptionServers(:final disabledHashes, :final nodes) =>
      !disabledHashes.containsKey(sourceNodeIdentities(nodes)[target]),
    FolderServers f => _memberAt(f, index)?.enabled ?? false,
    _ => true,
  };
}

/// Эффективная политика узла-цели в его источнике (у члена папки —
/// `FolderDetourPlan.policyFor` по индексу среди включённых членов).
DetourPolicy _effectivePolicy(ServerList source, int index) {
  if (source is! FolderServers) return source.detourPolicy;
  // Индекс среди включённых членов (выровнен с `FolderServers.nodes`);
  // цель здесь всегда включена — её проверил `_targetEnabled`.
  var enabledIndex = -1;
  var seen = 0;
  var k = 0;
  for (final m in source.members) {
    if (m.node == null) continue;
    if (k == index) {
      enabledIndex = seen;
      break;
    }
    if (m.enabled) seen++;
    k++;
  }
  if (enabledIndex < 0) return source.detourPolicy;
  return FolderDetourPlan(source).policyFor(enabledIndex, source.detourPolicy);
}

TlsLayers _tlsOf(ServerList source, int index) => switch (source) {
      FolderServers f =>
        TlsLayers(node: _memberAt(f, index)?.tls ?? TlsPolicy.none, source: f.tls),
      UserServer(:final tls) => TlsLayers(node: tls),
      _ => TlsLayers(source: source.tls),
    };
