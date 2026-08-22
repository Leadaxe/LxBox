import '../../../models/node_spec.dart';
import '../uri_utils.dart';

// ════════════════════════════════════════════════════════════════════════════
// WireGuard (URI form)
// ════════════════════════════════════════════════════════════════════════════

WireguardSpec? parseWireguardUri(String uri) {
  // §106 — сырой `/` в base64-ключе (userInfo) ломает Uri.tryParse.
  final p = Uri.tryParse(encodeUserInfoSlashes(uri));
  if (p == null || p.host.isEmpty) return null;

  final q = p.queryParameters;
  final port = p.hasPort ? p.port : 51820;

  // В v1 private_key хранится в userInfo. В некоторых clients — в query.
  var privateKeyRaw = p.userInfo.isEmpty
      ? (q['privatekey'] ?? q['private_key'] ?? '')
      : Uri.decodeComponent(p.userInfo);
  privateKeyRaw = privateKeyRaw.trim();
  if (privateKeyRaw.isEmpty) return null;
  // SPEC 103 D-023/D-030 — мусорный или неканонический ключ (не ровно 32
  // байта base64, любая из 4 форм) валит `sing-box check` целиком (класс
  // `pbk=enabled`) или даёт разные identity-хеши одной ноды; эталон Go
  // normalizeWGKey — нода отбрасывается, не эмитится как есть.
  final privateKey = normalizeWGKey(privateKeyRaw);
  if (privateKey == null) return null;

  final publicKeyRaw = q['publickey'] ?? q['public_key'] ?? '';
  if (publicKeyRaw.isEmpty) return null;
  final publicKey = normalizeWGKey(publicKeyRaw);
  if (publicKey == null) return null;

  final address = q['address'] ?? '';
  if (address.isEmpty) return null;

  // §106 — bare IP → CIDR (/32 | /128), иначе sing-box не грузит endpoint.
  final localAddresses = address
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .map(ensureCidr)
      .toList();

  final allowedIpsRaw = q['allowedips'] ?? q['allowed_ips'] ?? '0.0.0.0/0, ::/0';
  final allowedIps = allowedIpsRaw
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .map(ensureCidr)
      .toList();

  // Канон — только `presharedkey` без подчёркивания: единственный ключ,
  // который читает Go (node_parser_wireguard.go: queryParamPreservePlus/
  // q.Get("presharedkey"), без "preshared_key"-алиаса, в отличие от
  // privatekey/private_key — тот алиас Go добавил намеренно, D-021).
  final pskRaw = q['presharedkey'] ?? '';
  // SPEC 103 D-023/D-030 — тот же ключевой guard, что private/public key;
  // пустой psk остаётся пустым (опционален), мусорный/невалидной длины —
  // нода отбрасывается (эталон Go normalizeWGKey на presharedkey).
  String psk;
  if (pskRaw.isEmpty) {
    psk = '';
  } else {
    final normalized = normalizeWGKey(pskRaw);
    if (normalized == null) return null;
    psk = normalized;
  }
  final keepalive = int.tryParse(q['keepalive'] ?? '');

  // §025 — WARP client_id: `reserved=b0,b1,b2` или base64 `client_id`.
  final reservedRaw = q['reserved'] ?? q['client_id'] ?? '';
  final reserved = reservedRaw.isEmpty ? null : parseReserved(reservedRaw);

  final peer = WireguardPeer(
    publicKey: publicKey,
    preSharedKey: psk,
    endpointHost: p.host,
    endpointPort: port,
    allowedIps: allowedIps,
    persistentKeepalive: keepalive,
    reserved: reserved,
  );

  final label = decodeFragment(p.fragment);
  final tag = tagFromLabel(label, 'wireguard', p.host, port);

  // §097/SPEC 103 D-026 — AWG: клиентский MTU клампим до 1280 (awgClampMtu);
  // обычный WG без явного mtu= в URI поле не эмитим вовсе — ядро само
  // ставит 1408 (transport/wireguard/endpoint.go), свой дефолт спорит с ним
  // и ломает identity-хеш (CANON §2.4).
  final awg = Awg.fromQuery(q);
  final rawMtu = int.tryParse(q['mtu'] ?? '');
  final mtu = awg != null ? awgClampMtu(rawMtu, tag) : rawMtu;

  return WireguardSpec(
    id: newUuidV4(),
    tag: tag,
    label: label,
    server: p.host,
    port: port,
    rawUri: uri,
    privateKey: privateKey,
    localAddresses: localAddresses,
    peers: [peer],
    mtu: mtu,
    awg: awg, // §097 — AmneziaWG2 obfuscation params (null = WG)
  );
}
