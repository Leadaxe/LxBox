/// §472 шаг 8 — маппер «карта Xray → карта sing-box».
///
/// Последний вход, переезжающий на конвейер, и единственный, у которого
/// исходный диалект — не строка, а ОБЪЕКТ. Общих ключей с sing-box у него нет
/// даже для типа записи: `protocol` против `type`, `streamSettings` против
/// `transport`, `settings.vnext[].users[]` против `uuid` (спека 472, 7.2).
/// Поэтому проход по дословной карте (шаг 1) Xray-узел пропускал: судить
/// Xray-ключи sing-box-схемой значило бы выдать `unknown_key` на каждый
/// законный. Карту, которой у этого входа не существовало, строит маппер —
/// и с этого шага её судит санитайзер, как у всех прочих входов.
///
/// **Маппер не судит значения.** Из Xray-веток сняты и уехали в реестр:
/// `normalizeTlsFingerprint` (мусорный `fingerprint` → `chrome` + класс),
/// `normalizeVmessSecurity` (значение вне enum ядра), `isValidRealityPublicKey`
/// (гейт REALITY по §169), `normalizeRealityShortId`, гашение `flow` при живом
/// транспорте. Все они теперь правила значений реестра — те же, что исполняются
/// на ссылке и на теле sing-box.
///
/// Рукописным остаётся ПЕРЕВОД написания, и он же описан секцией `mapper`
/// реестра: раскладка `flow=xtls-rprx-vision-udp443` на два поля
/// (`vision_udp443_is_a_compound_name`), имена транспортов Xray
/// (`transport_name_dialect`: `h2` → `http`, `splithttp` → `xhttp`,
/// `headerType=http` поверх tcp → `http`), early data хвостом пути
/// (`ws_early_data_path_suffix`), псевдонимы uTLS (`utls_xray_hello_names`).
///
/// **Вход — `xray`, а не `singbox`.** Санитайзер получает [BodySource.other]:
/// исключение `except_sources: ["singbox"]` у потолка `mtu` (§473) относится
/// к телу, написанному в форме ЯДРА самим человеком или подпиской, а карту
/// Xray-узла собрал наш маппер. Словарь `sources` реестра различает входы
/// тоньше (`uri`/`singbox`/`xray`/`wgconf`), но правило сегодня одно и делит
/// ровно надвое — см. doc [BodySource].
library;

import '../../../models/node_warning.dart';
import '../transport.dart'
    show mergeXhttpExtra, splitEarlyDataPath, xhttpScalarsFromJson;
import 'common_parts.dart';
import 'uri_mapper.dart';

/// Результат перевода одного Xray-outbound'а.
///
/// Отличается от [UriMapping] тем, что несёт ещё и `label`: имя Xray-узла
/// приходит не из фрагмента ссылки, а от ЭЛЕМЕНТА подписки (`remarks` плюс
/// правила §310/§322), и считает его вызывающий — маппер получает готовое.
final class XrayMapping {
  const XrayMapping({
    required this.body,
    this.warnings = const [],
    this.wsEarlyDataHeaderImplicit = false,
    this.tagScheme,
  });

  /// Сырая карта sing-box. Ещё не судимая: в ней законно лежит и мусор,
  /// который снимет санитайзер.
  final Map<String, dynamic> body;

  /// Предупреждения САМОГО перевода (не о значениях) — та же граница, что у
  /// [UriMapping.warnings].
  final List<NodeWarning> warnings;

  /// §103 D-008 — заголовок early data подставлен формой записи (`?ed=N`
  /// хвостом пути), а не написан автором конфига.
  final bool wsEarlyDataHeaderImplicit;

  /// Имя схемы для ТЕГ-ФОЛБЭКА безымянного узла, когда оно не равно типу
  /// тела. Совпадений нет у двух протоколов, и обе разницы историчны:
  /// прежние ветки звали фолбэк `ss-…` при теле `shadowsocks` и `hy2-…` при
  /// теле `hysteria2`. Тег И ЕСТЬ identity (`node_hash.dart`), поэтому
  /// написание сохраняется буква в букву: возьми конвейер имя типа, у живых
  /// безымянных узлов слетели бы выбор, отключения и цепочки.
  ///
  /// `null` — фолбэк строится по `body['type']`, как у всех прочих.
  final String? tagScheme;
}

/// Служебные outbound'ы Xray: не серверы, узлами не становятся (§321).
const kXrayServiceProtocols = {'freedom', 'blackhole', 'dns', 'loopback'};

/// Порт по умолчанию у протоколов, которые его не обязаны нести.
const _kDefaultPort = 443;

/// Составное имя из `vless.json` → mapper → `vision_udp443_is_a_compound_name`.
const _kVisionUdp443 = 'xtls-rprx-vision-udp443';
const _kVision = 'xtls-rprx-vision';

/// Перевести Xray-outbound в карту sing-box. `null` — записи нет вовсе
/// (нет адреса, нет обязательного удостоверения): тем же `null`, каким
/// отвечали прежние `_xray*ToSpec`.
///
/// Бросить эта функция может (мусорный ТИП поля — `settings: []`), и это
/// намеренно: вызывающий ловит и пропускает такой outbound, как раньше
/// (§322 «битые формы не роняют парсинг целиком» на гранулярности узла).
XrayMapping? mapXrayOutbound(Map<String, dynamic> o) {
  final protocol = o['protocol']?.toString() ?? '';
  return switch (protocol) {
    'vless' => _vless(o),
    'trojan' => _trojan(o),
    'vmess' => _vmess(o),
    'shadowsocks' => _shadowsocks(o),
    'hysteria' => _hysteria2(o),
    'socks' => _socks(o),
    _ => null,
  };
}

/// `streamSettings` записи.
///
/// Каст НАМЕРЕННО жёсткий (`as Map?`), как в прежних ветках: мусорный ТИП
/// поля (`streamSettings: "none"`, `settings: []`) обязан бросить, и
/// вызывающий пропускает такой outbound целиком, назвав протокол в
/// `UnsupportedProtocolWarning` (§322 «битые формы не роняют парсинг» на
/// гранулярности узла). Мягкое `is Map` сделало бы из битой записи РАБОЧИЙ
/// узел без транспорта и TLS — узел, который провайдер таким не присылал.
Map _streamOf(Map<String, dynamic> o) => o['streamSettings'] as Map? ?? const {};

XrayMapping? _vless(Map<String, dynamic> o) {
  final v = _firstVnext(o);
  if (v == null) return null;
  final server = v['address']?.toString() ?? '';
  final users = (v['users'] as List?)?.cast<Map>() ?? const [];
  final user = users.isEmpty ? const {} : users.first;
  final uuid = user['id']?.toString() ?? '';
  if (server.isEmpty || uuid.isEmpty) return null;
  final port = (v['port'] as num?)?.toInt() ?? _kDefaultPort;

  // `vision_udp443_is_a_compound_name` — раскладка составного ИМЕНИ. Судить
  // тут нечего: `xtls-rprx-vision-udp443` в enum ядра не входит вовсе.
  //
  // §459 — порт узла при этом НЕ переписывается: прежняя перезапись на 443
  // делала узел `…:8443` недозваниваемым.
  var flow = (user['flow']?.toString() ?? '').trim();
  String? packetEncoding;
  if (flow == _kVisionUdp443) {
    flow = _kVision;
    packetEncoding = 'xudp';
  }

  // §335/§477 — постквантовый слой. Маппер берёт значение как есть и не
  // кладёт ключа, если поля не было. Обрезка краёв (`normalize: trim`),
  // выключатель (`absent_values: ["none"]`) и форма (`pattern`) — работа
  // САНИТАЙЗЕРА: правило записано один раз и исполняется одинаково на ссылке,
  // в теле sing-box и здесь. Негодное значение снимает УЗЕЛ (`drop_node`).
  final encryption = user['encryption']?.toString() ?? '';

  final stream = _streamOf(o);
  final transport = _transport(stream);
  final body = <String, dynamic>{
    'type': 'vless',
    'server': server,
    'server_port': port,
    'uuid': uuid,
    if (flow.isNotEmpty) 'flow': flow,
    if (encryption.trim().isNotEmpty) 'encryption': encryption,
    'packet_encoding': ?packetEncoding,
  };

  // §474 — гашение vision при живом транспорте уехало в реестр целиком:
  // правило `flow.conflicts.with = transport` со своим кодом
  // `vision_with_transport`. Рукописного `VisionWithTransportWarning` на этом
  // входе больше нет.

  final tls = _tls(stream, server, reality: true);
  if (tls != null) body['tls'] = tls;
  if (transport.map != null) body['transport'] = transport.map;
  _putKeepAlive(body, stream);

  return XrayMapping(
    body: body,
    warnings: transport.warnings,
    wsEarlyDataHeaderImplicit: transport.wsEarlyDataHeaderImplicit,
  );
}

XrayMapping? _trojan(Map<String, dynamic> o) {
  final s = _firstServer(o);
  if (s == null) return null;
  final server = s['address']?.toString() ?? '';
  final password = s['password']?.toString() ?? '';
  if (server.isEmpty || password.isEmpty) return null;
  final port = (s['port'] as num?)?.toInt() ?? _kDefaultPort;

  final stream = _streamOf(o);
  final transport = _transport(stream);
  final body = <String, dynamic>{
    'type': 'trojan',
    'server': server,
    'server_port': port,
    'password': password,
  };
  final tls = _tls(stream, server);
  if (tls != null) body['tls'] = tls;
  if (transport.map != null) body['transport'] = transport.map;
  _putKeepAlive(body, stream);

  return XrayMapping(
    body: body,
    warnings: transport.warnings,
    wsEarlyDataHeaderImplicit: transport.wsEarlyDataHeaderImplicit,
  );
}

XrayMapping? _vmess(Map<String, dynamic> o) {
  final v = _firstVnext(o);
  if (v == null) return null;
  final server = v['address']?.toString() ?? '';
  final users = (v['users'] as List?)?.cast<Map>() ?? const [];
  final user = users.isEmpty ? const {} : users.first;
  final uuid = user['id']?.toString() ?? '';
  if (server.isEmpty || uuid.isEmpty) return null;
  final port = (v['port'] as num?)?.toInt() ?? _kDefaultPort;

  // §459 — значение вне enum ядра роняет ВЕСЬ конфиг, и судит его теперь
  // реестр (`vmess.json` → `security`, enum + `on_invalid: coerce auto`):
  // рукописный `normalizeVmessSecurity` с этого входа снят.
  //
  // Ключ обязан ПОЯВИТЬСЯ в теле даже при пустом значении: у ядра поле без
  // `omitempty`, у схемы оно `required`, а `default` реестра тело не
  // наполняет (материализуется только `default_when`, CANON §2.4).
  // Опущенный ключ снял бы узел кодом `field_missing` — ровно это и вышло
  // при первом заходе шага. Написание — общее с маппером ссылки
  // (`_securitySpelling`, vmess_mapper.dart): «не задано» даёт `auto`
  // молча, синоним `chacha20-ietf-poly1305` переводится, прочее уезжает как
  // приехало, и вердикт выносит санитайзер.
  final security = _vmessSecuritySpelling(user['security']?.toString() ?? '');

  final stream = _streamOf(o);
  final transport = _transport(stream);
  final body = <String, dynamic>{
    'type': 'vmess',
    'server': server,
    'server_port': port,
    'uuid': uuid,
    'security': security,
    'alter_id': (user['alterId'] as num?)?.toInt() ?? 0,
  };
  final tls = _tls(stream, server);
  if (tls != null) body['tls'] = tls;
  if (transport.map != null) body['transport'] = transport.map;
  _putKeepAlive(body, stream);

  return XrayMapping(
    body: body,
    warnings: transport.warnings,
    wsEarlyDataHeaderImplicit: transport.wsEarlyDataHeaderImplicit,
  );
}

XrayMapping? _shadowsocks(Map<String, dynamic> o) {
  final s = _firstServer(o);
  if (s == null) return null;
  final server = s['address']?.toString() ?? '';
  final method = s['method']?.toString() ?? '';
  final port = (s['port'] as num?)?.toInt() ?? 0;
  if (server.isEmpty || method.isEmpty || port == 0) return null;

  final body = <String, dynamic>{
    'type': 'shadowsocks',
    'server': server,
    'server_port': port,
    'method': method,
    'password': s['password']?.toString() ?? '',
  };
  // §453 — у ss своего транспорта нет, но sockopt лежит там же.
  _putKeepAlive(body, _streamOf(o));
  return XrayMapping(body: body, tagScheme: 'ss');
}

/// §321 — `protocol: "hysteria"` с `version: 2` — форма форка Xray (апстрим
/// hysteria2 не поддерживает вовсе). `finalmask.quicParams` НЕ переносим: у
/// sing-box нет соответствия, а unknown field валит весь конфиг.
XrayMapping? _hysteria2(Map<String, dynamic> o) {
  final s = o['settings'] as Map? ?? const {};
  final stream = _streamOf(o);
  final hy = stream['hysteriaSettings'] as Map? ?? const {};

  final version =
      (hy['version'] as num?)?.toInt() ?? (s['version'] as num?)?.toInt() ?? 2;
  if (version != 2) return null; // hysteria v1 — своего Spec у нас нет

  final server = s['address']?.toString() ?? '';
  if (server.isEmpty) return null;
  final port = (s['port'] as num?)?.toInt() ?? _kDefaultPort;

  final body = <String, dynamic>{
    'type': 'hysteria2',
    'server': server,
    'server_port': port,
    'password': hy['auth']?.toString() ?? '',
  };
  // QUIC-протокол без TLS не бывает: блок обязателен, даже когда
  // `security` записи о нём молчит (прежняя ветка ставила тот же дефолт).
  //
  // `quic_has_no_utls_or_reality` (`hysteria.json` mapper) — у QUIC нет
  // TLS-рукопожатия, которое формировали бы uTLS или REALITY, и блоков этих в
  // теле не бывает. Снимает их МАППЕР, а не санитайзер: прежняя ветка
  // отпечаток тоже читала, но `Hysteria2Spec` его не эмитил — то есть в теле
  // его не было никогда. Отдай маппер эти блоки судье, узел получил бы код
  // `tls_not_applicable_quic` там, где раньше стояла тишина.
  final tls = _tls(stream, server) ?? <String, dynamic>{'enabled': true};
  tls.remove('utls');
  tls.remove('reality');
  body['tls'] = tls;
  return XrayMapping(body: body, tagScheme: 'hy2');
}

/// SOCKS-outbound: самостоятельным узлом подписки не становится (§321), он
/// бывает только звеном цепочки `dialerProxy`.
XrayMapping? _socks(Map<String, dynamic> o) {
  final s = _firstServer(o);
  if (s == null) return null;
  final server = s['address']?.toString() ?? '';
  if (server.isEmpty) return null;
  final port = (s['port'] as num?)?.toInt() ?? 1080;
  final users = (s['users'] as List?)?.cast<Map>() ?? const [];
  final user = users.isEmpty ? const {} : users.first;
  final username = user['user']?.toString() ?? '';
  final password = user['pass']?.toString() ?? '';

  return XrayMapping(body: <String, dynamic>{
    'type': 'socks',
    'server': server,
    'server_port': port,
    if (username.isNotEmpty) 'username': username,
    if (password.isNotEmpty) 'password': password,
  });
}

/// Написание `security` vmess — то же правило, что у маппера ссылки
/// (`vmess_mapper.dart`, `_securitySpelling`). Второй копии суждения тут нет:
/// годность значения судит реестр, здесь только перевод написания и
/// обязательный ключ (см. вызывающего).
String _vmessSecuritySpelling(String raw) {
  final s = raw.trim().toLowerCase();
  if (s.isEmpty || s == 'null' || s == 'undefined') return 'auto';
  if (s == 'chacha20-ietf-poly1305') return 'chacha20-poly1305';
  return s;
}

Map? _firstVnext(Map<String, dynamic> o) {
  final vnext = (o['settings']?['vnext'] as List?)?.cast<Map>();
  return vnext == null || vnext.isEmpty ? null : vnext.first;
}

Map? _firstServer(Map<String, dynamic> o) {
  final servers = (o['settings']?['servers'] as List?)?.cast<Map>();
  return servers == null || servers.isEmpty ? null : servers.first;
}

/// §453 — Xray держит keep-alive в `sockopt` целыми секундами. Перевод
/// написания (число → `30s`), а не суждение: значения судит `dialer.json`.
void _putKeepAlive(Map<String, dynamic> body, Map stream) {
  final sockopt = stream['sockopt'];
  if (sockopt is! Map) return;
  final idle = (sockopt['tcpKeepAliveIdle'] as num?)?.toInt() ?? 0;
  final interval = (sockopt['tcpKeepAliveInterval'] as num?)?.toInt() ?? 0;
  // ЛЮБОЕ отрицательное значит `SO_KEEPALIVE=0` (`sockopt_linux.go:143`), то
  // есть keep-alive выключен целиком — у ядра это `disable_tcp_keep_alive`.
  // Ноль = «не задано». Правило зеркалит `tcpKeepAliveFromXraySockopt`, у
  // которого этот вход и жил.
  if (idle < 0 || interval < 0) body['disable_tcp_keep_alive'] = true;
  if (idle > 0) body['tcp_keep_alive'] = '${idle}s';
  if (interval > 0) body['tcp_keep_alive_interval'] = '${interval}s';
}

/// TLS-блок тела из `streamSettings`.
///
/// Маппер решает только НАЛИЧИЕ блока и написание его полей. Годность `pbk`
/// (`format: base64_32`), форму `short_id` (`hex`, чётная длина), значение
/// `key_share` и `fingerprint` судит санитайзер — рукописные
/// `isValidRealityPublicKey`, `normalizeRealityShortId` и
/// `normalizeTlsFingerprint` с этого входа сняты.
Map<String, dynamic>? _tls(Map stream, String server, {bool reality = false}) {
  final security = (stream['security']?.toString() ?? '').toLowerCase().trim();
  // `security_none_no_tls` (SPEC 045) — блока нет.
  if (security == 'none' || security.isEmpty) return null;

  if (security == 'reality' && reality) {
    final r = stream['realitySettings'] as Map? ?? const {};
    final pbk = (r['publicKey']?.toString() ?? '').trim();
    final sid = (r['shortId']?.toString() ?? '').trim();
    final sni = r['serverName']?.toString() ?? server;
    final fp = (r['fingerprint']?.toString() ?? '').trim();
    final tls = <String, dynamic>{
      'enabled': true,
      'server_name': sni.isEmpty ? server : sni,
    };
    // REALITY требует uTLS-блок («uTLS is required by reality client» —
    // fatal при создании outbound), поэтому пустой отпечаток здесь получает
    // дефолт ядра. Это НАЛИЧИЕ блока, а не суждение о значении: написанное
    // значение уезжает как есть и судится реестром.
    tls['utls'] = <String, dynamic>{
      'enabled': true,
      'fingerprint': fp.isEmpty ? 'chrome' : utlsSpellingToFamily(fp),
    };
    // `pbk_makes_reality_block` — блок появляется при НАЛИЧИИ ключа; годность
    // ключа судит реестр (`base64_32`, код `reality_pbk_invalid`).
    if (pbk.isNotEmpty) {
      // `realitySettings.keyShare` НЕ переносится — так же, как не переносила
      // прежняя ветка. На входе sing-box поле читается (§457,
      // `_realityKeyShare`), на Xray — никогда не читалось, и это разрыв
      // входов, а не решение: узел с `keyShare: "hybrid"` уезжает без него
      // (SPEC 083 — гибридный key share решает, примет ли REALITY-сервер
      // Xray ≥ v26.9.8 рукопожатие). Переносить его здесь значило бы сдвинуть
      // ТЕЛО и identity живых узлов, а корпус этого входа такого кейса не
      // несёт — вопрос вынесен лаунчеру (спека 472, 14.5).
      tls['reality'] = <String, dynamic>{
        'enabled': true,
        'public_key': pbk,
        if (sid.isNotEmpty) 'short_id': sid,
      };
    }
    return tls;
  }

  if (security == 'tls') {
    final t = stream['tlsSettings'] as Map? ?? const {};
    final sni = t['serverName']?.toString() ?? server;
    final fp = (t['fingerprint']?.toString() ?? '').trim();
    final tls = <String, dynamic>{
      'enabled': true,
      'server_name': sni.isEmpty ? server : sni,
    };
    if (t['allowInsecure'] == true) tls['insecure'] = true;
    // `tlsSettings.alpn` НЕ переносится — так же, как не переносила прежняя
    // ветка. Перенести его значило бы поменять ТЕЛО и identity живых узлов
    // (у Xray-подписок ALPN встречается часто), а шаг переезда меняет
    // маршрут, а не состав полей. Это долг к списку §473-образных: правило
    // одного входа, которого нет у остальных. Заводить его надо отдельным
    // решением, вместе с ответом, что делать со сдвигом identity.
    // `utls_xray_hello_names` — перевод написания; мусор уедет как есть и
    // получит `utls_fp_unknown` от санитайзера.
    if (fp.isNotEmpty) {
      tls['utls'] = <String, dynamic>{
        'enabled': true,
        'fingerprint': utlsSpellingToFamily(fp),
      };
    }
    return tls;
  }

  // Прочее написание `security` блока не даёт — как и прежняя ветка.
  return null;
}

/// Результат перевода транспорта: карта плюс то, чего в теле не выразить.
final class _XrayTransport {
  const _XrayTransport(
    this.map, {
    this.warnings = const [],
    this.wsEarlyDataHeaderImplicit = false,
  });

  final Map<String, dynamic>? map;
  final List<NodeWarning> warnings;
  final bool wsEarlyDataHeaderImplicit;
}

/// `streamSettings` → карта `transport` тела.
///
/// Правило `transport_name_dialect` реестра: у Xray транспорт зовётся своим
/// именем (`h2`, `splithttp`), и настройки лежат в своей секции.
_XrayTransport _transport(Map stream) {
  final net = (stream['network']?.toString() ?? 'tcp').toLowerCase().trim();
  switch (net) {
    case 'ws':
      final ws = stream['wsSettings'] as Map? ?? const {};
      final headers = (ws['headers'] as Map?)?.cast<String, dynamic>();
      final host = headers?['Host']?.toString() ?? '';
      // §103 D-016(в) — ключа `path` не было вовсе → путь не задан.
      final hasPath = ws.containsKey('path');
      // `ws_early_data_path_suffix` — §303: Xray кладёт early data хвостом
      // пути (`/x?ed=2560`), в sing-box это отдельные поля, а хвост в пути
      // даёт 404.
      final (splitPath, edFromPath) =
          splitEarlyDataPath(ws['path']?.toString() ?? '');
      final path = hasPath ? splitPath : '';
      // §320 — Xray-конфиги несут early data и плоскими полями `ed`/`eh`;
      // хвост пути в приоритете.
      final edField = ws['ed'];
      final ed = edFromPath ??
          (edField is num
              ? edField.toInt()
              : int.tryParse(edField?.toString().trim() ?? ''));
      var eh = ws['eh']?.toString().trim() ?? '';
      // §103 D-008 — дефолт заголовка применим ТОЛЬКО когда early data взята
      // из хвоста пути (Go: applyWSEarlyData), не из плоских полей.
      var ehImplicit = false;
      if (eh.isEmpty && edFromPath != null) {
        eh = 'Sec-WebSocket-Protocol';
        ehImplicit = true;
      }
      final warnings = <NodeWarning>[
        if (edFromPath != null) WsEarlyDataConvertedWarning(edFromPath),
      ];
      return _XrayTransport(
        <String, dynamic>{
          'type': 'ws',
          if (hasPath) 'path': path,
          if (host.isNotEmpty) 'headers': <String, dynamic>{'Host': host},
          if (ed != null && ed > 0) 'max_early_data': ed,
          if (ed != null && ed > 0 && eh.isNotEmpty)
            'early_data_header_name': eh,
        },
        warnings: warnings,
        wsEarlyDataHeaderImplicit: ehImplicit,
      );
    case 'grpc':
      final g = stream['grpcSettings'] as Map? ?? const {};
      // §468 — значение идёт ядру как есть, ведущий «/» разбирает ядро само.
      final sn = g['serviceName']?.toString() ?? '';
      return _XrayTransport(<String, dynamic>{
        'type': 'grpc',
        if (sn.isNotEmpty) 'service_name': sn,
      });
    case 'http':
    case 'h2':
      final h = stream['httpSettings'] as Map? ?? const {};
      final hosts = <String>[
        for (final e in (h['host'] as List?) ?? const []) e.toString(),
      ];
      final path = h['path']?.toString() ?? '/';
      return _XrayTransport(<String, dynamic>{
        'type': 'http',
        if (path.isNotEmpty && path != '/') 'path': path,
        if (hosts.isNotEmpty) 'host': hosts,
      });
    // §463 — `splithttp` = прежнее имя `xhttp` в Xray; настройки лежат под
    // своим именем секции, поэтому читаем обе.
    case 'splithttp':
    case 'xhttp':
      final x =
          (stream['xhttpSettings'] ?? stream['splithttpSettings']) as Map? ??
              const {};
      // §399 — состав полей общий с URI-веткой. Xray допускает обе раскладки:
      // плоско и вложенным объектом `extra`; при конфликте выигрывает `extra`.
      return _XrayTransport(
        xhttpMapFromScalars(
          mergeXhttpExtra(xhttpScalarsFromJson(x), raw: x['extra']),
        ),
      );
    default:
      return const _XrayTransport(null);
  }
}
