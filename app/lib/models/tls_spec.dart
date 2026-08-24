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

  /// §103/D-078 — пиннинг сертификата (`pinSHA256=` в URI подписки →
  /// `tls.certificate_public_key_sha256`). Base64 SHA-256 публичного ключа;
  /// список — сервер вправе ротировать ключи. ЗАЩИТА ОТ ПОДМЕНЫ: молча
  /// терять параметр значило поднимать соединение слабее, чем обещала
  /// подписка (паритет с лаунчером, outbound_generator.go:496).
  /// В отличие от utls/reality, на QUIC валиден — не срезается.
  final List<String> certificatePublicKeySha256;

  const TlsSpec({
    required this.enabled,
    this.serverName,
    this.alpn = const [],
    this.insecure = false,
    this.fingerprint,
    this.reality,
    this.certificatePublicKeySha256 = const [],
  });

  static const disabled = TlsSpec(enabled: false);

  Map<String, dynamic> toSingbox() => _toSingbox(quic: false);

  /// §282 — uTLS И REALITY поверх QUIC (hysteria2/tuic) в ядре не работают
  /// вообще: их `STDConfig()` возвращает ошибку («unsupported usage for
  /// uTLS»/«…for reality»), а QUIC-путь фолбэчит именно на `STDConfig()`
  /// (аудит ядра SPECS/027-UTLS_OVER_QUIC). Оба блока на QUIC = мёртвая
  /// нода, и `fp`/reality на hy2/tuic — мусор xray-подписок. Для QUIC-эмита
  /// срезаем `utls` и `reality`; server_name/alpn/insecure цел.
  Map<String, dynamic> toSingboxForQuic() => _toSingbox(quic: true);

  Map<String, dynamic> _toSingbox({required bool quic}) {
    if (!enabled) return const {};
    final m = <String, dynamic>{'enabled': true};
    if (serverName != null && serverName!.isNotEmpty) {
      m['server_name'] = serverName;
    }
    if (alpn.isNotEmpty) m['alpn'] = List<String>.from(alpn);
    if (insecure) m['insecure'] = true;
    if (certificatePublicKeySha256.isNotEmpty) {
      m['certificate_public_key_sha256'] =
          List<String>.from(certificatePublicKeySha256);
    }
    if (!quic && fingerprint != null && fingerprint!.isNotEmpty) {
      m['utls'] = {'enabled': true, 'fingerprint': fingerprint};
    }
    if (!quic && reality != null) {
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
    List<String>? certificatePublicKeySha256,
  }) =>
      TlsSpec(
        enabled: enabled ?? this.enabled,
        serverName: serverName ?? this.serverName,
        alpn: alpn ?? this.alpn,
        insecure: insecure ?? this.insecure,
        fingerprint: fingerprint ?? this.fingerprint,
        reality: reality ?? this.reality,
        certificatePublicKeySha256:
            certificatePublicKeySha256 ?? this.certificatePublicKeySha256,
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
