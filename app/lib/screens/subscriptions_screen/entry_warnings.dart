import 'package:flutter/material.dart';

import '../../controllers/subscription_controller.dart';
import '../../controllers/subscription_controller/core_reject_ops.dart';
import '../../models/core_reject_verdict.dart';
import '../../models/node_spec.dart';
import '../../models/node_warning.dart';
import '../../models/server_list.dart';
import '../../screens/home/source_lookup.dart';
import '../../services/node_hash.dart';
import '../../services/tag_resolver.dart';
import '../../widgets/banner_palette.dart';

/// Сводка actionable-предупреждений (error/warning) у записи списка
/// источников: счётчик и старший уровень для значка на строке подписки/папки.
class EntryWarningSummary {
  const EntryWarningSummary({
    required this.actionableCount,
    required this.topSeverity,
  });

  final int actionableCount;
  final WarningSeverity topSeverity;
}

/// Есть ли у узла предупреждение, требующее действия (error/warning).
bool nodeHasActionableWarnings(List<NodeWarning> warnings) =>
    warnings.any((w) => w.severity != WarningSeverity.info);

/// Старший уровень среди уведомлений узла; `null` — список пуст.
WarningSeverity? topWarningSeverity(List<NodeWarning> warnings) {
  if (warnings.isEmpty) return null;
  return warnings
      .map((w) => w.severity)
      .reduce((a, b) => a.index > b.index ? a : b);
}

/// Все уведомления узла по эмитированному config-тегу. Паритет с Servers и
/// Diagnostics (§505): разбор + вердикт из хранилища + предупреждения сборки.
List<NodeWarning> warningsForConfigTag(
  String emittedTag,
  List<SubscriptionEntry> entries, {
  Map<String, NodeSpec> emittedTagMap = const {},
  Map<String, List<NodeWarning>>? buildWarningsByTag,
}) {
  final stored = storedNodeOfEmittedTag(emittedTag, entries);
  final parseAndVerdict = stored == null
      ? List<NodeWarning>.unmodifiable(
          emittedTagMap[emittedTag]?.warnings ?? const [],
        )
      : mergedNodeWarnings(stored.node, stored.stored);
  final build = buildWarningsByTag?[emittedTag];
  if (build == null || build.isEmpty) return parseAndVerdict;
  return _mergeBuildWarnings(parseAndVerdict, build);
}

List<NodeWarning> _mergeBuildWarnings(
  List<NodeWarning> base,
  List<NodeWarning> build,
) {
  final out = [...base];
  for (final w in build) {
    final dup = out.any(
      (x) =>
          x is RegistryWarning &&
          w is RegistryWarning &&
          x.code == w.code &&
          x.path == w.path,
    );
    if (!dup) out.add(w);
  }
  return out;
}

/// Все уведомления узла по эмитированному [node]: разбор + хранимый вердикт
/// страховки. Предпочтительнее [warningsForConfigTag] по config-тегу (§505).
List<NodeWarning> warningsForEmittedNode(
  NodeSpec node,
  List<SubscriptionEntry> entries,
) {
  final owner = ownerOfNode(node, entries);
  if (owner == null) return List.unmodifiable(node.warnings);

  final list = entries[owner.entryIndex].list;
  final source = sourceNodeOf(node, list) ?? node;
  final stored = switch (list) {
    SubscriptionServers() => () {
        final id = sourceNodeIdentities(list.nodes)[source];
        return id == null
            ? const <StoredWarning>[]
            : list.nodeWarnings[id] ?? const <StoredWarning>[];
      }(),
    FolderServers() => owner.memberIndex == null
        ? const <StoredWarning>[]
        : list.members[owner.memberIndex!].warnings,
    UserServer() => list.warnings,
  };
  return mergedNodeWarnings(source, stored);
}

/// Текст inline-строки предупреждения в списке. У `core_rejected` — дословная
/// причина ядра; у остальных — заголовок кода реестра ([NodeWarning.message]).
String inlineWarningMessage(NodeWarning w) {
  if (w is RegistryWarning && w.code == kCoreRejectedCode) {
    final reason = w.params[kCoreRejectedReasonParam];
    if (reason != null && reason.isNotEmpty) return reason;
  }
  return w.message();
}

/// Все предупреждения одиночного сервера: разбор + вердикт + сборка.
List<NodeWarning> userServerWarnings(
  UserServer list,
  List<SubscriptionEntry> entries, {
  Map<String, List<NodeWarning>>? buildWarningsByTag,
}) {
  if (list.nodes.isEmpty) return const [];
  final tag = TagResolver.displayTag(list.tagPrefix, list.nodes.first.tag);
  return warningsForConfigTag(
    tag,
    entries,
    buildWarningsByTag: buildWarningsByTag,
  );
}

/// Сводка actionable-предупреждений по записи (подписка / папка / одиночный).
EntryWarningSummary? entryWarningSummary(SubscriptionEntry entry) {
  var actionable = 0;
  WarningSeverity? top;

  void consider(List<NodeWarning> ws) {
    final spoken =
        ws.where((w) => w.severity != WarningSeverity.info).toList();
    if (spoken.isEmpty) return;
    actionable++;
    final sev = spoken
        .map((w) => w.severity)
        .reduce((a, b) => a.index > b.index ? a : b);
    if (top == null || sev.index > top!.index) top = sev;
  }

  switch (entry.list) {
    case SubscriptionServers sub:
      final ids = sourceNodeIdentities(sub.nodes);
      for (final node in sub.nodes) {
        final id = ids[node];
        final stored = id == null ? const <StoredWarning>[] : sub.nodeWarnings[id] ?? const [];
        consider(mergedNodeWarnings(node, stored));
      }
    case FolderServers folder:
      for (final m in folder.members) {
        final n = m.node;
        if (n == null) continue;
        consider(mergedNodeWarnings(n, m.warnings));
      }
    case UserServer us:
      consider(userServerWarnings(us, [entry]));
  }

  if (actionable == 0 || top == null) return null;
  return EntryWarningSummary(actionableCount: actionable, topSeverity: top!);
}

/// Значок старшего уровня и счётчик actionable-узлов у строки подписки/папки.
class EntryWarningBadge extends StatelessWidget {
  const EntryWarningBadge(this.summary, {super.key});

  final EntryWarningSummary summary;

  @override
  Widget build(BuildContext context) {
    final (color, icon) =
        warningSeverityStyle(context, summary.topSeverity);
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 2),
          Text(
            '${summary.actionableCount}', // l10n-exempt: число рядом со значком
            style: TextStyle(fontSize: 12, color: color),
          ),
        ],
      ),
    );
  }
}

/// У одиночного сервера есть вердикт страховки (подпись протокола заменяется).
bool userServerHasCoreRejected(UserServer list) =>
    list.warnings.any((w) => w.isCoreRejected);
