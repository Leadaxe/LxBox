/// Type-safe VPN tunnel status, mapped from native string events.
enum TunnelStatus {
  disconnected,
  connecting,
  connected,
  stopping,
  error;

  bool get isUp => this == connected;

  static TunnelStatus fromNative(String raw) {
    return switch (raw) {
      'Started' => connected,
      'Starting' => connecting,
      'Stopped' => disconnected,
      'Stopping' => stopping,
      _ => disconnected,
    };
  }

  String get label => switch (this) {
        disconnected => 'Disconnected',
        connecting => 'Connecting…',
        connected => 'Started',
        stopping => 'Stopping…',
        error => 'Error',
      };
}
