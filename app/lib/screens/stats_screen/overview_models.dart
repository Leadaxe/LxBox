/// §089 — модели overview-таба StatsScreen. Вынесены из stats_screen.dart
/// без изменения семантики (были приватные `_OutboundGroup` / `_Connection`).
class OutboundGroup {
  OutboundGroup({required this.name, this.upload = 0, this.download = 0, required this.connections});
  final String name;
  int upload;
  int download;
  final List<Connection> connections;
}

class Connection {
  Connection({
    required this.host,
    this.destPort = '',
    this.network = '',
    this.chains = const [],
    this.rule = '',
    this.rulePayload = '',
    this.upload = 0,
    this.download = 0,
    this.start = '',
    this.process = '',
  });

  final String host;
  final String destPort;
  final String network;
  final List<String> chains;
  final String rule;
  final String rulePayload;
  final int upload;
  final int download;
  final String start;
  final String process;
}
