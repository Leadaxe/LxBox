import 'package:flutter/material.dart';

import '../../controllers/subscription_controller.dart';
import '../../models/server_list.dart';
import '../../services/format_utils.dart' as fmt;
import '../../services/l10n/l10n.dart';

/// Pure formatting/status helpers for [SubscriptionDetailScreen].
///
/// Extracted verbatim from the screen — no behaviour change. Grouped here as
/// top-level pure functions to keep the screen file focused on widgets/state.
/// §279 Phase 5 — словесные хелперы принимают [AppLocalizations] параметром
/// (render-path по построению, спека §9.4).
String statusLabel(AppLocalizations l, SubscriptionServers list) {
  switch (list.lastUpdateStatus) {
    case UpdateStatus.ok:
      return l.subUpdateStatusOk;
    case UpdateStatus.failed:
      final n = list.consecutiveFails;
      return n > 1 ? l.subUpdateStatusFailedN(n) : l.subUpdateStatusFailed;
    case UpdateStatus.inProgress:
      return l.subUpdateStatusRefreshing;
    case UpdateStatus.never:
      return l.subUpdateStatusNever;
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

String subscriptionStatusSubtitle(AppLocalizations l, SubscriptionServers list) {
  final parts = <String>[];
  if (list.lastUpdated != null) {
    parts.add(
        l.subStatusLastSuccess(SubscriptionEntry.formatAgo(l, list.lastUpdated!)));
  }
  if (list.lastUpdateAttempt != null &&
      list.lastUpdateAttempt != list.lastUpdated) {
    parts.add(l.subStatusLastAttempt(
        SubscriptionEntry.formatAgo(l, list.lastUpdateAttempt!)));
  }
  if (list.lastNodeCount > 0) {
    parts.add(l.subEntryNodesCount(list.lastNodeCount));
  }
  return parts.isEmpty ? '—' : parts.join(' · ');
}

String intervalHuman(AppLocalizations l, int hours) {
  // Суффиксы h/d — латиница в обеих локалях (граница единиц, спека §5).
  if (hours < 24) return '${hours}h';
  final d = hours ~/ 24;
  final rem = hours % 24;
  if (rem == 0) return l.subIntervalEveryDays(d);
  return '${d}d ${rem}h';
}

/// §090 A2 — делегирует канону (`format_utils.formatBytes`, spaced:true).
/// Прежний локальный вариант был внутренне непоследователен (`500B` без
/// пробела, но `1.5 KB` с пробелом, `0` вместо `0 B`) — теперь консистентно
/// `0 B` / `500 B` / `1.5 KB` / `2.34 GB`.
String formatBytes(int bytes) => fmt.formatBytes(bytes, spaced: true);

String formatExpire(AppLocalizations l, int timestamp) {
  if (timestamp <= 0) return l.subExpireUnlimited;
  final dt = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
  final diff = dt.difference(DateTime.now());
  if (diff.isNegative) return l.subExpireExpired;
  if (diff.inDays > 0) return l.subExpireDaysLeft(diff.inDays);
  return l.subExpireHoursLeft(diff.inHours);
}
