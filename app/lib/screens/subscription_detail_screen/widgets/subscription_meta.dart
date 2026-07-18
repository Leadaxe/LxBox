import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../controllers/subscription_controller.dart';
import '../../../services/l10n/l10n.dart';
import '../subscription_detail_format.dart';

/// Header/meta block on the Nodes tab: url + copy, last-updated, node counts,
/// traffic quota bar, expiry, support/web-page chips. Extracted verbatim from
/// `_buildMeta`/`_buildTrafficBar`.
class SubscriptionMeta extends StatelessWidget {
  const SubscriptionMeta({
    super.key,
    required this.entry,
    required this.onOpenUrl,
    this.offCount = 0,
  });

  final SubscriptionEntry entry;
  final Future<void> Function(String) onOpenUrl;

  /// §283 — сколько нод выключено per-node toggle'ом («M off» в счётчике).
  final int offCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final url = entry.url.isNotEmpty
        ? entry.url
        : entry.connections.isNotEmpty
            ? entry.connections.first
            : '';

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (url.isNotEmpty) ...[
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    url,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 2,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy, size: 16),
                  tooltip: context.l.subCopyUrl,
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: url));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(context.l.subUrlCopied)),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              if (entry.lastUpdated != null) ...[
                Icon(Icons.schedule, size: 14, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 4),
                Text(
                  SubscriptionEntry.formatAgo(context.l, entry.lastUpdated!),
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(width: 16),
              ],
              Icon(Icons.dns_outlined, size: 14, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Text(
                [
                  entry.detourCount > 0
                      ? context.l.subNodesCountWithDetour(
                          entry.nodeCount, entry.detourCount)
                      : context.l.subEntryNodesCount(entry.nodeCount),
                  // §283 — счётчик выключенных (ключ общий с папками §234).
                  if (offCount > 0) context.l.folderOffCount(offCount),
                ].join(' · '),
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
          // Traffic quota
          if (entry.totalBytes > 0) ...[
            const SizedBox(height: 8),
            _buildTrafficBar(context, entry, theme),
          ],
          // Expire
          if (entry.expireTimestamp > 0) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.event_outlined, size: 14, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 4),
                Text(
                  context.l.subExpires(formatExpire(context.l, entry.expireTimestamp)),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ],
          // Support & web page links
          if (entry.supportUrl.isNotEmpty || entry.webPageUrl.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                if (entry.supportUrl.isNotEmpty)
                  ActionChip(
                    avatar: Icon(
                      entry.supportUrl.contains('t.me') ? Icons.telegram : Icons.open_in_new,
                      size: 16,
                      color: entry.supportUrl.contains('t.me')
                          ? const Color(0xFF2AABEE)
                          : null,
                    ),
                    label: Text(context.l.subSupportChip),
                    onPressed: () => unawaited(onOpenUrl(entry.supportUrl)),
                  ),
                if (entry.webPageUrl.isNotEmpty)
                  ActionChip(
                    avatar: const Icon(Icons.language, size: 16),
                    label: Text(context.l.subWebPageChip),
                    onPressed: () => unawaited(Future.sync(() => onOpenUrl(entry.webPageUrl))),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTrafficBar(
      BuildContext context, SubscriptionEntry entry, ThemeData theme) {
    final used = entry.uploadBytes + entry.downloadBytes;
    final total = entry.totalBytes;
    final pct = total > 0 ? (used / total).clamp(0.0, 1.0) : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(value: pct),
        const SizedBox(height: 2),
        Text(
          context.l.subTrafficUsed(formatBytes(used), formatBytes(total)),
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}
