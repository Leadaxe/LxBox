/// Parsed proxy node from subscription URI or Xray JSON config.
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
    this.sourceUri = '',
    this.jump,
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
  String sourceUri;
  Map<String, String> query;
  Map<String, dynamic> outbound;

  /// Optional chained proxy (jump server) — the main outbound uses `detour`
  /// pointing at this jump's tag so traffic is tunneled through it first.
  ParsedJump? jump;
}

/// A chained proxy outbound (SOCKS or VLESS) used as a jump/detour server.
class ParsedJump {
  ParsedJump({
    required this.tag,
    required this.scheme,
    required this.server,
    required this.port,
    this.uuid = '',
    this.flow = '',
    required this.outbound,
  });

  String tag;
  String scheme;
  String server;
  int port;
  String uuid;
  String flow;
  Map<String, dynamic> outbound;
}
