import 'package:flutter/material.dart';

import '../../../models/dependency_graph.dart';
import '../../../services/l10n/locale_controller.dart';

/// §355 — bottom sheet «кто сломан мёртвой нодой»: список DNS-серверов и нод,
/// зависящих от корня беды через detour/каналы. Открывается тапом по ⚠-метке
/// строки ноды ([NodeViewItem.isSickRoot]). Паттерн — detour_cycle_sheet
/// (grabber/header/список), только read-only: чинится выбором живой ноды в
/// канале или сменой detour, действий у шита нет.
Future<void> showDependencySheet(
  BuildContext context, {
  required String rootTag,
  required List<DependentRef> dependents,
  required String Function(String tag) groupLabelOf,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _DependencySheet(
      rootTag: rootTag,
      dependents: dependents,
      groupLabelOf: groupLabelOf,
    ),
  );
}

class _DependencySheet extends StatelessWidget {
  const _DependencySheet({
    required this.rootTag,
    required this.dependents,
    required this.groupLabelOf,
  });

  final String rootTag;
  final List<DependentRef> dependents;
  final String Function(String tag) groupLabelOf;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // DNS-жертвы сверху — они самые коварные (§355: юзер видит «интернет не
    // работает», а не мёртвую ноду в списке).
    final sorted = [...dependents]
      ..sort((a, b) {
        if (a.isDns != b.isDns) return a.isDns ? -1 : 1;
        return a.tag.compareTo(b.tag);
      });
    return DraggableScrollableSheet(
      initialChildSize: 0.45,
      minChildSize: 0.3,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scrollController) => Column(
        children: [
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: cs.onSurfaceVariant.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: cs.error, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    getLocalText.s("Broken dependencies"),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                getLocalText.s(
                    'These depend on dead node "%1\$s" and are not working:',
                    rootTag),
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              controller: scrollController,
              itemCount: sorted.length,
              itemBuilder: (ctx, i) {
                final d = sorted[i];
                final via = d.via;
                return ListTile(
                  dense: true,
                  leading: Icon(
                    d.isDns ? Icons.dns_outlined : Icons.lan_outlined,
                    size: 20,
                    color: cs.onSurfaceVariant,
                  ),
                  title: Text(d.tag,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    via == null
                        ? (d.isDns
                            ? getLocalText.s("DNS server — direct detour")
                            : getLocalText.s("Node — direct detour"))
                        : (d.isDns
                            ? getLocalText.s(
                                'DNS server — via "%1\$s"', groupLabelOf(via))
                            : getLocalText.s(
                                'Node — via "%1\$s"', groupLabelOf(via))),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
