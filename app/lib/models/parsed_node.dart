/// Parsed proxy node from subscription URI.
class ParsedNode {
  ParsedNode({
    required this.tag,
    required this.scheme,
    required this.server,
    required this.port,
    this.uuid = '',
    this.flow = '',
    this.label = '',
    this.comment = '',
    Map<String, String>? query,
    Map<String, dynamic>? outbound,
  })  : query = query ?? {},
        outbound = outbound ?? {};

  String tag;
  String scheme;
  String server;
  int port;
  String uuid;
  String flow;
  String label;
  String comment;
  Map<String, String> query;
  Map<String, dynamic> outbound;
}
