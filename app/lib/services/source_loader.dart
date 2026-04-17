import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/parsed_node.dart';
import '../models/proxy_source.dart';
import 'node_parser.dart';
import 'subscription_fetcher.dart';
import 'xray_json_parser.dart';

/// Result of loading nodes from a source — nodes + optional metadata.
class LoadResult {
  LoadResult({required this.nodes, this.profileTitle, this.userInfo, this.supportUrl, this.webPageUrl});
  final List<ParsedNode> nodes;
  final String? profileTitle;
  final SubscriptionUserInfo? userInfo;
  final String? supportUrl;
  final String? webPageUrl;
}

/// Loads and processes nodes from a [ProxySource].
class SourceLoader {
  SourceLoader._();

  static Future<LoadResult> loadNodesWithMeta(
    ProxySource source,
    Map<String, int> tagCounts, {
    void Function(double progress, String message)? onProgress,
    int sourceIndex = 0,
    int totalSources = 1,
    bool cacheOnly = false,
  }) async {
    final nodes = <ParsedNode>[];
    var count = 0;
    String? profileTitle;
    SubscriptionUserInfo? userInfo;
    String? supportUrl;
    String? webPageUrl;

    if (source.source.isNotEmpty) {
      if (NodeParser.isSubscriptionURL(source.source)) {
        onProgress?.call(
          0.2 + sourceIndex * 0.5 / totalSources,
          'Downloading ${sourceIndex + 1}/$totalSources',
        );

        final cacheKey = source.source.hashCode.toRadixString(16);
        FetchResult? fetchResult;
        if (cacheOnly) {
          // Read from cache only — no network request
          try {
            final dir = await getApplicationSupportDirectory();
            final cached = File('${dir.path}/sub_cache/$cacheKey');
            if (cached.existsSync()) {
              final bytes = await cached.readAsBytes();
              fetchResult = FetchResult(content: bytes);
            }
          } catch (_) {}
          if (fetchResult == null) {
            return LoadResult(nodes: []);
          }
        } else {
          try {
            fetchResult = await SubscriptionFetcher.fetchWithMeta(source.source);
            // Cache raw response on success
            try {
              final dir = await getApplicationSupportDirectory();
              final cacheDir = Directory('${dir.path}/sub_cache');
              if (!cacheDir.existsSync()) cacheDir.createSync(recursive: true);
              await File('${cacheDir.path}/$cacheKey').writeAsBytes(fetchResult.content);
            } catch (_) {}
          } catch (_) {
            // Network error — try reading from cache
            try {
              final dir = await getApplicationSupportDirectory();
              final cached = File('${dir.path}/sub_cache/$cacheKey');
              if (cached.existsSync()) {
                final bytes = await cached.readAsBytes();
                fetchResult = FetchResult(content: bytes);
              } else {
                rethrow;
              }
            } catch (_) {
              rethrow;
            }
          }
        }
        profileTitle = fetchResult.title;
        userInfo = fetchResult.userInfo;
        supportUrl = fetchResult.supportUrl;
        webPageUrl = fetchResult.webPageUrl;
        final content = fetchResult.content;
        onProgress?.call(
          0.2 + sourceIndex * 0.5 / totalSources + 0.1 / totalSources,
          'Parsing ${sourceIndex + 1}/$totalSources',
        );

        final text = utf8
            .decode(content, allowMalformed: true)
            .replaceAll('\r\n', '\n')
            .replaceAll('\r', '\n')
            .trim();

        if (XrayJsonParser.isXrayJsonArray(text)) {
          // Xray JSON Array format (full configs with protocol/vnext)
          for (final node in XrayJsonParser.parse(text)) {
            if (count >= maxNodesPerSubscription) break;
            _applyPrefix(node, source);
            _dedup(node, tagCounts);
            if (node.jump != null) {
              node.jump!.tag = _makeUnique(node.jump!.tag, tagCounts);
              if (node.jump!.outbound.isNotEmpty) {
                node.jump!.outbound['tag'] = node.jump!.tag;
              }
              node.outbound['detour'] = node.jump!.tag;
            }
            nodes.add(node);
            count++;
          }
        } else {
          // Standard format: base64/plain text URI links
          for (var line in text.split('\n')) {
            line = line.trim();
            if (line.isEmpty || count >= maxNodesPerSubscription) continue;
            try {
              final node = NodeParser.parseNode(line, const []);
              if (node != null) {
                _applyPrefix(node, source);
                _dedup(node, tagCounts);
                nodes.add(node);
                count++;
              }
            } catch (_) {}
          }
        }
      } else if (NodeParser.isDirectLink(source.source)) {
        try {
          final node = NodeParser.parseNode(source.source.trim(), const []);
          if (node != null) {
            _applyPrefix(node, source);
            _dedup(node, tagCounts);
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
          count >= maxNodesPerSubscription) {
        continue;
      }
      try {
        final node = NodeParser.parseNode(trimmed, const []);
        if (node != null) {
          _applyPrefix(node, source);
          _dedup(node, tagCounts);
          nodes.add(node);
          count++;
        }
      } catch (_) {}
    }

    return LoadResult(
      nodes: nodes,
      profileTitle: profileTitle,
      userInfo: userInfo,
      supportUrl: supportUrl,
      webPageUrl: webPageUrl,
    );
  }

  /// Simple load — returns nodes only (backward compat).
  static Future<List<ParsedNode>> loadNodesFromSource(
    ProxySource source,
    Map<String, int> tagCounts, {
    void Function(double progress, String message)? onProgress,
    int sourceIndex = 0,
    int totalSources = 1,
    bool cacheOnly = false,
  }) async {
    final result = await loadNodesWithMeta(
      source, tagCounts,
      onProgress: onProgress,
      sourceIndex: sourceIndex,
      totalSources: totalSources,
      cacheOnly: cacheOnly,
    );
    return result.nodes;
  }

  static void _applyPrefix(ParsedNode node, ProxySource source) {
    if (source.tagPrefix.isNotEmpty) {
      node.tag = '${source.tagPrefix}${node.tag}';
      if (node.outbound.isNotEmpty) {
        node.outbound['tag'] = node.tag;
      }
      if (node.jump != null) {
        node.jump!.tag = '${source.tagPrefix}${node.jump!.tag}';
        if (node.jump!.outbound.isNotEmpty) {
          node.jump!.outbound['tag'] = node.jump!.tag;
        }
      }
    }
  }

  /// Assigns a unique tag to the node and syncs it into outbound['tag'].
  static void _dedup(ParsedNode node, Map<String, int> tagCounts) {
    node.tag = _makeUnique(node.tag, tagCounts);
    if (node.outbound.isNotEmpty) {
      node.outbound['tag'] = node.tag;
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
