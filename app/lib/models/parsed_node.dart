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
    this.detourServer,
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

  /// Non-empty = соединение построено с компромиссом/фоллбэком.
  /// UI показывает warning-иконку и пояснение; config_builder не скипает ноду.
  String warning = '';

  /// Optional chained proxy (detour server) — the main outbound uses `detour`
  /// pointing at this server's tag so traffic is tunneled through it first.
  ParsedDetour? detourServer;
}

/// A chained proxy outbound (SOCKS or VLESS) used as a detour server.
class ParsedDetour {
  ParsedDetour({
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
