import '../../models/node_spec.dart' show Awg;
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
    this.awg,
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

  /// §126 — AmneziaWG 1.5 obfuscation поля (jc/jmin/jmax/s1-2/h1-4/i1). `null`
  /// = обычный WARP (без обфускации, byte-for-byte plain WG). Когда задано —
  /// узел добавляется через `.conf` ([toWireguardConf]), не через короткий URI.
  final Awg? awg;

  static const String defaultEndpoint = 'engage.cloudflareclient.com:2408';

  /// §137 — тег WARP-узла с эмодзи внутри. Облако ☁️ для plain, гроза ⛈️ для
  /// AWG-обфускации (визуальный сигнал «маскируется от DPI»). `+` для WARP+.
  /// Коллизия-суффикс (` 2`/` 3`) накидывает caller (контроллер знает соседей).
  static String nodeTag({required bool warpPlus, required bool hasAwg}) {
    final plus = warpPlus ? '+' : '';
    return hasAwg ? '🔥⛈️ WARP$plus (AWG 1.5)' : '🔥☁️ WARP$plus';
  }

  /// `reserved` как 3 байта (из base64 client_id). null если client_id битый.
  List<int>? get reserved => parseReserved(clientId);

  /// `clearAwg: true` снимает обфускацию (awg → null), игнорируя [awg].
  WarpAccount copyWith({
    String? license,
    bool? warpPlus,
    String? endpoint,
    Awg? awg,
    bool clearAwg = false,
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
        awg: clearAwg ? null : (awg ?? this.awg),
      );

  /// Собирает `wireguard://` URI для добавления узла через стандартный
  /// `addFromInput`. `reserved` доносит client_id (десятичный `b0,b1,b2` —
  /// `parseReserved` принимает его обратно).
  ///
  /// Адреса: оба (v4 + v6); allowed_ips = весь трафик. MTU=1280 — рекомендация
  /// Cloudflare для WARP (избегает фрагментации). Тег `WARP`/`WARP+`.
  /// §142 — [includeReserved]: класть ли client_id в reserved. Plain WARP —
  /// true (своя регистрация, §025). Обфускация — обычно false (привязка к
  /// устройству режется; рабочие конфиги все БЕЗ reserved).
  String toWireguardUri({bool includeReserved = true}) {
    final res = includeReserved ? reserved : null;
    final addrs = [clientV4, if (clientV6.isNotEmpty) clientV6].join(',');
    // §137 — тег с эмодзи (plain = облако). Коллизию контроллер чинит ре-тегом.
    final tag = nodeTag(warpPlus: warpPlus, hasAwg: false);
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
    return 'wireguard://${Uri.encodeQueryComponent(privKey)}@$endpoint?$qs#${Uri.encodeComponent(tag)}';
  }

  /// §126 — собирает `.conf` (WireGuard INI) для обфусцированного узла.
  ///
  /// Используется когда [awg] задан (обфускация включена): `i1` ~1700b в hex
  /// дружелюбнее провести через INI (`parseWireguardIni` уже читает AWG из
  /// `[Interface]` и эскейпит `<>`/пробелы), формат 1:1 совпадает с тем, что
  /// эмитит генератор Amnezia 1.5. `reserved` (client_id) идёт в `[Peer]`.
  ///
  /// Для plain WARP (awg==null) используем короткий [toWireguardUri].
  ///
  /// §142 — [includeReserved]: обфусцированный узел обычно БЕЗ reserved
  /// (привязка к устройству режется, рабочие конфиги все без него).
  String toWireguardConf({bool includeReserved = true}) {
    final res = includeReserved ? reserved : null;
    final tag = warpPlus ? 'WARP+' : 'WARP';
    final addrs = [clientV4, if (clientV6.isNotEmpty) clientV6].join(', ');
    final b = StringBuffer()
      ..writeln('# $tag (Amnezia 1.5 obfuscation)')
      ..writeln('[Interface]')
      ..writeln('PrivateKey = $privKey')
      ..writeln('Address = $addrs')
      ..writeln('MTU = 1280');
    // AWG-поля (Jc/Jmin/.../I1). Ключи — как ждёт ini_parser (он lowercase'ит);
    // значения i* идут сырыми (`<b 0x…>`), парсер сам их эскейпит.
    final awgFields = awg?.fields;
    if (awgFields != null) {
      // Детерминированный порядок: числовые сначала, i* в конце (читаемость).
      final keys = awgFields.keys.toList()..sort();
      for (final k in keys) {
        b.writeln('${k.toUpperCase()} = ${awgFields[k]}');
      }
    }
    b
      ..writeln()
      ..writeln('[Peer]')
      ..writeln('PublicKey = $peerPub')
      ..writeln('AllowedIPs = 0.0.0.0/0, ::/0')
      ..writeln('Endpoint = $endpoint');
    if (res != null) {
      b.writeln('Reserved = ${res.join(',')}');
    }
    return b.toString();
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
        if (awg != null) 'awg': Map<String, Object>.from(awg!.fields),
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
      awg: m['awg'] is Map
          ? Awg.fromJson(Map<String, dynamic>.from(m['awg'] as Map))
          : null,
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
        'obfuscated': awg != null,
        'priv_key': '<redacted>',
        'token': '<redacted>',
        'license': license == null ? null : '<redacted>',
      };
}
