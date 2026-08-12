import '../parser/uri_utils.dart' show ensureCidr;

/// §130 — закешированный Cloudflare WARP-аккаунт для MASQUE-транспорта.
///
/// Отдельная модель от [WarpAccount] (X25519/WireGuard): у MASQUE другая крипта
/// (ECDSA P-256 DER), нет `reserved`/AWG. Приватник генерится на устройстве
/// ([MasqueKeys]) и НЕ покидает телефон — в Cloudflare уходит только публичная
/// часть (PATCH enroll).
///
/// §393 — транспорта (h3/h2) здесь НЕТ и в хранилище он больше не пишется: это
/// не свойство регистрации, а параметр конкретного узла. Одни и те же креды
/// порождают и h3-, и h2-узлы (см. `ScanNodeBuilder`), а визард задаёт транспорт
/// заново при каждом добавлении. Старые записи с ключом `network` не трогаем —
/// он просто игнорируется при чтении.
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
    this.sni = '',
    this.idleTimeout = '',
    this.keepAlive = '',
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

  /// TLS SNI override; пусто = дефолт ядра (§393: `www.cloudflare.com`).
  final String sni;

  /// idle-suspend (Go-duration, напр. `5m`); пусто = дефолт ядра.
  final String idleTimeout;

  /// QUIC keepalive (Go-duration, напр. `30s`); пусто = дефолт ядра.
  final String keepAlive;

  /// Дефолтный data-plane endpoint MASQUE (QUIC).
  static const String defaultServer = '162.159.198.1';
  static const int defaultPort = 443;

  /// §137-style тег с эмодзи. Маска 🎭 — отличает MASQUE от ☁️ (plain WG) и
  /// ⛈️ (AWG). Коллизия-суффикс накидывает контроллер.
  static String nodeTag() => '🔥🎭 WARP (MASQUE)';

  MasqueAccount copyWith({
    String? sni,
    String? idleTimeout,
    String? keepAlive,
  }) =>
      MasqueAccount(
        privKeyDer: privKeyDer,
        serverPubDer: serverPubDer,
        clientV4: clientV4,
        clientV6: clientV6,
        server: server,
        port: port,
        deviceId: deviceId,
        token: token,
        createdAt: createdAt,
        sni: sni ?? this.sni,
        idleTimeout: idleTimeout ?? this.idleTimeout,
        keepAlive: keepAlive ?? this.keepAlive,
      );

  /// Собирает `masque://` URI для добавления узла через стандартный
  /// `addFromInput` (аналог [WarpAccount.toWireguardUri]).
  ///
  /// §393 — [transport] (`h3`/`h2`) приходит параметром: он принадлежит узлу,
  /// а не аккаунту. В URI пишется новым ключом `transport=`.
  String toMasqueUri({String transport = 'h3'}) {
    final addrs = [
      if (clientV4.isNotEmpty) ensureCidr(clientV4),
      if (clientV6.isNotEmpty) ensureCidr(clientV6),
    ].join(',');
    final q = <String, String>{
      'publickey': serverPubDer,
      'address': addrs,
      'profile': 'cloudflare',
      'transport': transport,
      'mtu': '1280',
      if (sni.isNotEmpty) 'sni': sni,
      if (idleTimeout.isNotEmpty) 'idle_timeout': idleTimeout,
      if (keepAlive.isNotEmpty) 'keep_alive': keepAlive,
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
        // §393 — ключа `network` здесь больше нет (транспорт принадлежит узлу).
        // Старые записи с ним остаются на диске нетронутыми и игнорируются.
        'sni': sni,
        'idle_timeout': idleTimeout,
        'keep_alive': keepAlive,
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
      sni: (m['sni'] as String?) ?? '',
      idleTimeout: (m['idle_timeout'] as String?) ?? '',
      keepAlive: (m['keep_alive'] as String?) ?? '',
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
        'priv_key_der': '<redacted>',
        'token': '<redacted>',
      };
}
