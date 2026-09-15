/// Пул ссылок на узлы для экранов (§439, NODE_LINK §5: «превью экрана строит
/// тот же пул производно, это кэш экрана, а не поле записи»).
///
/// Финальные теги узлов считаются тем же `ServerList.build`, что у сборки
/// конфига, с тем же резервом тегов Направлений и служебных outbound'ов:
/// экран показывает ссылку финальным тегом и переводит выбранный финальный
/// тег (кандидат позиции цепочки из собранного конфига) обратно в ссылку.
/// Конфиг здесь не собирается: entries никуда не кладутся, detour-ссылки не
/// разрешаются.
library;

import '../../config/consts.dart';
import '../../models/direction.dart';
import '../../models/emit_context.dart';
import '../../models/node_link.dart';
import '../../models/server_list.dart';
import '../../models/singbox_entry.dart';
import '../../models/template_vars.dart';
import '../tag_resolver.dart';
import 'node_link_resolve.dart';
import 'rule_set_registry.dart';
import 'server_list_build.dart';

/// Пул ссылок источников [lists]: словарь с финальными тегами узлов и
/// корневыми именами ([directions] и их `-auto`, служебные outbound'ы).
NodeLinkTargets computeNodeLinkPool(
  List<ServerList> lists, {
  List<Direction> directions = const [],
}) {
  final targets = NodeLinkTargets()
    ..addRootNames([
      kDirectOutboundTag,
      kBlockOutboundTag,
      for (final d in directions) ...[d.tag, d.autoTag],
    ]);
  for (final l in lists) {
    if (l is! UserServer) targets.noteContainer(l.id, l.name);
  }
  final ctx = _PoolCtx(targets, [
    for (final d in directions) ...[d.tag, d.autoTag],
  ]);
  for (final l in lists) {
    try {
      l.build(ctx);
    } catch (_) {
      // Превью best-effort: источник, чей узел не эмитится, просто не даёт
      // финальных тегов (ссылка на него показывается тегом как есть).
    }
  }
  return targets;
}

/// Показ ссылки [link]: финальный тег узла из пула; ссылка, которой в пуле
/// нет, — финальная форма по источнику (префикс контейнера + сырой тег) или
/// тег как есть.
String nodeLinkDisplay(
  NodeLink link,
  NodeLinkTargets? pool, {
  List<ServerList> lists = const [],
}) {
  if (link.isEmpty) return '';
  final known = pool?.finalOf(link);
  if (known != null) return known;
  if (!link.isRoot) {
    for (final l in lists) {
      if (l.id == link.folderId) {
        return TagResolver.displayTag(l.tagPrefix, link.tag);
      }
    }
  }
  return link.tag;
}

class _PoolCtx implements EmitContext {
  _PoolCtx(this.linkTargets, Iterable<String> reserved) {
    _taken.addAll(reserved);
  }

  @override
  final NodeLinkTargets linkTargets;

  // Тот же резерв, что у `_BuildCtx` сборки.
  final _taken = <String>{kDirectOutboundTag, 'dns-out', 'block-out'};
  final _ruleSets = RuleSetRegistry();

  @override
  TemplateVars get vars => TemplateVars.empty;

  @override
  RuleSetRegistry get ruleSets => _ruleSets;

  @override
  bool get passiveCheck => false;

  @override
  bool get coreSupportsTailscale => true;

  @override
  String get coreVersion => '';

  @override
  String allocateTag(String baseTag) {
    if (_taken.add(baseTag)) return baseTag;
    for (var i = 1; i < 100000; i++) {
      final c = '$baseTag-$i';
      if (_taken.add(c)) return c;
    }
    return baseTag;
  }

  @override
  void addEntry(SingboxEntry entry) {}

  @override
  void addToSelectorTagList(SingboxEntry entry) {}

  @override
  void addToAutoList(SingboxEntry entry) {}

  @override
  void noteEmitted(node, String finalTag) {}

  @override
  void warn(String line) {}

  @override
  void deferDetour(DeferredDetour detour) {}
}
