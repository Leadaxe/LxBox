import 'package:flutter/material.dart';

import '../../services/traffic_profiler.dart';
import '../../services/format_utils.dart';

/// §048 Принцип 1 — banner с count'ом unattributed events за last 30s.
/// Показывается когда recentUnattributedCount > 5: это сигнал что
/// sing-box не детектит owner package для значимой части traffic'а
/// (DNS fail без `router: found package` etc).
Widget unattributedBanner(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  return Container(
    width: double.infinity,
    color: cs.errorContainer,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    child: Row(
      children: [
        Icon(Icons.warning_amber, size: 16, color: cs.onErrorContainer),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '${TrafficProfiler.I.recentUnattributedCount} unattributed events / 30s — '
            'attribution gaps detected. See "System-wide" section in Live tab.',
            style: TextStyle(fontSize: 12, color: cs.onErrorContainer),
          ),
        ),
      ],
    ),
  );
}

Widget verboseBanner(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  return Container(
    width: double.infinity,
    color: cs.tertiaryContainer,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    child: Row(
      children: [
        Icon(Icons.bolt, size: 16, color: cs.onTertiaryContainer),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Verbose core logs active — battery/CPU impact while session runs',
            style: TextStyle(fontSize: 12, color: cs.onTertiaryContainer),
          ),
        ),
      ],
    ),
  );
}

/// Saved-sessions footer list (shown when no active session but completed
/// sessions exist). [onShare] mirrors the parent's `_shareSession` so the
/// share button keeps identical behavior; delete goes straight to the
/// profiler singleton as before.
Widget savedSessions(BuildContext context,
    {required ValueChanged<Session> onShare}) {
  final cs = Theme.of(context).colorScheme;
  final sessions = TrafficProfiler.I.completed.toList().reversed.toList();
  return Container(
    decoration: BoxDecoration(
      border: Border(top: BorderSide(color: cs.outlineVariant)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text('Saved sessions (last ${sessions.length})',
              style: Theme.of(context).textTheme.labelMedium),
        ),
        ...sessions.map((s) => ListTile(
              dense: true,
              title: Text(s.targetPackage,
                  style: const TextStyle(fontSize: 13)),
              subtitle: Text(
                '${formatDuration(s.finishedAt!.difference(s.startedAt))} · '
                '${s.byDomain.length} doms · ${s.byIp.length} ips',
                style: const TextStyle(fontSize: 11),
              ),
              trailing: Wrap(
                spacing: 4,
                children: [
                  IconButton(
                    icon: const Icon(Icons.share, size: 18),
                    tooltip: 'Share',
                    onPressed: () => onShare(s),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    tooltip: 'Delete',
                    onPressed: () {
                      TrafficProfiler.I.delete(s.id);
                    },
                  ),
                ],
              ),
            )),
      ],
    ),
  );
}
