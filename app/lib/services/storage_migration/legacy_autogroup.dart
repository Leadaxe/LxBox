/// Член-группа папки в тексте `autogroup://…` — форма 2.23.2 (§322), разбор
/// которой снят в §439 N2. Замороженный читатель и перевод состава в узлы
/// папки: один путь на миграцию хранения (`migrateAutogroupMembers`) и импорт
/// LX Backup 0.x (`lx_backup.dart`), чтобы группа из файла и группа из
/// хранения переводились одинаково.
library;

import '../../models/auto_select.dart';
import '../../models/direction.dart' show StickyHashKey, UrltestMode;
import '../../models/node_link.dart';
import '../../models/node_spec.dart';
import '../node_identity.dart';
import '../parser/uri_utils.dart' show newUuidV4, tagFromLabel;

/// Схема члена-группы папки в хранении и файле 0.x до §439 N2.
const String kLegacyAutogroupScheme = 'autogroup://';

/// Текст члена папки — группа `autogroup://`.
bool isLegacyAutogroupText(Object? raw) =>
    raw is String &&
    raw.trimLeft().toLowerCase().startsWith(kLegacyAutogroupScheme);

/// Итог перевода группы: узел автовыбора и члены состава, которые сняты
/// (`<ключ или тег>: <причина>`).
typedef LegacyAutogroup = ({AutoSelectSpec group, List<String> dropped});

/// Текст [raw] группы папки → узел автовыбора. `null` — текст не читается.
///
/// - Режим правила (`include`/`exclude`, «все члены») переносится как есть.
/// - Явный состав — ключи `protocol|server|port|credential` — становится
///   ссылками [linkOf] на члены той же папки (индекс в [nodes] и тег узла):
///   [nodes] — разобранные члены по месту (`null` — не разобран или сам
///   группа), [enabledAt] — включён ли член. Ключ нескольких членов решает
///   включённый, если он один (его и собирала сборка 2.23.2). Ключ без члена,
///   неоднозначный ключ, член без тега или с тегом, который носит ещё кто-то
///   в папке, в состав не входят и называются в `dropped`.
LegacyAutogroup? legacyAutogroupSpec(
  String raw, {
  required List<NodeSpec?> nodes,
  required bool Function(int index) enabledAt,
  required NodeLink Function(int index, String tag) linkOf,
}) {
  final legacy = _readLegacyAutogroup(raw.trim());
  if (legacy == null) return null;
  final label = legacy.label.isEmpty ? 'Auto' : legacy.label;
  final tag = tagFromLabel(label, 'urltest', 'auto', 0);
  final dropped = <String>[];
  final keys = legacy.keys;
  final AutoSelectMembership membership;
  if (keys == null) {
    membership = RuleMembers(include: legacy.include, exclude: legacy.exclude);
  } else {
    final links = <NodeLink>[];
    for (final key in keys) {
      final member = _memberTagOfKey(key, nodes, enabledAt);
      if (member.error != null) {
        dropped.add(member.error!);
        continue;
      }
      final link = linkOf(member.index!, member.tag!);
      if (!links.contains(link)) links.add(link);
    }
    membership = ExplicitMembers(links);
  }
  return (
    group: AutoSelectSpec(
      id: newUuidV4(),
      tag: tag,
      label: label,
      membership: membership,
      params: legacy.params,
      poolBadge: legacy.poolBadge,
    ),
    dropped: dropped,
  );
}

/// Ключ `protocol|server|port|credential` → тег члена папки.
({int? index, String? tag, String? error}) _memberTagOfKey(
  String key,
  List<NodeSpec?> nodes,
  bool Function(int index) enabledAt,
) {
  var hits = [
    for (var i = 0; i < nodes.length; i++)
      if (nodes[i] case final n? when nodeIdentityKey(n) == key) i,
  ];
  // Сборка до N2 брала только включённых членов.
  if (hits.length > 1) hits = hits.where(enabledAt).toList();
  if (hits.isEmpty) {
    return (index: null, tag: null, error: 'key "$key" matches no node');
  }
  if (hits.length > 1) {
    return (
      index: null,
      tag: null,
      error: 'key "$key" matches ${hits.length} nodes',
    );
  }
  final tag = nodes[hits.single]!.tag;
  if (tag.isEmpty) {
    return (index: null, tag: null, error: 'key "$key" has an untagged node');
  }
  final sameTag = nodes.where((n) => n?.tag == tag).length;
  if (sameTag > 1) {
    return (
      index: null,
      tag: null,
      error: 'tag "$tag" is carried by $sameTag nodes',
    );
  }
  return (index: hits.single, tag: tag, error: null);
}

/// Разбор `autogroup://?members=…|include=…&mode=…#Label` — замороженная
/// форма 2.23.2 (`autoGroupFromUri`). [keys] `null` — режим правила.
({
  String label,
  List<String>? keys,
  String include,
  String exclude,
  AutoSelectParams params,
  String poolBadge,
})? _readLegacyAutogroup(String raw) {
  final uri = Uri.tryParse(raw);
  if (uri == null) return null;
  try {
    final q = uri.queryParameters;
    const d = AutoSelectParams();
    final rawMembers = q['members'];
    final sticky = q['sticky'];
    return (
      label: Uri.decodeComponent(uri.fragment),
      // §352 — узкое экранирование ключа: `,` и `%`.
      keys: rawMembers?.split(',')
          .map((e) =>
              e.trim().replaceAll('%2C', ',').replaceAll('%25', '%'))
          .where((e) => e.isNotEmpty)
          .toList(),
      include: q['include'] ?? '',
      exclude: q['exclude'] ?? '',
      params: AutoSelectParams(
        url: q['url'] ?? d.url,
        interval: q['interval'] ?? d.interval,
        tolerance: int.tryParse(q['tolerance'] ?? '') ?? d.tolerance,
        idleTimeout: q['idle_timeout'] ?? d.idleTimeout,
        interruptExistConnections: q['interrupt'] == '1',
        mode: UrltestMode.fromWire(q['mode']),
        pool: int.tryParse(q['pool'] ?? '') ?? d.pool,
        poolTolerance: clampPoolTolerance(
            int.tryParse(q['pool_tolerance'] ?? '') ?? d.poolTolerance),
        stickyHash: sticky == null
            ? d.stickyHash
            : sticky
                .split(',')
                .map((k) => StickyHashKey.fromWire(k.trim()))
                .whereType<StickyHashKey>()
                .toList(),
      ),
      poolBadge: q['badge'] ?? kDefaultPoolBadge,
    );
  } catch (_) {
    return null;
  }
}
