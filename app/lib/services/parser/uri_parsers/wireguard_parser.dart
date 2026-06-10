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
  var privateKey = p.userInfo.isEmpty
      ? (q['privatekey'] ?? q['private_key'] ?? '')
      : Uri.decodeComponent(p.userInfo);
  privateKey = privateKey.trim();
  if (privateKey.isEmpty) return null;

  final publicKey = q['publickey'] ?? q['public_key'] ?? '';
  if (publicKey.isEmpty) return null;

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

  final psk = q['presharedkey'] ?? q['preshared_key'] ?? '';
  final keepalive = int.tryParse(q['keepalive'] ?? '');

  final peer = WireguardPeer(
    publicKey: publicKey,
    preSharedKey: psk,
    endpointHost: p.host,
    endpointPort: port,
    allowedIps: allowedIps,
    persistentKeepalive: keepalive,
  );

  final label = decodeFragment(p.fragment);
  final tag = tagFromLabel(label, 'wireguard', p.host, port);

  // §097 — AWG: клиентский MTU клампим до 1280 (awgClampMtu); обычный WG
  // не трогаем (дефолт 1408 как в sing-box).
  final awg = Awg.fromQuery(q);
  final rawMtu = int.tryParse(q['mtu'] ?? '');
  final mtu = awg != null ? awgClampMtu(rawMtu, tag) : (rawMtu ?? 1408);

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
