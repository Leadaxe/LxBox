import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  final String? sourceError;
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
                sourceLoading ? 'Fetching…' : 'Response headers',
                style: theme.textTheme.titleSmall?.copyWith(
                    color: cs.primary, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: 'Re-fetch live',
                visualDensity: VisualDensity.compact,
                onPressed: sourceLoading ? null : onRefetch,
              ),
              if (rawHeaders.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.copy, size: 16),
                  tooltip: 'Copy headers',
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    final text = rawHeaders.entries
                        .map((e) => '${e.key}: ${e.value}')
                        .join('\n');
                    Clipboard.setData(ClipboardData(text: text));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Headers copied')),
                    );
                  },
                ),
            ],
          ),
          const Divider(),
          if (sourceError != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text('Fetch failed: $sourceError',
                  style: TextStyle(fontSize: 12, color: cs.error)),
            )
          else if (sourceLoading && rawHeaders.isEmpty)
            const LinearProgressIndicator()
          else if (rawHeaders.isEmpty)
            const Text('No data — tap refresh above',
                style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic))
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
                    ? 'Hide others'
                    : 'Show all (${rawHeaders.length - importantHeaders.length})'),
              ),
              if (showAllHeaders)
                for (final h in moreHeaders)
                  _headerRow(h.key, h.value, theme),
            ],
          ],
          const SizedBox(height: 16),
        ],

        // Raw source
        Text('Raw response', style: theme.textTheme.titleSmall?.copyWith(
          color: cs.primary, fontWeight: FontWeight.bold,
        )),
        const Divider(),
        if (rawSource.isEmpty)
          const Text('No cached source data')
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
                  tooltip: 'Copy source',
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: rawSource));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Source copied')),
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
