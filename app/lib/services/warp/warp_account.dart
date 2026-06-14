import '../parser/uri_utils.dart' show parseReserved;

/// §025 — закешированный Cloudflare WARP-аккаунт.
///
/// Регистрируется на устройстве через [WarpClient]: приватный ключ X25519
/// генерится локально и НИКОГДА не покидает телефон — в Cloudflare уходит
/// только публичная часть. Эта модель — то, что мы кешируем в storage
/// (`warp_account`) и из чего собираем `wireguard://` URI для добавления узла.
class WarpAccount {
  const WarpAccount({
    required this.privKey,
    required this.peerPub,
    required this.clientV4,
    required this.clientV6,
    required this.clientId,
    required this.accountId,
    required this.deviceId,
    required this.token,
    required this.endpoint,
    required this.createdAt,
    this.license,
    this.warpPlus = false,
  });

  /// base64, X25519 private key — сгенерирован на устройстве. СЕКРЕТ: не
  /// логировать, маскировать в diag-снапшотах.
  final String privKey;

  /// base64, public key пира Cloudflare (`config.peers[0].public_key`).
  final String peerPub;

  /// Интерфейсный адрес v4 (`config.interface.addresses.v4`), напр. `172.16.0.2`.
  final String clientV4;

  /// Интерфейсный адрес v6.
  final String clientV6;

  /// base64 `config.client_id` (3 байта) → WireGuard `reserved`. Без него
  /// handshake проходит, но трафик не идёт.
  final String clientId;

  final String accountId;
  final String deviceId;

  /// Bearer-token устройства (нужен для PATCH account). СЕКРЕТ: не логировать.
  final String token;

  /// `host:port` пира, default `engage.cloudflareclient.com:2408`.
  final String endpoint;

  /// ISO8601 момента регистрации.
  final String createdAt;

  /// WARP+ license key, если вводился пользователем.
  final String? license;

  /// true если license успешно привязан (account.warp_plus).
  final bool warpPlus;

  static const String defaultEndpoint = 'engage.cloudflareclient.com:2408';

  /// `reserved` как 3 байта (из base64 client_id). null если client_id битый.
  List<int>? get reserved => parseReserved(clientId);

  WarpAccount copyWith({
    String? license,
    bool? warpPlus,
    String? endpoint,
  }) =>
      WarpAccount(
        privKey: privKey,
        peerPub: peerPub,
        clientV4: clientV4,
        clientV6: clientV6,
        clientId: clientId,
        accountId: accountId,
        deviceId: deviceId,
        token: token,
        endpoint: endpoint ?? this.endpoint,
        createdAt: createdAt,
        license: license ?? this.license,
        warpPlus: warpPlus ?? this.warpPlus,
      );

  /// Собирает `wireguard://` URI для добавления узла через стандартный
  /// `addFromInput`. `reserved` доносит client_id (десятичный `b0,b1,b2` —
  /// `parseReserved` принимает его обратно).
  ///
  /// Адреса: оба (v4 + v6); allowed_ips = весь трафик. MTU=1280 — рекомендация
  /// Cloudflare для WARP (избегает фрагментации). Тег `WARP`/`WARP+`.
  String toWireguardUri() {
    final res = reserved;
    final addrs = [clientV4, if (clientV6.isNotEmpty) clientV6].join(',');
    final tag = warpPlus ? 'WARP+' : 'WARP';
    final q = <String, String>{
      'publickey': peerPub,
      'address': addrs,
      'allowedips': '0.0.0.0/0,::/0',
      'mtu': '1280',
      if (res != null) 'reserved': res.join(','),
    };
    final qs = q.entries
        .map((e) =>
            '${e.key}=${Uri.encodeQueryComponent(e.value).replaceAll('+', '%20')}')
        .join('&');
    return 'wireguard://${Uri.encodeQueryComponent(privKey)}@$endpoint?$qs#$tag';
  }

  /// Storage JSON. Секреты идут в storage (это локальный зашифрованный файл
  /// приложения), но НЕ должны попадать в логи/diag — см. [redacted].
  Map<String, Object?> toJson() => {
        'priv_key': privKey,
        'peer_pub': peerPub,
        'client_v4': clientV4,
        'client_v6': clientV6,
        'client_id': clientId,
        'account_id': accountId,
        'device_id': deviceId,
        'token': token,
        'endpoint': endpoint,
        'created_at': createdAt,
        'license': license,
        'warp_plus': warpPlus,
      };

  static WarpAccount? fromJson(Map<String, dynamic> m) {
    final priv = m['priv_key'];
    final pub = m['peer_pub'];
    if (priv is! String || priv.isEmpty || pub is! String || pub.isEmpty) {
      return null;
    }
    return WarpAccount(
      privKey: priv,
      peerPub: pub,
      clientV4: (m['client_v4'] as String?) ?? '',
      clientV6: (m['client_v6'] as String?) ?? '',
      clientId: (m['client_id'] as String?) ?? '',
      accountId: (m['account_id'] as String?) ?? '',
      deviceId: (m['device_id'] as String?) ?? '',
      token: (m['token'] as String?) ?? '',
      endpoint: (m['endpoint'] as String?) ?? defaultEndpoint,
      createdAt: (m['created_at'] as String?) ?? '',
      license: m['license'] as String?,
      warpPlus: m['warp_plus'] == true,
    );
  }

  /// Безопасное для логов представление — секреты замаскированы.
  Map<String, Object?> redacted() => {
        'peer_pub': peerPub,
        'client_v4': clientV4,
        'client_v6': clientV6,
        'client_id': clientId,
        'account_id': accountId,
        'device_id': deviceId,
        'endpoint': endpoint,
        'created_at': createdAt,
        'warp_plus': warpPlus,
        'priv_key': '<redacted>',
        'token': '<redacted>',
        'license': license == null ? null : '<redacted>',
      };
}
