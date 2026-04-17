/// A proxy subscription source (URL or direct links).
class ProxySource {
  ProxySource({
    this.source = '',
    this.connections = const [],
    this.tagPrefix = '',
    this.name = '',
    this.lastUpdated,
    this.lastNodeCount = 0,
    this.uploadBytes = 0,
    this.downloadBytes = 0,
    this.totalBytes = 0,
    this.expireTimestamp = 0,
    this.supportUrl = '',
    this.webPageUrl = '',
    this.enabled = true,
    this.showDetourServers = true,
    this.useDetourServers = true,
  });

  final String source;
  final List<String> connections;
  final String tagPrefix;
  String name;
  DateTime? lastUpdated;
  int lastNodeCount;
  int uploadBytes;
  int downloadBytes;
  int totalBytes;
  int expireTimestamp; // unix seconds, 0 = unlimited
  String supportUrl;
  String webPageUrl;
  bool enabled;
  bool showDetourServers;
  bool useDetourServers;

  String get displayName {
    if (name.isNotEmpty) return name;
    if (source.isNotEmpty) {
      final uri = Uri.tryParse(source);
      if (uri != null && uri.host.isNotEmpty) return uri.host;
      return source.length > 40 ? '${source.substring(0, 40)}…' : source;
    }
    if (connections.isNotEmpty) {
      final c = connections.first;
      // JSON outbound — extract tag
      if (c.startsWith('{')) {
        final tagMatch = RegExp(r'"tag"\s*:\s*"([^"]+)"').firstMatch(c);
        if (tagMatch != null) return tagMatch.group(1)!;
        final typeMatch = RegExp(r'"type"\s*:\s*"([^"]+)"').firstMatch(c);
        if (typeMatch != null) return typeMatch.group(1)!;
      }
      // URI — extract label from fragment (#name)
      final uri = Uri.tryParse(c);
      if (uri != null && uri.fragment.isNotEmpty) {
        return Uri.decodeComponent(uri.fragment);
      }
      // Fallback: scheme + host:port
      if (uri != null && uri.host.isNotEmpty) {
        return '${uri.scheme}://${uri.host}:${uri.port}';
      }
      return c.length > 40 ? '${c.substring(0, 40)}...' : c;
    }
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
      uploadBytes: json['upload_bytes'] as int? ?? 0,
      downloadBytes: json['download_bytes'] as int? ?? 0,
      totalBytes: json['total_bytes'] as int? ?? 0,
      expireTimestamp: json['expire_timestamp'] as int? ?? 0,
      supportUrl: json['support_url'] as String? ?? '',
      webPageUrl: json['web_page_url'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? true,
      showDetourServers: json['show_detour_servers'] as bool? ?? true,
      useDetourServers: json['use_detour_servers'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
        if (source.isNotEmpty) 'source': source,
        if (connections.isNotEmpty) 'connections': connections,
        if (tagPrefix.isNotEmpty) 'tag_prefix': tagPrefix,
        if (name.isNotEmpty) 'name': name,
        if (lastUpdated != null) 'last_updated': lastUpdated!.toIso8601String(),
        if (lastNodeCount > 0) 'last_node_count': lastNodeCount,
        if (uploadBytes > 0) 'upload_bytes': uploadBytes,
        if (downloadBytes > 0) 'download_bytes': downloadBytes,
        if (totalBytes > 0) 'total_bytes': totalBytes,
        if (expireTimestamp > 0) 'expire_timestamp': expireTimestamp,
        if (supportUrl.isNotEmpty) 'support_url': supportUrl,
        if (webPageUrl.isNotEmpty) 'web_page_url': webPageUrl,
        if (!enabled) 'enabled': false,
        if (!showDetourServers) 'show_detour_servers': false,
        if (!useDetourServers) 'use_detour_servers': false,
      };
}

/// Constants.
const int maxNodesPerSubscription = 3000;
const int maxURILength = 8192;
const String subscriptionUserAgent = 'SubscriptionParserClient';
