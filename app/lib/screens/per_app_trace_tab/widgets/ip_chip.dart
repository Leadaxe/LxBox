import 'package:flutter/material.dart';

/// `IP ↗` chip — текст IP'а + clickable иконка. §160: используется в
/// `aggregate_detail_sheet` (IPs домена → тап кладёт IP в общий поиск).
/// [onTap] null → просто текст без иконки.
Widget ipChip(BuildContext context, String ip, ValueChanged<String>? onTap) {
  final cs = Theme.of(context).colorScheme;
  final content = Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(ip,
          style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
      if (onTap != null) ...[
        const SizedBox(width: 3),
        Icon(Icons.open_in_new, size: 12, color: cs.primary),
      ],
    ],
  );
  if (onTap == null) return content;
  return InkWell(
    onTap: () => onTap(ip),
    borderRadius: BorderRadius.circular(4),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
      child: content,
    ),
  );
}

/// Wrap из [ipChip] для рендера множества IP'ов (Domains/Connections
/// expanded views).
Widget ipChipList(
    BuildContext context, Iterable<String> ips, ValueChanged<String>? onTap) {
  return Wrap(
    spacing: 4,
    runSpacing: 2,
    children: [for (final ip in ips) ipChip(context, ip, onTap)],
  );
}
