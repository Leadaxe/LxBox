import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../controllers/subscription_controller.dart';
import '../subscription_detail_format.dart';
import '../../../services/l10n/locale_controller.dart';
import 'node_warnings_sheet.dart';
import 'source_build_codes_row.dart';
import '../../../services/telegram_link.dart'; // §657

/// Header/meta block on the Nodes tab: url + copy, last-updated, node counts,
/// traffic quota bar, expiry, announce text (§648), support/web-page chips. Extracted verbatim from
/// `_buildMeta`/`_buildTrafficBar`.
class SubscriptionMeta extends StatelessWidget {
  const SubscriptionMeta({
    super.key,
    required this.entry,
    required this.onOpenUrl,
    this.offCount = 0,
    this.controller,
  });

  final SubscriptionEntry entry;
  final Future<void> Function(String) onOpenUrl;

  /// §283 — сколько нод выключено per-node toggle'ом («M off» в счётчике).
  /// §391 — bulk-переключатель в probe-баре (`_buildProbeBar`), здесь только
  /// счётчик.
  final int offCount;

  /// §739 итер. 2 — источник кодов сборки для строки ⚠ источника; `null` —
  /// строки нет (тесты шапки без контроллера).
  final SubscriptionController? controller;

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
              Expanded(
                child: Text(
                  [
                    entry.detourCount > 0
                        ? getLocalText.plural("%1\$d +%2\$d⚙ nodes", entry.nodeCount, entry.detourCount)
                        : getLocalText.plural("%d nodes", entry.nodeCount),
                    // §283 — счётчик выключенных (ключ общий с папками §234).
                    if (offCount > 0) getLocalText.s("%d off", offCount),
                  ].join(' · '),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
          // §561 — записи тела, не ставшие узлами (`dropped[]` последнего
          // разбора): причины — в той же шторке уведомлений, что у узла.
          if (entry.dropped.isNotEmpty) ...[
            const SizedBox(height: 4),
            _DroppedRow(entry: entry),
          ],
          // §589 — повторы одного сервера схлопнуты в узлы: строка отдельно
          // от «dropped» (ничего не отброшено); итер. 2 — тап раскрывает
          // шторку: выживший узел и имена слившихся в него записей.
          if (entry.duplicatesMerged.merged > 0) ...[
            const SizedBox(height: 4),
            _MergedRow(entry: entry),
          ],
          // §739 итер. 2 — коды сборки источника (недоступный detour и др.):
          // строка как у «dropped», тап — та же шторка.
          if (controller != null)
            SourceBuildCodesRow(
              controller: controller!,
              sourceId: entry.id,
              padding: const EdgeInsets.only(top: 4),
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
          // §648 — описание подписки из заголовка `announce`.
          if (entry.announce.isNotEmpty) ...[
            const SizedBox(height: 8),
            _AnnounceBlock(text: entry.announce),
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
                      isTelegramUrl(entry.supportUrl) ? Icons.telegram : Icons.open_in_new,
                      size: 16,
                      color: isTelegramUrl(entry.supportUrl)
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

/// §648 — описание подписки как есть: свёрнуто до [_collapsedLines] строк
/// с многоточием; если текст длиннее, тап раскрывает и сворачивает его.
/// Короткий текст на тап не реагирует.
class _AnnounceBlock extends StatefulWidget {
  const _AnnounceBlock({required this.text});

  final String text;

  @override
  State<_AnnounceBlock> createState() => _AnnounceBlockState();
}

class _AnnounceBlockState extends State<_AnnounceBlock> {
  static const _collapsedLines = 4;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return LayoutBuilder(builder: (context, constraints) {
      // Длиннее ли текст свёрнутого вида — меряем той же раскладкой, что Text.
      final painter = TextPainter(
        text: TextSpan(text: widget.text, style: style),
        maxLines: _collapsedLines,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: constraints.maxWidth);
      final overflows = painter.didExceedMaxLines;
      painter.dispose();
      final text = Text(
        widget.text,
        style: style,
        maxLines: _expanded ? null : _collapsedLines,
        overflow: _expanded ? null : TextOverflow.ellipsis,
      );
      if (!overflows) return text;
      return InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () => setState(() => _expanded = !_expanded),
        child: text,
      );
    });
  }
}

/// §561 — строка сводки «N entries dropped»; тап открывает шторку причин.
class _DroppedRow extends StatelessWidget {
  const _DroppedRow({required this.entry});

  final SubscriptionEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dropped = entry.dropped;
    final color = theme.colorScheme.error;
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: () => showNodeWarningsSheet(context, dropped),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Icon(Icons.error_outline, size: 14, color: color),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                getLocalText.plural("%d entries dropped", dropped.length),
                style: theme.textTheme.bodySmall?.copyWith(color: color),
              ),
            ),
            Icon(Icons.chevron_right, size: 16, color: color),
          ],
        ),
      ),
    );
  }
}

/// §589 — строка сводки «M duplicates merged into K nodes». Справочная
/// (info), итер. 2 — тап открывает ту же шторку, что «entries dropped»: по
/// карточке `duplicates_collapsed` на выживший узел.
class _MergedRow extends StatelessWidget {
  const _MergedRow({required this.entry});

  final SubscriptionEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    final merged = entry.duplicatesMerged;
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: () => showNodeWarningsSheet(context, entry.duplicatesCollapsed),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Icon(Icons.merge_type, size: 14, color: color),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                getLocalText.plural("%1\$d duplicates merged into %2\$d nodes",
                    merged.merged, merged.into),
                style: theme.textTheme.bodySmall?.copyWith(color: color),
              ),
            ),
            Icon(Icons.chevron_right, size: 16, color: color),
          ],
        ),
      ),
    );
  }
}
