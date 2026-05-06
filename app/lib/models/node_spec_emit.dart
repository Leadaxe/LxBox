import 'dart:convert';

import '../services/parser/transport.dart';
import '../services/parser/uri_utils.dart';
import 'node_spec.dart';
import 'singbox_entry.dart';
import 'template_vars.dart';
import 'transport_spec.dart';

/// Реализация `emit()` и `toUri()` для каждого варианта NodeSpec.
///
/// Файл отдельно, чтобы node_spec.dart оставался чистой data-моделью. Вызов
/// из node_spec.dart делегирует сюда через `ref.emitImpl(vars)`.
///
/// Контракт: выход должен совпадать с v1 `_buildOutbound` на том же узле
/// (гарантируется parity-тестами в `test/parity/`).

// ════════════════════════════════════════════════════════════════════════════
// VLESS
// ════════════════════════════════════════════════════════════════════════════

Outbound emitVless(VlessSpec s, TemplateVars vars) {
  final out = <String, dynamic>{
    'type': 'vless',
    'tag': s.tag,
    'server': s.server,
    'server_port': s.port,
    'uuid': s.uuid,
  };

  if (s.transport != null) {
    final (tmap, warnings) = s.transport!.toSingbox(vars);
    out['transport'] = tmap;
    for (final w in warnings) {
      if (!s.warnings.contains(w)) s.warnings.add(w);
    }
  }

  if (s.flow.isNotEmpty) out['flow'] = s.flow;
  if (s.packetEncoding.isNotEmpty) out['packet_encoding'] = s.packetEncoding;

  final tlsMap = s.tls.toSingbox();
  if (tlsMap.isNotEmpty) out['tls'] = tlsMap;

  if (s.chained != null) out['detour'] = s.chained!.tag;

  return Outbound(out);
}

String toUriVless(VlessSpec s) {
  final q = <String, String>{};
  if (s.flow.isNotEmpty) q['flow'] = s.flow;
  if (s.packetEncoding.isNotEmpty) q['packetEncoding'] = s.packetEncoding;

  if (s.transport != null) {
    q.addAll(transportToQuery(s.transport!));
  }

  if (s.tls.enabled) {
    if (s.tls.reality != null) {
      q['security'] = 'reality';
      q['pbk'] = s.tls.reality!.publicKey;
      if (s.tls.reality!.shortId.isNotEmpty) {
        q['sid'] = s.tls.reality!.shortId;
      }
    } else {
      q['security'] = 'tls';
    }
    if (s.tls.serverName != null && s.tls.serverName!.isNotEmpty) {
      q['sni'] = s.tls.serverName!;
    }
    if (s.tls.fingerprint != null && s.tls.fingerprint!.isNotEmpty) {
      q['fp'] = s.tls.fingerprint!;
    }
    if (s.tls.alpn.isNotEmpty) q['alpn'] = s.tls.alpn.join(',');
    if (s.tls.insecure) q['allowInsecure'] = '1';
  } else {
    q['security'] = 'none';
  }

  return _buildUri('vless', s.uuid, s.server, s.port, q, s.label);
}

// ════════════════════════════════════════════════════════════════════════════
// VMess
// ════════════════════════════════════════════════════════════════════════════

Outbound emitVmess(VmessSpec s, TemplateVars vars) {
  final out = <String, dynamic>{
    'type': 'vmess',
    'tag': s.tag,
    'server': s.server,
    'server_port': s.port,
    'uuid': s.uuid,
    'security': s.security,
  };
  if (s.alterId != 0) out['alter_id'] = s.alterId;

  if (s.transport != null) {
    final (tmap, warnings) = s.transport!.toSingbox(vars);
    out['transport'] = tmap;
    for (final w in warnings) {
      if (!s.warnings.contains(w)) s.warnings.add(w);
    }
  }

  final tlsMap = s.tls.toSingbox();
  if (tlsMap.isNotEmpty) out['tls'] = tlsMap;

  if (s.chained != null) out['detour'] = s.chained!.tag;
  return Outbound(out);
}

String toUriVmess(VmessSpec s) {
  // VMess v2rayN: base64(JSON).
  final json = <String, dynamic>{
    'v': '2',
    'ps': s.label,
    'add': s.server,
    'port': s.port.toString(),
    'id': s.uuid,
    'aid': s.alterId.toString(),
    'scy': s.security,
    'net': _vmessNetFromTransport(s.transport),
    'type': 'none',
    'host': _vmessHostFromTransport(s.transport),
    'path': _vmessPathFromTransport(s.transport),
    'tls': s.tls.enabled ? 'tls' : '',
    if (s.tls.serverName != null) 'sni': s.tls.serverName,
    if (s.tls.fingerprint != null) 'fp': s.tls.fingerprint,
    if (s.tls.alpn.isNotEmpty) 'alpn': s.tls.alpn.join(','),
  };
  final cleaned = Map<String, dynamic>.fromEntries(
      json.entries.where((e) => e.value != null));
  final bytes = utf8.encode(jsonEncode(cleaned));
  return 'vmess://${base64.encode(bytes).replaceAll('=', '')}';
}

String _vmessNetFromTransport(TransportSpec? t) {
  return switch (t) {
    null => 'tcp',
    WsTransport() => 'ws',
    GrpcTransport() => 'grpc',
    HttpTransport() => 'http',
    HttpUpgradeTransport() => 'httpupgrade',
    XhttpTransport() => 'xhttp',
  };
}

String _vmessHostFromTransport(TransportSpec? t) => switch (t) {
      WsTransport(host: final h) => h,
      HttpTransport(hosts: final hs) => hs.isEmpty ? '' : hs.first,
      HttpUpgradeTransport(host: final h) => h,
      XhttpTransport(host: final h) => h,
      _ => '',
    };

String _vmessPathFromTransport(TransportSpec? t) => switch (t) {
      WsTransport(path: final p) => p,
      HttpTransport(path: final p) => p,
      HttpUpgradeTransport(path: final p) => p,
      XhttpTransport(path: final p) => p,
      GrpcTransport(serviceName: final sn) => sn,
      _ => '',
    };

// ════════════════════════════════════════════════════════════════════════════
// Trojan
// ════════════════════════════════════════════════════════════════════════════

Outbound emitTrojan(TrojanSpec s, TemplateVars vars) {
  final out = <String, dynamic>{
    'type': 'trojan',
    'tag': s.tag,
    'server': s.server,
    'server_port': s.port,
    'password': s.password,
  };
  if (s.transport != null) {
    final (tmap, warnings) = s.transport!.toSingbox(vars);
    out['transport'] = tmap;
    for (final w in warnings) {
      if (!s.warnings.contains(w)) s.warnings.add(w);
    }
  }
  if (s.tls.enabled) {
    out['tls'] = s.tls.toSingbox();
  } else {
    out['tls'] = {'enabled': false};
  }
  if (s.chained != null) out['detour'] = s.chained!.tag;
  return Outbound(out);
}

String toUriTrojan(TrojanSpec s) {
  final q = <String, String>{};
  if (s.transport != null) q.addAll(transportToQuery(s.transport!));
  if (s.tls.enabled) {
    q['security'] = 'tls';
    if (s.tls.serverName != null) q['sni'] = s.tls.serverName!;
    if (s.tls.fingerprint != null) q['fp'] = s.tls.fingerprint!;
    if (s.tls.alpn.isNotEmpty) q['alpn'] = s.tls.alpn.join(',');
    if (s.tls.insecure) q['allowInsecure'] = '1';
  } else {
    q['security'] = 'none';
  }
  return _buildUri('trojan', s.password, s.server, s.port, q, s.label);
}

// ════════════════════════════════════════════════════════════════════════════
// Shadowsocks
// ════════════════════════════════════════════════════════════════════════════

Outbound emitShadowsocks(ShadowsocksSpec s, TemplateVars vars) {
  final out = <String, dynamic>{
    'type': 'shadowsocks',
    'tag': s.tag,
    'server': s.server,
    'server_port': s.port,
    'method': s.method,
    'password': s.password,
  };
  if (s.plugin.isNotEmpty) {
    out['plugin'] = s.plugin;
    if (s.pluginOpts.isNotEmpty) out['plugin_opts'] = s.pluginOpts;
  }
  if (s.chained != null) out['detour'] = s.chained!.tag;
  return Outbound(out);
}

String toUriShadowsocks(ShadowsocksSpec s) {
  final userinfo = base64
      .encode(utf8.encode('${s.method}:${s.password}'))
      .replaceAll('=', '');
  final host = _wrapIpv6(s.server);
  final frag = encodeFragment(s.label);
  return 'ss://$userinfo@$host:${s.port}${frag.isEmpty ? '' : '#$frag'}';
}

// ════════════════════════════════════════════════════════════════════════════
// Hysteria2
// ════════════════════════════════════════════════════════════════════════════

Outbound emitHysteria2(Hysteria2Spec s, TemplateVars vars) {
  final out = <String, dynamic>{
    'type': 'hysteria2',
    'tag': s.tag,
    'server': s.server,
    'server_port': s.port,
  };
  if (s.password.isNotEmpty) out['password'] = s.password;
  if (s.obfs == 'salamander') {
    out['obfs'] = {
      'type': 'salamander',
      if (s.obfsPassword.isNotEmpty) 'password': s.obfsPassword,
    };
  }
  if (s.upMbps != null) out['up_mbps'] = s.upMbps;
  if (s.downMbps != null) out['down_mbps'] = s.downMbps;
  out['tls'] = s.tls.toSingbox();
  if (s.chained != null) out['detour'] = s.chained!.tag;
  return Outbound(out);
}

String toUriHysteria2(Hysteria2Spec s) {
  final q = <String, String>{};
  if (s.obfs.isNotEmpty) q['obfs'] = s.obfs;
  if (s.obfsPassword.isNotEmpty) q['obfs-password'] = s.obfsPassword;
  if (s.tls.serverName != null) q['sni'] = s.tls.serverName!;
  if (s.tls.insecure) q['insecure'] = '1';
  if (s.tls.alpn.isNotEmpty) q['alpn'] = s.tls.alpn.join(',');
  if (s.tls.fingerprint != null) q['fp'] = s.tls.fingerprint!;
  return _buildUri('hysteria2', s.password, s.server, s.port, q, s.label);
}

// ════════════════════════════════════════════════════════════════════════════
// NaïveProxy
// ════════════════════════════════════════════════════════════════════════════

/// Charset для имени HTTP-заголовка из DuckSoft de-facto спеки naive URI:
/// `! # $ % & ' * + - . 0-9 A-Z \ ^ _ ` a-z | ~`. Невалидные пары при
/// сериализации/десериализации silently дропаются с лог-варном.
final RegExp _naiveHeaderName =
    RegExp(r"^[!#$%&'*+\-.0-9A-Z\\^_`a-z|~]+$");

bool isValidNaiveHeaderName(String name) =>
    name.isNotEmpty && _naiveHeaderName.hasMatch(name);

Outbound emitNaive(NaiveSpec s, TemplateVars vars) {
  final out = <String, dynamic>{
    'type': 'naive',
    'tag': s.tag,
    'server': s.server,
    'server_port': s.port,
  };
  if (s.username.isNotEmpty) out['username'] = s.username;
  if (s.password.isNotEmpty) out['password'] = s.password;
  if (s.extraHeaders.isNotEmpty) {
    final keys = s.extraHeaders.keys.toList()..sort();
    final sorted = <String, String>{};
    for (final k in keys) {
      sorted[k] = s.extraHeaders[k]!;
    }
    out['extra_headers'] = sorted;
  }
  out['tls'] = s.tls.toSingbox();
  if (s.chained != null) out['detour'] = s.chained!.tag;
  return Outbound(out);
}

String toUriNaive(NaiveSpec s) {
  // userinfo: оба пусто → нет; только password → password@; оба → user:pass@.
  final hasUser = s.username.isNotEmpty;
  final hasPass = s.password.isNotEmpty;
  final ui = !hasUser && !hasPass
      ? ''
      : (!hasUser
          ? '${encodeParam(s.password)}@'
          : (!hasPass
              ? '${encodeParam(s.username)}@'
              : '${encodeParam(s.username)}:${encodeParam(s.password)}@'));

  final q = <String, String>{};
  if (s.extraHeaders.isNotEmpty) {
    q['extra-headers'] = serializeNaiveExtraHeaders(s.extraHeaders);
  }

  final host = _wrapIpv6(s.server);
  // port=443 опускаем — соответствует канонической форме DuckSoft.
  final portPart = s.port == 443 ? '' : ':${s.port}';
  final qs = buildQuery(q);
  final frag = encodeFragment(s.label);
  return 'naive+https://$ui$host$portPart'
      '${qs.isEmpty ? '' : '?$qs'}'
      '${frag.isEmpty ? '' : '#$frag'}';
}

/// `Header1: Value1\r\nHeader2: Value2` (отсортировано по ключу). Невалидные
/// имена дропаются с warning, чтобы encoder оставался robust.
String serializeNaiveExtraHeaders(Map<String, String> headers) {
  if (headers.isEmpty) return '';
  final keys = headers.keys.toList()..sort();
  final parts = <String>[];
  for (final k in keys) {
    if (!isValidNaiveHeaderName(k)) continue;
    parts.add('$k: ${headers[k]!}');
  }
  return parts.join('\r\n');
}

// ════════════════════════════════════════════════════════════════════════════
// TUIC v5
// ════════════════════════════════════════════════════════════════════════════

Outbound emitTuic(TuicSpec s, TemplateVars vars) {
  final out = <String, dynamic>{
    'type': 'tuic',
    'tag': s.tag,
    'server': s.server,
    'server_port': s.port,
    'uuid': s.uuid,
    'password': s.password,
    'congestion_control': s.congestionControl,
    'udp_relay_mode': s.udpRelayMode,
    if (s.zeroRtt) 'zero_rtt_handshake': true,
    'tls': s.tls.toSingbox(),
  };
  if (s.chained != null) out['detour'] = s.chained!.tag;
  return Outbound(out);
}

String toUriTuic(TuicSpec s) {
  final q = <String, String>{
    'congestion_control': s.congestionControl,
    'udp_relay_mode': s.udpRelayMode,
    if (s.tls.serverName != null) 'sni': s.tls.serverName!,
    if (s.tls.alpn.isNotEmpty) 'alpn': s.tls.alpn.join(','),
    if (s.zeroRtt) 'reduce_rtt': '1',
    if (s.tls.insecure) 'allow_insecure': '1',
  };
  final userinfo = '${encodeParam(s.uuid)}:${encodeParam(s.password)}';
  final host = _wrapIpv6(s.server);
  final qs = buildQuery(q);
  final frag = encodeFragment(s.label);
  return 'tuic://$userinfo@$host:${s.port}${qs.isEmpty ? '' : '?$qs'}${frag.isEmpty ? '' : '#$frag'}';
}

// ════════════════════════════════════════════════════════════════════════════
// SSH
// ════════════════════════════════════════════════════════════════════════════

Outbound emitSsh(SshSpec s, TemplateVars vars) {
  final out = <String, dynamic>{
    'type': 'ssh',
    'tag': s.tag,
    'server': s.server,
    'server_port': s.port,
    'user': s.user,
  };
  if (s.password.isNotEmpty) out['password'] = s.password;
  if (s.privateKey.isNotEmpty) out['private_key'] = s.privateKey;
  if (s.privateKeyPassphrase.isNotEmpty) {
    out['private_key_passphrase'] = s.privateKeyPassphrase;
  }
  if (s.hostKey.isNotEmpty) out['host_key'] = s.hostKey;
  if (s.hostKeyAlgorithms.isNotEmpty) {
    out['host_key_algorithms'] = s.hostKeyAlgorithms;
  }
  if (s.chained != null) out['detour'] = s.chained!.tag;
  return Outbound(out);
}

String toUriSsh(SshSpec s) {
  final q = <String, String>{};
  if (s.privateKey.isNotEmpty) q['private_key'] = s.privateKey;
  if (s.privateKeyPassphrase.isNotEmpty) {
    q['private_key_passphrase'] = s.privateKeyPassphrase;
  }
  if (s.hostKey.isNotEmpty) q['host_key'] = s.hostKey.join(',');
  if (s.hostKeyAlgorithms.isNotEmpty) {
    q['host_key_algorithms'] = s.hostKeyAlgorithms.join(',');
  }
  final userinfo = s.password.isEmpty
      ? encodeParam(s.user)
      : '${encodeParam(s.user)}:${encodeParam(s.password)}';
  final host = _wrapIpv6(s.server);
  final qs = buildQuery(q);
  final frag = encodeFragment(s.label);
  return 'ssh://$userinfo@$host:${s.port}${qs.isEmpty ? '' : '?$qs'}${frag.isEmpty ? '' : '#$frag'}';
}

// ════════════════════════════════════════════════════════════════════════════
// SOCKS
// ════════════════════════════════════════════════════════════════════════════

Outbound emitSocks(SocksSpec s, TemplateVars vars) {
  final out = <String, dynamic>{
    'type': 'socks',
    'tag': s.tag,
    'server': s.server,
    'server_port': s.port,
    'version': s.version,
  };
  if (s.username.isNotEmpty) out['username'] = s.username;
  if (s.password.isNotEmpty) out['password'] = s.password;
  if (s.chained != null) out['detour'] = s.chained!.tag;
  return Outbound(out);
}

String toUriSocks(SocksSpec s) {
  final userinfo = s.username.isEmpty
      ? ''
      : (s.password.isEmpty
          ? '${encodeParam(s.username)}@'
          : '${encodeParam(s.username)}:${encodeParam(s.password)}@');
  final host = _wrapIpv6(s.server);
  final frag = encodeFragment(s.label);
  return 'socks5://$userinfo$host:${s.port}${frag.isEmpty ? '' : '#$frag'}';
}

// ════════════════════════════════════════════════════════════════════════════
// WireGuard
// ════════════════════════════════════════════════════════════════════════════

Endpoint emitWireguard(WireguardSpec s, TemplateVars vars) {
  final peers = s.peers
      .map((p) => <String, dynamic>{
            'address': p.endpointHost,
            'port': p.endpointPort,
            'public_key': p.publicKey,
            'allowed_ips': List<String>.from(p.allowedIps),
            if (p.preSharedKey.isNotEmpty) 'pre_shared_key': p.preSharedKey,
            if (p.persistentKeepalive != null)
              'persistent_keepalive_interval': p.persistentKeepalive,
          })
      .toList();

  final map = <String, dynamic>{
    'type': 'wireguard',
    'tag': s.tag,
    if (s.mtu != null) 'mtu': s.mtu,
    'address': List<String>.from(s.localAddresses),
    'private_key': s.privateKey,
    'peers': peers,
  };
  return Endpoint(map);
}

String toUriWireguard(WireguardSpec s) {
  final peer = s.peers.isEmpty ? null : s.peers.first;
  final q = <String, String>{
    if (peer != null) 'publickey': peer.publicKey,
    if (s.localAddresses.isNotEmpty) 'address': s.localAddresses.join(','),
  };
  if (peer != null && peer.allowedIps.isNotEmpty) {
    q['allowedips'] = peer.allowedIps.join(',');
  }
  if (s.mtu != null) q['mtu'] = s.mtu.toString();
  if (peer != null && peer.preSharedKey.isNotEmpty) {
    q['presharedkey'] = peer.preSharedKey;
  }
  if (peer?.persistentKeepalive != null) {
    q['keepalive'] = peer!.persistentKeepalive.toString();
  }
  final userinfo = encodeParam(s.privateKey);
  final host = _wrapIpv6(s.server);
  final qs = buildQuery(q);
  final frag = encodeFragment(s.label);
  return 'wireguard://$userinfo@$host:${s.port}${qs.isEmpty ? '' : '?$qs'}${frag.isEmpty ? '' : '#$frag'}';
}

// ════════════════════════════════════════════════════════════════════════════
// Helpers
// ════════════════════════════════════════════════════════════════════════════

String _buildUri(
  String scheme,
  String userinfo,
  String server,
  int port,
  Map<String, String> q,
  String label,
) {
  final ui = encodeParam(userinfo);
  final host = _wrapIpv6(server);
  final qs = buildQuery(q);
  final frag = encodeFragment(label);
  return '$scheme://$ui@$host:$port${qs.isEmpty ? '' : '?$qs'}${frag.isEmpty ? '' : '#$frag'}';
}

String _wrapIpv6(String host) =>
    host.contains(':') && !host.startsWith('[') ? '[$host]' : host;
