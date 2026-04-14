/// A proxy subscription source (URL or direct links).
class ProxySource {
  ProxySource({
    this.source = '',
    this.connections = const [],
    this.tagPrefix = '',
    this.name = '',
    this.lastUpdated,
    this.lastNodeCount = 0,
  });

  final String source;
  final List<String> connections;
  final String tagPrefix;
  String name;
  DateTime? lastUpdated;
  int lastNodeCount;

  String get displayName {
    if (name.isNotEmpty) return name;
    if (source.isNotEmpty) {
      final uri = Uri.tryParse(source);
      if (uri != null && uri.host.isNotEmpty) return uri.host;
      return source.length > 40 ? '${source.substring(0, 40)}…' : source;
    }
    if (connections.isNotEmpty) return connections.first;
    return '(empty)';
  }

  factory ProxySource.fromJson(Map<String, dynamic> json) {
    return ProxySource(
      source: json['source'] as String? ?? '',
      connections: (json['connections'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
      tagPrefix: json['tag_prefix'] as String? ?? '',
      name: json['name'] as String? ?? '',
      lastUpdated: json['last_updated'] != null
          ? DateTime.tryParse(json['last_updated'] as String)
          : null,
      lastNodeCount: json['last_node_count'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        if (source.isNotEmpty) 'source': source,
        if (connections.isNotEmpty) 'connections': connections,
        if (tagPrefix.isNotEmpty) 'tag_prefix': tagPrefix,
        if (name.isNotEmpty) 'name': name,
        if (lastUpdated != null) 'last_updated': lastUpdated!.toIso8601String(),
        if (lastNodeCount > 0) 'last_node_count': lastNodeCount,
      };
}

/// Constants.
const int maxNodesPerSubscription = 3000;
const int maxURILength = 8192;
const String subscriptionUserAgent = 'SubscriptionParserClient';
