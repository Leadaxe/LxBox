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

/// Пулы «при включении» (§439, миграция ссылок D-112): для каждого источника
/// [lists] с выключенным содержимым — сам источник, член папки, узел
/// подписки — отдельный пул с финальными тегами его узлов, как их назвала бы
/// сборка, будь он включён целиком: источники перед ним — как есть, теги
/// считает тот же `ServerList.build` (префиксы, уникализация, резерв тегов
/// Направлений и служебных outbound'ов). Узлы других источников в такой пул
/// не попадают — действительные теги даёт [computeNodeLinkPool].
///
/// Пул на источник, а не общий: включение одного источника не сдвигает
/// уникализацию другого, и неоднозначность видна вызывающему.
List<NodeLinkTargets> computeDisabledNodeLinkPools(
  List<ServerList> lists, {
  List<Direction> directions = const [],
}) {
  final reserved = [
    for (final d in directions) ...[d.tag, d.autoTag],
  ];
  final live = _PoolCtx(NodeLinkTargets(), reserved);
  final out = <NodeLinkTargets>[];
  for (final l in lists) {
    final whole = _enabledWhole(l);
    if (whole != null) {
      final targets = NodeLinkTargets();
      _buildQuiet(whole, _PoolCtx(targets, live._taken));
      out.add(targets);
    }
    _buildQuiet(l, live);
  }
  return out;
}

/// Источник [l], включённый целиком; null — выключенного в нём нет.
ServerList? _enabledWhole(ServerList l) => switch (l) {
      SubscriptionServers s when !s.enabled || s.disabledHashes.isNotEmpty =>
        s.copyWith(enabled: true, disabledHashes: const {}),
      UserServer u when !u.enabled => u.copyWith(enabled: true),
      FolderServers f when !f.enabled || f.members.any((m) => !m.enabled) =>
        f.copyWith(enabled: true, members: [
          for (final m in f.members) m.enabled ? m : m.copyWith(enabled: true),
        ]),
      _ => null,
    };

void _buildQuiet(ServerList l, EmitContext ctx) {
  try {
    l.build(ctx);
  } catch (_) {
    // Как в [computeNodeLinkPool]: источник без эмиссии не даёт тегов.
  }
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
  void noteEmittedAlias(String finalTag, node) {}

  // §473 — пул звеньев тел в конфиг не отдаёт: он считает теги, а гард
  // реестра сюда не заглядывает. Метку записывать некуда и незачем.
  @override
  void noteVerbatim(SingboxEntry entry) {}

  @override
  void warn(String line) {}

  @override
  void deferDetour(DeferredDetour detour) {}
}
