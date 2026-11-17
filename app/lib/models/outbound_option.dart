import 'custom_rule.dart' show kOutboundReject;

/// Опция в [OutboundPicker] — либо outbound tag, либо sentinel "reject".
class OutboundOption {
  const OutboundOption({required this.value, required this.label});
  final String value;  // tag (e.g. "vpn-1", "direct-out") или `kOutboundReject`
  final String label;  // human-readable: "vpn-1", "direct-out", "Reject"

  static const reject =
      OutboundOption(value: kOutboundReject, label: 'Reject');
}
