/// §750 — индекс ассистента для натива.
///
/// Нативу (AppFunctions, без Flutter-движка) нужны подписи Направлений,
/// подключения (включая выключенные) и правила по приложениям — всё это
/// живёт в `lxbox_settings.json`, который Kotlin не открывает (ARCHITECTURE
/// § 5). Dart собирает сводку в момент запроса ([collectAssistantIndex]) и
/// передаёт её нативу аргументом `index` вызова (`assistantOverview`,
/// `assistantAppRoute`); нигде не хранится и заранее не считается.
library;

import 'dart:collection';

import '../../config/consts.dart' show kDetourTagPrefix;
import '../../models/custom_rule.dart';
import '../../models/direction.dart';
import '../../models/node_spec.dart';
import '../../models/server_list.dart';
import '../builder/rule_order.dart' show sortRulesByNum;
import '../debug/debug_registry.dart';
import '../node_hash.dart' show sourceNodeIdentities;
import '../settings_storage.dart';
import '../tag_resolver.dart';

/// Версия формы индекса (поле `v`).
const int kAssistantIndexVersion = 1;

/// Где в источниках лежит подключение: по этому адресу его включает и
/// выключает [setConnectionEnabled] (тот же путь, что у UI).
enum AssistantConnectionSlot {
  /// Одиночный сервер: флаг `enabled` самого источника (`toggleAt`).
  userServer,

  /// Член папки: флаг члена (`setMembersEnabled`).
  folderMember,

  /// Узел подписки: отметка в `disabledHashes` (`setSubscriptionNodesEnabled`).
  subscriptionNode,
}

/// Подключение (WG / AWG / OpenVPN / OpenConnect / Tailscale) в источниках.
class AssistantConnection {
  const AssistantConnection({
    required this.id,
    required this.name,
    required this.type,
    required this.enabled,
    required this.nodeEnabled,
    required this.sourceEnabled,
    required this.sourceName,
    required this.sourceIndex,
    required this.slot,
    required this.node,
    this.memberIndex,
  });

  /// Тег узла в конфиге ядра (с префиксом источника): из обратной карты
  /// последней сборки, а для невошедшего (выключенного) узла — тот тег,
  /// под которым он попал бы (`TagResolver.displayTag`).
  final String id;
  final String name;

  /// `wireguard` | `amneziawg` | `openvpn` | `openconnect` | `tailscale`.
  final String type;

  /// Узел реально в конфиге: включены и он сам, и его контейнер.
  final bool enabled;

  /// Флаг самого узла (член папки / отметка подписки / одиночный сервер).
  final bool nodeEnabled;

  /// Флаг контейнера (папки / подписки); у одиночного сервера всегда `true`.
  final bool sourceEnabled;
  final String sourceName;
  final int sourceIndex;
  final AssistantConnectionSlot slot;
  final int? memberIndex;
  final NodeSpec node;

  Map<String, dynamic> toIndexJson() => {
        'id': id,
        'name': name,
        'type': type,
        'enabled': enabled,
      };
}

/// §750 — вид подключения по модели узла; `null` — не подключение.
/// AWG = `WireguardSpec` с полями обфускации (`awg != null`, PROTOCOLS
/// § 8.5); `openvpn-client` / `openconnect` — типы реестра без модели
/// приложения, приходят `UnknownTypeSpec` (PROTOCOLS, задачи 586/654).
String? assistantConnectionType(NodeSpec node) => switch (node) {
      WireguardSpec(:final awg) => awg != null ? 'amneziawg' : 'wireguard',
      TailscaleSpec() => 'tailscale',
      UnknownTypeSpec(type: 'openvpn-client') => 'openvpn',
      UnknownTypeSpec(type: 'openconnect') => 'openconnect',
      _ => null,
    };

/// §750 — подключения из всех источников в порядке `sources[]`, включая
/// выключенные узлы и узлы выключенных контейнеров.
///
/// [emittedTagMap] — обратная карта последней сборки
/// (`SubscriptionController.lastEmittedTagMap`, финальный тег → исходный
/// узел): по ней берётся точный тег ядра (с учётом переименования тёзок).
List<AssistantConnection> assistantConnections(
  List<ServerList> lists, {
  Map<String, NodeSpec> emittedTagMap = const {},
}) {
  final emitted = LinkedHashMap<NodeSpec, String>.identity();
  for (final e in emittedTagMap.entries) {
    emitted.putIfAbsent(e.value, () => e.key);
  }
  String coreTag(ServerList list, NodeSpec node) =>
      emitted[node] ?? TagResolver.displayTag(list.tagPrefix, node.tag);

  final out = <AssistantConnection>[];
  for (var i = 0; i < lists.length; i++) {
    final list = lists[i];
    switch (list) {
      case UserServer():
        for (final node in list.nodes) {
          final type = assistantConnectionType(node);
          if (type == null) continue;
          out.add(AssistantConnection(
            id: coreTag(list, node),
            name: node.tag,
            type: type,
            enabled: list.enabled,
            nodeEnabled: list.enabled,
            sourceEnabled: true,
            sourceName: node.tag,
            sourceIndex: i,
            slot: AssistantConnectionSlot.userServer,
            node: node,
          ));
        }
      case FolderServers():
        for (var m = 0; m < list.members.length; m++) {
          final member = list.members[m];
          final node = member.node;
          if (node == null) continue;
          final type = assistantConnectionType(node);
          if (type == null) continue;
          out.add(AssistantConnection(
            id: coreTag(list, node),
            name: node.tag,
            type: type,
            enabled: list.enabled && member.enabled,
            nodeEnabled: member.enabled,
            sourceEnabled: list.enabled,
            sourceName: list.name,
            sourceIndex: i,
            slot: AssistantConnectionSlot.folderMember,
            memberIndex: m,
            node: node,
          ));
        }
      case SubscriptionServers():
        final identities = sourceNodeIdentities(list.nodes);
        for (final node in list.nodes) {
          final type = assistantConnectionType(node);
          if (type == null) continue;
          final identity = identities[node];
          final nodeOn =
              identity == null || !list.disabledHashes.containsKey(identity);
          out.add(AssistantConnection(
            id: coreTag(list, node),
            name: node.tag,
            type: type,
            enabled: list.enabled && nodeOn,
            nodeEnabled: nodeOn,
            sourceEnabled: list.enabled,
            sourceName: list.name,
            sourceIndex: i,
            slot: AssistantConnectionSlot.subscriptionNode,
            node: node,
          ));
        }
    }
  }
  return out;
}

/// §750 — у правила есть условия отбора, кроме пакетов: маршрут приложения
/// тогда зависит от них. У srs-правила условия лежат ещё и в наборе.
bool assistantRuleConditional(CustomRule r) {
  if (r is CustomRuleSrs) return true;
  return r.domains.isNotEmpty ||
      r.domainSuffixes.isNotEmpty ||
      r.domainKeywords.isNotEmpty ||
      r.domainRegexes.isNotEmpty ||
      r.ipCidrs.isNotEmpty ||
      r.ports.isNotEmpty ||
      r.portRanges.isNotEmpty ||
      r.protocols.isNotEmpty ||
      r.network.isNotEmpty ||
      r.ipIsPrivate ||
      r.sourceIpCidrs.isNotEmpty ||
      r.sourceIpIsPrivate ||
      r.inbounds.isNotEmpty ||
      r.wifiSsids.isNotEmpty ||
      r.wifiBssids.isNotEmpty ||
      r.networkTypes.isNotEmpty ||
      r.networkIsExpensive;
}

/// §750 — чистая сборка индекса.
///
/// - `directions` — все Направления, `name` = подпись пользователя
///   (`label`, при пустой — тег), без служебного префикса detour ⚙.
/// - `connections` — [assistantConnections].
/// - `app_rules` — включённые inline/srs-правила с `packages` /
///   `package_regexes` в порядке применения (`sortRulesByNum`). Пресеты не
///   разворачиваются: их условия живут в шаблоне.
/// - `route_final` — как его читает приложение: пусто → `vpn-1` (так же
///   экран Routing); остальное — как записано (`direct-out`, `block`, тег).
Map<String, dynamic> buildAssistantIndex({
  required List<Direction> directions,
  required List<CustomRule> rules,
  required List<ServerList> lists,
  required String routeFinal,
  Map<String, NodeSpec> emittedTagMap = const {},
}) {
  return {
    'v': kAssistantIndexVersion,
    'route_final': routeFinal.isEmpty ? 'vpn-1' : routeFinal,
    'directions': [
      for (final d in directions)
        {
          'tag': d.tag,
          'name': _directionName(d),
          'enabled': d.enabled || d.isRequired,
        },
    ],
    'connections': [
      for (final c in assistantConnections(lists, emittedTagMap: emittedTagMap))
        c.toIndexJson(),
    ],
    'app_rules': [
      for (final r in sortRulesByNum(rules))
        if (r.enabled &&
            (r is CustomRuleInline || r is CustomRuleSrs) &&
            (r.packages.isNotEmpty || r.packageRegexes.isNotEmpty))
          {
            'name': r.name,
            'packages': [...r.packages],
            'package_regexes': [...r.packageRegexes],
            'outbound': r.outbound,
            'conditional': assistantRuleConditional(r),
          },
    ],
  };
}

String _directionName(Direction d) {
  final base = d.label.isNotEmpty ? d.label : d.tag;
  return base.startsWith(kDetourTagPrefix)
      ? base.substring(kDetourTagPrefix.length).trim()
      : base;
}

/// §750 — собрать индекс сейчас, в момент запроса (предрасчёта нет: решение
/// владельца — всё по требованию).
///
/// Источники — из контроллера подписок, если он поднят (у подписок узлы
/// живут в кэше, в хранилище их нет); иначе — из хранилища. [lists] и
/// [emittedTagMap] — inject-точки тестов.
Future<Map<String, Object?>> collectAssistantIndex({
  List<ServerList>? lists,
  Map<String, NodeSpec>? emittedTagMap,
}) async {
  final sub = DebugRegistry.I.sub;
  final sources = lists ??
      (sub != null
          ? [for (final e in sub.entries) e.list]
          : await SettingsStorage.getServerLists());
  return buildAssistantIndex(
    directions: await SettingsStorage.getDirections(),
    rules: await SettingsStorage.getCustomRules(),
    lists: sources,
    routeFinal: await SettingsStorage.getRouteFinal(),
    emittedTagMap: emittedTagMap ?? sub?.lastEmittedTagMap ?? const {},
  );
}
