/// Кодек члена папки `kind: auto` (§439, трек N2): узел автовыбора
/// [AutoSelectSpec] ↔ запись `sources[].nodes[]` контракта 1.0
/// (`$defs/node` + `$defs/autoGroup`). Хранение и LX Backup пишут одну форму.
///
/// ```json
/// { "kind": "auto", "tag": "Auto", "enabled": true,
///   "group": {
///     "group_type": "urltest",
///     "members": [ { "folder_id": "<id папки>", "tag": "de-1" } ],
///     "strategy": { "mode": "least_test", "url": "…", "interval": "15m",
///                   "tolerance": 50, "idle_timeout": "30m",
///                   "interrupt_exist_connections": false },
///     "members_rule": { "include": "^DE", "exclude": "" },
///     "pool_badge": "…" } }
/// ```
///
/// К — `kind`, `tag`, `enabled`, `group{group_type, members, strategy}`.
/// Поля стороны LxBox внутри `group` (контракт 1.0.1, BACKUP.md §2 «Поля
/// стороны LxBox»): `members_rule` (членство правилом: регулярки не ссылки,
/// NODE_LINK §9.1) и `pool_badge` (значки строки списка, в конфиг не уходят).
/// У группы-правила `members` нет: состав считает сборка.
///
/// Писатель: `group_type` всегда `urltest`, члены — только парами (NODE_LINK
/// §2 п. 1). Читатель терпим (решение 15.09): член `{tag}` → пара с `id` своей
/// папки (S1); `default` строкой → пара, если член с этим тегом ровно один
/// (S2); у urltest-группы LxBox `default` нет, он называется потерей;
/// `selector` читается urltest'ом с предупреждением. `members_rule` и
/// `pool_badge` уровня узла — форма dev-сборок до контракта 1.0.1 — читаются
/// молча; `group` сильнее. Непустой `members[]` сильнее `members_rule`: по
/// схеме группа-правило явного состава не несёт.
library;

import 'package:collection/collection.dart';

import '../../services/parser/uri_utils.dart' show newUuidV4;
import '../auto_select.dart';
import '../direction.dart' show StickyHashKey, UrltestMode;
import '../node_link.dart';
import '../node_spec.dart';
import '../server_list.dart';
import 'node_link_record.dart';

/// Вид члена папки — узел автовыбора.
const String kNodeKindAuto = 'auto';

const String _kGroupUrltest = 'urltest';
const String _kGroupSelector = 'selector';

/// Тег записи без тега (так же называл безымянную группу прежний разбор).
const String _kUntaggedAuto = 'Auto';

/// `members_rule` и `pool_badge` на уровне узла — dev-форма до 1.0.1.
const Set<String> _autoKeys = {
  'kind', 'tag', 'enabled', 'group', 'members_rule', 'pool_badge',
};

const Set<String> _groupKeys = {
  'group_type', 'default', 'members', 'strategy', 'members_rule', 'pool_badge',
};

const Set<String> _ruleKeys = {'include', 'exclude'};

/// `$defs/directionAuto` — форма `strategy`.
const Set<String> _strategyKeys = {
  'mode', 'url', 'interval', 'tolerance', 'idle_timeout',
  'interrupt_exist_connections', 'pool', 'pool_tolerance', 'sticky_hash',
};

// ─── запись ─────────────────────────────────────────────────────────────────

/// Член-группа [m] папки [folderId] → запись `kind: auto`. Корневая ссылка
/// члена (группа, приехавшая без адреса контейнера) пишется парой с
/// [folderId].
Map<String, dynamic> autoGroupMemberToRecord(
  FolderMember m,
  AutoSelectSpec group,
  String folderId,
) {
  final membership = group.membership;
  return {
    'kind': kNodeKindAuto,
    if (group.tag.isNotEmpty) 'tag': group.tag,
    'enabled': m.enabled,
    'group': {
      'group_type': _kGroupUrltest,
      if (membership is ExplicitMembers)
        'members': [
          for (final l in membership.members)
            nodeLinkToRecord(
                l.isRoot ? NodeLink(folderId: folderId, tag: l.tag) : l),
        ],
      'strategy': autoSelectParamsToStrategy(group.params),
      // Поля стороны LxBox (контракт 1.0.1).
      if (membership is RuleMembers)
        'members_rule': {
          'include': membership.include,
          'exclude': membership.exclude,
        },
      if (group.poolBadge != kDefaultPoolBadge) 'pool_badge': group.poolBadge,
    },
  };
}

/// [AutoSelectParams] → `strategy` формы `$defs/directionAuto`.
///
/// Поля пула значат что-то только у `round_robin`; у `least_test` они
/// пишутся, лишь когда отличаются от умолчания, — это настройка редактора,
/// которая вернётся при обратном переключении режима. Выключенная липкость —
/// явный `["none"]`: пустой список ядро схлопывает в умолчание.
Map<String, dynamic> autoSelectParamsToStrategy(AutoSelectParams p) {
  const d = AutoSelectParams();
  final rr = p.mode == UrltestMode.roundRobin;
  return {
    'mode': p.mode.wire,
    'url': p.url,
    'interval': p.interval,
    'tolerance': p.tolerance,
    'idle_timeout': p.idleTimeout,
    'interrupt_exist_connections': p.interruptExistConnections,
    if (rr || p.pool != d.pool) 'pool': p.pool,
    if (rr || p.poolTolerance != d.poolTolerance)
      'pool_tolerance': p.poolTolerance,
    if (rr ||
        !const ListEquality<StickyHashKey>().equals(p.stickyHash, d.stickyHash))
      'sticky_hash': p.stickyHash.isEmpty
          ? ['none']
          : [for (final k in p.stickyHash) k.wire],
  };
}

// ─── чтение ─────────────────────────────────────────────────────────────────

/// Итог чтения записи `kind: auto`: член папки и признак, что группа
/// приехала `selector`'ом (импорт называет это предупреждением).
typedef AutoGroupRead = ({FolderMember member, bool fromSelector});

/// Запись `kind: auto` папки [folderId] → член-группа. Не бросает.
///
/// Что прочитано не дословно — строкой в [notes] с [where]; незнакомые ключи
/// — путями в [unknown] от [path] (`nodes[3].group.fold`).
AutoGroupRead autoGroupMemberFromRecord(
  Map<String, dynamic> j, {
  required String folderId,
  required String where,
  List<String>? notes,
  List<String>? unknown,
  String path = '',
}) {
  _collectUnknown(j, _autoKeys, path, unknown);

  final rawTag = j['tag'];
  var tag = rawTag is String ? rawTag.trim() : '';
  if (tag.isEmpty) {
    notes?.add('$where: auto node without tag, named "$_kUntaggedAuto"');
    tag = _kUntaggedAuto;
  }

  final rawGroup = j['group'];
  final group = rawGroup is Map
      ? rawGroup.cast<String, dynamic>()
      : const <String, dynamic>{};
  if (rawGroup is! Map) {
    notes?.add('$where: auto node without group, read with no members');
  }
  _collectUnknown(group, _groupKeys, '${path}group.', unknown);

  final type = group['group_type'];
  final fromSelector = type == _kGroupSelector;
  if (fromSelector) {
    notes?.add('$where: selector group is read as urltest');
  } else if (type != _kGroupUrltest) {
    notes?.add('$where: group_type "$type" is read as urltest');
  }

  final links = <NodeLink>[];
  final rawMembers = group['members'];
  if (rawMembers is List) {
    for (var i = 0; i < rawMembers.length; i++) {
      final link = nodeLinkFromRecord(rawMembers[i]);
      if (link == null || link.tag.isEmpty) {
        notes?.add('$where: group.members[$i] is not a link, dropped');
        continue;
      }
      // S1 — член без контейнера адресует свою папку.
      links.add(link.isRoot ? NodeLink(folderId: folderId, tag: link.tag) : link);
    }
  }

  final rawDefault = group['default'];
  if (rawDefault != null) {
    final def = _defaultLink(rawDefault, links, folderId);
    notes?.add('$where: group.default '
        '"${def == null ? rawDefault : def.tag}" is not kept, '
        'the group is urltest');
  }

  // Поле стороны LxBox — в `group`; уровень узла — dev-форма до 1.0.1.
  final inGroup = group.containsKey('members_rule');
  final rule = inGroup ? group['members_rule'] : j['members_rule'];
  final AutoSelectMembership membership;
  if (rule is Map && links.isEmpty) {
    _collectUnknown(rule, _ruleKeys,
        '$path${inGroup ? 'group.' : ''}members_rule.', unknown);
    membership = RuleMembers(
      include: rule['include'] is String ? rule['include'] as String : '',
      exclude: rule['exclude'] is String ? rule['exclude'] as String : '',
    );
  } else {
    if (rule is Map) {
      notes?.add('$where: group.members wins, members_rule ignored');
    }
    membership = ExplicitMembers(links);
  }

  final strategy = group['strategy'];
  if (strategy is Map) {
    _collectUnknown(strategy, _strategyKeys, '${path}group.strategy.', unknown);
  }
  final badge =
      group.containsKey('pool_badge') ? group['pool_badge'] : j['pool_badge'];
  final enabled = j['enabled'];

  return (
    member: FolderMember.auto(
      AutoSelectSpec(
        id: newUuidV4(),
        tag: tag,
        label: tag,
        membership: membership,
        params: autoSelectParamsFromStrategy(strategy),
        poolBadge: badge is String ? badge : kDefaultPoolBadge,
      ),
      enabled: enabled is bool ? enabled : true,
    ),
    fromSelector: fromSelector,
  );
}

/// `strategy` формы `$defs/directionAuto` → [AutoSelectParams]. Поле не того
/// типа — умолчание; `["none"]` в `sticky_hash` — липкость выключена.
AutoSelectParams autoSelectParamsFromStrategy(Object? raw) {
  const d = AutoSelectParams();
  if (raw is! Map) return d;
  String str(String key, String fallback) {
    final v = raw[key];
    return v is String ? v : fallback;
  }

  int integer(String key, int fallback) {
    final v = raw[key];
    return v is num ? v.toInt() : fallback;
  }

  final sticky = raw['sticky_hash'];
  final interrupt = raw['interrupt_exist_connections'];
  final mode = raw['mode'];
  return AutoSelectParams(
    mode: UrltestMode.fromWire(mode is String ? mode : null),
    url: str('url', d.url),
    interval: str('interval', d.interval),
    tolerance: integer('tolerance', d.tolerance),
    idleTimeout: str('idle_timeout', d.idleTimeout),
    interruptExistConnections:
        interrupt is bool ? interrupt : d.interruptExistConnections,
    pool: integer('pool', d.pool),
    poolTolerance:
        clampPoolTolerance(integer('pool_tolerance', d.poolTolerance)),
    stickyHash: sticky is List
        ? (sticky.contains('none')
            ? const <StickyHashKey>[]
            : [
                for (final k in sticky)
                  ?StickyHashKey.fromWire(k is String ? k : null),
              ])
        : d.stickyHash,
  );
}

/// S2 — `default` группы → ссылка: строка становится парой, если член с этим
/// тегом ровно один, иначе остаётся корневой; объект читается ссылкой с S1.
NodeLink? _defaultLink(Object? raw, List<NodeLink> members, String folderId) {
  if (raw is String) {
    if (raw.isEmpty) return null;
    final hits = members.where((l) => l.tag == raw).toList();
    return hits.length == 1 ? hits.single : NodeLink(tag: raw);
  }
  final link = nodeLinkFromRecord(raw);
  if (link == null || link.tag.isEmpty) return null;
  return link.isRoot ? NodeLink(folderId: folderId, tag: link.tag) : link;
}

void _collectUnknown(
  Map<dynamic, dynamic> j,
  Set<String> known,
  String prefix,
  List<String>? out,
) {
  if (out == null) return;
  for (final k in j.keys) {
    if (!known.contains(k)) out.add('$prefix$k');
  }
}
