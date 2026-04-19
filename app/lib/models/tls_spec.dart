/// TLS-параметры узла. Singleton для «TLS выключен» — `TlsSpec.disabled`.
///
/// `reality != null` — взаимоисключающе с uTLS fingerprint'ом в sing-box
/// (REALITY уже задаёт fingerprint через `utls`, но разные секции).
class TlsSpec {
  final bool enabled;
  final String? serverName;
  final List<String> alpn;
  final bool insecure;
  final String? fingerprint; // utls: chrome, firefox, safari, etc.
  final RealitySpec? reality;

  const TlsSpec({
    required this.enabled,
    this.serverName,
    this.alpn = const [],
    this.insecure = false,
    this.fingerprint,
    this.reality,
  });

  static const disabled = TlsSpec(enabled: false);

  Map<String, dynamic> toSingbox() {
    if (!enabled) return const {};
    final m = <String, dynamic>{'enabled': true};
    if (serverName != null && serverName!.isNotEmpty) {
      m['server_name'] = serverName;
    }
    if (alpn.isNotEmpty) m['alpn'] = List<String>.from(alpn);
    if (insecure) m['insecure'] = true;
    if (fingerprint != null && fingerprint!.isNotEmpty) {
      m['utls'] = {'enabled': true, 'fingerprint': fingerprint};
    }
    if (reality != null) {
      m['reality'] = reality!.toSingbox();
    }
    return m;
  }

  TlsSpec copyWith({
    bool? enabled,
    String? serverName,
    List<String>? alpn,
    bool? insecure,
    String? fingerprint,
    RealitySpec? reality,
  }) =>
      TlsSpec(
        enabled: enabled ?? this.enabled,
        serverName: serverName ?? this.serverName,
        alpn: alpn ?? this.alpn,
        insecure: insecure ?? this.insecure,
        fingerprint: fingerprint ?? this.fingerprint,
        reality: reality ?? this.reality,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TlsSpec &&
          enabled == other.enabled &&
          serverName == other.serverName &&
          _listEq(alpn, other.alpn) &&
          insecure == other.insecure &&
          fingerprint == other.fingerprint &&
          reality == other.reality);

  @override
  int get hashCode => Object.hash(enabled, serverName, Object.hashAll(alpn),
      insecure, fingerprint, reality);
}

class RealitySpec {
  final String publicKey;
  final String shortId;

  const RealitySpec({required this.publicKey, required this.shortId});

  Map<String, dynamic> toSingbox() => {
        'enabled': true,
        'public_key': publicKey,
        'short_id': shortId,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RealitySpec &&
          publicKey == other.publicKey &&
          shortId == other.shortId);

  @override
  int get hashCode => Object.hash(publicKey, shortId);
}

bool _listEq(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
