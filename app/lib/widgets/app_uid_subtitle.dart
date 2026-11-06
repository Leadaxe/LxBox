import 'package:flutter/material.dart';

import '../models/app_info.dart';
import '../services/l10n/locale_controller.dart';

/// Подзаголовок строки приложения: `<text> · UID n` и, если UID делят
/// несколько пакетов, строка-подсказка «Shared with N other apps» с диалогом
/// списка. Ядро и VpnService различают приложения по UID — выбор одного
/// пакета действует на всю группу. Выбор подсказка не трогает.
class AppUidSubtitle extends StatelessWidget {
  const AppUidSubtitle({
    super.key,
    required this.text,
    required this.uid,
    required this.peers,
    this.style,
    this.maxLines,
  });

  /// Первая строка без UID (пакет или «пакет — not installed…»).
  final String text;
  final int? uid;

  /// Другие установленные пакеты с тем же UID (`AppInfoCache.uidPeers`).
  final List<AppInfo> peers;
  final TextStyle? style;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final line = uid == null
        ? text
        : '$text · UID $uid'; // l10n-exempt: системный идентификатор
    final first = Text(
      line,
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
      style: style,
    );
    if (peers.isEmpty || uid == null) return first;
    final hintStyle = (style ?? const TextStyle()).copyWith(color: cs.tertiary);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        first,
        InkWell(
          onTap: () => showSharedUidDialog(context, uid!, peers),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Icon(Icons.group_outlined, size: 14, color: cs.tertiary),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    getLocalText.plural(
                        "Shared with %d other apps — they are routed together",
                        peers.length),
                    style: hintStyle,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Список пакетов группы общего UID — только чтение.
Future<void> showSharedUidDialog(
    BuildContext context, int uid, List<AppInfo> peers) {
  final sorted = List<AppInfo>.from(peers)
    ..sort((a, b) => a.appName.toLowerCase().compareTo(b.appName.toLowerCase()));
  return showDialog<void>(
    context: context,
    builder: (ctx) {
      final tt = Theme.of(ctx).textTheme;
      final cs = Theme.of(ctx).colorScheme;
      return AlertDialog(
        title: Text('UID $uid'), // l10n-exempt: системный идентификатор
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                getLocalText.s(
                    "Android identifies these apps by one UID. Routing rules and Tunnel apps apply to all of them at once."),
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: sorted.length,
                  itemBuilder: (_, i) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(sorted[i].appName,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(sorted[i].packageName,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(getLocalText.s("Close")),
          ),
        ],
      );
    },
  );
}
