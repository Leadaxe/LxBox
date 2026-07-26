import 'dart:convert';

import '../../models/node_spec.dart';
import '../../models/node_warning.dart';
import '../../models/tls_spec.dart';
import '../../models/transport_spec.dart';
import 'transport.dart';
import 'uri_utils.dart';
import 'utls_fingerprint.dart';

/// §310 — Парсинг одного элемента Xray JSON array в список узлов.
///
/// Раньше элемент сворачивался в ОДИН узел («main» VLESS, остальные —
/// отбрасывались). Провайдеры кладут в элемент несколько равноправных
/// серверов (основной + резервные) — они терялись, подписка приезжала без
/// резерва. Теперь каждый VLESS-outbound становится своим узлом.
///
/// Исключение — outbound'ы, на которые ссылается `sockopt.dialerProxy`: они
/// приезжают как detour-звено (`⚙ <tag>`) своего владельца и самостоятельным
/// узлом НЕ дублируются (контракт §018 detour-chain не меняется).
///
/// Упрощённая версия — поддерживает VLESS + SOCKS для detour-chain.
List<NodeSpec> parseXrayElement(Map<String, dynamic> element) {
  final outbounds = element['outbounds'];
  if (outbounds is! List) return const [];

  final vlessAll =
      outbounds.whereType<Map<String, dynamic>>().where((o) => o['protocol'] == 'vless').toList();
  if (vlessAll.isEmpty) return const [];

  // dialerProxy-ссылки: цели исключаются из самостоятельных узлов.
  final dialerRefOf = <Map<String, dynamic>, String>{};
  final dialerTargets = <String>{};
  for (final ob in vlessAll) {
    final sockopt = (ob['streamSettings']?['sockopt']) as Map?;
    final ref = sockopt?['dialerProxy']?.toString();
    if (ref != null && ref.isNotEmpty) {
      dialerRefOf[ob] = ref;
      dialerTargets.add(ref);
    }
  }

  // Порядок: «main» первым (dialerProxy → тег `proxy` → первый), чтобы у
  // существующих подписок первый узел остался тем же, что и до §310.
  final candidates = vlessAll
      .where((o) => !dialerTargets.contains(o['tag']?.toString()))
      .toList();
  if (candidates.isEmpty) return const [];
  final mainIdx = candidates.indexWhere((o) => dialerRefOf.containsKey(o)) >= 0
      ? candidates.indexWhere((o) => dialerRefOf.containsKey(o))
      : (candidates.indexWhere((o) => o['tag'] == 'proxy') >= 0
          ? candidates.indexWhere((o) => o['tag'] == 'proxy')
          : 0);
  final ordered = [
    candidates[mainIdx],
    for (var i = 0; i < candidates.length; i++)
      if (i != mainIdx) candidates[i],
  ];

  final remarks = element['remarks']?.toString() ?? '';
  final extended = _prettyJson(element);

  final result = <NodeSpec>[];
  for (var i = 0; i < ordered.length; i++) {
    final ob = ordered[i];
    // §310 — имя разводим на парсинге: `allocateTag` уникализирует теги лишь
    // на build'е (суффикс `-N`), а в списке узлов пользователь иначе увидит
    // несколько одинаковых строк. Одиночный узел — имя ровно как до §310.
    final spec = _xrayVlessToSpec(ob, _elementLabel(remarks, ob, i));
    if (spec == null) continue;

    // §302 — исходник узла для UI («Source» на экране узла) и для правил по
    // JSON-телам: compact = сам outbound, extended = весь элемент как пришёл
    // от провайдера (dns/inbounds/routing соседи). rawUri для таких узлов —
    // синтетическая заглушка `xray://<tag>`, источником служить не может.
    final compact = _prettyJson(ob);

    final ref = dialerRefOf[ob];
    NodeSpec? chained;
    if (ref != null) {
      final detour = outbounds.whereType<Map<String, dynamic>>().firstWhere(
          (o) => o['tag'] == ref,
          orElse: () => <String, dynamic>{});
      if (detour.isNotEmpty) chained = _xrayDetourToSpec(detour);
    }

    final node = chained == null
        ? spec
        : VlessSpec(
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
    result.add(node
      ..sourceCompact = compact
      ..sourceExtended = extended == compact ? null : extended);
  }
  return result;
}

/// Первый («main») узел элемента или `null`. Совместимость с вызовами,
/// которым нужен ровно один узел; полный список даёт [parseXrayElement].
NodeSpec? parseXrayOutbound(Map<String, dynamic> element) {
  final nodes = parseXrayElement(element);
  return nodes.isEmpty ? null : nodes.first;
}

/// §310 — метка узла внутри элемента. Первый узел (`i == 0`) — `remarks` как
/// есть (обратная совместимость: элемент с одним VLESS даёт то же имя, что и
/// до таски). Последующие — `remarks` + тег outbound'а, а если тега нет —
/// индексный суффикс (` 2`, ` 3`, …), как `_indexedHint` в §243.
String _elementLabel(String remarks, Map<String, dynamic> ob, int i) {
  if (i == 0) return remarks;
  final tag = ob['tag']?.toString().trim() ?? '';
  if (remarks.isEmpty) return tag;
  return tag.isNotEmpty ? '$remarks $tag' : '$remarks ${i + 1}';
}

/// §302 — стабильный отступ для показа фрагмента подписки пользователю.
String _prettyJson(Object? value) {
  try {
    return const JsonEncoder.withIndent('  ').convert(value);
  } catch (_) {
    return value.toString();
  }
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
  final warnings = <NodeWarning>[];
  if (flow == 'xtls-rprx-vision-udp443') {
    flow = 'xtls-rprx-vision';
    packetEncoding = 'xudp';
    port2 = 443;
  }

  final stream = o['streamSettings'] as Map? ?? const {};
  // §281 — fp вне словаря ядра = fatal всего конфига; канонизируем на входе.
  final tls =
      normalizeTlsFingerprint(_xrayTlsFromStream(stream, server), warnings);
  final transport = _xrayTransportFromStream(stream);

  // §115 — flow берём из конфига как есть (раньше REALITY+tcp без flow
  // получал навязанный vision → ломались валидные none-сетапы). vision
  // несовместим с транспортом → гасим flow + warning.
  if (flow == 'xtls-rprx-vision' && transport != null) {
    warnings.add(
        VisionWithTransportWarning((stream['network'] ?? 'transport').toString()));
    flow = '';
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
    warnings: warnings,
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
    final pbk = r['publicKey']?.toString() ?? '';
    // §169 — REALITY только при валидном X25519-ключе. Битый publicKey →
    // деградируем до plain TLS (нода рабочая), а не отравляем config.json.
    return TlsSpec(
      enabled: true,
      serverName: r['serverName']?.toString() ?? server,
      fingerprint: r['fingerprint']?.toString() ?? 'random',
      reality: isValidRealityPublicKey(pbk)
          ? RealitySpec(
              publicKey: pbk,
              shortId: normalizeRealityShortId(r['shortId']?.toString() ?? ''),
            )
          : null,
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
      // §303 — Xray кладёт early data хвостом пути (`/x?ed=2560`); в sing-box
      // это отдельное поле, а хвост в пути даёт 404.
      final (path, ed) = splitEarlyDataPath(ws['path']?.toString() ?? '/');
      return WsTransport(path: path, host: host, maxEarlyData: ed);
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
    case 'xhttp': // §097 — Xray xhttpSettings → нативный xhttp
      final x = stream['xhttpSettings'] as Map? ?? const {};
      return XhttpTransport(
        path: x['path']?.toString() ?? '/',
        host: x['host']?.toString() ?? '',
        mode: x['mode']?.toString() ?? '',
      );
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
    case 'anytls': // §269
      if (server.isEmpty || port == 0) return null;
      // AnyTLS всегда поверх TLS: если tls-блок отсутствует/выключен —
      // подставляем минимальный enabled (serverName=server).
      var anyTls = _tlsFromSingbox(entry['tls'], server);
      if (!anyTls.enabled) {
        anyTls = TlsSpec(enabled: true, serverName: server);
      }
      return AnyTlsSpec(
        id: newUuidV4(),
        tag: tag.isEmpty ? 'anytls-$server-$port' : tag,
        label: label,
        server: server,
        port: port,
        rawUri: '',
        password: entry['password']?.toString() ?? '',
        tls: anyTls,
        idleSessionCheckInterval:
            entry['idle_session_check_interval']?.toString() ?? '',
        idleSessionTimeout: entry['idle_session_timeout']?.toString() ?? '',
        minIdleSession: (entry['min_idle_session'] as num?)?.toInt(),
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
      // §219 — кастуем entry['obfs'] один раз (было дважды).
      final obfs = entry['obfs'] as Map?;
      return Hysteria2Spec(
        id: newUuidV4(),
        tag: tag.isEmpty ? 'hy2-$server-$port' : tag,
        label: label,
        server: server,
        port: port,
        rawUri: '',
        password: entry['password']?.toString() ?? '',
        obfs: obfs?['type']?.toString() ?? '',
        obfsPassword: obfs?['password']?.toString() ?? '',
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
        // §281 (ревью) — naive принимает ТОЛЬКО enabled/server_name в TLS:
        // alpn/utls/insecure/reality ядро отклоняет при создании outbound
        // (fatal всего конфига). Зеркало naive_parser: срезаем блок.
        tls: _naiveTlsFromSingbox(entry['tls'], server),
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
    case 'http': // §222 — HTTP(S) CONNECT proxy
      if (server.isEmpty || port == 0) return null;
      // headers: listable-значения sing-box (string | [string, ...]) —
      // как naive extra_headers.
      final hh = entry['headers'];
      final headers = <String, String>{};
      if (hh is Map) {
        for (final k in hh.keys) {
          final v = hh[k];
          if (v is String) {
            headers[k.toString()] = v;
          } else if (v is List && v.isNotEmpty) {
            headers[k.toString()] = v.first.toString();
          }
        }
      }
      return HttpSpec(
        id: newUuidV4(),
        tag: tag.isEmpty ? 'http-$server-$port' : tag,
        label: label,
        server: server,
        port: port,
        rawUri: '',
        username: entry['username']?.toString() ?? '',
        password: entry['password']?.toString() ?? '',
        path: entry['path']?.toString() ?? '',
        headers: headers,
        tls: _tlsFromSingbox(entry['tls'], server),
      );
    case 'wireguard':
      // §106 — bare IP → CIDR (/32 | /128) для address и allowed_ips.
      final addr = (entry['address'] as List?)
              ?.map((e) => ensureCidr(e.toString()))
              .toList() ??
          const <String>[];
      final peers = (entry['peers'] as List?)?.cast<Map>() ?? const [];
      if (peers.isEmpty) return null;
      final p = peers.first;
      final peerServer = p['address']?.toString() ?? server;
      final peerPort = (p['port'] as num?)?.toInt() ?? port;
      if (peerServer.isEmpty) return null;
      final allowedIps = (p['allowed_ips'] as List?)
              ?.map((e) => ensureCidr(e.toString()))
              .toList() ??
          const ['0.0.0.0/0', '::/0'];
      final awg = Awg.fromJson(entry); // §097 — AmneziaWG2 obfuscation params
      final wgTag = tag.isEmpty ? 'wg-$peerServer-$peerPort' : tag;
      // §097 — AWG: клампим MTU до 1280. §219 — plain WG дефолтит 1408 как в
      // URI-парсере (было null → зеркалим `wireguard_parser.dart`, чтобы модель
      // не зависела от источника парсинга: JSON vs URI).
      final rawMtu = (entry['mtu'] as num?)?.toInt();
      // §025/§126 — WARP client_id. §219 — раньше JSON-парсер не заполнял
      // `reserved` (WARP-handshake проходил, трафик не шёл). В sing-box JSON
      // `reserved` — массив из 3 байт `[b0,b1,b2]` (наш round-trip формат
      // эмиттера); `client_id` — base64-строка. Массив берём напрямую
      // (с валидацией 3×0..255), строку — через parseReserved.
      final reserved = _reservedFromJson(p['reserved'] ?? entry['reserved']) ??
          (p['client_id'] is String
              ? parseReserved(p['client_id'] as String)
              : null);
      return WireguardSpec(
        id: newUuidV4(),
        tag: wgTag,
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
            reserved: reserved,
          )
        ],
        mtu: awg != null ? awgClampMtu(rawMtu, wgTag) : (rawMtu ?? 1408),
        awg: awg,
      );
    case 'masque':
      // §130 — обратная операция к emitMasque (round-trip JSON-редактор /
      // Smart-Paste). ip/ipv6 → localAddresses; keep_alive_period → keepAlive.
      if (server.isEmpty || port == 0) return null;
      final priv = entry['private_key']?.toString() ?? '';
      final pub = entry['public_key']?.toString() ?? '';
      if (priv.isEmpty || pub.isEmpty) return null;
      final ip = entry['ip']?.toString() ?? '';
      final ipv6 = entry['ipv6']?.toString() ?? '';
      final addrs = <String>[
        if (ip.isNotEmpty) ensureCidr(ip),
        if (ipv6.isNotEmpty) ensureCidr(ipv6),
      ];
      if (addrs.isEmpty) return null;
      return MasqueSpec(
        id: newUuidV4(),
        tag: tag.isEmpty ? 'masque-$server-$port' : tag,
        label: label,
        server: server,
        port: port,
        rawUri: '',
        privateKeyDer: priv,
        publicKeyDer: pub,
        localAddresses: addrs,
        profile: entry['profile']?.toString() ?? 'cloudflare',
        network: entry['network']?.toString() ?? 'h3',
        sni: entry['sni']?.toString() ?? '',
        mtu: (entry['mtu'] as num?)?.toInt(),
        idleTimeout: entry['idle_timeout']?.toString() ?? '',
        keepAlive: entry['keep_alive_period']?.toString() ?? '',
      );
    default:
      return null;
  }
}

/// §219 — `reserved` из sing-box JSON WireGuard-peer: массив ровно из 3 байт
/// `[b0,b1,b2]` (0..255). Не-массив / не-3-элемента / вне диапазона → null
/// (не роняем ноду, деградируем к «без reserved» — ср. §172).
List<int>? _reservedFromJson(dynamic raw) {
  if (raw is! List || raw.length != 3) return null;
  final out = <int>[];
  for (final e in raw) {
    final n = e is num ? e.toInt() : null;
    if (n == null || n < 0 || n > 255) return null;
    out.add(n);
  }
  return out;
}

/// §281 — TLS для naive-entry: только enabled/server_name (см. naive_parser).
TlsSpec _naiveTlsFromSingbox(dynamic raw, String server) {
  final full = _tlsFromSingbox(raw, server);
  if (!full.enabled) return full;
  return TlsSpec(enabled: true, serverName: full.serverName);
}

TlsSpec _tlsFromSingbox(dynamic raw, String server) {
  if (raw is! Map) return TlsSpec.disabled;
  if (raw['enabled'] != true) return TlsSpec.disabled;
  final utls = raw['utls'] as Map?;
  final reality = raw['reality'] as Map?;
  // §281 — fp канонизируется молча (псевдонимы И мусор → словарь ядра):
  // у parseSingboxEntry нет warnings-аккумулятора, это power-user путь
  // JSON-редактора/Smart-Paste — итоговое значение видно в самом JSON.
  return normalizeTlsFingerprint(TlsSpec(
    enabled: true,
    serverName: raw['server_name']?.toString() ?? server,
    alpn: (raw['alpn'] as List?)?.map((e) => e.toString()).toList() ?? const [],
    insecure: raw['insecure'] == true,
    fingerprint: utls?['fingerprint']?.toString(),
    // §169 — REALITY только при enabled И валидном X25519 public_key. Битый
    // ключ → reality=null (нода остаётся plain TLS), а не отравляет config.
    reality: reality == null ||
            reality['enabled'] != true ||
            !isValidRealityPublicKey(reality['public_key']?.toString() ?? '')
        ? null
        : RealitySpec(
            publicKey: reality['public_key']!.toString(),
            shortId:
                normalizeRealityShortId(reality['short_id']?.toString() ?? ''),
          ),
  ), null);
}

TransportSpec? _transportFromSingbox(dynamic raw) {
  if (raw is! Map) return null;
  final type = raw['type']?.toString() ?? '';
  switch (type) {
    case 'ws':
      final headers = (raw['headers'] as Map?)?.cast<String, dynamic>();
      // §303 — sing-box JSON обычно уже разделён (`max_early_data`), но в
      // редактор попадают и склеенные Xray-пути.
      final (path, edFromPath) =
          splitEarlyDataPath(raw['path']?.toString() ?? '/');
      final edField = raw['max_early_data'];
      return WsTransport(
        path: path,
        host: headers?['Host']?.toString() ?? '',
        maxEarlyData: edField is int ? edField : edFromPath,
        earlyDataHeaderName:
            (raw['early_data_header_name']?.toString().isNotEmpty ?? false)
                ? raw['early_data_header_name'].toString()
                : null,
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
      // §303 — early data у httpupgrade нет, но хвост пути всё равно чужой.
      final (path, _) = splitEarlyDataPath(raw['path']?.toString() ?? '/');
      return HttpUpgradeTransport(
        path: path,
        host: raw['host']?.toString() ?? '',
      );
    case 'xhttp': // §097 — нативный xhttp из sing-box JSON
      return XhttpTransport(
        path: raw['path']?.toString() ?? '/',
        host: raw['host']?.toString() ?? '',
        mode: raw['mode']?.toString() ?? '',
        xPaddingBytes: raw['x_padding_bytes']?.toString() ?? '',
        noGrpcHeader: raw['no_grpc_header'] == true,
        headers: (raw['headers'] as Map?)
                ?.map((k, v) => MapEntry(k.toString(), v.toString())) ??
            const {},
      );
    default:
      return null;
  }
}
