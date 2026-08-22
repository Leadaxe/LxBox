import '../../../models/node_spec.dart';
import '../uri_utils.dart';

// ════════════════════════════════════════════════════════════════════════════
// MASQUE (URI form) — §130
// ════════════════════════════════════════════════════════════════════════════
//
// `masque://<privKeyDer>@<server>:<port>?publickey=<serverPubDer>&address=<v4,v6>
//   &profile=cloudflare&vhttp=h3[&sni=...][&disable_sni=1][&mtu=1280]#<label>`
//
// Ключи — base64(DER), как в конфиге ядра. Отличие от WireGuard: нет reserved/
// allowed_ips/psk/keepalive; есть profile/vhttp/sni.
//
// §393 — вход принимает ОБА поколения имён: `vhttp` (ядро) и legacy `network`
// (наши URI, выпущенные до миграции, плюс чужие ссылки). Legacy-имена живут
// только здесь и в JSON-импорте; модель и эмит знают одно имя.
//
// Промежуточного `transport` тут нет намеренно: имя прожило один коммит в
// develop, ни в один релиз и ни в один пользовательский URI не попало.

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
  // §393 — `vhttp` приоритетнее legacy `network`; ядро при обоих именах с
  // разными значениями падает, у нас на входе просто выигрывает новое.
  final vhttpRaw = (q['vhttp'] ?? '').trim();
  final vhttpPicked =
      vhttpRaw.isNotEmpty ? vhttpRaw : (q['network'] ?? 'h3').trim();
  // SPEC 103 п.5 — невалидное значение форсится в h3 (node_parser_masque.go:
  // vhttp != "h3" && vhttp != "h2" → forcing h3), а не пропускается как есть.
  final vhttp = (vhttpPicked == 'h3' || vhttpPicked == 'h2')
      ? vhttpPicked
      : 'h3';
  final sni = (q['sni'] ?? q['server_name'] ?? '').trim();
  final disableSni = q['disable_sni'] == '1' || q['disable_sni'] == 'true';
  final mtu = int.tryParse(q['mtu'] ?? '') ?? 1280;
  final idleTimeout = (q['idle_timeout'] ?? '').trim();
  final keepAlive = (q['keep_alive'] ?? '').trim();

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
    vhttp: vhttp,
    sni: sni,
    disableSni: disableSni,
    mtu: mtu,
    idleTimeout: idleTimeout,
    keepAlive: keepAlive,
  );
}
