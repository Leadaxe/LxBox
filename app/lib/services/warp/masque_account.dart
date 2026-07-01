import '../parser/uri_utils.dart' show ensureCidr;

/// §130 — закешированный Cloudflare WARP-аккаунт для MASQUE-транспорта.
///
/// Отдельная модель от [WarpAccount] (X25519/WireGuard): у MASQUE другая крипта
/// (ECDSA P-256 DER), нет `reserved`/AWG, есть `network` (h3/h2). Приватник
/// генерится на устройстве ([MasqueKeys]) и НЕ покидает телефон — в Cloudflare
/// уходит только публичная часть (PATCH enroll).
class MasqueAccount {
  const MasqueAccount({
    required this.privKeyDer,
    required this.serverPubDer,
    required this.clientV4,
    required this.clientV6,
    required this.server,
    required this.port,
    required this.deviceId,
    required this.token,
    required this.createdAt,
    this.network = 'h3',
    this.sni = '',
  });

  /// base64(SEC1 DER) нашего ECDSA-приватника. СЕКРЕТ: не логировать.
  final String privKeyDer;

  /// base64(PKIX DER) серверного ECDSA-pubkey (`peers[0].public_key`, pinning).
  final String serverPubDer;

  /// Интерфейсный адрес v4 (CIDR), напр. `172.16.0.2/32`.
  final String clientV4;

  /// Интерфейсный адрес v6 (CIDR).
  final String clientV6;

  /// Data-plane endpoint IP (без `:0`-заглушки), напр. `162.159.198.1`.
  final String server;

  /// Data-plane порт, обычно 443.
  final int port;

  final String deviceId;

  /// Bearer-token устройства. СЕКРЕТ: не логировать.
  final String token;

  /// ISO8601 момента регистрации.
  final String createdAt;

  /// Транспорт: `h3` (QUIC) | `h2` (HTTP/2).
  final String network;

  /// TLS SNI override; пусто = дефолт ядра.
  final String sni;

  /// Дефолтный data-plane endpoint MASQUE (QUIC).
  static const String defaultServer = '162.159.198.1';
  static const int defaultPort = 443;

  /// §137-style тег с эмодзи. Маска 🎭 — отличает MASQUE от ☁️ (plain WG) и
  /// ⛈️ (AWG). Коллизия-суффикс накидывает контроллер.
  static String nodeTag() => '🔥🎭 WARP (MASQUE)';

  MasqueAccount copyWith({String? network, String? sni}) => MasqueAccount(
        privKeyDer: privKeyDer,
        serverPubDer: serverPubDer,
        clientV4: clientV4,
        clientV6: clientV6,
        server: server,
        port: port,
        deviceId: deviceId,
        token: token,
        createdAt: createdAt,
        network: network ?? this.network,
        sni: sni ?? this.sni,
      );

  /// Собирает `masque://` URI для добавления узла через стандартный
  /// `addFromInput` (аналог [WarpAccount.toWireguardUri]).
  String toMasqueUri() {
    final addrs = [
      if (clientV4.isNotEmpty) ensureCidr(clientV4),
      if (clientV6.isNotEmpty) ensureCidr(clientV6),
    ].join(',');
    final q = <String, String>{
      'publickey': serverPubDer,
      'address': addrs,
      'profile': 'cloudflare',
      'network': network,
      'mtu': '1280',
      if (sni.isNotEmpty) 'sni': sni,
    };
    final qs = q.entries
        .map((e) =>
            '${e.key}=${Uri.encodeQueryComponent(e.value).replaceAll('+', '%20')}')
        .join('&');
    return 'masque://${Uri.encodeQueryComponent(privKeyDer)}@$server:$port?$qs#${Uri.encodeComponent(nodeTag())}';
  }

  Map<String, Object?> toJson() => {
        'priv_key_der': privKeyDer,
        'server_pub_der': serverPubDer,
        'client_v4': clientV4,
        'client_v6': clientV6,
        'server': server,
        'port': port,
        'device_id': deviceId,
        'token': token,
        'created_at': createdAt,
        'network': network,
        'sni': sni,
      };

  static MasqueAccount? fromJson(Map<String, dynamic> m) {
    final priv = m['priv_key_der'];
    final pub = m['server_pub_der'];
    if (priv is! String || priv.isEmpty || pub is! String || pub.isEmpty) {
      return null;
    }
    return MasqueAccount(
      privKeyDer: priv,
      serverPubDer: pub,
      clientV4: (m['client_v4'] as String?) ?? '',
      clientV6: (m['client_v6'] as String?) ?? '',
      server: (m['server'] as String?) ?? defaultServer,
      port: (m['port'] as num?)?.toInt() ?? defaultPort,
      deviceId: (m['device_id'] as String?) ?? '',
      token: (m['token'] as String?) ?? '',
      createdAt: (m['created_at'] as String?) ?? '',
      network: (m['network'] as String?) ?? 'h3',
      sni: (m['sni'] as String?) ?? '',
    );
  }

  /// Безопасное для логов представление — секреты замаскированы.
  Map<String, Object?> redacted() => {
        'server_pub_der': serverPubDer,
        'client_v4': clientV4,
        'client_v6': clientV6,
        'server': server,
        'port': port,
        'device_id': deviceId,
        'created_at': createdAt,
        'network': network,
        'priv_key_der': '<redacted>',
        'token': '<redacted>',
      };
}
