import 'dart:convert';

import '../models/parsed_node.dart';
import '../models/proxy_source.dart';

/// Subscription node parser — port of singbox-launcher `node_parser.go` and helpers.
class NodeParser {
  NodeParser._();

  /// Returns true if [input] looks like a WireGuard INI config ([Interface] + [Peer]).
  static bool isWireGuardConfig(String input) {
    final t = input.trim();
    return t.contains('[Interface]') && t.contains('[Peer]');
  }

  /// Converts a WireGuard INI config to a wireguard:// URI.
  static String wireGuardConfigToUri(String config) {
    final lines = config.split(RegExp(r'\r?\n'));
    String section = '';
    String privateKey = '';
    String address = '';
    String dns = '';
    String publicKey = '';
    String endpoint = '';
    String presharedKey = '';
    int mtu = 0;
    int keepalive = 0;

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.startsWith('[')) {
        section = trimmed.toLowerCase();
        continue;
      }
      final parts = trimmed.split('=');
      if (parts.length < 2) continue;
      final key = parts[0].trim().toLowerCase();
      final value = parts.sublist(1).join('=').trim();

      if (section == '[interface]') {
        if (key == 'privatekey') privateKey = value;
        if (key == 'address') address = value;
        if (key == 'dns') dns = value;
        if (key == 'mtu') mtu = int.tryParse(value) ?? 0;
      } else if (section == '[peer]') {
        if (key == 'publickey') publicKey = value;
        if (key == 'endpoint') endpoint = value;
        if (key == 'presharedkey') presharedKey = value;
        if (key == 'persistentkeepalive') keepalive = int.tryParse(value) ?? 0;
      }
    }

    if (privateKey.isEmpty || publicKey.isEmpty || endpoint.isEmpty) {
      throw const FormatException('WireGuard config missing required fields');
    }

    // endpoint is host:port
    final epParts = endpoint.split(':');
    final host = epParts[0];
    final port = epParts.length > 1 ? epParts[1] : '51820';

    final params = <String, String>{
      'publickey': publicKey,
      'privatekey': privateKey,
    };
    if (address.isNotEmpty) params['address'] = address;
    if (dns.isNotEmpty) params['dns'] = dns;
    if (mtu > 0) params['mtu'] = mtu.toString();
    if (presharedKey.isNotEmpty) params['presharedkey'] = presharedKey;
    if (keepalive > 0) params['keepalive'] = keepalive.toString();

    final query = params.entries.map((e) =>
      '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}').join('&');

    return 'wireguard://$host:$port?$query#WireGuard';
  }

  /// Returns true if [input] looks like a direct proxy link (vless://, vmess://, etc.)
  static bool isDirectLink(String input) {
    final t = input.trim();
    return t.startsWith('vless://') ||
        t.startsWith('vmess://') ||
        t.startsWith('trojan://') ||
        t.startsWith('ss://') ||
        t.startsWith('hysteria2://') ||
        t.startsWith('hy2://') ||
        t.startsWith('ssh://') ||
        t.startsWith('wireguard://') ||
        t.startsWith('socks5://') ||
        t.startsWith('socks://');
  }

  /// Returns true if [input] is a subscription URL (http / https).
  static bool isSubscriptionURL(String input) {
    final t = input.trim();
    return t.startsWith('http://') || t.startsWith('https://');
  }

  /// Parses a single proxy URI into [ParsedNode]. Returns null if node should be skipped.
  static ParsedNode? parseNode(
    String uri, [
    List<Map<String, String>> skipFilters = const [],
  ]) {
    if (uri.length > maxURILength) {
      throw FormatException(
        'URI length (${uri.length}) exceeds maximum ($maxURILength)',
      );
    }

    if (uri.startsWith('vmess://')) return _parseVMess(uri, skipFilters);
    if (uri.startsWith('wireguard://')) return _parseWireGuard(uri, skipFilters);

    String scheme;
    String uriToParse = uri;
    int defaultPort = 443;
    String ssMethod = '';
    String ssPassword = '';

    if (uri.startsWith('vless://')) {
      scheme = 'vless';
    } else if (uri.startsWith('trojan://')) {
      scheme = 'trojan';
    } else if (uri.startsWith('ss://')) {
      scheme = 'ss';
      final result = _preprocessSS(uri);
      uriToParse = result.uri;
      ssMethod = result.method;
      ssPassword = result.password;
    } else if (uri.startsWith('hysteria2://') || uri.startsWith('hy2://')) {
      scheme = 'hysteria2';
      if (uri.startsWith('hy2://')) {
        uriToParse = uri.replaceFirst('hy2://', 'hysteria2://');
      }
    } else if (uri.startsWith('ssh://')) {
      scheme = 'ssh';
      defaultPort = 22;
    } else if (uri.startsWith('socks5://')) {
      scheme = 'socks5';
      defaultPort = 1080;
    } else if (uri.startsWith('socks://')) {
      scheme = 'socks';
      defaultPort = 1080;
    } else {
      throw FormatException('Unsupported scheme');
    }

    final parsed = Uri.tryParse(uriToParse);
    if (parsed == null) throw FormatException('Failed to parse URI');

    final query = <String, String>{};
    parsed.queryParameters.forEach((k, v) => query[k] = v);

    if (scheme == 'ss') {
      if (ssMethod.isEmpty || ssPassword.isEmpty) {
        throw FormatException('SS link missing required method or password');
      }
      query['method'] = ssMethod;
      query['password'] = ssPassword;
    }

    final node = ParsedNode(
      tag: '',
      scheme: scheme,
      server: parsed.host,
      port: parsed.hasPort ? parsed.port : defaultPort,
      query: query,
    );

    // UUID / userinfo
    if (parsed.userInfo.isNotEmpty) {
      final userParts = parsed.userInfo.split(':');
      node.uuid = Uri.decodeComponent(userParts.first);
      if ((scheme == 'ssh' ||
              scheme == 'trojan' ||
              scheme == 'socks' ||
              scheme == 'socks5') &&
          userParts.length > 1) {
        node.query['password'] = Uri.decodeComponent(userParts.sublist(1).join(':'));
      }
    }

    // Fragment → label → tag
    var label = parsed.fragment;
    if (label.isNotEmpty) {
      label = Uri.decodeComponent(label);
      label = _sanitizeForDisplay(label);
    }
    node.label = label;

    if (label.isEmpty && parsed.path.length > 1) {
      node.label = parsed.path.substring(1);
    }

    _extractTagFromLabel(node);

    node.flow = query['flow'] ?? '';

    if (_shouldSkipNode(node, skipFilters)) return null;

    node.outbound = _buildOutbound(node);
    return node;
  }

  // ---------------------------------------------------------------------------
  // VMess
  // ---------------------------------------------------------------------------

  static ParsedNode? _parseVMess(
    String uri,
    List<Map<String, String>> skipFilters,
  ) {
    var b64Part = uri.substring('vmess://'.length);
    var fragment = '';
    final hashIdx = b64Part.indexOf('#');
    if (hashIdx >= 0) {
      fragment = Uri.decodeComponent(b64Part.substring(hashIdx + 1));
      b64Part = b64Part.substring(0, hashIdx);
    }

    final decoded = _decodeBase64(b64Part);
    if (decoded == null || decoded.isEmpty) {
      throw FormatException('Failed to decode VMess base64');
    }

    final str = utf8.decode(decoded, allowMalformed: true).trim();
    if (str.isEmpty) throw FormatException('VMess decoded payload is empty');

    // Try JSON first
    try {
      final json = jsonDecode(str);
      if (json is Map<String, dynamic>) {
        return _parseVMessJSON(json, skipFilters);
      }
    } catch (_) {}

    // Legacy cleartext: method:uuid@host:port
    return _parseVMessLegacy(str, fragment, skipFilters);
  }

  static ParsedNode? _parseVMessJSON(
    Map<String, dynamic> cfg,
    List<Map<String, String>> skipFilters,
  ) {
    final server = cfg['add']?.toString() ?? '';
    final portRaw = cfg['port'];
    final id = cfg['id']?.toString() ?? '';

    if (server.isEmpty || id.isEmpty) {
      throw FormatException('VMess missing required fields (add, id)');
    }

    int port;
    if (portRaw is num) {
      port = portRaw.toInt();
    } else {
      port = int.tryParse(portRaw?.toString() ?? '') ?? 443;
    }

    final node = ParsedNode(
      tag: '',
      scheme: 'vmess',
      server: server,
      port: port,
      uuid: id,
      query: <String, String>{},
    );

    final ps = cfg['ps']?.toString() ?? '';
    if (ps.isNotEmpty) {
      node.label = _sanitizeForDisplay(ps);
    }
    _extractTagFromLabel(node);

    node.query['security'] = _normalizeVMessSecurity(
      (cfg['scy'] ?? cfg['security'])?.toString() ?? '',
    );

    final aid = cfg['aid'];
    if (aid != null) {
      final aidStr = aid is num ? aid.toInt().toString() : aid.toString();
      if (aidStr != '0' && aidStr.isNotEmpty) node.query['alter_id'] = aidStr;
    }

    var net = (cfg['net']?.toString() ?? 'tcp').toLowerCase().trim();
    if (net == 'xhttp' || net == 'httpupgrade') net = 'httpupgrade';
    node.query['network'] = net;

    if (cfg['path'] != null) node.query['path'] = cfg['path'].toString();
    if (cfg['host'] != null) node.query['host'] = cfg['host'].toString();

    if (cfg['tls'] == 'tls') {
      node.query['tls_enabled'] = 'true';
      var sni = cfg['sni']?.toString() ?? '';
      if (sni.isEmpty) sni = cfg['host']?.toString() ?? '';
      if (sni.isEmpty) sni = server;
      node.query['sni'] = sni;
      if (cfg['alpn'] != null) node.query['alpn'] = cfg['alpn'].toString();
      if (cfg['fp'] != null) node.query['fp'] = cfg['fp'].toString();
      if (cfg['insecure'] == '1') node.query['insecure'] = 'true';
    }

    if (net == 'h2' && node.query['tls_enabled'] != 'true') {
      node.query['tls_enabled'] = 'true';
      var sni = cfg['sni']?.toString() ?? '';
      if (sni.isEmpty) sni = cfg['host']?.toString() ?? '';
      if (sni.isEmpty) sni = server;
      node.query['sni'] = sni;
    }

    if (_shouldSkipNode(node, skipFilters)) return null;
    node.outbound = _buildOutbound(node);
    return node;
  }

  static ParsedNode? _parseVMessLegacy(
    String s,
    String fragmentLabel,
    List<Map<String, String>> skipFilters,
  ) {
    final atIdx = s.indexOf('@');
    if (atIdx < 0) throw FormatException('VMess legacy: expected method:uuid@host:port');

    final userinfo = s.substring(0, atIdx);
    final hp = s.substring(atIdx + 1).split('?').first;
    final parts = userinfo.split(':');
    if (parts.length < 2) throw FormatException('VMess legacy: bad userinfo');

    final method = parts[0].trim();
    final uuid = parts.sublist(1).join(':').trim();
    if (method.isEmpty || uuid.isEmpty) {
      throw FormatException('VMess legacy: empty method or uuid');
    }

    final lastColon = hp.lastIndexOf(':');
    if (lastColon <= 0) throw FormatException('VMess legacy: missing port');

    final host = hp.substring(0, lastColon);
    final port = int.tryParse(hp.substring(lastColon + 1)) ?? 443;

    final node = ParsedNode(
      tag: '',
      scheme: 'vmess',
      server: host,
      port: port,
      uuid: uuid,
      query: <String, String>{},
    );
    node.query['security'] = _normalizeVMessSecurity(method);

    if (fragmentLabel.isNotEmpty) {
      node.label = _sanitizeForDisplay(fragmentLabel);
    }
    _extractTagFromLabel(node);

    if (_shouldSkipNode(node, skipFilters)) return null;
    node.outbound = _buildOutbound(node);
    return node;
  }

  // ---------------------------------------------------------------------------
  // Shadowsocks preprocessing
  // ---------------------------------------------------------------------------

  static _SSPreprocess _preprocessSS(String uri) {
    var ssPart = uri.substring('ss://'.length);
    var fragSuffix = '';
    final hashIdx = ssPart.indexOf('#');
    if (hashIdx >= 0) {
      fragSuffix = ssPart.substring(hashIdx);
      ssPart = ssPart.substring(0, hashIdx);
    }
    ssPart = ssPart.trim();

    final atIdx = ssPart.indexOf('@');
    if (atIdx > 0) {
      // SIP002 format: ss://base64(method:password)@host:port
      var encoded = ssPart.substring(0, atIdx);
      final rest = ssPart.substring(atIdx + 1);
      encoded = Uri.decodeComponent(encoded);
      final decoded = _decodeBase64(encoded);
      if (decoded != null) {
        final decodedStr = utf8.decode(decoded, allowMalformed: true);
        final colonIdx = decodedStr.indexOf(':');
        if (colonIdx > 0) {
          final method = decodedStr.substring(0, colonIdx);
          final password = decodedStr.substring(colonIdx + 1);
          if (_isValidShadowsocksMethod(method)) {
            return _SSPreprocess('ss://$rest$fragSuffix', method, password);
          }
          throw FormatException('Unsupported Shadowsocks method: $method');
        }
      }
    } else {
      // Legacy format: ss://base64(method:password@host:port)
      final decoded = _decodeBase64(Uri.decodeComponent(ssPart));
      if (decoded != null) {
        final decStr = utf8.decode(decoded, allowMalformed: true);
        final at = decStr.indexOf('@');
        if (at > 0) {
          final left = decStr.substring(0, at);
          final right = decStr.substring(at + 1).trim();
          final colonIdx = left.indexOf(':');
          if (colonIdx > 0 && right.isNotEmpty) {
            final method = left.substring(0, colonIdx).trim();
            final password = left.substring(colonIdx + 1);
            if (_isValidShadowsocksMethod(method)) {
              return _SSPreprocess('ss://$right$fragSuffix', method, password);
            }
            throw FormatException('Unsupported Shadowsocks method: $method');
          }
        }
      }
    }
    return _SSPreprocess(uri, '', '');
  }

  // ---------------------------------------------------------------------------
  // WireGuard
  // ---------------------------------------------------------------------------

  static ParsedNode? _parseWireGuard(
    String uri,
    List<Map<String, String>> skipFilters,
  ) {
    final parsed = Uri.tryParse(uri);
    if (parsed == null) throw FormatException('Failed to parse WireGuard URI');
    if (parsed.host.isEmpty) throw FormatException('WireGuard: missing hostname');
    if (parsed.userInfo.isEmpty) throw FormatException('WireGuard: missing private key');

    final privateKey = Uri.decodeComponent(parsed.userInfo).trim();
    if (privateKey.isEmpty) throw FormatException('WireGuard: empty private key');

    final port = parsed.hasPort ? parsed.port : 51820;
    final q = parsed.queryParameters;
    final publicKey = q['publickey'] ?? '';
    final address = q['address'] ?? '';
    final allowedips = q['allowedips'] ?? '0.0.0.0/0, ::/0';
    if (publicKey.isEmpty) throw FormatException('WireGuard: missing publickey');
    if (address.isEmpty) throw FormatException('WireGuard: missing address');

    final addressList =
        address.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    final allowedipsList =
        allowedips.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

    final mtu = int.tryParse(q['mtu'] ?? '') ?? 1408;

    final peer = <String, dynamic>{
      'address': parsed.host,
      'port': port,
      'public_key': publicKey,
      'allowed_ips': allowedipsList,
    };
    if (q.containsKey('keepalive')) {
      final ka = int.tryParse(q['keepalive']!);
      if (ka != null) peer['persistent_keepalive_interval'] = ka;
    }
    if (q.containsKey('presharedkey')) {
      peer['pre_shared_key'] = q['presharedkey']!;
    }

    var label = parsed.fragment;
    if (label.isNotEmpty) label = Uri.decodeComponent(label);
    if (label.isEmpty) label = parsed.host;
    label = _sanitizeForDisplay(label);

    final tag = _tagFromLabel(label, 'wireguard', parsed.host, port);

    final endpoint = <String, dynamic>{
      'type': 'wireguard',
      'tag': tag,
      'mtu': mtu,
      'address': addressList,
      'private_key': privateKey,
      'peers': [peer],
    };

    final node = ParsedNode(
      tag: tag,
      scheme: 'wireguard',
      server: parsed.host,
      port: port,
      label: label,
      comment: tag,
      query: q.map((k, v) => MapEntry(k, v)),
      outbound: endpoint,
    );

    if (_shouldSkipNode(node, skipFilters)) return null;
    return node;
  }

  // ---------------------------------------------------------------------------
  // Outbound builder
  // ---------------------------------------------------------------------------

  static Map<String, dynamic> _buildOutbound(ParsedNode node) {
    final out = <String, dynamic>{
      'tag': node.tag,
      'server': node.server,
      'server_port': node.port,
    };

    if (node.scheme == 'ss') {
      out['type'] = 'shadowsocks';
    } else if (node.scheme == 'socks' || node.scheme == 'socks5') {
      out['type'] = 'socks';
      out['version'] = '5';
    } else {
      out['type'] = node.scheme;
    }

    switch (node.scheme) {
      case 'vless':
        _buildVLESS(node, out);
      case 'vmess':
        _buildVMess(node, out);
      case 'trojan':
        _buildTrojan(node, out);
      case 'ss':
        if (node.query['method']?.isNotEmpty ?? false) out['method'] = node.query['method'];
        if (node.query['password']?.isNotEmpty ?? false) out['password'] = node.query['password'];
      case 'hysteria2':
        _buildHysteria2(node, out);
      case 'ssh':
        _buildSSH(node, out);
      case 'socks' || 'socks5':
        if (node.uuid.isNotEmpty) out['username'] = node.uuid;
        if (node.query['password']?.isNotEmpty ?? false) out['password'] = node.query['password'];
    }

    return out;
  }

  // ---------------------------------------------------------------------------
  // VLESS
  // ---------------------------------------------------------------------------

  static void _buildVLESS(ParsedNode node, Map<String, dynamic> out) {
    out['uuid'] = node.uuid;

    final transport = _transportFromQuery(node.query);
    final hasTransport = transport != null;
    if (hasTransport) out['transport'] = transport;

    final flow = node.flow.isNotEmpty ? node.flow : (node.query['flow'] ?? '');
    if (flow.isNotEmpty) {
      if (flow == 'xtls-rprx-vision-udp443') {
        out['flow'] = 'xtls-rprx-vision';
        out['packet_encoding'] = 'xudp';
        out['server_port'] = 443;
      } else {
        out['flow'] = flow;
      }
    } else if ((node.query['pbk'] ?? '').trim().isNotEmpty && !hasTransport) {
      out['flow'] = 'xtls-rprx-vision';
    }

    if (node.query.containsKey('packetEncoding')) {
      out['packet_encoding'] = node.query['packetEncoding'];
    }

    final tls = _vlessTLS(node);
    if (tls != null) out['tls'] = tls;
  }

  static Map<String, dynamic>? _vlessTLS(ParsedNode node) {
    final q = node.query;
    final sec = (q['security'] ?? '').toLowerCase().trim();
    final pbk = (q['pbk'] ?? '').trim();

    if (sec == 'none') return null;

    var sni = q['sni'] ?? q['peer'] ?? '';
    if (sni.isEmpty) sni = node.server;
    var fp = (q['fp'] ?? q['fingerprint'] ?? '').toLowerCase().trim();
    if (fp.isEmpty) fp = 'random';

    if (pbk.isNotEmpty) {
      final tls = <String, dynamic>{
        'enabled': true,
        'server_name': sni,
        'utls': {'enabled': true, 'fingerprint': fp},
        'reality': {
          'enabled': true,
          'public_key': pbk,
          'short_id': _normalizeRealityShortID(q['sid'] ?? ''),
        },
      };
      _applyTLSExtras(q, tls);
      return tls;
    }

    if (sec == 'reality') {
      final tls = <String, dynamic>{
        'enabled': true,
        'server_name': sni,
        'utls': {'enabled': true, 'fingerprint': fp},
      };
      _applyTLSExtras(q, tls);
      return tls;
    }

    if (sec.isEmpty && _isPlaintextVLESSPort(node.port)) return null;

    final tls = <String, dynamic>{
      'enabled': true,
      'server_name': sni,
      'utls': {'enabled': true, 'fingerprint': fp},
    };
    _applyTLSExtras(q, tls);
    return tls;
  }

  // ---------------------------------------------------------------------------
  // VMess outbound
  // ---------------------------------------------------------------------------

  static void _buildVMess(ParsedNode node, Map<String, dynamic> out) {
    out['uuid'] = node.uuid;
    out['security'] = _normalizeVMessSecurity(node.query['security'] ?? '');

    if (node.query.containsKey('alter_id')) {
      final aid = int.tryParse(node.query['alter_id']!);
      if (aid != null) out['alter_id'] = aid;
    }

    var net = (node.query['network'] ?? 'tcp').toLowerCase().trim();
    if (net == 'xhttp') net = 'httpupgrade';

    switch (net) {
      case 'httpupgrade':
        final tr = <String, dynamic>{'type': 'httpupgrade'};
        if (node.query['path']?.isNotEmpty ?? false) tr['path'] = node.query['path'];
        final host = node.query['host'] ?? node.query['sni'] ?? '';
        if (host.isNotEmpty) tr['host'] = host;
        out['transport'] = tr;
      case 'h2':
        final tr = <String, dynamic>{'type': 'http'};
        if (node.query['path']?.isNotEmpty ?? false) tr['path'] = node.query['path'];
        var host = node.query['host'] ?? node.query['sni'] ?? '';
        if (host.isEmpty) host = node.server;
        if (host.isNotEmpty) tr['host'] = [host];
        out['transport'] = tr;
      case 'ws':
        final tr = <String, dynamic>{'type': 'ws'};
        if (node.query['path']?.isNotEmpty ?? false) tr['path'] = node.query['path'];
        final host = node.query['host'] ?? node.query['sni'] ?? '';
        if (host.isNotEmpty) tr['headers'] = {'Host': host};
        out['transport'] = tr;
      case 'grpc':
        final tr = <String, dynamic>{'type': 'grpc'};
        if (node.query['path']?.isNotEmpty ?? false) tr['service_name'] = node.query['path'];
        out['transport'] = tr;
      case 'http':
        final tr = <String, dynamic>{'type': 'http'};
        if (node.query['path']?.isNotEmpty ?? false) tr['path'] = node.query['path'];
        final host = node.query['host'] ?? '';
        if (host.isNotEmpty) tr['host'] = [host];
        out['transport'] = tr;
    }

    if (node.query['tls_enabled'] == 'true') {
      final tls = <String, dynamic>{'enabled': true};
      var sni = node.query['sni'] ?? node.query['peer'] ?? '';
      if (sni.isEmpty) sni = node.server;
      tls['server_name'] = sni;

      if (node.query['alpn']?.isNotEmpty ?? false) {
        tls['alpn'] = node.query['alpn']!.split(',').map((e) => e.trim()).toList();
      }
      final fp = (node.query['fp'] ?? '').toLowerCase().trim();
      if (fp.isNotEmpty) {
        tls['utls'] = {'enabled': true, 'fingerprint': fp};
      }
      if (_isTLSInsecure(node.query)) tls['insecure'] = true;
      out['tls'] = tls;
    }
  }

  // ---------------------------------------------------------------------------
  // Trojan
  // ---------------------------------------------------------------------------

  static void _buildTrojan(ParsedNode node, Map<String, dynamic> out) {
    out['password'] = node.uuid;

    final transport = _transportFromQuery(node.query);
    if (transport != null) out['transport'] = transport;

    final sec = (node.query['security'] ?? '').toLowerCase().trim();
    if (sec == 'none') {
      out['tls'] = {'enabled': false};
      return;
    }

    var sni = node.query['sni'] ?? node.query['peer'] ?? node.query['host'] ?? '';
    if (sni.isEmpty) sni = node.server;

    final tls = <String, dynamic>{'enabled': true, 'server_name': sni};
    final fp = (node.query['fp'] ?? '').toLowerCase().trim();
    if (fp.isNotEmpty) {
      tls['utls'] = {'enabled': true, 'fingerprint': fp};
    }
    _applyTLSExtras(node.query, tls);
    out['tls'] = tls;
  }

  // ---------------------------------------------------------------------------
  // Hysteria2
  // ---------------------------------------------------------------------------

  static void _buildHysteria2(ParsedNode node, Map<String, dynamic> out) {
    if (node.uuid.isNotEmpty) out['password'] = node.uuid;

    final mport = (node.query['mport'] ?? node.query['ports'] ?? '').trim();
    if (mport.isNotEmpty) {
      final sp = _hysteria2MportToServerPorts(mport);
      if (sp.isNotEmpty) out['server_ports'] = sp;
    }

    final obfs = node.query['obfs'] ?? '';
    if (obfs == 'salamander') {
      final obfsCfg = <String, dynamic>{'type': obfs};
      if (node.query['obfs-password']?.isNotEmpty ?? false) {
        obfsCfg['password'] = node.query['obfs-password'];
      }
      out['obfs'] = obfsCfg;
    }

    // TLS (required)
    final q = node.query;
    var sni = q['sni'] ?? '';
    final tls = <String, dynamic>{'enabled': true};
    if (sni.isNotEmpty && sni != '🔒' && (sni.contains('.') || sni.contains(':'))) {
      tls['server_name'] = sni;
    } else if (node.server.isNotEmpty) {
      tls['server_name'] = node.server;
    }
    if (_isTLSInsecure(q) ||
        q['skip-cert-verify'] == 'true' ||
        q['skip-cert-verify'] == '1') {
      tls['insecure'] = true;
    }
    final fp = (q['fp'] ?? q['fingerprint'] ?? '').toLowerCase().trim();
    if (fp.isNotEmpty) {
      tls['utls'] = {'enabled': true, 'fingerprint': fp};
    }
    if (q['alpn']?.isNotEmpty ?? false) {
      tls['alpn'] = q['alpn']!.split(',').map((e) => e.trim()).toList();
    }
    out['tls'] = tls;
  }

  // ---------------------------------------------------------------------------
  // SSH
  // ---------------------------------------------------------------------------

  static void _buildSSH(ParsedNode node, Map<String, dynamic> out) {
    out['user'] = node.uuid.isNotEmpty ? node.uuid : 'root';
    if (node.query['password']?.isNotEmpty ?? false) {
      out['password'] = node.query['password'];
    }
    if (node.query['private_key']?.isNotEmpty ?? false) {
      out['private_key'] = Uri.decodeComponent(node.query['private_key']!);
    } else if (node.query['private_key_path']?.isNotEmpty ?? false) {
      out['private_key_path'] = Uri.decodeComponent(node.query['private_key_path']!);
    }
    if (node.query['private_key_passphrase']?.isNotEmpty ?? false) {
      out['private_key_passphrase'] = Uri.decodeComponent(node.query['private_key_passphrase']!);
    }
    if (node.query['host_key']?.isNotEmpty ?? false) {
      out['host_key'] = node.query['host_key']!
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
  }

  // ---------------------------------------------------------------------------
  // Transport (VLESS/Trojan)
  // ---------------------------------------------------------------------------

  static Map<String, dynamic>? _transportFromQuery(Map<String, String> q) {
    final typ = (q['type'] ?? '').toLowerCase().trim();
    final headerType = (q['headerType'] ?? '').toLowerCase().trim();

    if ((typ == 'raw' || typ == 'tcp') && headerType == 'http') {
      final t = <String, dynamic>{'type': 'http'};
      if (q['path']?.isNotEmpty ?? false) t['path'] = q['path'];
      final host = q['host'] ?? '';
      if (host.isNotEmpty) t['host'] = [host];
      return t;
    }

    switch (typ) {
      case 'ws':
        final t = <String, dynamic>{'type': 'ws'};
        if (q['path']?.isNotEmpty ?? false) t['path'] = q['path'];
        var host = (q['host'] ?? '').trim();
        if (host.isEmpty) host = (q['sni'] ?? '').trim();
        if (host.isEmpty) host = (q['obfsParam'] ?? '').trim();
        if (host.isNotEmpty) t['headers'] = {'Host': host};
        return t;
      case 'grpc':
        final t = <String, dynamic>{'type': 'grpc'};
        final sn = (q['serviceName'] ?? q['service_name'] ?? q['path'] ?? '').trim();
        if (sn.isNotEmpty) t['service_name'] = sn;
        return t;
      case 'http':
        final t = <String, dynamic>{'type': 'http'};
        if (q['path']?.isNotEmpty ?? false) t['path'] = q['path'];
        final host = q['host'] ?? '';
        if (host.isNotEmpty) t['host'] = [host];
        return t;
      case 'xhttp' || 'httpupgrade':
        final t = <String, dynamic>{'type': 'httpupgrade'};
        if (q['path']?.isNotEmpty ?? false) t['path'] = q['path'];
        final host = q['host'] ?? '';
        if (host.isNotEmpty) t['host'] = host;
        return t;
      case 'raw' || 'tcp' || '':
        return null;
      default:
        return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static String _normalizeVMessSecurity(String raw) {
    final s = raw.toLowerCase().trim();
    if (s.isEmpty || s == 'null' || s == 'undefined') return 'auto';
    switch (s) {
      case 'auto':
      case 'none':
      case 'zero':
      case 'aes-128-gcm':
      case 'chacha20-poly1305':
      case 'aes-128-ctr':
        return s;
      case 'chacha20-ietf-poly1305':
        return 'chacha20-poly1305';
      default:
        return 'auto';
    }
  }

  static bool _isValidShadowsocksMethod(String method) {
    const valid = {
      '2022-blake3-aes-128-gcm',
      '2022-blake3-aes-256-gcm',
      '2022-blake3-chacha20-poly1305',
      'none',
      'aes-128-gcm',
      'aes-192-gcm',
      'aes-256-gcm',
      'chacha20-ietf-poly1305',
      'xchacha20-ietf-poly1305',
    };
    return valid.contains(method);
  }

  static bool _isTLSInsecure(Map<String, String> q) {
    for (final key in ['insecure', 'allowInsecure', 'allowinsecure']) {
      final v = (q[key] ?? '').toLowerCase().trim();
      if (v == '1' || v == 'true' || v == 'yes') return true;
    }
    return false;
  }

  static void _applyTLSExtras(Map<String, String> q, Map<String, dynamic> tls) {
    if (q['alpn']?.isNotEmpty ?? false) {
      tls['alpn'] = q['alpn']!.split(',').map((e) => e.trim()).toList();
    }
    if (_isTLSInsecure(q)) tls['insecure'] = true;
  }

  static String _normalizeRealityShortID(String s) {
    final buf = StringBuffer();
    for (final r in s.trim().runes) {
      if (r >= 0x30 && r <= 0x39) {
        buf.writeCharCode(r); // 0-9
      } else if (r >= 0x61 && r <= 0x66) {
        buf.writeCharCode(r); // a-f
      } else if (r >= 0x41 && r <= 0x46) {
        buf.writeCharCode(r + 32); // A-F → a-f
      }
    }
    final out = buf.toString();
    return out.length > 16 ? out.substring(0, 16) : out;
  }

  static const _plaintextVLESSPorts = {80, 8080, 8880, 2052, 2082, 2086, 2095};

  static bool _isPlaintextVLESSPort(int port) => _plaintextVLESSPorts.contains(port);

  static List<String> _hysteria2MportToServerPorts(String spec) {
    final out = <String>[];
    for (var part in spec.split(',')) {
      part = part.trim();
      if (part.isEmpty) continue;
      var pr = part.replaceAll('-', ':');
      if (!pr.contains(':')) pr = '$pr:$pr';
      out.add(pr);
    }
    return out;
  }

  static String _sanitizeForDisplay(String s) {
    if (s.isEmpty) return s;
    final buf = StringBuffer();
    for (final r in s.runes) {
      if (r == 9 || r == 10 || r == 13) {
        buf.writeCharCode(r);
        continue;
      }
      if (r <= 0x1F || r == 0x7F) continue;
      buf.writeCharCode(r);
    }
    return buf.toString();
  }

  static void _extractTagFromLabel(ParsedNode node) {
    if (node.label.isNotEmpty) {
      node.tag = node.label.trim();
      final pipeIdx = node.label.indexOf('|');
      node.comment = pipeIdx >= 0
          ? node.label.substring(pipeIdx + 1).trim()
          : node.tag;
      node.tag = node.tag.replaceAll('🇪🇳', '🇬🇧');
    } else {
      node.tag = '${node.scheme}-${node.server}-${node.port}';
      node.comment = node.tag;
    }
  }

  static String _tagFromLabel(String label, String scheme, String server, int port) {
    if (label.isNotEmpty) {
      return label.trim().replaceAll('🇪🇳', '🇬🇧');
    }
    return '$scheme-$server-$port';
  }

  static bool _shouldSkipNode(
    ParsedNode node,
    List<Map<String, String>> skipFilters,
  ) {
    for (final filter in skipFilters) {
      var allMatch = true;
      for (final entry in filter.entries) {
        final value = _getNodeValue(node, entry.key);
        if (!_matchesPattern(value, entry.value)) {
          allMatch = false;
          break;
        }
      }
      if (allMatch) return true;
    }
    return false;
  }

  static String _getNodeValue(ParsedNode node, String key) {
    switch (key) {
      case 'tag':
        return node.tag;
      case 'host':
        return node.server;
      case 'label':
        return node.label;
      case 'scheme':
        return node.scheme;
      case 'fragment':
        return node.label;
      case 'comment':
        return node.comment;
      case 'flow':
        return node.flow;
      default:
        return '';
    }
  }

  static bool _matchesPattern(String value, String pattern) {
    // Negation regex: !/regex/i
    if (pattern.startsWith('!/') && pattern.endsWith('/i')) {
      final regex = pattern.substring(2, pattern.length - 2);
      return !RegExp(regex, caseSensitive: false).hasMatch(value);
    }
    // Negation literal: !literal
    if (pattern.startsWith('!') && !pattern.startsWith('!/')) {
      return value != pattern.substring(1);
    }
    // Regex: /regex/i
    if (pattern.startsWith('/') && pattern.endsWith('/i')) {
      final regex = pattern.substring(1, pattern.length - 2);
      return RegExp(regex, caseSensitive: false).hasMatch(value);
    }
    // Literal match
    return value == pattern;
  }

  static List<int>? _decodeBase64(String s) {
    var input = s.replaceAll(RegExp(r'\s+'), '');
    // Try URL-safe without padding
    for (final codec in [base64Url, base64]) {
      for (final pad in [true, false]) {
        try {
          var attempt = input;
          if (pad) {
            final rem = attempt.length % 4;
            if (rem == 2) attempt += '==';
            if (rem == 3) attempt += '=';
          }
          return codec.decode(attempt);
        } catch (_) {}
      }
    }
    return null;
  }
}

class _SSPreprocess {
  _SSPreprocess(this.uri, this.method, this.password);
  final String uri;
  final String method;
  final String password;
}
