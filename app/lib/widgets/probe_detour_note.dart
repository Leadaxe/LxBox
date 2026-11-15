import 'package:flutter/material.dart';

import '../services/l10n/locale_controller.dart';
import '../services/probe/probe_detour.dart';

/// §730 — пометка под панелью «Тест серверов»: учтён ли в пробе detour
/// источника. `null` — detour не задан ни у одного узла, пометки нет.
///
/// - все узлы с detour «не учтён» — узлы проверяются напрямую;
/// - все «учтён» через одну цель — «Tested through %s.»;
/// - все «учтён», но цели разные (личные detour членов папки) — общая фраза;
/// - смешанно (папка) — счётчик «учтён у N из M», остальные напрямую.
String? probeDetourNoteText(ProbeDetourPlan plan) {
  if (plan.isEmpty) return null;
  final applied = plan.appliedCount;
  final unapplied = plan.unappliedCount;
  if (applied == 0) {
    return getLocalText.s(
        "Detour of this source is not applied in the test — nodes are checked directly.");
  }
  if (unapplied == 0) {
    final labels = plan.appliedLabels;
    return labels.length == 1
        ? getLocalText.s("Tested through %s.", labels.single)
        : getLocalText.s("Tested through each node's own detour.");
  }
  return getLocalText.s(
      "Detour is applied in the test for %d of %d; the others are checked directly.",
      applied,
      applied + unapplied);
}

/// Пометка §730 тем же стилем, что сводка теста (12, onSurfaceVariant).
class ProbeDetourNote extends StatelessWidget {
  const ProbeDetourNote({
    super.key,
    required this.plan,
    this.padding = const EdgeInsets.fromLTRB(16, 0, 16, 6),
  });

  final ProbeDetourPlan plan;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final text = probeDetourNoteText(plan);
    if (text == null) return const SizedBox.shrink();
    return Padding(
      padding: padding,
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
