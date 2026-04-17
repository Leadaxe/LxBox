import 'dart:convert';

import '../models/parsed_node.dart';

/// Port of singbox-launcher `xray_json_array.go` + `xray_outbound_convert.go`.
/// Parses JSON array of Xray/v2ray full configs into sing-box-compatible ParsedNode list.
class XrayJsonParser {
  XrayJsonParser._();

  static const _tagBaseMaxRunes = 48;
  static const detourPrefix = '⚙ ';

  /// Returns true if [text] is a JSON array where elements have Xray-style
  /// `outbounds` with `protocol` field (not sing-box `type`).
  static bool isXrayJsonArray(String text) {
    final trimmed = text.trim();
    if (!trimmed.startsWith('[')) return false;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! List || decoded.isEmpty) return false;
      final first = decoded[0];
      if (first is! Map<String, dynamic>) return false;
      final outbounds = first['outbounds'];
      if (outbounds is! List || outbounds.isEmpty) return false;
      return outbounds.any(
        (ob) => ob is Map<String, dynamic> && ob.containsKey('protocol'),
      );
    } catch (_) {
      return false;
    }
  }

  /// Parses every element in the Xray JSON array into a [ParsedNode].
  /// Non-Xray elements and parse errors are skipped silently.
  static List<ParsedNode> parse(String jsonBody) {
    final decoded = jsonDecode(jsonBody.trim());
    if (decoded is! List) return [];

    final result = <ParsedNode>[];
    for (var i = 0; i < decoded.length; i++) {
      final elem = decoded[i];
      if (elem is! Map<String, dynamic>) continue;
      try {
        final node = _parseElement(elem, i);
        if (node != null) result.add(node);
      } catch (_) {
        continue;
      }
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // Element parsing
  // ---------------------------------------------------------------------------

  static ParsedNode? _parseElement(Map<String, dynamic> root, int index) {
    if (!_hasProtocolOutbounds(root)) return null;

    final outboundsRaw = root['outbounds'];
    if (outboundsRaw is! List || outboundsRaw.isEmpty) return null;

    final byTag = <String, Map<String, dynamic>>{};
    final vlessCands = <_VlessCandidate>[];

    for (final obRaw in outboundsRaw) {
      if (obRaw is! Map<String, dynamic>) continue;
      final tag = _str(obRaw, 'tag');
      if (tag.isNotEmpty) byTag[tag] = obRaw;

      final protocol = _str(obRaw, 'protocol').toLowerCase();
      if (protocol != 'vless') continue;

      final settings = obRaw['settings'];
      if (settings is! Map<String, dynamic>) continue;
      final vnext = settings['vnext'];
      if (vnext is! List || vnext.isEmpty) continue;

      final streamSettings = obRaw['streamSettings'];
      final dialer = _sockoptDialerRef(
        streamSettings is Map<String, dynamic> ? streamSettings : null,
      );
      vlessCands.add(_VlessCandidate(ob: obRaw, dialer: dialer, tag: tag));
    }

    if (vlessCands.isEmpty) return null;

    final mainCand = _pickMainVless(vlessCands);
    final mainOb = mainCand.ob;

    var label = _str(root, 'remarks').trim();
    if (label.isEmpty) label = _str(mainOb, 'tag');
    if (label.isEmpty) label = 'xray-$index';

    final node = _buildVlessFromOutbound(mainOb, label);
    if (node == null) return null;

    final base = _tagBaseFromRemarks(label, index);
    final mainTag = base;

    node.tag = mainTag;
    if (node.outbound.isNotEmpty) {
      node.outbound['tag'] = mainTag;
    }

    final streamSettings = mainOb['streamSettings'];
    final dialerRef = _sockoptDialerRef(
      streamSettings is Map<String, dynamic> ? streamSettings : null,
    );
    if (dialerRef.isNotEmpty) {
      final detourOb = byTag[dialerRef];
      if (detourOb == null) return null;
      // Build jump tag from original Xray tag or protocol+host
      final detourName = _detourTagName(detourOb, dialerRef);
      final detourTag = '$detourPrefix$detourName';
      final detour = _buildDetourFromOutbound(detourOb, detourTag, label);
      if (detour == null) return null;
      node.detourServer = detour;
    }

    return node;
  }

  static bool _hasProtocolOutbounds(Map<String, dynamic> root) {
    final outbounds = root['outbounds'];
    if (outbounds is! List) return false;
    return outbounds.any(
      (ob) => ob is Map<String, dynamic> && ob['protocol'] is String,
    );
  }

  static _VlessCandidate _pickMainVless(List<_VlessCandidate> cands) {
    final withDial = <int>[];
    for (var i = 0; i < cands.length; i++) {
      if (cands[i].dialer.isNotEmpty) withDial.add(i);
    }

    if (withDial.length == 1) return cands[withDial[0]];
    if (withDial.length > 1) {
      for (final i in withDial) {
        if (cands[i].tag == 'proxy') return cands[i];
      }
      return cands[withDial[0]];
    }

    if (cands.length == 1) return cands[0];
    for (final c in cands) {
      if (c.tag == 'proxy') return c;
    }
    return cands[0];
  }

  // ---------------------------------------------------------------------------
  // VLESS outbound → sing-box
  // ---------------------------------------------------------------------------

  static ParsedNode? _buildVlessFromOutbound(
    Map<String, dynamic> ob,
    String label,
  ) {
    final settings = ob['settings'];
    if (settings is! Map<String, dynamic>) return null;
    final vnext = settings['vnext'];
    if (vnext is! List || vnext.isEmpty) return null;
    final vn0 = vnext[0];
    if (vn0 is! Map<String, dynamic>) return null;

    final addr = _str(vn0, 'address');
    if (addr.isEmpty) return null;
    final port = _int(vn0['port']);
    if (port <= 0 || port > 65535) return null;

    final users = vn0['users'];
    if (users is! List || users.isEmpty) return null;
    final u0 = users[0];
    if (u0 is! Map<String, dynamic>) return null;
    final uuid = _str(u0, 'id');
    if (uuid.isEmpty) return null;
    var flow = _str(u0, 'flow');

    final streamSettings = ob['streamSettings'];
    final ss = streamSettings is Map<String, dynamic> ? streamSettings : null;
    final network = (ss != null ? _str(ss, 'network') : '').toLowerCase();
    final security = (ss != null ? _str(ss, 'security') : '').toLowerCase();

    final outbound = <String, dynamic>{
      'tag': _str(ob, 'tag'),
      'type': 'vless',
      'server': addr,
      'server_port': port,
      'uuid': uuid,
    };

    if (flow.isNotEmpty) {
      if (flow == 'xtls-rprx-vision-udp443') {
        outbound['flow'] = 'xtls-rprx-vision';
        outbound['packet_encoding'] = 'xudp';
        outbound['server_port'] = 443;
      } else {
        outbound['flow'] = flow;
      }
    }

    final tls = _vlessTls(ss, security);
    if (tls != null) outbound['tls'] = tls;

    final transport = _transportFromStreamSettings(ss, network);
    if (transport != null) outbound['transport'] = transport;

    if (flow.isEmpty && (network.isEmpty || network == 'tcp')) {
      if (tls != null) {
        final reality = tls['reality'];
        if (reality is Map<String, dynamic>) {
          final enabled = reality['enabled'];
          final pk = (reality['public_key'] ?? '').toString().trim();
          if (enabled == true && pk.isNotEmpty) {
            flow = 'xtls-rprx-vision';
            outbound['flow'] = flow;
          }
        }
      }
    }

    return ParsedNode(
      tag: _str(ob, 'tag'),
      scheme: 'vless',
      server: addr,
      port: port,
      uuid: uuid,
      flow: flow,
      label: label,
      comment: label,
      outbound: outbound,
    );
  }

  static Map<String, dynamic>? _vlessTls(
    Map<String, dynamic>? streamSettings,
    String security,
  ) {
    if (streamSettings == null) return null;
    if (security != 'reality' && security != 'tls') return null;

    final tls = <String, dynamic>{'enabled': true};

    if (security == 'reality') {
      final rs = streamSettings['realitySettings'];
      if (rs is! Map<String, dynamic>) return tls;

      var sni = _str(rs, 'serverName');
      if (sni.isEmpty) sni = _str(rs, 'server_name');
      if (sni.isNotEmpty) tls['server_name'] = sni;

      var fp = _str(rs, 'fingerprint').toLowerCase().trim();
      if (fp.isEmpty) fp = 'random';
      tls['utls'] = {'enabled': true, 'fingerprint': fp};

      final insecure = rs['allowInsecure'];
      if (insecure == true) tls['insecure'] = true;

      var pbk = _str(rs, 'publicKey');
      if (pbk.isEmpty) pbk = _str(rs, 'public_key');
      var sid = _str(rs, 'shortId');
      if (sid.isEmpty) sid = _str(rs, 'short_id');

      tls['reality'] = {
        'enabled': true,
        'public_key': pbk,
        'short_id': sid,
      };
      return tls;
    }

    // generic TLS
    final tlsSettings = streamSettings['tlsSettings'];
    if (tlsSettings is Map<String, dynamic>) {
      final sni = _str(tlsSettings, 'serverName');
      if (sni.isNotEmpty) tls['server_name'] = sni;
      final fp = _str(tlsSettings, 'fingerprint').toLowerCase().trim();
      if (fp.isNotEmpty) {
        tls['utls'] = {'enabled': true, 'fingerprint': fp};
      }
      final insecure = tlsSettings['allowInsecure'];
      if (insecure == true) tls['insecure'] = true;
    }
    return tls;
  }

  static Map<String, dynamic>? _transportFromStreamSettings(
    Map<String, dynamic>? ss,
    String network,
  ) {
    if (ss == null || network.isEmpty || network == 'tcp') return null;

    switch (network) {
      case 'ws':
        final ws = ss['wsSettings'];
        final tr = <String, dynamic>{'type': 'ws'};
        if (ws is Map<String, dynamic>) {
          final p = _str(ws, 'path');
          if (p.isNotEmpty) tr['path'] = p;
          final h = _str(ws, 'host');
          if (h.isNotEmpty) tr['headers'] = {'Host': h};
        }
        return tr;
      case 'grpc':
        final gs = ss['grpcSettings'];
        final tr = <String, dynamic>{'type': 'grpc'};
        if (gs is Map<String, dynamic>) {
          final sn = _str(gs, 'serviceName');
          if (sn.isNotEmpty) tr['service_name'] = sn;
        }
        return tr;
      case 'http' || 'h2':
        final hs = ss['httpSettings'];
        final tr = <String, dynamic>{'type': 'http'};
        if (hs is Map<String, dynamic>) {
          final p = _str(hs, 'path');
          if (p.isNotEmpty) tr['path'] = p;
          final host = _str(hs, 'host');
          if (host.isNotEmpty) tr['host'] = [host];
        }
        return tr;
      default:
        return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Jump outbound (SOCKS / VLESS)
  // ---------------------------------------------------------------------------

  /// Builds a human-readable name for a jump server from its Xray outbound.
  static String _detourTagName(Map<String, dynamic> ob, String originalTag) {
    // Try original Xray tag first
    final tag = _str(ob, 'tag').trim();
    if (tag.isNotEmpty && tag != originalTag) return tag;

    // Fallback: protocol + host:port
    final protocol = _str(ob, 'protocol').toLowerCase();
    final settings = ob['settings'];
    if (settings is Map<String, dynamic>) {
      final servers = settings['servers'];
      if (servers is List && servers.isNotEmpty) {
        final s0 = servers[0];
        if (s0 is Map<String, dynamic>) {
          final host = _str(s0, 'address');
          final port = _int(s0['port']);
          if (host.isNotEmpty) return '$protocol $host:$port';
        }
      }
    }
    return '$protocol $originalTag';
  }

  static ParsedDetour? _buildDetourFromOutbound(
    Map<String, dynamic> detourOb,
    String detourTag,
    String label,
  ) {
    final protocol = _str(detourOb, 'protocol').toLowerCase();
    switch (protocol) {
      case 'socks':
        return _buildSocksDetour(detourOb, detourTag);
      case 'vless':
        return _buildVlessDetour(detourOb, detourTag, label);
      default:
        return null;
    }
  }

  static ParsedDetour? _buildSocksDetour(
    Map<String, dynamic> ob,
    String detourTag,
  ) {
    final settings = ob['settings'];
    if (settings is! Map<String, dynamic>) return null;
    final servers = settings['servers'];
    if (servers is! List || servers.isEmpty) return null;
    final s0 = servers[0];
    if (s0 is! Map<String, dynamic>) return null;

    final addr = _str(s0, 'address');
    final port = _int(s0['port']);
    if (addr.isEmpty || port <= 0 || port > 65535) return null;

    final outbound = <String, dynamic>{
      'type': 'socks',
      'tag': detourTag,
      'server': addr,
      'server_port': port,
      'version': '5',
    };

    final users = s0['users'];
    if (users is List && users.isNotEmpty) {
      final u0 = users[0];
      if (u0 is Map<String, dynamic>) {
        final user = _str(u0, 'user');
        final pass = _str(u0, 'pass');
        if (user.isNotEmpty) outbound['username'] = user;
        if (pass.isNotEmpty) outbound['password'] = pass;
      }
    }

    return ParsedDetour(
      tag: detourTag,
      scheme: 'socks',
      server: addr,
      port: port,
      outbound: outbound,
    );
  }

  static ParsedDetour? _buildVlessDetour(
    Map<String, dynamic> ob,
    String detourTag,
    String label,
  ) {
    final node = _buildVlessFromOutbound(ob, label);
    if (node == null || node.outbound.isEmpty) return null;
    final outbound = Map<String, dynamic>.from(node.outbound);
    outbound['tag'] = detourTag;
    return ParsedDetour(
      tag: detourTag,
      scheme: 'vless',
      server: node.server,
      port: node.port,
      uuid: node.uuid,
      flow: node.flow,
      outbound: outbound,
    );
  }

  // ---------------------------------------------------------------------------
  // Tag generation
  // ---------------------------------------------------------------------------

  static String _tagBaseFromRemarks(String remarks, int index) {
    final s = remarks.trim();
    if (s.isEmpty) return 'xray-$index';

    final buf = StringBuffer();
    var lastSep = false;
    for (final r in s.runes) {
      if (_isTagSlugKeepRune(r)) {
        buf.writeCharCode(r);
        lastSep = false;
        continue;
      }
      if (r == 0x5F || r == 0x2D) {
        // _ or -
        if (buf.length > 0 && !lastSep) {
          buf.write('-');
          lastSep = true;
        }
        continue;
      }
      if (buf.length > 0 && !lastSep) {
        buf.write('-');
        lastSep = true;
      }
    }

    var out = buf.toString();
    while (out.startsWith('-')) {
      out = out.substring(1);
    }
    while (out.endsWith('-')) {
      out = out.substring(0, out.length - 1);
    }

    if (out.isEmpty) return 'xray-$index';
    if (out.runes.length > _tagBaseMaxRunes) {
      out = String.fromCharCodes(out.runes.take(_tagBaseMaxRunes));
      while (out.endsWith('-')) {
        out = out.substring(0, out.length - 1);
      }
    }
    return out.isEmpty ? 'xray-$index' : out;
  }

  /// Letters, digits, and Regional Indicator symbols (flag emoji pairs).
  static bool _isTagSlugKeepRune(int r) {
    if (_isLetterOrDigit(r)) return true;
    return r >= 0x1F1E6 && r <= 0x1F1FF;
  }

  static bool _isLetterOrDigit(int r) {
    if (r >= 0x30 && r <= 0x39) return true; // 0-9
    if (r >= 0x41 && r <= 0x5A) return true; // A-Z
    if (r >= 0x61 && r <= 0x7A) return true; // a-z
    // Cyrillic
    if (r >= 0x0400 && r <= 0x04FF) return true;
    // CJK, Arabic, etc. — broad unicode letter check
    if (r > 0x7F) {
      final s = String.fromCharCode(r);
      return RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(s);
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static String _str(Map<String, dynamic> m, String key) {
    final v = m[key];
    if (v == null) return '';
    return v.toString().trim();
  }

  static int _int(dynamic v) {
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  static String _sockoptDialerRef(Map<String, dynamic>? streamSettings) {
    if (streamSettings == null) return '';
    final sockopt = streamSettings['sockopt'];
    if (sockopt is! Map<String, dynamic>) return '';
    final dp = _str(sockopt, 'dialerProxy');
    if (dp.isNotEmpty) return dp;
    return _str(sockopt, 'dialer');
  }
}

class _VlessCandidate {
  _VlessCandidate({
    required this.ob,
    required this.dialer,
    required this.tag,
  });

  final Map<String, dynamic> ob;
  final String dialer;
  final String tag;
}
