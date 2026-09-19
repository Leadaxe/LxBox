import 'package:flutter/material.dart';

import '../../controllers/subscription_controller.dart';
import '../../controllers/subscription_controller/core_reject_ops.dart';
import '../../models/core_reject_verdict.dart';
import '../../models/node_warning.dart';
import '../../models/server_list.dart';
import '../../services/node_hash.dart';
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

/// Текст inline-строки предупреждения в списке. У `core_rejected` — дословная
/// причина ядра; у остальных — заголовок кода реестра ([NodeWarning.message]).
String inlineWarningMessage(NodeWarning w) {
  if (w is RegistryWarning && w.code == kCoreRejectedCode) {
    final reason = w.params[kCoreRejectedReasonParam];
    if (reason != null && reason.isNotEmpty) return reason;
  }
  return w.message();
}

/// Все предупреждения одиночного сервера: разбор + хранимый вердикт.
List<NodeWarning> userServerWarnings(UserServer list) {
  if (list.nodes.isEmpty) return const [];
  return mergedNodeWarnings(list.nodes.first, list.warnings);
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
      consider(userServerWarnings(us));
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

