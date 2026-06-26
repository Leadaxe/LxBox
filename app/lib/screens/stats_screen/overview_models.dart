/// Модели overview-таба StatsScreen. §122 — упрощены под `CcConnection`
/// (libbox CommandClient): нет chains/rulePayload/process; группировка по
/// `rule`. `start` — epoch ms (`createdAt`), не ISO-строка.
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
    this.rule = '',
    this.upload = 0,
    this.download = 0,
    this.start = 0,
  });

  /// ≈ `CcConnection.domain`.
  final String host;

  /// Порт из `CcConnection.destination` (часть после последнего ':').
  final String destPort;
  final String network;
  final String rule;
  final int upload;
  final int download;

  /// Epoch ms (`CcConnection.createdAt`). 0 = неизвестно.
  final int start;
}
