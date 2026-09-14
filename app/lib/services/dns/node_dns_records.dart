// ===========================================================================
// §435 — производные DNS-записи узлов для экрана DNS Settings (спека §9.2,
// NODE_SECTIONS.md §7). Секции узла (`UserServer.sections`,
// `FolderMember.sections`) хранятся с плейсхолдерами `@self`; экран
// показывает их read-only ПОСЛЕ подстановки display-тега узла с пометкой
// «from node <тег>». Записи — производные, как preset-серверы в
// `DnsController.load`: в `_servers`/`_rules` экрана они не кладутся
// (резолверы `resolveDnsServersList`/`resolveDnsRulesList` отбросили бы чужой
// kind и персистили усечённый список).
//
// Чистые функции над `List<ServerList>` — без storage и BuildContext, чтобы
// тестировались изолированно (`node_dns_records_test.dart`).
// ===========================================================================

import '../../models/dns_ref.dart';
import '../../models/node_sections.dart';
import '../../models/node_spec.dart';
import '../../models/server_list.dart';
import '../tag_resolver.dart';

/// DNS-сервер узла после подстановки `@self` + владелец.
final class NodeDnsServerRecord {
  const NodeDnsServerRecord({
    required this.nodeTag,
    required this.server,
    required this.nodeEnabled,
  });

  /// Display-тег узла (`TagResolver.displayTag(prefix, node.tag)`) — тот же,
  /// что подставлен в запись.
  final String nodeTag;

  /// Запись после `substituteSelf` — тело рендерится тем же кодом, что у
  /// корневых серверов.
  final DnsServerInline server;

  /// Источник и член включены. false → строка приглушена с подсказкой «node
  /// is disabled» (паритет с лаунчером, спека §9.1/§9.2): в конфиг такой
  /// узел не попадает, но пользователь видит, что появится при включении.
  final bool nodeEnabled;
}

/// DNS-правило узла после подстановки `@self` + владелец.
final class NodeDnsRuleRecord {
  const NodeDnsRuleRecord({
    required this.nodeTag,
    required this.rule,
    required this.nodeEnabled,
  });

  final String nodeTag;
  final DnsRuleInline rule;
  final bool nodeEnabled;
}

/// Опция пикера `endpoint` у DNS-сервера типа `tailscale` (спека §9.4):
/// display-тег узла Tailscale. `enabled == false` → узел/источник выключен,
/// сервер на него санитайзер сборки выбросит (endpoint не эмитирован) —
/// пикер помечает «disabled — will be skipped» (как у членов DNS-группы).
final class TailscaleEndpointOption {
  const TailscaleEndpointOption({required this.tag, required this.enabled});
  final String tag;
  final bool enabled;
}

/// Всё, что экран DNS выводит из списков источников за один проход.
final class NodeDnsRecords {
  const NodeDnsRecords({
    this.servers = const [],
    this.rules = const [],
    this.tailscaleEndpoints = const [],
  });

  final List<NodeDnsServerRecord> servers;
  final List<NodeDnsRuleRecord> rules;
  final List<TailscaleEndpointOption> tailscaleEndpoints;

  bool get isEmpty =>
      servers.isEmpty && rules.isEmpty && tailscaleEndpoints.isEmpty;
}

/// Обход свободных узлов (UserServer, члены папок; у подписок и цепочек
/// секций нет — NODE_SECTIONS.md §1) в порядке хранения. Узел без
/// распарсенного `NodeSpec` пропускается — тега для подстановки нет. Тег —
/// `TagResolver.displayTag(prefix, node.tag)`, как до первой сборки (спека
/// §5); выключенные узлы НЕ пропускаются (в отличие от сборки), а помечаются
/// `nodeEnabled: false`.
///
/// Здесь же собираются опции `endpoint` для формы DNS-сервера `tailscale`:
/// узлы `TailscaleSpec` тех же источников. Дубль display-тега — первый
/// побеждает (дропдаун требует уникальных значений).
NodeDnsRecords collectNodeDnsRecords(List<ServerList> lists) {
  final servers = <NodeDnsServerRecord>[];
  final rules = <NodeDnsRuleRecord>[];
  final endpoints = <TailscaleEndpointOption>[];
  final seenEndpointTags = <String>{};

  void visit(ServerList list, NodeSpec? node, NodeSections? sections,
      {required bool memberEnabled}) {
    if (node == null) return;
    final tag = TagResolver.displayTag(list.tagPrefix, node.tag);
    final enabled = list.enabled && memberEnabled;
    if (node is TailscaleSpec && seenEndpointTags.add(tag)) {
      endpoints.add(TailscaleEndpointOption(tag: tag, enabled: enabled));
    }
    if (sections == null || sections.isEmpty) return;
    final s = sections.substituteSelf(tag);
    for (final srv in s.dnsServers) {
      servers.add(NodeDnsServerRecord(
        nodeTag: tag,
        server: srv,
        nodeEnabled: enabled,
      ));
    }
    for (final r in s.dnsRules) {
      rules.add(NodeDnsRuleRecord(nodeTag: tag, rule: r, nodeEnabled: enabled));
    }
  }

  for (final list in lists) {
    switch (list) {
      case UserServer u:
        visit(u, u.nodes.isEmpty ? null : u.nodes.first, u.sections,
            memberEnabled: true);
      case FolderServers f:
        for (final m in f.members) {
          visit(f, m.node, m.sections, memberEnabled: m.enabled);
        }
      case SubscriptionServers():
        break;
    }
  }
  return NodeDnsRecords(
    servers: servers,
    rules: rules,
    tailscaleEndpoints: endpoints,
  );
}
