import 'dart:convert';

import '../models/parsed_node.dart';
import '../models/proxy_source.dart';
import 'node_parser.dart';
import 'subscription_fetcher.dart';

/// Loads and processes nodes from a [ProxySource].
class SourceLoader {
  SourceLoader._();

  static Future<List<ParsedNode>> loadNodesFromSource(
    ProxySource source,
    Map<String, int> tagCounts, {
    void Function(double progress, String message)? onProgress,
    int sourceIndex = 0,
    int totalSources = 1,
  }) async {
    final nodes = <ParsedNode>[];
    var count = 0;

    if (source.source.isNotEmpty) {
      if (NodeParser.isSubscriptionURL(source.source)) {
        onProgress?.call(
          0.2 + sourceIndex * 0.5 / totalSources,
          'Downloading ${sourceIndex + 1}/$totalSources',
        );

        final content = await SubscriptionFetcher.fetch(source.source);
        onProgress?.call(
          0.2 + sourceIndex * 0.5 / totalSources + 0.1 / totalSources,
          'Parsing ${sourceIndex + 1}/$totalSources',
        );

        final text = utf8
            .decode(content, allowMalformed: true)
            .replaceAll('\r\n', '\n')
            .replaceAll('\r', '\n')
            .trim();

        for (var line in text.split('\n')) {
          line = line.trim();
          if (line.isEmpty || count >= maxNodesPerSubscription) continue;
          try {
            final node = NodeParser.parseNode(line, const []);
            if (node != null) {
              _applyPrefix(node, source);
              node.tag = _makeUnique(node.tag, tagCounts);
              nodes.add(node);
              count++;
            }
          } catch (_) {}
        }
      } else if (NodeParser.isDirectLink(source.source)) {
        try {
          final node = NodeParser.parseNode(source.source.trim(), const []);
          if (node != null) {
            _applyPrefix(node, source);
            node.tag = _makeUnique(node.tag, tagCounts);
            nodes.add(node);
            count++;
          }
        } catch (_) {}
      }
    }

    for (final conn in source.connections) {
      final trimmed = conn.trim();
      if (trimmed.isEmpty ||
          !NodeParser.isDirectLink(trimmed) ||
          count >= maxNodesPerSubscription) continue;
      try {
        final node = NodeParser.parseNode(trimmed, const []);
        if (node != null) {
          _applyPrefix(node, source);
          node.tag = _makeUnique(node.tag, tagCounts);
          nodes.add(node);
          count++;
        }
      } catch (_) {}
    }

    return nodes;
  }

  static void _applyPrefix(ParsedNode node, ProxySource source) {
    if (source.tagPrefix.isNotEmpty) {
      node.tag = '${source.tagPrefix}${node.tag}';
      if (node.outbound.isNotEmpty) {
        node.outbound['tag'] = node.tag;
      }
    }
  }

  static String _makeUnique(String tag, Map<String, int> tagCounts) {
    final count = tagCounts[tag] ?? 0;
    if (count > 0) {
      tagCounts[tag] = count + 1;
      return '$tag-${count + 1}';
    }
    tagCounts[tag] = 1;
    return tag;
  }
}
