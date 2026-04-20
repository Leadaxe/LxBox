/// Type-safe VPN tunnel status, mapped from native string events.
enum TunnelStatus {
  disconnected,
  connecting,
  connected,
  stopping,
  revoked,
  error,
  /// Native прислал raw, который мы не знаем как мапить. Был раньше default
  /// на `disconnected` — это ложно резолвило predicate'ы типа
  /// `firstWhere(disconnected|revoked)` на мусор из stream'а. Отдельный
  /// `unknown` позволяет `_handleStatusEvent` явно не делать cleanup и
  /// просто залогировать событие (см. handler). В reconnect/pull — тоже
  /// explicit no-op ветка.
  unknown;

  bool get isUp => this == connected;

  static TunnelStatus fromNative(String raw) {
    return switch (raw) {
      'Started' => connected,
      'Starting' => connecting,
      'Stopped' => disconnected,
      'Stopping' => stopping,
      'Revoked' => revoked,
      _ => unknown,
    };
  }

  String get label => switch (this) {
        disconnected => 'Disconnected',
        connecting => 'Connecting…',
        connected => 'Connected',
        stopping => 'Stopping…',
        revoked => 'Revoked by another VPN',
        error => 'Error',
        unknown => 'Unknown',
      };
}
