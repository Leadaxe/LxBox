import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../models/ui_msg.dart';

import '../../../services/l10n/l10n.dart';

/// Source tab: live HTTP response headers (important + collapsible "others")
/// and the raw response body. Extracted verbatim from `_buildSourceTab` /
/// `_headerRow`; all state stays owned by the screen and is passed in.
class SubscriptionSourceTab extends StatelessWidget {
  const SubscriptionSourceTab({
    super.key,
    required this.hasUrl,
    required this.sourceLoading,
    required this.sourceError,
    required this.rawHeaders,
    required this.rawSource,
    required this.showAllHeaders,
    required this.importantHeaders,
    required this.moreHeaders,
    required this.onRefetch,
    required this.onToggleShowAll,
  });

  final bool hasUrl;
  final bool sourceLoading;
  final UiMsg? sourceError;
  final Map<String, String> rawHeaders;
  final String rawSource;
  final bool showAllHeaders;

  /// Pre-filtered important headers (sorted) — matches
  /// `_filteredHeaders(important: true)`.
  final List<MapEntry<String, String>> importantHeaders;

  /// Pre-filtered non-important headers (sorted) — matches
  /// `_filteredHeaders(important: false)`.
  final List<MapEntry<String, String>> moreHeaders;

  final VoidCallback onRefetch;
  final VoidCallback onToggleShowAll;

  bool get _hasMoreHeaders => moreHeaders.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // HTTP Response Headers — живой GET с сервера, без кеша.
        if (hasUrl) ...[
          Row(
            children: [
              Text(
                sourceLoading
                    ? context.l.subFetching
                    : context.l.subResponseHeaders,
                style: theme.textTheme.titleSmall?.copyWith(
                    color: cs.primary, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: context.l.subRefetchLive,
                visualDensity: VisualDensity.compact,
                onPressed: sourceLoading ? null : onRefetch,
              ),
              if (rawHeaders.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.copy, size: 16),
                  tooltip: context.l.subCopyHeaders,
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    final text = rawHeaders.entries
                        .map((e) => '${e.key}: ${e.value}')
                        .join('\n');
                    Clipboard.setData(ClipboardData(text: text));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(context.l.subHeadersCopied)),
                    );
                  },
                ),
            ],
          ),
          const Divider(),
          if (sourceError != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(context.l.subFetchFailed(sourceError!.render(context.l)),
                  style: TextStyle(fontSize: 12, color: cs.error)),
            )
          else if (sourceLoading && rawHeaders.isEmpty)
            const LinearProgressIndicator()
          else if (rawHeaders.isEmpty)
            Text(context.l.subNoDataTapRefresh,
                style: const TextStyle(
                    fontSize: 12, fontStyle: FontStyle.italic))
          else ...[
            for (final h in importantHeaders)
              _headerRow(h.key, h.value, theme),
            if (_hasMoreHeaders) ...[
              const SizedBox(height: 4),
              TextButton.icon(
                onPressed: onToggleShowAll,
                icon: Icon(
                    showAllHeaders
                        ? Icons.expand_less
                        : Icons.expand_more,
                    size: 16),
                label: Text(showAllHeaders
                    ? context.l.subHideOthers
                    : context.l.subShowAllHeaders(
                        rawHeaders.length - importantHeaders.length)),
              ),
              if (showAllHeaders)
                for (final h in moreHeaders)
                  _headerRow(h.key, h.value, theme),
            ],
          ],
          const SizedBox(height: 16),
        ],

        // Raw source
        Text(context.l.subRawResponse, style: theme.textTheme.titleSmall?.copyWith(
          color: cs.primary, fontWeight: FontWeight.bold,
        )),
        const Divider(),
        if (rawSource.isEmpty)
          Text(context.l.subNoCachedSource)
        else
          Stack(
            children: [
              SelectableText(
                rawSource,
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
              ),
              Positioned(
                top: 0,
                right: 0,
                child: IconButton(
                  icon: const Icon(Icons.copy, size: 16),
                  tooltip: context.l.subCopySource,
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: rawSource));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(context.l.subSourceCopied)),
                    );
                  },
                ),
              ),
            ],
          ),
      ],
    );
  }

  Widget _headerRow(String name, String value, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(name, style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurfaceVariant,
            )),
          ),
          Expanded(
            child: SelectableText(value, style: const TextStyle(fontSize: 11)),
          ),
        ],
      ),
    );
  }
}
