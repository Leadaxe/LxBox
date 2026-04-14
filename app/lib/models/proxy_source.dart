/// A proxy subscription source (URL or direct links).
class ProxySource {
  ProxySource({
    this.source = '',
    this.connections = const [],
    this.skip = const [],
    this.outbounds = const [],
    this.tagPrefix = '',
    this.tagPostfix = '',
    this.tagMask = '',
    this.excludeFromGlobal = false,
    this.exposeGroupTagsToGlobal = false,
    this.name = '',
    this.lastUpdated,
    this.lastNodeCount = 0,
  });

  final String source;
  final List<String> connections;
  final List<Map<String, String>> skip;
  final List<OutboundConfig> outbounds;
  final String tagPrefix;
  final String tagPostfix;
  final String tagMask;
  final bool excludeFromGlobal;
  final bool exposeGroupTagsToGlobal;
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
      skip: (json['skip'] as List<dynamic>?)
              ?.map((e) => (e as Map<String, dynamic>)
                  .map((k, v) => MapEntry(k, v as String)))
              .toList() ??
          const [],
      outbounds: (json['outbounds'] as List<dynamic>?)
              ?.map((e) => OutboundConfig.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      tagPrefix: json['tag_prefix'] as String? ?? '',
      tagPostfix: json['tag_postfix'] as String? ?? '',
      tagMask: json['tag_mask'] as String? ?? '',
      excludeFromGlobal: json['exclude_from_global'] as bool? ?? false,
      exposeGroupTagsToGlobal:
          json['expose_group_tags_to_global'] as bool? ?? false,
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
        if (skip.isNotEmpty) 'skip': skip,
        if (outbounds.isNotEmpty)
          'outbounds': outbounds.map((e) => e.toJson()).toList(),
        if (tagPrefix.isNotEmpty) 'tag_prefix': tagPrefix,
        if (tagPostfix.isNotEmpty) 'tag_postfix': tagPostfix,
        if (tagMask.isNotEmpty) 'tag_mask': tagMask,
        if (excludeFromGlobal) 'exclude_from_global': excludeFromGlobal,
        if (exposeGroupTagsToGlobal)
          'expose_group_tags_to_global': exposeGroupTagsToGlobal,
        if (name.isNotEmpty) 'name': name,
        if (lastUpdated != null) 'last_updated': lastUpdated!.toIso8601String(),
        if (lastNodeCount > 0) 'last_node_count': lastNodeCount,
      };
}

/// Outbound selector configuration from ParserConfig.
class OutboundConfig {
  OutboundConfig({
    required this.tag,
    required this.type,
    this.options = const {},
    this.filters = const {},
    this.addOutbounds = const [],
    this.comment = '',
    this.wizard,
  });

  final String tag;
  final String type;
  final Map<String, dynamic> options;
  final Map<String, dynamic> filters;
  final List<String> addOutbounds;
  final String comment;
  final dynamic wizard;

  bool get isWizardHidden {
    if (wizard == null) return false;
    if (wizard is String) return wizard == 'hide';
    if (wizard is Map<String, dynamic>) {
      return wizard['hide'] == true;
    }
    return false;
  }

  int get wizardRequired {
    if (wizard is Map<String, dynamic>) {
      final r = wizard['required'];
      if (r is int) return r;
      if (r is double) return r.toInt();
    }
    return 0;
  }

  factory OutboundConfig.fromJson(Map<String, dynamic> json) {
    return OutboundConfig(
      tag: json['tag'] as String? ?? '',
      type: json['type'] as String? ?? '',
      options: json['options'] as Map<String, dynamic>? ?? const {},
      filters: json['filters'] as Map<String, dynamic>? ?? const {},
      addOutbounds: (json['addOutbounds'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
      comment: json['comment'] as String? ?? '',
      wizard: json['wizard'],
    );
  }

  Map<String, dynamic> toJson() => {
        'tag': tag,
        'type': type,
        if (options.isNotEmpty) 'options': options,
        if (filters.isNotEmpty) 'filters': filters,
        if (addOutbounds.isNotEmpty) 'addOutbounds': addOutbounds,
        if (comment.isNotEmpty) 'comment': comment,
        if (wizard != null) 'wizard': wizard,
      };
}

/// Constants matching the Go launcher.
const int maxNodesPerSubscription = 3000;
const int maxURILength = 8192;
const String subscriptionUserAgent = 'SubscriptionParserClient';
