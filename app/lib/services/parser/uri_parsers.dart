import 'dart:convert';

import '../../models/node_spec.dart';
import '../../models/node_warning.dart';
import '../../models/tls_spec.dart';
import '../app_log.dart';
import 'transport.dart';
import 'uri_utils.dart';

/// Диспетчер по схеме URI. Возвращает NodeSpec или null (skip).
/// Ошибки структуры (отсутствие host, uuid) — null, не throw.
NodeSpec? parseUri(String uri) {
  if (uri.length > maxURILength) return null;
  final t = uri.trim();
  if (t.isEmpty) return null;
  final scheme = t.split('://').first.toLowerCase();
  try {
    switch (scheme) {
      case 'vless':
        return parseVless(t);
      case 'vmess':
        return parseVmess(t);
      case 'trojan':
        return parseTrojan(t);
      case 'ss':
        return parseShadowsocks(t);
      case 'hysteria2':
      case 'hy2':
        return parseHysteria2(t);
      case 'naive+https':
        return parseNaive(t);
      case 'tuic':
        return parseTuic(t);
      case 'ssh':
        return parseSsh(t);
      case 'socks':
      case 'socks5':
        return parseSocks(t);
      case 'wg':
      case 'wireguard':
        return parseWireguardUri(t);
      default:
        return null;
    }
  } catch (_) {
    return null;
  }
}

// ════════════════════════════════════════════════════════════════════════════
// VLESS
// ════════════════════════════════════════════════════════════════════════════

VlessSpec? parseVless(String uri) {
  final p = Uri.tryParse(uri);
  if (p == null || p.host.isEmpty || p.userInfo.isEmpty) return null;

  final uuid = Uri.decodeComponent(p.userInfo.split(':').first);
  final server = p.host;
  final port = p.hasPort ? p.port : 443;
  final q = Map<String, String>.from(p.queryParameters);
  final label = decodeFragment(p.fragment);
  final tag = tagFromLabel(label, 'vless', server, port);

  final transport = parseTransport(q);
  final tls = parseVlessTls(q, server, port);

  var flow = (q['flow'] ?? '').trim();
  final warnings = <NodeWarning>[];
  var packetEncoding = '';

  // v1 quirk: flow=xtls-rprx-vision-udp443 → vision + packet_encoding=xudp.
  if (flow == 'xtls-rprx-vision-udp443') {
    flow = 'xtls-rprx-vision';
    packetEncoding = 'xudp';
  }
  // v1 quirk: auto-flow когда REALITY активна без transport'а.
  if (flow.isEmpty && (q['pbk'] ?? '').trim().isNotEmpty && transport == null) {
    flow = 'xtls-rprx-vision';
  }
  if (q.containsKey('packetEncoding') && packetEncoding.isEmpty) {
    packetEncoding = q['packetEncoding']!;
  }

  if (tls.insecure) warnings.add(const InsecureTlsWarning());

  return VlessSpec(
    id: newUuidV4(),
    tag: tag,
    label: label,
    server: server,
    port: port,
    rawUri: uri,
    uuid: uuid,
    flow: flow,
    tls: tls,
    transport: transport,
    packetEncoding: packetEncoding,
    warnings: warnings,
  );
}

// ════════════════════════════════════════════════════════════════════════════
// VMess (legacy JSON base64 + modern cleartext)
// ════════════════════════════════════════════════════════════════════════════

VmessSpec? parseVmess(String uri) {
  var body = uri.substring('vmess://'.length);
  var fragment = '';
  final hashIdx = body.indexOf('#');
  if (hashIdx >= 0) {
    fragment = body.substring(hashIdx + 1);
    body = body.substring(0, hashIdx);
  }

  final bytes = decodeBase64Safe(body);
  if (bytes == null || bytes.isEmpty) return null;
  final decoded = utf8Lossy(bytes).trim();
  if (decoded.isEmpty) return null;

  // Попытка распарсить как JSON (v2rayN format).
  try {
    final j = jsonDecode(decoded);
    if (j is Map<String, dynamic>) {
      return _vmessFromJson(j, uri);
    }
  } catch (_) {}

  // Fallback: legacy cleartext `method:uuid@host:port`.
  return _vmessLegacy(decoded, fragment, uri);
}

VmessSpec? _vmessFromJson(Map<String, dynamic> cfg, String rawUri) {
  final server = cfg['add']?.toString() ?? '';
  final id = cfg['id']?.toString() ?? '';
  if (server.isEmpty || id.isEmpty) return null;

  final portRaw = cfg['port'];
  final port = portRaw is num
      ? portRaw.toInt()
      : int.tryParse(portRaw?.toString() ?? '') ?? 443;

  final ps = cfg['ps']?.toString() ?? '';
  final label = sanitizeForDisplay(ps);
  final tag = tagFromLabel(label, 'vmess', server, port);

  final security = normalizeVmessSecurity(
    (cfg['scy'] ?? cfg['security'])?.toString() ?? '',
  );
  final aidRaw = cfg['aid'];
  final alterId = aidRaw is num
      ? aidRaw.toInt()
      : int.tryParse(aidRaw?.toString() ?? '') ?? 0;

  final net = (cfg['net']?.toString() ?? 'tcp').toLowerCase().trim();
  final q = <String, String>{
    if (cfg['path'] != null) 'path': cfg['path'].toString(),
    if (cfg['host'] != null) 'host': cfg['host'].toString(),
    if (cfg['sni'] != null) 'sni': cfg['sni'].toString(),
    if (cfg['serviceName'] != null)
      'serviceName': cfg['serviceName'].toString(),
  };
  final transport = parseTransport(
    q,
    networkOverride: net,
    defaultHost: server,
  );

  final tls = parseVmessTls(cfg, server, net);

  final warnings = <NodeWarning>[];
  if (tls.insecure) warnings.add(const InsecureTlsWarning());

  return VmessSpec(
    id: newUuidV4(),
    tag: tag,
    label: label,
    server: server,
    port: port,
    rawUri: rawUri,
    uuid: id,
    alterId: alterId,
    security: security,
    tls: tls,
    transport: transport,
    warnings: warnings,
  );
}

VmessSpec? _vmessLegacy(String s, String fragment, String rawUri) {
  final atIdx = s.indexOf('@');
  if (atIdx < 0) return null;
  final userinfo = s.substring(0, atIdx);
  final hp = s.substring(atIdx + 1).split('?').first;
  final parts = userinfo.split(':');
  if (parts.length < 2) return null;
  final method = parts[0].trim();
  final uuid = parts.sublist(1).join(':').trim();
  if (method.isEmpty || uuid.isEmpty) return null;

  final lastColon = hp.lastIndexOf(':');
  if (lastColon <= 0) return null;
  final host = hp.substring(0, lastColon);
  final port = int.tryParse(hp.substring(lastColon + 1)) ?? 443;

  final label = sanitizeForDisplay(decodeFragment(fragment));
  final tag = tagFromLabel(label, 'vmess', host, port);

  return VmessSpec(
    id: newUuidV4(),
    tag: tag,
    label: label,
    server: host,
    port: port,
    rawUri: rawUri,
    uuid: uuid,
    security: normalizeVmessSecurity(method),
  );
}

// ════════════════════════════════════════════════════════════════════════════
// Trojan
// ════════════════════════════════════════════════════════════════════════════

TrojanSpec? parseTrojan(String uri) {
  final p = Uri.tryParse(uri);
  if (p == null || p.host.isEmpty) return null;

  final userParts = p.userInfo.split(':');
  final password = Uri.decodeComponent(userParts.join(':'));
  if (password.isEmpty) return null;

  final server = p.host;
  final port = p.hasPort ? p.port : 443;
  final q = Map<String, String>.from(p.queryParameters);
  final label = decodeFragment(p.fragment);
  final tag = tagFromLabel(label, 'trojan', server, port);

  final transport = parseTransport(q);
  final tls = parseTrojanTls(q, server);

  final warnings = <NodeWarning>[];
  if (tls.insecure) warnings.add(const InsecureTlsWarning());

  return TrojanSpec(
    id: newUuidV4(),
    tag: tag,
    label: label,
    server: server,
    port: port,
    rawUri: uri,
    password: password,
    tls: tls,
    transport: transport,
    warnings: warnings,
  );
}

// ════════════════════════════════════════════════════════════════════════════
// Shadowsocks (SIP002 + legacy base64)
// ════════════════════════════════════════════════════════════════════════════

ShadowsocksSpec? parseShadowsocks(String uri) {
  var body = uri.substring('ss://'.length);
  var fragment = '';
  final hashIdx = body.indexOf('#');
  if (hashIdx >= 0) {
    fragment = body.substring(hashIdx + 1);
    body = body.substring(0, hashIdx);
  }
  body = body.trim();

  String method = '';
  String password = '';
  String rest = '';

  final atIdx = body.indexOf('@');
  if (atIdx > 0) {
    // SIP002: ss://base64(method:password)@host:port
    final encoded = Uri.decodeComponent(body.substring(0, atIdx));
    rest = body.substring(atIdx + 1);
    final decoded = decodeBase64Safe(encoded);
    if (decoded == null) return null;
    final s = utf8Lossy(decoded);
    final colonIdx = s.indexOf(':');
    if (colonIdx <= 0) return null;
    method = s.substring(0, colonIdx).trim();
    password = s.substring(colonIdx + 1);
  } else {
    // Legacy: ss://base64(method:password@host:port)
    final decoded = decodeBase64Safe(Uri.decodeComponent(body));
    if (decoded == null) return null;
    final s = utf8Lossy(decoded);
    final at = s.indexOf('@');
    if (at <= 0) return null;
    final left = s.substring(0, at);
    rest = s.substring(at + 1).trim();
    final colonIdx = left.indexOf(':');
    if (colonIdx <= 0) return null;
    method = left.substring(0, colonIdx).trim();
    password = left.substring(colonIdx + 1);
  }

  if (!isValidShadowsocksMethod(method) || password.isEmpty) return null;

  // rest = "host:port?query" or "host:port"
  final qIdx = rest.indexOf('?');
  final hostPort = qIdx < 0 ? rest : rest.substring(0, qIdx);
  final q = qIdx < 0
      ? const <String, String>{}
      : Uri.splitQueryString(rest.substring(qIdx + 1));

  // Parse host:port (IPv6 bracketed).
  String server;
  int port;
  if (hostPort.startsWith('[')) {
    final close = hostPort.indexOf(']');
    if (close < 0) return null;
    server = hostPort.substring(1, close);
    final tail = hostPort.substring(close + 1);
    port = int.tryParse(tail.startsWith(':') ? tail.substring(1) : tail) ?? 8388;
  } else {
    final colonIdx = hostPort.lastIndexOf(':');
    if (colonIdx <= 0) return null;
    server = hostPort.substring(0, colonIdx);
    port = int.tryParse(hostPort.substring(colonIdx + 1)) ?? 8388;
  }

  final label = decodeFragment(fragment);
  final tag = tagFromLabel(label, 'shadowsocks', server, port);

  return ShadowsocksSpec(
    id: newUuidV4(),
    tag: tag,
    label: label,
    server: server,
    port: port,
    rawUri: uri,
    method: method,
    password: password,
    plugin: _ssPluginName(q['plugin']),
    pluginOpts: _ssPluginOpts(q['plugin']) ?? (q['plugin_opts'] ?? ''),
  );
}

/// SIP003: `plugin` query содержит `name;k=v;k=v…`. Имя — до первого `;`.
String _ssPluginName(String? raw) {
  if (raw == null || raw.isEmpty) return '';
  final i = raw.indexOf(';');
  return i < 0 ? raw : raw.substring(0, i);
}

/// SIP003: всё после первого `;` — opts. Null если отдельного `plugin_opts`
/// надо взять (старый split не применим).
String? _ssPluginOpts(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  final i = raw.indexOf(';');
  return i < 0 ? null : raw.substring(i + 1);
}

// ════════════════════════════════════════════════════════════════════════════
// Hysteria2
// ════════════════════════════════════════════════════════════════════════════

Hysteria2Spec? parseHysteria2(String uri) {
  final normalized = uri.startsWith('hy2://')
      ? uri.replaceFirst('hy2://', 'hysteria2://')
      : uri;
  final p = Uri.tryParse(normalized);
  if (p == null || p.host.isEmpty) return null;

  final password = Uri.decodeComponent(p.userInfo);
  if (password.isEmpty) return null;

  final server = p.host;
  final port = p.hasPort ? p.port : 443;
  final q = Map<String, String>.from(p.queryParameters);
  final label = decodeFragment(p.fragment);
  final tag = tagFromLabel(label, 'hysteria2', server, port);

  final obfs = q['obfs'] ?? '';
  final obfsPass = q['obfs-password'] ?? '';

  var sni = q['sni'] ?? '';
  if (sni.isEmpty || sni == '🔒' || (!sni.contains('.') && !sni.contains(':'))) {
    sni = server;
  }
  final fp = (q['fp'] ?? q['fingerprint'] ?? '').toLowerCase().trim();
  final alpn = (q['alpn'] ?? '').isEmpty
      ? const <String>[]
      : q['alpn']!.split(',').map((e) => e.trim()).toList();

  final tls = TlsSpec(
    enabled: true,
    serverName: sni,
    fingerprint: fp.isEmpty ? null : fp,
    insecure: isTlsInsecure(q),
    alpn: alpn,
  );

  final warnings = <NodeWarning>[];
  if (tls.insecure) warnings.add(const InsecureTlsWarning());

  return Hysteria2Spec(
    id: newUuidV4(),
    tag: tag,
    label: label,
    server: server,
    port: port,
    rawUri: uri,
    password: password,
    obfs: obfs,
    obfsPassword: obfsPass,
    tls: tls,
    warnings: warnings,
  );
}

// ════════════════════════════════════════════════════════════════════════════
// NaïveProxy — see spec 037.
// ════════════════════════════════════════════════════════════════════════════

/// Charset для имени HTTP-заголовка из DuckSoft de-facto спеки naive URI.
final RegExp _naiveHeaderName =
    RegExp(r"^[!#$%&'*+\-.0-9A-Z\\^_`a-z|~]+$");

/// Известные query-keys; всё остальное — log warning + ignore.
const _naiveKnownQueryKeys = <String>{'extra-headers', 'padding'};

NaiveSpec? parseNaive(String uri) {
  final p = Uri.tryParse(uri);
  if (p == null || p.host.isEmpty) return null;

  // userinfo: только password (без `:`) → password=userinfo, username='';
  // user:pass → split; пустой → both empty.
  String username = '';
  String password = '';
  if (p.userInfo.isNotEmpty) {
    final colon = p.userInfo.indexOf(':');
    if (colon < 0) {
      password = Uri.decodeComponent(p.userInfo);
    } else {
      username = Uri.decodeComponent(p.userInfo.substring(0, colon));
      password = Uri.decodeComponent(p.userInfo.substring(colon + 1));
    }
  }

  final server = p.host;
  final port = p.hasPort ? p.port : 443;
  final q = Map<String, String>.from(p.queryParameters);
  final label = decodeFragment(p.fragment);
  final tag = tagFromLabel(label, 'naive', server, port);

  // padding не имеет соответствия в sing-box — silently drop с log-warn.
  if (q.containsKey('padding')) {
    AppLog.I.warning(
      "naive: 'padding' parameter has no sing-box equivalent, ignoring",
    );
  }

  // Незнакомые query — лог + игнор.
  for (final key in q.keys) {
    if (!_naiveKnownQueryKeys.contains(key)) {
      AppLog.I.warning("naive: unknown query param '$key', ignoring");
    }
  }

  // extra-headers: уже URL-decoded внутри queryParameters.
  final headers = parseNaiveExtraHeaders(q['extra-headers'] ?? '');

  // Naive accepts ТОЛЬКО enabled/server_name/cert/ECH в TLS-блоке.
  // Никаких alpn/utls/insecure/reality — sing-box валидатор отклонит.
  final tls = TlsSpec(enabled: true, serverName: server);

  return NaiveSpec(
    id: newUuidV4(),
    tag: tag,
    label: label,
    server: server,
    port: port,
    rawUri: uri,
    username: username,
    password: password,
    tls: tls,
    extraHeaders: headers,
  );
}

/// Парсит уже-URL-decoded строку `Header1: Value1\r\nHeader2: Value2`.
/// Невалидные пары (нет `:`, имя нарушает charset, пустое имя) — drop с warn.
Map<String, String> parseNaiveExtraHeaders(String raw) {
  if (raw.isEmpty) return const {};
  final out = <String, String>{};
  for (final line in raw.split('\r\n')) {
    final l = line.trim();
    if (l.isEmpty) continue;
    final colon = l.indexOf(':');
    if (colon <= 0) {
      AppLog.I.warning("naive: invalid extra-headers entry '$l', skipping");
      continue;
    }
    final name = l.substring(0, colon).trim();
    final value = l.substring(colon + 1).trim();
    if (name.isEmpty || !_naiveHeaderName.hasMatch(name)) {
      AppLog.I
          .warning("naive: invalid header name '$name' in extra-headers, skipping");
      continue;
    }
    out[name] = value;
  }
  return out;
}

// ════════════════════════════════════════════════════════════════════════════
// TUIC v5 — новый протокол в v2.
// ════════════════════════════════════════════════════════════════════════════

TuicSpec? parseTuic(String uri) {
  final p = Uri.tryParse(uri);
  if (p == null || p.host.isEmpty || p.userInfo.isEmpty) return null;

  final userParts = p.userInfo.split(':');
  if (userParts.length < 2) return null;
  final uuid = Uri.decodeComponent(userParts.first);
  final password = Uri.decodeComponent(userParts.sublist(1).join(':'));
  if (uuid.isEmpty || password.isEmpty) return null;

  final server = p.host;
  final port = p.hasPort ? p.port : 443;
  final q = Map<String, String>.from(p.queryParameters);
  final label = decodeFragment(p.fragment);
  final tag = tagFromLabel(label, 'tuic', server, port);

  final cc = (q['congestion_control'] ?? 'cubic').toLowerCase().trim();
  final urm = (q['udp_relay_mode'] ?? 'native').toLowerCase().trim();
  final zeroRtt = (q['reduce_rtt'] ?? q['zero_rtt'] ?? '0') == '1' ||
      (q['reduce_rtt'] ?? q['zero_rtt'] ?? '').toLowerCase() == 'true';

  var sni = q['sni'] ?? '';
  if (sni.isEmpty) sni = server;
  final alpn = (q['alpn'] ?? 'h3').split(',').map((e) => e.trim()).toList();

  final tls = TlsSpec(
    enabled: true,
    serverName: q['disable_sni'] == '1' ? null : sni,
    alpn: alpn,
    insecure: isTlsInsecure(q),
  );

  final warnings = <NodeWarning>[];
  if (tls.insecure) warnings.add(const InsecureTlsWarning());

  return TuicSpec(
    id: newUuidV4(),
    tag: tag,
    label: label,
    server: server,
    port: port,
    rawUri: uri,
    uuid: uuid,
    password: password,
    congestionControl: _normalizeCongestion(cc),
    udpRelayMode: urm == 'quic' ? 'quic' : 'native',
    zeroRtt: zeroRtt,
    tls: tls,
    warnings: warnings,
  );
}

String _normalizeCongestion(String s) =>
    {'bbr', 'cubic', 'new_reno'}.contains(s) ? s : 'cubic';

// ════════════════════════════════════════════════════════════════════════════
// SSH
// ════════════════════════════════════════════════════════════════════════════

SshSpec? parseSsh(String uri) {
  final p = Uri.tryParse(uri);
  if (p == null || p.host.isEmpty || p.userInfo.isEmpty) return null;

  final userParts = p.userInfo.split(':');
  final user = Uri.decodeComponent(userParts.first);
  final password = userParts.length > 1
      ? Uri.decodeComponent(userParts.sublist(1).join(':'))
      : '';
  if (user.isEmpty) return null;

  final server = p.host;
  final port = p.hasPort ? p.port : 22;
  final q = Map<String, String>.from(p.queryParameters);
  final label = decodeFragment(p.fragment);
  final tag = tagFromLabel(label, 'ssh', server, port);

  final hostKey = (q['host_key'] ?? '').isEmpty
      ? const <String>[]
      : q['host_key']!
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
  final hostKeyAlgorithms = (q['host_key_algorithms'] ?? '').isEmpty
      ? const <String>[]
      : q['host_key_algorithms']!
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();

  return SshSpec(
    id: newUuidV4(),
    tag: tag,
    label: label,
    server: server,
    port: port,
    rawUri: uri,
    user: user,
    password: password,
    privateKey: q['private_key'] ?? '',
    privateKeyPassphrase: q['private_key_passphrase'] ?? '',
    hostKey: hostKey,
    hostKeyAlgorithms: hostKeyAlgorithms,
  );
}

// ════════════════════════════════════════════════════════════════════════════
// SOCKS 5
// ════════════════════════════════════════════════════════════════════════════

SocksSpec? parseSocks(String uri) {
  final p = Uri.tryParse(uri);
  if (p == null || p.host.isEmpty) return null;

  final userParts = p.userInfo.split(':');
  final username = userParts.isEmpty || userParts.first.isEmpty
      ? ''
      : Uri.decodeComponent(userParts.first);
  final password = userParts.length > 1
      ? Uri.decodeComponent(userParts.sublist(1).join(':'))
      : '';

  final server = p.host;
  final port = p.hasPort ? p.port : 1080;
  final label = decodeFragment(p.fragment);
  final tag = tagFromLabel(label, 'socks', server, port);

  return SocksSpec(
    id: newUuidV4(),
    tag: tag,
    label: label,
    server: server,
    port: port,
    rawUri: uri,
    username: username,
    password: password,
  );
}

// ════════════════════════════════════════════════════════════════════════════
// WireGuard (URI form)
// ════════════════════════════════════════════════════════════════════════════

WireguardSpec? parseWireguardUri(String uri) {
  final p = Uri.tryParse(uri);
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

  final localAddresses = address
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  final allowedIpsRaw = q['allowedips'] ?? q['allowed_ips'] ?? '0.0.0.0/0, ::/0';
  final allowedIps = allowedIpsRaw
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  final mtu = int.tryParse(q['mtu'] ?? '') ?? 1408;
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
  );
}
