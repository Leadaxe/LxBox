import '../../models/node_spec.dart';
import 'uri_parsers.dart';

/// Парсинг WireGuard INI → WireguardSpec через wg:// URI (§3.3).
///
/// Обязательные поля: `[Interface].PrivateKey`, `[Peer].PublicKey`,
/// `[Peer].Endpoint`. Остальные — опциональные с дефолтами.
WireguardSpec? parseWireguardIni(String config) {
  final uri = _iniToUri(config);
  if (uri == null) return null;
  final spec = parseWireguardUri(uri);
  if (spec == null) return null;
  return WireguardSpec(
    id: spec.id,
    tag: spec.tag,
    label: spec.label,
    server: spec.server,
    port: spec.port,
    rawUri: spec.rawUri,
    privateKey: spec.privateKey,
    localAddresses: spec.localAddresses,
    peers: spec.peers,
    mtu: spec.mtu,
    rawIni: config,
    awg: spec.awg, // §097 — не теряем AWG при rebuild для rawIni
    warnings: spec.warnings,
  );
}

String? _iniToUri(String config) {
  final lines = config.split(RegExp(r'\r?\n'));
  String section = '';
  String privateKey = '';
  String address = '';
  String publicKey = '';
  String endpoint = '';
  String presharedKey = '';
  String reserved = ''; // §126 — WARP client_id (reserved/client_id в [Peer])
  int mtu = 0;
  int keepalive = 0;
  // §097 — AmneziaWG2 поля из [Interface] (Jc/Jmin/.../I1-I5; регистр value
  // сохраняем, ключ lowercase). Прокинем в URI-query → Awg.fromQuery.
  final awg = <String, String>{};

  for (final line in lines) {
    final t = line.trim();
    if (t.startsWith('[')) {
      section = t.toLowerCase();
      continue;
    }
    final idx = t.indexOf('=');
    if (idx < 0) continue;
    final k = t.substring(0, idx).trim().toLowerCase();
    final v = t.substring(idx + 1).trim();
    if (section == '[interface]') {
      if (k == 'privatekey') privateKey = v;
      if (k == 'address') address = v;
      if (k == 'mtu') mtu = int.tryParse(v) ?? 0;
      if (Awg.numKeys.contains(k) || Awg.strKeys.contains(k)) awg[k] = v;
    } else if (section == '[peer]') {
      if (k == 'publickey') publicKey = v;
      if (k == 'endpoint') endpoint = v;
      if (k == 'presharedkey') presharedKey = v;
      if (k == 'persistentkeepalive') keepalive = int.tryParse(v) ?? 0;
      // §126 — WARP `client_id` → reserved. Amnezia-генератор кладёт его в
      // [Peer] как `Reserved` (или `ClientId`); парсер reserved (parseReserved)
      // принимает и `b0,b1,b2`, и base64. Прокидываем сырым в URI-query.
      if (k == 'reserved' || k == 'client_id' || k == 'clientid') reserved = v;
    }
  }

  if (privateKey.isEmpty || publicKey.isEmpty || endpoint.isEmpty) return null;

  // endpoint → host + port (поддержка IPv6 [::1]:51820).
  String host;
  String port;
  if (endpoint.startsWith('[')) {
    final close = endpoint.indexOf(']');
    host = endpoint.substring(1, close > 0 ? close : endpoint.length);
    final after = close > 0 ? endpoint.substring(close + 1) : '';
    port = after.startsWith(':') ? after.substring(1) : '51820';
  } else {
    final lastColon = endpoint.lastIndexOf(':');
    final firstColon = endpoint.indexOf(':');
    if (lastColon > 0 && firstColon == lastColon) {
      host = endpoint.substring(0, lastColon);
      port = endpoint.substring(lastColon + 1);
    } else if (lastColon > 0) {
      // §219 — несколько ':' без скобок = голый IPv6. Порт здесь ПРИНЦИПИАЛЬНО
      // неотличим от адреса (`2001:db8::1:51820` vs адрес `...::1:51820`), т.к.
      // WireGuard требует `[IPv6]:port`. Осознанная деградация: весь endpoint —
      // host, порт по умолчанию. Явный порт голого IPv6 сюда не долетает — это
      // ожидаемо (некорректный по спеке формат), не баг.
      host = endpoint;
      port = '51820';
    } else {
      host = endpoint;
      port = '51820';
    }
  }

  final params = <String, String>{
    'publickey': publicKey,
    'privatekey': privateKey,
    'address': address,
  };
  if (mtu > 0) params['mtu'] = mtu.toString();
  if (presharedKey.isNotEmpty) params['presharedkey'] = presharedKey;
  if (keepalive > 0) params['keepalive'] = keepalive.toString();
  if (reserved.isNotEmpty) params['reserved'] = reserved; // §126

  // §097 — AWG-поля в query (encodeComponent ниже эскейпит i* с <>/пробелами).
  awg.forEach((k, v) {
    if (v.isNotEmpty) params[k] = v;
  });

  final query = params.entries
      .map((e) =>
          '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
      .join('&');

  final wrappedHost = host.contains(':') && !host.startsWith('[') ? '[$host]' : host;
  return 'wireguard://$wrappedHost:$port?$query#WireGuard';
}
