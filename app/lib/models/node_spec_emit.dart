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

/// §219 — общий каркас outbound-map (`type`/`tag`/`server`/`server_port`).
/// Был продублирован в 9 emit-функциях. Возвращает growable map для дописывания.
Map<String, dynamic> _baseOutbound(String type, NodeSpec s) => <String, dynamic>{
      'type': type,
      'tag': s.tag,
      'server': s.server,
      'server_port': s.port,
    };

/// §219 — присвоение `detour` при наличии chained-ноды. Было продублировано
/// 9 раз (`if (s.chained != null) out['detour'] = s.chained!.tag;`).
void _addDetour(Map<String, dynamic> out, NodeSpec s) {
  if (s.chained != null) out['detour'] = s.chained!.tag;
}

// ════════════════════════════════════════════════════════════════════════════
// VLESS
// ════════════════════════════════════════════════════════════════════════════

Outbound emitVless(VlessSpec s, TemplateVars vars) {
  final out = _baseOutbound('vless', s)..['uuid'] = s.uuid;

  if (s.transport != null) {
    final (tmap, warnings) = s.transport!.toSingbox(vars);
    out['transport'] = tmap;
    for (final w in warnings) {
      if (!s.warnings.contains(w)) s.warnings.add(w);
    }
  }

  // §115 — ядро принимает РОВНО два flow: "" и "xtls-rprx-vision". vision
  // валиден ТОЛЬКО на голом TLS (с любым транспортом ws/grpc/http/httpupgrade/
  // xhttp ядро отвергает конфиг на load). Универсальный net на все пути
  // (URI/Xray/raw sing-box JSON/manual): пишем flow только если он РОВНО
  // vision И транспорта нет. Всё прочее (`none`, deprecated
  // xtls-rprx-direct/origin/splice, мусор) → поле не пишется = plain VLESS.
  if (s.flow == 'xtls-rprx-vision' && s.transport == null) {
    out['flow'] = s.flow;
  }
  if (s.packetEncoding.isNotEmpty) out['packet_encoding'] = s.packetEncoding;

  // §335 — постквантовый слой VLESS. Плоское поле верхнего уровня (в Xray-JSON
  // оно вложено в users[0], у ядра — рядом с uuid). Пишем только непустое и не
  // "none": обычные узлы не должны измениться ни на байт. Значение как есть —
  // битую строку отвергнет ядро на check с указанием сегмента.
  if (s.encryption.isNotEmpty && s.encryption != 'none') {
    out['encryption'] = s.encryption;
  }

  final tlsMap = s.tls.toSingbox();
  if (tlsMap.isNotEmpty) out['tls'] = tlsMap;

  _addDetour(out, s);

  return Outbound(out);
}

String toUriVless(VlessSpec s) {
  final q = <String, String>{};
  // §115 — share-URI несёт flow только если он валиден: ровно vision на
  // bare TLS (см. emitVless). Прочее (none/deprecated/мусор) опускаем.
  if (s.flow == 'xtls-rprx-vision' && s.transport == null) q['flow'] = s.flow;
  if (s.packetEncoding.isNotEmpty) q['packetEncoding'] = s.packetEncoding;
  // §335 — без обратной записи поле теряется на round-trip (§302-правила и
  // ручное редактирование ходят через эмит-URI), и узел снова становится
  // мёртвым — уже без внешней причины.
  if (s.encryption.isNotEmpty && s.encryption != 'none') {
    q['encryption'] = s.encryption;
  }

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
  final out = _baseOutbound('vmess', s)
    ..['uuid'] = s.uuid
    ..['security'] = s.security;
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

  _addDetour(out, s);
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
  final out = _baseOutbound('trojan', s)..['password'] = s.password;
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
  _addDetour(out, s);
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
// AnyTLS (§269)
// ════════════════════════════════════════════════════════════════════════════

Outbound emitAnyTls(AnyTlsSpec s, TemplateVars vars) {
  final out = _baseOutbound('anytls', s)..['password'] = s.password;
  // AnyTLS всегда поверх TLS — эмитим tls-блок безусловно (в отличие от trojan,
  // где может быть {enabled:false}).
  out['tls'] = s.tls.toSingbox();
  if (s.idleSessionCheckInterval.isNotEmpty) {
    out['idle_session_check_interval'] = s.idleSessionCheckInterval;
  }
  if (s.idleSessionTimeout.isNotEmpty) {
    out['idle_session_timeout'] = s.idleSessionTimeout;
  }
  if (s.minIdleSession != null) {
    out['min_idle_session'] = s.minIdleSession;
  }
  _addDetour(out, s);
  return Outbound(out);
}

String toUriAnyTls(AnyTlsSpec s) {
  // AnyTLS всегда TLS. idle-поля несём в query для round-trip parity
  // (URI-стандарта у anytls нет, форма — trojan/vless-подобная).
  final q = <String, String>{};
  // REALITY (pbk/sid) — как у vless, иначе round-trip терял бы REALITY-блок,
  // приходящий из sing-box JSON.
  if (s.tls.reality != null) {
    q['security'] = 'reality';
    q['pbk'] = s.tls.reality!.publicKey;
    if (s.tls.reality!.shortId.isNotEmpty) {
      q['sid'] = s.tls.reality!.shortId;
    }
  } else {
    q['security'] = 'tls';
  }
  if (s.tls.serverName != null) q['sni'] = s.tls.serverName!;
  if (s.tls.fingerprint != null) q['fp'] = s.tls.fingerprint!;
  if (s.tls.alpn.isNotEmpty) q['alpn'] = s.tls.alpn.join(',');
  if (s.tls.insecure) q['allowInsecure'] = '1';
  if (s.idleSessionCheckInterval.isNotEmpty) {
    q['idle_session_check_interval'] = s.idleSessionCheckInterval;
  }
  if (s.idleSessionTimeout.isNotEmpty) {
    q['idle_session_timeout'] = s.idleSessionTimeout;
  }
  if (s.minIdleSession != null) {
    q['min_idle_session'] = s.minIdleSession.toString();
  }
  return _buildUri('anytls', s.password, s.server, s.port, q, s.label);
}

// ════════════════════════════════════════════════════════════════════════════
// Shadowsocks
// ════════════════════════════════════════════════════════════════════════════

Outbound emitShadowsocks(ShadowsocksSpec s, TemplateVars vars) {
  final out = _baseOutbound('shadowsocks', s)
    ..['method'] = s.method
    ..['password'] = s.password;
  if (s.plugin.isNotEmpty) {
    out['plugin'] = s.plugin;
    if (s.pluginOpts.isNotEmpty) out['plugin_opts'] = s.pluginOpts;
  }
  _addDetour(out, s);
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
  final out = _baseOutbound('hysteria2', s);
  if (s.password.isNotEmpty) out['password'] = s.password;
  // §358 — оба типа из enum ядра. Тип и наличие пароля уже отвалидированы
  // парсером (normalizeHysteria2Obfs): сюда доезжает только то, что ядро
  // примет, иначе obfs отсутствует. Плоские min/max внутри `obfs` — так их
  // кладёт badjson.MarshallObjects(_Hysteria2Obfs, Hysteria2ObfsGecko).
  if (s.obfs == 'salamander' || s.obfs == 'gecko') {
    out['obfs'] = {
      'type': s.obfs,
      if (s.obfsPassword.isNotEmpty) 'password': s.obfsPassword,
      if (s.obfs == 'gecko') ...{
        if (s.obfsMinPacketSize != null) 'min_packet_size': s.obfsMinPacketSize,
        if (s.obfsMaxPacketSize != null) 'max_packet_size': s.obfsMaxPacketSize,
      },
    };
  }
  if (s.upMbps != null) out['up_mbps'] = s.upMbps;
  if (s.downMbps != null) out['down_mbps'] = s.downMbps;
  // §282 — QUIC не поддерживает uTLS; fp на hysteria2 = мусор подписок.
  out['tls'] = s.tls.toSingboxForQuic();
  _addDetour(out, s);
  return Outbound(out);
}

String toUriHysteria2(Hysteria2Spec s) {
  final q = <String, String>{};
  if (s.obfs.isNotEmpty) q['obfs'] = s.obfs;
  if (s.obfsPassword.isNotEmpty) q['obfs-password'] = s.obfsPassword;
  // §358 — у hysteria2 нет де-факто URI-ключей для gecko (ядро читает его
  // только из JSON); свои — симметрично obfs-password, parseHysteria2 читает
  // их обратно. Пишем независимо от типа: смена salamander↔gecko в редакторе
  // не должна терять уже разобранные значения.
  if (s.obfsMinPacketSize != null) {
    q['obfs-min-packet-size'] = s.obfsMinPacketSize.toString();
  }
  if (s.obfsMaxPacketSize != null) {
    q['obfs-max-packet-size'] = s.obfsMaxPacketSize.toString();
  }
  if (s.tls.serverName != null) q['sni'] = s.tls.serverName!;
  if (s.tls.insecure) q['insecure'] = '1';
  if (s.tls.alpn.isNotEmpty) q['alpn'] = s.tls.alpn.join(',');
  if (s.tls.fingerprint != null) q['fp'] = s.tls.fingerprint!;
  // §084 H3: round-trip bandwidth hint'ов. emit пишет up_mbps/down_mbps в
  // sing-box JSON — URI должен их сохранять, иначе parse→emit→toUri→parse
  // теряет значения (parseHysteria2 читает те же ключи обратно).
  if (s.upMbps != null) q['up_mbps'] = s.upMbps.toString();
  if (s.downMbps != null) q['down_mbps'] = s.downMbps.toString();
  return _buildUri('hysteria2', s.password, s.server, s.port, q, s.label);
}

// ════════════════════════════════════════════════════════════════════════════
// NaïveProxy
// ════════════════════════════════════════════════════════════════════════════
// §084 M7: `isValidNaiveHeaderName` / `naiveHeaderNameRe` переехали в
// services/parser/uri_utils.dart (единый источник, был дубль с uri_parsers).

Outbound emitNaive(NaiveSpec s, TemplateVars vars) {
  final out = _baseOutbound('naive', s);
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
  _addDetour(out, s);
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
  final out = _baseOutbound('tuic', s)
    ..['uuid'] = s.uuid
    ..['password'] = s.password
    ..['congestion_control'] = s.congestionControl
    ..['udp_relay_mode'] = s.udpRelayMode;
  if (s.zeroRtt) out['zero_rtt_handshake'] = true;
  // §282 — QUIC не поддерживает uTLS; fp на tuic = мусор подписок.
  out['tls'] = s.tls.toSingboxForQuic();
  _addDetour(out, s);
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
  final out = _baseOutbound('ssh', s)..['user'] = s.user;
  if (s.password.isNotEmpty) out['password'] = s.password;
  if (s.privateKey.isNotEmpty) out['private_key'] = s.privateKey;
  if (s.privateKeyPassphrase.isNotEmpty) {
    out['private_key_passphrase'] = s.privateKeyPassphrase;
  }
  if (s.hostKey.isNotEmpty) out['host_key'] = s.hostKey;
  if (s.hostKeyAlgorithms.isNotEmpty) {
    out['host_key_algorithms'] = s.hostKeyAlgorithms;
  }
  _addDetour(out, s);
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
  final out = _baseOutbound('socks', s)..['version'] = s.version;
  if (s.username.isNotEmpty) out['username'] = s.username;
  if (s.password.isNotEmpty) out['password'] = s.password;
  _addDetour(out, s);
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
// HTTP(S) CONNECT proxy — task 222
// ════════════════════════════════════════════════════════════════════════════

Outbound emitHttp(HttpSpec s, TemplateVars vars) {
  final out = _baseOutbound('http', s);
  if (s.username.isNotEmpty) out['username'] = s.username;
  if (s.password.isNotEmpty) out['password'] = s.password;
  if (s.path.isNotEmpty) out['path'] = s.path;
  if (s.headers.isNotEmpty) {
    final keys = s.headers.keys.toList()..sort();
    final sorted = <String, String>{};
    for (final k in keys) {
      sorted[k] = s.headers[k]!;
    }
    out['headers'] = sorted;
  }
  final tlsMap = s.tls.toSingbox();
  if (tlsMap.isNotEmpty) out['tls'] = tlsMap;
  _addDetour(out, s);
  return Outbound(out);
}

String toUriHttp(HttpSpec s) {
  // userinfo: оба пусто → нет; только user → user@; только pass → :pass@.
  final hasUser = s.username.isNotEmpty;
  final hasPass = s.password.isNotEmpty;
  final ui = !hasUser && !hasPass
      ? ''
      : (!hasPass
          ? '${encodeParam(s.username)}@'
          : '${encodeParam(s.username)}:${encodeParam(s.password)}@');

  final q = <String, String>{};
  if (s.path.isNotEmpty) q['path'] = s.path;
  if (s.headers.isNotEmpty) {
    q['headers'] = serializeNaiveExtraHeaders(s.headers);
  }
  if (s.tls.enabled) {
    if (s.tls.serverName != null && s.tls.serverName!.isNotEmpty) {
      q['sni'] = s.tls.serverName!;
    }
    if (s.tls.fingerprint != null && s.tls.fingerprint!.isNotEmpty) {
      q['fp'] = s.tls.fingerprint!;
    }
    if (s.tls.alpn.isNotEmpty) q['alpn'] = s.tls.alpn.join(',');
    if (s.tls.insecure) q['allowInsecure'] = '1';
  }

  final scheme = s.tls.enabled ? 'proxy-https' : 'proxy-http';
  final host = _wrapIpv6(s.server);
  final qs = buildQuery(q);
  final frag = encodeFragment(s.label);
  return '$scheme://$ui$host:${s.port}'
      '${qs.isEmpty ? '' : '?$qs'}'
      '${frag.isEmpty ? '' : '#$frag'}';
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
            // §025 — WARP client_id → reserved (3 байта). Перед public_ key/
            // allowed_ips порядок не важен (JSON-объект), но кладём рядом.
            if (p.reserved != null && p.reserved!.isNotEmpty)
              'reserved': List<int>.from(p.reserved!),
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
  // §097 — AmneziaWG2 obfuscation-поля в корень endpoint (числа → JSON number).
  s.awg?.writeInto(map);
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
  // §025 — WARP client_id round-trip (десятичный `b0,b1,b2`; parseReserved
  // принимает его обратно).
  if (peer?.reserved != null && peer!.reserved!.isNotEmpty) {
    q['reserved'] = peer.reserved!.join(',');
  }
  // §097 — AmneziaWG2 query-params (round-trip); buildQuery эскейпит i*.
  s.awg?.writeQuery(q);
  final userinfo = encodeParam(s.privateKey);
  final host = _wrapIpv6(s.server);
  final qs = buildQuery(q);
  final frag = encodeFragment(s.label);
  return 'wireguard://$userinfo@$host:${s.port}${qs.isEmpty ? '' : '?$qs'}${frag.isEmpty ? '' : '#$frag'}';
}

// ─── §130 MASQUE ────────────────────────────────────────────────────────────

/// §130 — MASQUE эмитится как **Outbound** (не Endpoint). Плоская структура
/// по `option.MASQUEOutboundOptions` ядра: `ip`/`ipv6` берутся из
/// [MasqueSpec.localAddresses] по признаку `:` (v6). `network` = транспорт h3/h2.
Outbound emitMasque(MasqueSpec s, TemplateVars vars) {
  String? ip, ipv6;
  for (final a in s.localAddresses) {
    if (a.contains(':')) {
      ipv6 ??= a;
    } else {
      ip ??= a;
    }
  }
  final map = <String, dynamic>{
    'type': 'masque',
    'tag': s.tag,
    'server': s.server,
    'server_port': s.port,
    'profile': s.profile,
    'network': s.network,
    'private_key': s.privateKeyDer,
    'public_key': s.publicKeyDer,
    'ip': ?ip,
    'ipv6': ?ipv6,
    if (s.sni.isNotEmpty) 'sni': s.sni,
    if (s.mtu != null) 'mtu': s.mtu,
    if (s.idleTimeout.isNotEmpty) 'idle_timeout': s.idleTimeout,
    if (s.keepAlive.isNotEmpty) 'keep_alive_period': s.keepAlive,
  };
  return Outbound(map);
}

String toUriMasque(MasqueSpec s) {
  final q = <String, String>{
    'publickey': s.publicKeyDer,
    if (s.localAddresses.isNotEmpty) 'address': s.localAddresses.join(','),
    'profile': s.profile,
    'network': s.network,
    if (s.sni.isNotEmpty) 'sni': s.sni,
    if (s.mtu != null) 'mtu': s.mtu.toString(),
    if (s.idleTimeout.isNotEmpty) 'idle_timeout': s.idleTimeout,
    if (s.keepAlive.isNotEmpty) 'keep_alive': s.keepAlive,
  };
  final userinfo = encodeParam(s.privateKeyDer);
  final host = _wrapIpv6(s.server);
  final qs = buildQuery(q);
  final frag = encodeFragment(s.label);
  return 'masque://$userinfo@$host:${s.port}${qs.isEmpty ? '' : '?$qs'}${frag.isEmpty ? '' : '#$frag'}';
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
