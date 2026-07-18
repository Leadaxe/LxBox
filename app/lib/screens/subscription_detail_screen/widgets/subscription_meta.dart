import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../controllers/subscription_controller.dart';
import '../subscription_detail_format.dart';
import '../../../services/l10n/locale_controller.dart';

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
                  tooltip: getLocalText.s("Copy URL"),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: url));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(getLocalText.s("URL copied"))),
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
                  SubscriptionEntry.formatAgo(entry.lastUpdated!),
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(width: 16),
              ],
              Icon(Icons.dns_outlined, size: 14, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Text(
                [
                  entry.detourCount > 0
                      ? getLocalText.plural("%1\$d +%2\$d⚙ nodes", entry.nodeCount, entry.detourCount)
                      : getLocalText.plural("%d nodes", entry.nodeCount),
                  // §283 — счётчик выключенных (ключ общий с папками §234).
                  if (offCount > 0) getLocalText.s("%d off", offCount),
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
                  getLocalText.s("Expires: %s", formatExpire(entry.expireTimestamp)),
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
                    label: Text(getLocalText.s("Support")),
                    onPressed: () => unawaited(onOpenUrl(entry.supportUrl)),
                  ),
                if (entry.webPageUrl.isNotEmpty)
                  ActionChip(
                    avatar: const Icon(Icons.language, size: 16),
                    label: Text(getLocalText.s("Web page")),
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
          getLocalText.s("%1\$s / %2\$s used", formatBytes(used), formatBytes(total)),
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}
