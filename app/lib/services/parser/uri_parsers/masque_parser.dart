import '../../../models/node_spec.dart';
import '../uri_utils.dart';

// ════════════════════════════════════════════════════════════════════════════
// MASQUE (URI form) — §130
// ════════════════════════════════════════════════════════════════════════════
//
// `masque://<privKeyDer>@<server>:<port>?publickey=<serverPubDer>&address=<v4,v6>
//   &profile=cloudflare&network=h3[&sni=...][&mtu=1280]#<label>`
//
// Ключи — base64(DER), как в конфиге ядра. Отличие от WireGuard: нет reserved/
// allowed_ips/psk/keepalive; есть profile/network/sni.

MasqueSpec? parseMasqueUri(String uri) {
  // §106 — сырой `/` в base64-ключе (userInfo) ломает Uri.tryParse.
  final p = Uri.tryParse(encodeUserInfoSlashes(uri));
  if (p == null || p.host.isEmpty) return null;

  final q = p.queryParameters;
  final port = p.hasPort ? p.port : 443;

  var privateKeyDer = p.userInfo.isEmpty
      ? (q['privatekey'] ?? q['private_key'] ?? '')
      : Uri.decodeComponent(p.userInfo);
  privateKeyDer = privateKeyDer.trim();
  if (privateKeyDer.isEmpty) return null;

  final publicKeyDer = (q['publickey'] ?? q['public_key'] ?? '').trim();
  if (publicKeyDer.isEmpty) return null;

  final address = q['address'] ?? '';
  if (address.isEmpty) return null;
  final localAddresses = address
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .map(ensureCidr)
      .toList();
  if (localAddresses.isEmpty) return null;

  final profile = (q['profile'] ?? 'cloudflare').trim();
  final network = (q['network'] ?? 'h3').trim();
  final sni = (q['sni'] ?? '').trim();
  final mtu = int.tryParse(q['mtu'] ?? '') ?? 1280;

  final label = decodeFragment(p.fragment);
  final tag = tagFromLabel(label, 'masque', p.host, port);

  return MasqueSpec(
    id: newUuidV4(),
    tag: tag,
    label: label,
    server: p.host,
    port: port,
    rawUri: uri,
    privateKeyDer: privateKeyDer,
    publicKeyDer: publicKeyDer,
    localAddresses: localAddresses,
    profile: profile,
    network: network,
    sni: sni,
    mtu: mtu,
  );
}
