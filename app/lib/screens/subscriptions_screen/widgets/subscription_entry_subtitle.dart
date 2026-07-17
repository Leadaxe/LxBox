import 'package:flutter/material.dart';

import '../../../controllers/subscription_controller.dart';
import '../../../models/server_list.dart';
import '../../../services/l10n/l10n.dart';
import '../../../services/subscription/input_helpers.dart';

/// Строка под именем подписки. Для SubscriptionServers показываем:
/// `{nodes} · 🔄 24h · 🕐 3h ago · (2 fails)`
/// где fail-часть только если consecutiveFails > 0.
///
/// Возвращает `null` если показывать нечего (как старый
/// `_buildEntrySubtitle`).
Widget? buildSubscriptionEntrySubtitle(
    BuildContext context, SubscriptionEntry entry) {
  final scheme = Theme.of(context).colorScheme;
  final muted = entry.enabled ? scheme.onSurfaceVariant : scheme.onSurfaceVariant.withValues(alpha: 0.6);
  final parts = <Widget>[];
  final textStyle = TextStyle(fontSize: 12, color: muted);

  // UserServer всегда single-node — показываем протокол (VLESS/WG/...).
  // SubscriptionServers — нодcount + ⚙ если есть detour-цепочки.
  // FolderServers (§234) — счётчик членов + сколько выключено.
  final isUser = entry.list is UserServer;
  final l = context.l;
  String statusText;
  if (entry.list is FolderServers) {
    final folder = entry.list as FolderServers;
    final total = folder.members.length;
    final off = folder.disabledCount;
    statusText = total == 0
        ? l.subEntryEmptyFolder
        : off > 0
            ? l.subEntryFolderServersOff(total, off)
            : l.subFolderServersCount(total);
  } else if (isUser) {
    final node = entry.list.nodes.isNotEmpty ? entry.list.nodes.first : null;
    statusText = node != null
        ? l.subEntryProtocolServer(node.protocol.toUpperCase())
        : '';
  } else if (entry.status.isNotEmpty) {
    statusText = entry.status;
  } else {
    statusText =
        entry.nodeCount > 0 ? l.subEntryNodesCount(entry.nodeCount) : '';
  }
  if (statusText.isNotEmpty) {
    parts.add(Text(statusText, style: textStyle));
  }

  if (entry.list is SubscriptionServers) {
    // §129 — файловая подписка: бейдж «file» вместо sync-интервала
    // (auto-update файл не читает; обновление вручную через Edit source).
    final isFile =
        isFileSubscription((entry.list as SubscriptionServers).url);
    if (isFile) {
      parts.add(Icon(Icons.insert_drive_file_outlined, size: 12, color: muted));
      parts.add(Text(l.subEntryFileBadge, style: textStyle));
    } else {
      final intervalH = entry.updateIntervalHours;
      if (intervalH > 0) {
        parts.add(Icon(Icons.sync, size: 12, color: muted));
        parts.add(Text(_compactHours(intervalH), style: textStyle));
      } else {
        // §129 — авто-обновление выключено (-1 «don't» / 0 «respect server»).
        parts.add(Icon(Icons.sync_disabled, size: 12, color: muted));
      }
    }

    final last = entry.lastUpdated;
    if (last != null) {
      parts.add(Icon(Icons.schedule, size: 12, color: muted));
      parts.add(Text(SubscriptionEntry.formatAgo(last), style: textStyle));
    } else if (entry.lastUpdateStatus == UpdateStatus.never) {
      parts.add(Icon(Icons.schedule, size: 12, color: muted));
      parts.add(Text(l.subEntryNever, style: textStyle));
    }

    final fails = entry.consecutiveFails;
    if (fails > 0) {
      final failColor = entry.enabled ? scheme.error : muted;
      parts.add(Text(
        l.subEntryFails(fails),
        style: TextStyle(fontSize: 12, color: failColor),
      ));
    }
  }

  if (parts.isEmpty) return null;
  return Padding(
    padding: const EdgeInsets.only(top: 2),
    child: Wrap(
      spacing: 4,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: parts,
    ),
  );
}

String _compactHours(int hours) {
  if (hours <= 0) return '';
  if (hours < 24) return '${hours}h';
  final d = hours ~/ 24;
  final rem = hours % 24;
  if (rem == 0) return '${d}d';
  return '${d}d${rem}h';
}
