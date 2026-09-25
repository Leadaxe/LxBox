import 'dart:convert';

import '../services/parser/engine/emitter.dart';
import '../services/parser/engine/section_loader.dart';
import '../services/parser/tcp_keep_alive.dart';
import 'node_spec.dart';
import 'singbox_entry.dart';
import 'template_vars.dart';

// ════════════════════════════════════════════════════════════════════════════
// §480 W7 — СБОРКА ССЫЛКИ ОТ ТАБЛИЦЫ
// ════════════════════════════════════════════════════════════════════════════

/// Собрать ссылку узла ДВИЖКОМ, по той же секции, что ведёт его разбор.
///
/// `null` — у типа тела нет секции либо секция не объявила обратного хода
/// (`emit`), и схема остаётся на рукописном `toUri<Схема>` до своей волны.
///
/// Вход движка — КАНОНИЧЕСКОЕ ТЕЛО (`emitRaw`), то самое, что отдаёт разбор.
/// Модели движок не знает: знал бы — знал бы и имена схем.
///
/// `TemplateVars.empty` здесь законен и обязателен: подстановка переменных —
/// дело СБОРКИ КОНФИГА, а ссылка это форма ХРАНЕНИЯ узла, и подставленное
/// значение переменной, попав в неё, замёрзло бы навсегда (NODE_SECTIONS §6).
String? uriViaEngine(NodeSpec s) {
  final section = MapperSections.I.sectionFor('uri', s.protocol);
  if (section == null || !sectionEmits(section)) return null;
  final body = s.emitRaw(TemplateVars.empty).map;
  return emitViaSection(section, body, s.label)?.uri;
}

/// Ссылка узла ДВИЖКОМ у схемы, которая на него переехала.
///
/// Отличается от [uriViaEngine] тем, что `null` здесь — не «идём прежним
/// путём», а ОШИБКА СБОРКИ: рукописного эмита у переехавшей схемы больше нет,
/// и молчаливый возврат пустой строки стоил бы владельцу узла — ссылка и есть
/// форма хранения. Тот же принцип, что у разбора (критерий 7 спеки):
/// отсутствие реестра — ошибка, а не тихий откат.
String uriViaEngineRequired(NodeSpec s) {
  final uri = uriViaEngine(s);
  if (uri != null) return uri;
  throw StateError(
    'нет секции эмита для типа тела «${s.protocol}»: реестр контракта не '
    'загружен либо секция не объявила emit. Рукописного эмита у этой схемы '
    'не осталось (§480 W7).',
  );
}

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
///
/// §453 — сюда же TCP keep-alive: это тоже dial-поле, общее для всех
/// outbound'ов, и точка у него ровно одна на все 13 вызовов. У не-носителей
/// `tcpKeepAlive == null` — не пишется ничего, emit прежний байт-в-байт.
void _addDialFields(Map<String, dynamic> out, NodeSpec s) {
  if (s.chained != null) out['detour'] = s.chained!.tag;
  tcpKeepAliveToSingbox(out, s.tcpKeepAlive);
}

// ════════════════════════════════════════════════════════════════════════════
// Tailscale (§435) — endpoint, тело как есть
// ════════════════════════════════════════════════════════════════════════════

/// `type`/`tag` первыми (порядок ключей конфига читаемее), дальше тело как
/// хранится. `state_directory` здесь НЕ подставляется — это делает сборка при
/// эмиссии (путь этой машины в хранимое тело не пишется, NODE_SECTIONS.md §6).
Endpoint emitTailscale(TailscaleSpec s, TemplateVars vars) {
  final map = <String, dynamic>{
    'type': 'tailscale',
    'tag': s.tag,
    ...deepCopyJson(s.body) as Map<String, dynamic>,
  };
  _addDialFields(map, s);
  return Endpoint(map);
}

/// Канонический текст узла Tailscale — компактный JSON endpoint'а (URI-формы
/// у схемы нет). Без `detour`: цепочка — дело контейнера, а не текста узла.
String toUriTailscale(TailscaleSpec s) => jsonEncode(<String, dynamic>{
      'type': 'tailscale',
      'tag': s.tag,
      ...s.body,
    });

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

  // §115 — ядро принимает РОВНО два flow: "" и "xtls-rprx-vision"; всё прочее
  // (`none`, deprecated xtls-rprx-direct/origin/splice, мусор) → поле не
  // пишется = plain VLESS.
  //
  // §544 — связь flow ↔ transport здесь НЕ судится: её решает реестр
  // (`vless.flow.conflicts`, `unless_set: [encryption]`) в санитайзере тела.
  // Прежнее рукописное «vision только без транспорта» молча снимало flow у
  // xhttp-узла с VLESS Encryption, где Vision работает поверх слоя шифрования
  // и сервер без flow рвёт соединение.
  if (s.flow == 'xtls-rprx-vision') {
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

  _addDialFields(out, s);

  return Outbound(out);
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

  _addDialFields(out, s);
  return Outbound(out);
}

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
  // §103 D-016(в) — TLS выключен = дефолт ядра (option/trojan.go omitempty),
  // ключ `tls` не эмитим вовсе (было: {enabled:false}, чего Go не пишет).
  final tlsMap = s.tls.toSingbox();
  if (tlsMap.isNotEmpty) out['tls'] = tlsMap;
  _addDialFields(out, s);
  return Outbound(out);
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
  _addDialFields(out, s);
  return Outbound(out);
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
  _addDialFields(out, s);
  return Outbound(out);
}

// ════════════════════════════════════════════════════════════════════════════
// Hysteria2
// ════════════════════════════════════════════════════════════════════════════

Outbound emitHysteria2(Hysteria2Spec s, TemplateVars vars) {
  final out = _baseOutbound('hysteria2', s);
  if (s.password.isNotEmpty) out['password'] = s.password;
  // §103 §9.B2 — multi-port / port hopping (mport=/ports= query, а также
  // authority host:443,20000-30000) → sing-box server_ports. Аддитивно к
  // server_port (Go: hysteria2_ports.go, оба поля живут одновременно).
  if (s.serverPorts != null && s.serverPorts!.isNotEmpty) {
    out['server_ports'] = List<String>.from(s.serverPorts!);
  }
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
  _addDialFields(out, s);
  return Outbound(out);
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
  // §103 §9.B1 — naive+quic: транспорт QUIC вместо HTTP/2. Go: bbr —
  // единственная поддерживаемая congestion control, не читается из URI.
  if (s.quic) {
    out['quic'] = true;
    out['quic_congestion_control'] = 'bbr';
  }
  if (s.extraHeaders.isNotEmpty) {
    final keys = s.extraHeaders.keys.toList()..sort();
    final sorted = <String, String>{};
    for (final k in keys) {
      sorted[k] = s.extraHeaders[k]!;
    }
    out['extra_headers'] = sorted;
  }
  out['tls'] = s.tls.toSingbox();
  _addDialFields(out, s);
  return Outbound(out);
}

// §480 W7 — `serializeNaiveExtraHeaders` удалён вместе с рукописным эмитом.
// Склейку заголовков в параметр ссылки делает движок, обращая `extract`
// записи: разделитель элементов он берёт из `list.sep`, а годность пары
// судит ТОЙ ЖЕ регуляркой `extract.re`, какой её читает разбор. Прежде
// правило жило двумя копиями — регуляркой в данных и `isValidNaiveHeaderName`
// в коде эмита, — и это ровно тот дубль, ради снятия которого затеяна
// кампания.

// ════════════════════════════════════════════════════════════════════════════
// TUIC v5
// ════════════════════════════════════════════════════════════════════════════

Outbound emitTuic(TuicSpec s, TemplateVars vars) {
  final out = _baseOutbound('tuic', s)..['uuid'] = s.uuid;
  // §493 / Q133-67 — пустой пароль принимается с `password_empty`, но поле в
  // теле не материализуется: ядро omitempty, корпус ждёт отсутствие ключа.
  if (s.password.isNotEmpty) out['password'] = s.password;
  // §103 D-016(в) — дефолт не эмитим: null = не было задано явно, ядро
  // подставит cubic/native само (option/tuic.go omitempty).
  if (s.congestionControl != null) {
    out['congestion_control'] = s.congestionControl;
  }
  if (s.udpRelayMode != null) out['udp_relay_mode'] = s.udpRelayMode;
  if (s.zeroRtt) out['zero_rtt_handshake'] = true;
  if (s.heartbeat != null) out['heartbeat'] = s.heartbeat;
  // §282 — QUIC не поддерживает uTLS; fp на tuic = мусор подписок.
  out['tls'] = s.tls.toSingboxForQuic();
  _addDialFields(out, s);
  return Outbound(out);
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
  _addDialFields(out, s);
  return Outbound(out);
}

// ════════════════════════════════════════════════════════════════════════════
// SOCKS
// ════════════════════════════════════════════════════════════════════════════

Outbound emitSocks(SocksSpec s, TemplateVars vars) {
  final out = _baseOutbound('socks', s)..['version'] = s.version;
  if (s.username.isNotEmpty) out['username'] = s.username;
  if (s.password.isNotEmpty) out['password'] = s.password;
  _addDialFields(out, s);
  return Outbound(out);
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
  _addDialFields(out, s);
  return Outbound(out);
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

// ─── §130 MASQUE ────────────────────────────────────────────────────────────

/// §130 — MASQUE эмитится как **Outbound** (не Endpoint). Плоская структура
/// по `option.MASQUEOutboundOptions` ядра: `ip`/`ipv6` берутся из
/// [MasqueSpec.localAddresses] по признаку `:` (v6). `vhttp` = версия HTTP h3/h2.
Outbound emitMasque(MasqueSpec s, TemplateVars vars) {
  String? ip, ipv6;
  for (final a in s.localAddresses) {
    if (a.contains(':')) {
      ipv6 ??= a;
    } else {
      ip ??= a;
    }
  }
  // §393 — схема ядра: версия HTTP под ключом `vhttp`, TLS-опции во вложенном
  // `tls{}`. Старые имена (`network`/`sni`) НЕ пишем: они ещё принимаются
  // ядром, но дают deprecation-варнинг на каждый outbound, а одновременная
  // запись старого и нового имени с разными значениями — fatal.
  final tls = <String, dynamic>{
    if (s.sni.isNotEmpty) 'server_name': s.sni,
    if (s.disableSni) 'disable_sni': true,
  };
  final map = <String, dynamic>{
    'type': 'masque',
    'tag': s.tag,
    'server': s.server,
    'server_port': s.port,
    'profile': s.profile,
    'vhttp': s.vhttp,
    'private_key': s.privateKeyDer,
    'public_key': s.publicKeyDer,
    'ip': ?ip,
    'ipv6': ?ipv6,
    if (tls.isNotEmpty) 'tls': tls,
    if (s.mtu != null) 'mtu': s.mtu,
    if (s.idleTimeout.isNotEmpty) 'idle_timeout': s.idleTimeout,
    if (s.keepAlive.isNotEmpty) 'keep_alive_period': s.keepAlive,
  };
  return Outbound(map);
}

// ════════════════════════════════════════════════════════════════════════════
// Helpers
// ════════════════════════════════════════════════════════════════════════════
