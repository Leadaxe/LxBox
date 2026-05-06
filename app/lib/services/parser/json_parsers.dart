import '../../models/node_spec.dart';
import '../../models/tls_spec.dart';
import '../../models/transport_spec.dart';
import 'uri_utils.dart';

/// Парсинг Xray JSON array (одно вхождение — один узел).
/// Упрощённая версия — поддерживает VLESS + SOCKS для detour-chain.
NodeSpec? parseXrayOutbound(Map<String, dynamic> element) {
  final outbounds = element['outbounds'];
  if (outbounds is! List) return null;

  Map<String, dynamic>? main;
  Map<String, dynamic>? detour;
  String? dialerRef;

  // Найти main VLESS outbound с dialerProxy (предпочтительнее).
  for (final ob in outbounds) {
    if (ob is! Map<String, dynamic>) continue;
    if (ob['protocol'] != 'vless') continue;
    final sockopt = (ob['streamSettings']?['sockopt']) as Map?;
    final ref = sockopt?['dialerProxy']?.toString();
    if (ref != null && ref.isNotEmpty) {
      main ??= ob;
      dialerRef ??= ref;
    }
  }
  main ??= outbounds
      .whereType<Map<String, dynamic>>()
      .firstWhere(
        (o) => o['protocol'] == 'vless' && o['tag'] == 'proxy',
        orElse: () => outbounds
            .whereType<Map<String, dynamic>>()
            .firstWhere(
              (o) => o['protocol'] == 'vless',
              orElse: () => <String, dynamic>{},
            ),
      );
  if (main.isEmpty) return null;

  // Найти detour outbound по dialerRef.
  if (dialerRef != null) {
    detour = outbounds
        .whereType<Map<String, dynamic>>()
        .firstWhere((o) => o['tag'] == dialerRef,
            orElse: () => <String, dynamic>{});
    if (detour.isEmpty) detour = null;
  }

  final remarks = element['remarks']?.toString() ?? '';

  final spec = _xrayVlessToSpec(main, remarks);
  if (spec == null) return null;

  if (detour != null) {
    final chained = _xrayDetourToSpec(detour);
    if (chained != null) {
      return VlessSpec(
        id: spec.id,
        tag: spec.tag,
        label: spec.label,
        server: spec.server,
        port: spec.port,
        rawUri: spec.rawUri,
        uuid: spec.uuid,
        flow: spec.flow,
        tls: spec.tls,
        transport: spec.transport,
        chained: chained,
        warnings: spec.warnings,
      );
    }
  }
  return spec;
}

VlessSpec? _xrayVlessToSpec(Map<String, dynamic> o, String remarks) {
  final vnext = (o['settings']?['vnext'] as List?)?.cast<Map>();
  if (vnext == null || vnext.isEmpty) return null;
  final v = vnext.first;
  final server = v['address']?.toString() ?? '';
  final port = (v['port'] as num?)?.toInt() ?? 443;
  final users = (v['users'] as List?)?.cast<Map>() ?? const [];
  final user = users.isEmpty ? const {} : users.first;
  final uuid = user['id']?.toString() ?? '';
  var flow = user['flow']?.toString() ?? '';
  if (server.isEmpty || uuid.isEmpty) return null;

  var port2 = port;
  var packetEncoding = '';
  if (flow == 'xtls-rprx-vision-udp443') {
    flow = 'xtls-rprx-vision';
    packetEncoding = 'xudp';
    port2 = 443;
  }

  final stream = o['streamSettings'] as Map? ?? const {};
  final tls = _xrayTlsFromStream(stream, server);
  final transport = _xrayTransportFromStream(stream);

  if (stream['security'] == 'reality' &&
      flow.isEmpty &&
      (stream['network'] ?? 'tcp') == 'tcp') {
    flow = 'xtls-rprx-vision';
  }

  final label = remarks.isNotEmpty ? remarks : (o['tag']?.toString() ?? '');
  final tag = tagFromLabel(label, 'vless', server, port2);

  return VlessSpec(
    id: newUuidV4(),
    tag: tag,
    label: label,
    server: server,
    port: port2,
    rawUri: 'xray://${o['tag'] ?? 'proxy'}',
    uuid: uuid,
    flow: flow,
    tls: tls,
    transport: transport,
    packetEncoding: packetEncoding,
  );
}

NodeSpec? _xrayDetourToSpec(Map<String, dynamic> o) {
  final protocol = o['protocol']?.toString() ?? '';
  if (protocol == 'socks') {
    final servers = (o['settings']?['servers'] as List?)?.cast<Map>();
    if (servers == null || servers.isEmpty) return null;
    final s = servers.first;
    final server = s['address']?.toString() ?? '';
    final port = (s['port'] as num?)?.toInt() ?? 1080;
    if (server.isEmpty) return null;
    final users = (s['users'] as List?)?.cast<Map>() ?? const [];
    final user = users.isEmpty ? const {} : users.first;
    final tag = '⚙ ${o['tag'] ?? 'jump'}';
    return SocksSpec(
      id: newUuidV4(),
      tag: tag,
      label: tag,
      server: server,
      port: port,
      rawUri: 'xray-jump://socks',
      username: user['user']?.toString() ?? '',
      password: user['pass']?.toString() ?? '',
    );
  }
  if (protocol == 'vless') {
    final spec = _xrayVlessToSpec(o, '⚙ ${o['tag'] ?? 'jump'}');
    return spec;
  }
  return null;
}

TlsSpec _xrayTlsFromStream(Map stream, String server) {
  final security = stream['security']?.toString() ?? '';
  if (security == 'none' || security.isEmpty) return TlsSpec.disabled;

  if (security == 'reality') {
    final r = stream['realitySettings'] as Map? ?? const {};
    return TlsSpec(
      enabled: true,
      serverName: r['serverName']?.toString() ?? server,
      fingerprint: r['fingerprint']?.toString() ?? 'random',
      reality: RealitySpec(
        publicKey: r['publicKey']?.toString() ?? '',
        shortId: (r['shortId']?.toString() ?? '').toLowerCase(),
      ),
    );
  }

  if (security == 'tls') {
    final t = stream['tlsSettings'] as Map? ?? const {};
    return TlsSpec(
      enabled: true,
      serverName: t['serverName']?.toString() ?? server,
      fingerprint: (t['fingerprint']?.toString() ?? '').toLowerCase().isEmpty
          ? null
          : t['fingerprint'].toString().toLowerCase(),
      insecure: t['allowInsecure'] == true,
    );
  }
  return TlsSpec.disabled;
}

TransportSpec? _xrayTransportFromStream(Map stream) {
  final net = (stream['network']?.toString() ?? 'tcp').toLowerCase();
  switch (net) {
    case 'ws':
      final ws = stream['wsSettings'] as Map? ?? const {};
      final headers = (ws['headers'] as Map?)?.cast<String, dynamic>();
      final host = headers?['Host']?.toString() ?? '';
      return WsTransport(path: ws['path']?.toString() ?? '/', host: host);
    case 'grpc':
      final g = stream['grpcSettings'] as Map? ?? const {};
      return GrpcTransport(
          serviceName: g['serviceName']?.toString() ?? '');
    case 'http':
    case 'h2':
      final h = stream['httpSettings'] as Map? ?? const {};
      final hosts = (h['host'] as List?)?.map((e) => e.toString()).toList() ??
          const <String>[];
      return HttpTransport(path: h['path']?.toString() ?? '/', hosts: hosts);
    default:
      return null;
  }
}

/// sing-box outbound / endpoint JSON → NodeSpec (§4 round-trip).
/// Используется для JSON-редактора и Smart-Paste одиночного sing-box entry.
NodeSpec? parseSingboxEntry(Map<String, dynamic> entry) {
  final type = entry['type']?.toString() ?? '';
  final tag = entry['tag']?.toString() ?? '';
  final server = entry['server']?.toString() ?? '';
  final port = (entry['server_port'] as num?)?.toInt() ?? 0;
  final label = tag;

  switch (type) {
    case 'vless':
      if (server.isEmpty || port == 0) return null;
      final tls = _tlsFromSingbox(entry['tls'], server);
      return VlessSpec(
        id: newUuidV4(),
        tag: tag.isEmpty ? 'vless-$server-$port' : tag,
        label: label,
        server: server,
        port: port,
        rawUri: '',
        uuid: entry['uuid']?.toString() ?? '',
        flow: entry['flow']?.toString() ?? '',
        tls: tls,
        transport: _transportFromSingbox(entry['transport']),
        packetEncoding: normalizePacketEncoding(
          entry['packet_encoding']?.toString() ?? '',
          tag: tag,
        ),
      );
    case 'vmess':
      if (server.isEmpty || port == 0) return null;
      return VmessSpec(
        id: newUuidV4(),
        tag: tag.isEmpty ? 'vmess-$server-$port' : tag,
        label: label,
        server: server,
        port: port,
        rawUri: '',
        uuid: entry['uuid']?.toString() ?? '',
        alterId: (entry['alter_id'] as num?)?.toInt() ?? 0,
        security: entry['security']?.toString() ?? 'auto',
        tls: _tlsFromSingbox(entry['tls'], server),
        transport: _transportFromSingbox(entry['transport']),
      );
    case 'trojan':
      if (server.isEmpty || port == 0) return null;
      return TrojanSpec(
        id: newUuidV4(),
        tag: tag.isEmpty ? 'trojan-$server-$port' : tag,
        label: label,
        server: server,
        port: port,
        rawUri: '',
        password: entry['password']?.toString() ?? '',
        tls: _tlsFromSingbox(entry['tls'], server),
        transport: _transportFromSingbox(entry['transport']),
      );
    case 'shadowsocks':
      if (server.isEmpty || port == 0) return null;
      return ShadowsocksSpec(
        id: newUuidV4(),
        tag: tag.isEmpty ? 'ss-$server-$port' : tag,
        label: label,
        server: server,
        port: port,
        rawUri: '',
        method: entry['method']?.toString() ?? '',
        password: entry['password']?.toString() ?? '',
      );
    case 'hysteria2':
      if (server.isEmpty || port == 0) return null;
      return Hysteria2Spec(
        id: newUuidV4(),
        tag: tag.isEmpty ? 'hy2-$server-$port' : tag,
        label: label,
        server: server,
        port: port,
        rawUri: '',
        password: entry['password']?.toString() ?? '',
        obfs: (entry['obfs'] as Map?)?['type']?.toString() ?? '',
        obfsPassword: (entry['obfs'] as Map?)?['password']?.toString() ?? '',
        tls: _tlsFromSingbox(entry['tls'], server),
      );
    case 'naive':
      if (server.isEmpty || port == 0) return null;
      final eh = entry['extra_headers'];
      final extraHeaders = <String, String>{};
      if (eh is Map) {
        for (final k in eh.keys) {
          final v = eh[k];
          if (v is String) {
            extraHeaders[k.toString()] = v;
          } else if (v is List && v.isNotEmpty) {
            extraHeaders[k.toString()] = v.first.toString();
          }
        }
      }
      return NaiveSpec(
        id: newUuidV4(),
        tag: tag.isEmpty ? 'naive-$server-$port' : tag,
        label: label,
        server: server,
        port: port,
        rawUri: '',
        username: entry['username']?.toString() ?? '',
        password: entry['password']?.toString() ?? '',
        tls: _tlsFromSingbox(entry['tls'], server),
        extraHeaders: extraHeaders,
      );
    case 'tuic':
      if (server.isEmpty || port == 0) return null;
      return TuicSpec(
        id: newUuidV4(),
        tag: tag.isEmpty ? 'tuic-$server-$port' : tag,
        label: label,
        server: server,
        port: port,
        rawUri: '',
        uuid: entry['uuid']?.toString() ?? '',
        password: entry['password']?.toString() ?? '',
        congestionControl:
            entry['congestion_control']?.toString() ?? 'cubic',
        udpRelayMode: entry['udp_relay_mode']?.toString() ?? 'native',
        zeroRtt: entry['zero_rtt_handshake'] == true,
        tls: _tlsFromSingbox(entry['tls'], server),
      );
    case 'ssh':
      if (server.isEmpty || port == 0) return null;
      final hk = entry['host_key'];
      return SshSpec(
        id: newUuidV4(),
        tag: tag.isEmpty ? 'ssh-$server-$port' : tag,
        label: label,
        server: server,
        port: port,
        rawUri: '',
        user: entry['user']?.toString() ?? 'root',
        password: entry['password']?.toString() ?? '',
        privateKey: entry['private_key']?.toString() ?? '',
        privateKeyPassphrase:
            entry['private_key_passphrase']?.toString() ?? '',
        hostKey: hk is List ? hk.map((e) => e.toString()).toList() : const [],
      );
    case 'socks':
      if (server.isEmpty || port == 0) return null;
      return SocksSpec(
        id: newUuidV4(),
        tag: tag.isEmpty ? 'socks-$server-$port' : tag,
        label: label,
        server: server,
        port: port,
        rawUri: '',
        username: entry['username']?.toString() ?? '',
        password: entry['password']?.toString() ?? '',
      );
    case 'wireguard':
      final addr = (entry['address'] as List?)?.map((e) => e.toString()).toList() ??
          const <String>[];
      final peers = (entry['peers'] as List?)?.cast<Map>() ?? const [];
      if (peers.isEmpty) return null;
      final p = peers.first;
      final peerServer = p['address']?.toString() ?? server;
      final peerPort = (p['port'] as num?)?.toInt() ?? port;
      if (peerServer.isEmpty) return null;
      final allowedIps =
          (p['allowed_ips'] as List?)?.map((e) => e.toString()).toList() ??
              const ['0.0.0.0/0', '::/0'];
      return WireguardSpec(
        id: newUuidV4(),
        tag: tag.isEmpty ? 'wg-$peerServer-$peerPort' : tag,
        label: label,
        server: peerServer,
        port: peerPort,
        rawUri: '',
        privateKey: entry['private_key']?.toString() ?? '',
        localAddresses: addr,
        peers: [
          WireguardPeer(
            publicKey: p['public_key']?.toString() ?? '',
            preSharedKey: p['pre_shared_key']?.toString() ?? '',
            endpointHost: peerServer,
            endpointPort: peerPort,
            allowedIps: allowedIps,
            persistentKeepalive:
                (p['persistent_keepalive_interval'] as num?)?.toInt(),
          )
        ],
        mtu: (entry['mtu'] as num?)?.toInt(),
      );
    default:
      return null;
  }
}

TlsSpec _tlsFromSingbox(dynamic raw, String server) {
  if (raw is! Map) return TlsSpec.disabled;
  if (raw['enabled'] != true) return TlsSpec.disabled;
  final utls = raw['utls'] as Map?;
  final reality = raw['reality'] as Map?;
  return TlsSpec(
    enabled: true,
    serverName: raw['server_name']?.toString() ?? server,
    alpn: (raw['alpn'] as List?)?.map((e) => e.toString()).toList() ?? const [],
    insecure: raw['insecure'] == true,
    fingerprint: utls?['fingerprint']?.toString(),
    reality: reality == null || reality['enabled'] != true
        ? null
        : RealitySpec(
            publicKey: reality['public_key']?.toString() ?? '',
            shortId: reality['short_id']?.toString() ?? '',
          ),
  );
}

TransportSpec? _transportFromSingbox(dynamic raw) {
  if (raw is! Map) return null;
  final type = raw['type']?.toString() ?? '';
  switch (type) {
    case 'ws':
      final headers = (raw['headers'] as Map?)?.cast<String, dynamic>();
      return WsTransport(
        path: raw['path']?.toString() ?? '/',
        host: headers?['Host']?.toString() ?? '',
      );
    case 'grpc':
      return GrpcTransport(
          serviceName: raw['service_name']?.toString() ?? '');
    case 'http':
      return HttpTransport(
        path: raw['path']?.toString() ?? '/',
        hosts: (raw['host'] as List?)?.map((e) => e.toString()).toList() ??
            const [],
      );
    case 'httpupgrade':
      return HttpUpgradeTransport(
        path: raw['path']?.toString() ?? '/',
        host: raw['host']?.toString() ?? '',
      );
    default:
      return null;
  }
}
