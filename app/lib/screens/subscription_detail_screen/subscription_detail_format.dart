import 'package:flutter/material.dart';

import '../../controllers/subscription_controller.dart';
import '../../models/server_list.dart';
import '../../services/format_utils.dart' as fmt;

/// Pure formatting/status helpers for [SubscriptionDetailScreen].
///
/// Extracted verbatim from the screen — no behaviour change. Grouped here as
/// top-level pure functions to keep the screen file focused on widgets/state.
String statusLabel(SubscriptionServers list) {
  switch (list.lastUpdateStatus) {
    case UpdateStatus.ok:
      return 'OK';
    case UpdateStatus.failed:
      final n = list.consecutiveFails;
      return n > 1 ? 'Failed ($n in a row)' : 'Failed';
    case UpdateStatus.inProgress:
      return 'Refreshing…';
    case UpdateStatus.never:
      return 'Never updated';
  }
}

Color statusColor(SubscriptionServers list, ColorScheme cs) {
  switch (list.lastUpdateStatus) {
    case UpdateStatus.ok:
      return cs.primary;
    case UpdateStatus.failed:
      return cs.error;
    case UpdateStatus.inProgress:
      return cs.secondary;
    case UpdateStatus.never:
      return cs.onSurfaceVariant;
  }
}

IconData statusIcon(SubscriptionServers list) {
  switch (list.lastUpdateStatus) {
    case UpdateStatus.ok:
      return Icons.check_circle_outline;
    case UpdateStatus.failed:
      return Icons.error_outline;
    case UpdateStatus.inProgress:
      return Icons.hourglass_empty;
    case UpdateStatus.never:
      return Icons.schedule;
  }
}

String subscriptionStatusSubtitle(SubscriptionServers list) {
  final parts = <String>[];
  if (list.lastUpdated != null) {
    parts.add('Last success: ${SubscriptionEntry.formatAgo(list.lastUpdated!)}');
  }
  if (list.lastUpdateAttempt != null &&
      list.lastUpdateAttempt != list.lastUpdated) {
    parts.add('Last attempt: ${SubscriptionEntry.formatAgo(list.lastUpdateAttempt!)}');
  }
  if (list.lastNodeCount > 0) {
    parts.add('${list.lastNodeCount} nodes');
  }
  return parts.isEmpty ? '—' : parts.join(' · ');
}

String intervalHuman(int hours) {
  if (hours < 24) return '${hours}h';
  final d = hours ~/ 24;
  final rem = hours % 24;
  if (rem == 0) return d == 1 ? 'day' : '$d days';
  return '${d}d ${rem}h';
}

/// §090 A2 — делегирует канону (`format_utils.formatBytes`, spaced:true).
/// Прежний локальный вариант был внутренне непоследователен (`500B` без
/// пробела, но `1.5 KB` с пробелом, `0` вместо `0 B`) — теперь консистентно
/// `0 B` / `500 B` / `1.5 KB` / `2.34 GB`.
String formatBytes(int bytes) => fmt.formatBytes(bytes, spaced: true);

String formatExpire(int timestamp) {
  if (timestamp <= 0) return 'Unlimited';
  final dt = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
  final diff = dt.difference(DateTime.now());
  if (diff.isNegative) return 'Expired';
  if (diff.inDays > 0) return '${diff.inDays} days left';
  return '${diff.inHours} hours left';
}
