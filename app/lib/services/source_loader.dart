import 'dart:convert';

import '../models/parsed_node.dart';
import '../models/proxy_source.dart';
import 'node_parser.dart';
import 'subscription_fetcher.dart';

/// Loads and processes nodes from a [ProxySource].
/// Port of singbox-launcher `source_loader.go`.
class SourceLoader {
  SourceLoader._();

  /// Loads nodes from [source], applying tag transforms and deduplication.
  static Future<List<ParsedNode>> loadNodesFromSource(
    ProxySource source,
    Map<String, int> tagCounts, {
    void Function(double progress, String message)? onProgress,
    int sourceIndex = 0,
    int totalSources = 1,
  }) async {
    final nodes = <ParsedNode>[];
    var nodesFromThis = 0;
    var skippedDueToLimit = 0;

    // Process subscription or direct link from source field
    if (source.source.isNotEmpty) {
      if (NodeParser.isSubscriptionURL(source.source)) {
        onProgress?.call(
          0.2 + sourceIndex * 0.5 / totalSources,
          'Downloading ${sourceIndex + 1}/$totalSources: ${source.source}',
        );

        try {
          final content = await SubscriptionFetcher.fetch(source.source);
          onProgress?.call(
            0.2 + sourceIndex * 0.5 / totalSources + 0.1 / totalSources,
            'Parsing ${sourceIndex + 1}/$totalSources',
          );

          final contentStr = utf8
              .decode(content, allowMalformed: true)
              .replaceAll('\r\n', '\n')
              .replaceAll('\r', '\n')
              .trim();

          if (_isXrayJSONArray(contentStr)) {
            _parseXrayArray(contentStr, source, nodes, tagCounts,
                nodesFromThis, skippedDueToLimit);
          } else {
            for (var line in contentStr.split('\n')) {
              line = line.trim();
              if (line.isEmpty) continue;

              if (nodesFromThis >= maxNodesPerSubscription) {
                skippedDueToLimit++;
                continue;
              }

              try {
                final node = NodeParser.parseNode(line, source.skip);
                if (node != null) {
                  _applyTagTransforms(node, source, nodesFromThis + 1);
                  node.tag = makeTagUnique(node.tag, tagCounts);
                  nodes.add(node);
                  nodesFromThis++;
                }
              } catch (_) {
                // Skip unparseable lines
              }
            }
          }
        } catch (e) {
          // Fetch/decode error — propagate for UI handling
          rethrow;
        }
      } else if (NodeParser.isDirectLink(source.source)) {
        onProgress?.call(
          0.2 + sourceIndex * 0.5 / totalSources,
          'Parsing direct link ${sourceIndex + 1}/$totalSources',
        );

        if (nodesFromThis < maxNodesPerSubscription) {
          try {
            final node = NodeParser.parseNode(source.source.trim(), source.skip);
            if (node != null) {
              _applyTagTransforms(node, source, nodesFromThis + 1);
              node.tag = makeTagUnique(node.tag, tagCounts);
              nodes.add(node);
              nodesFromThis++;
            }
          } catch (_) {}
        }
      }
    }

    // Process direct links from connections
    for (var i = 0; i < source.connections.length; i++) {
      final connection = source.connections[i].trim();
      if (connection.isEmpty || !NodeParser.isDirectLink(connection)) continue;

      if (nodesFromThis >= maxNodesPerSubscription) {
        skippedDueToLimit++;
        continue;
      }

      try {
        final node = NodeParser.parseNode(connection, source.skip);
        if (node != null) {
          _applyTagTransforms(node, source, nodesFromThis + 1);
          node.tag = makeTagUnique(node.tag, tagCounts);
          nodes.add(node);
          nodesFromThis++;
        }
      } catch (_) {}
    }

    return nodes;
  }

  /// Makes [tag] unique by appending a suffix if it already exists in [tagCounts].
  static String makeTagUnique(String tag, Map<String, int> tagCounts) {
    final count = tagCounts[tag] ?? 0;
    if (count > 0) {
      tagCounts[tag] = count + 1;
      return '$tag-${count + 1}';
    }
    tagCounts[tag] = 1;
    return tag;
  }

  static bool _isXrayJSONArray(String s) {
    if (!s.startsWith('[')) return false;
    try {
      final decoded = jsonDecode(s);
      return decoded is List && decoded.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static void _parseXrayArray(
    String content,
    ProxySource source,
    List<ParsedNode> nodes,
    Map<String, int> tagCounts,
    int nodesFromThis,
    int skippedDueToLimit,
  ) {
    // Xray JSON array handling is simplified:
    // each element is expected to have outbound-compatible structure.
    // Full Xray conversion is a complex feature; for MVP we skip this.
  }

  static void _applyTagTransforms(ParsedNode node, ProxySource source, int num) {
    if (source.tagMask.isNotEmpty) {
      node.tag = _replaceTagVars(source.tagMask, node, num);
    } else {
      if (source.tagPrefix.isNotEmpty) {
        node.tag = _replaceTagVars(source.tagPrefix, node, num) + node.tag;
      }
      if (source.tagPostfix.isNotEmpty) {
        node.tag = node.tag + _replaceTagVars(source.tagPostfix, node, num);
      }
    }
    // Update outbound tag
    if (node.outbound.isNotEmpty) {
      node.outbound['tag'] = node.tag;
    }
  }

  static String _replaceTagVars(String template, ParsedNode node, int num) {
    return template
        .replaceAll(r'{$tag}', node.tag)
        .replaceAll(r'{$scheme}', node.scheme)
        .replaceAll(r'{$protocol}', node.scheme)
        .replaceAll(r'{$server}', node.server)
        .replaceAll(r'{$port}', node.port.toString())
        .replaceAll(r'{$label}', node.label)
        .replaceAll(r'{$comment}', node.comment)
        .replaceAll(r'{$num}', num.toString());
  }
}
