import '../../../models/node_spec.dart';
import '../../../models/node_warning.dart';
import '../../app_log.dart';
import '../ini_parser.dart';
import '../uri_utils.dart';

// ════════════════════════════════════════════════════════════════════════════
// WireGuard (URI form)
// ════════════════════════════════════════════════════════════════════════════

WireguardSpec? parseWireguardUri(String uri) {
  // §450 — вторая форма: после схемы не `key@host:port?…`, а base64 целого
  // wg-quick (панели с AmneziaWG 3.1). Штатный разбор видел бы в base64
  // «хост» без ключа и ронял узел молча.
  final fromConf = _parseWgConfBase64Link(uri);
  if (fromConf != null) return fromConf;

  // §106 — сырой `/` в base64-ключе (userInfo) ломает Uri.tryParse.
  final p = Uri.tryParse(encodeUserInfoSlashes(uri));
  if (p == null || p.host.isEmpty) return null;

  final q = p.queryParameters;
  final port = p.hasPort ? p.port : 51820;

  // В v1 private_key хранится в userInfo. В некоторых clients — в query.
  var privateKeyRaw = p.userInfo.isEmpty
      ? (q['privatekey'] ?? q['private_key'] ?? '')
      : Uri.decodeComponent(p.userInfo);
  privateKeyRaw = privateKeyRaw.trim();
  if (privateKeyRaw.isEmpty) return null;
  // SPEC 103 D-023/D-030 — мусорный или неканонический ключ (не ровно 32
  // байта base64, любая из 4 форм) валит `sing-box check` целиком (класс
  // `pbk=enabled`) или даёт разные identity-хеши одной ноды; эталон Go
  // normalizeWGKey — нода отбрасывается, не эмитится как есть.
  final privateKey = normalizeWGKey(privateKeyRaw);
  if (privateKey == null) return null;

  final publicKeyRaw = q['publickey'] ?? q['public_key'] ?? '';
  if (publicKeyRaw.isEmpty) return null;
  final publicKey = normalizeWGKey(publicKeyRaw);
  if (publicKey == null) return null;

  final address = q['address'] ?? '';
  if (address.isEmpty) return null;

  // §106 — bare IP → CIDR (/32 | /128), иначе sing-box не грузит endpoint.
  final localAddresses = address
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .map(ensureCidr)
      .toList();

  final allowedIpsRaw = q['allowedips'] ?? q['allowed_ips'] ?? '0.0.0.0/0, ::/0';
  final allowedIps = allowedIpsRaw
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .map(ensureCidr)
      .toList();

  // Канон — только `presharedkey` без подчёркивания: единственный ключ,
  // который читает Go (node_parser_wireguard.go: queryParamPreservePlus/
  // q.Get("presharedkey"), без "preshared_key"-алиаса, в отличие от
  // privatekey/private_key — тот алиас Go добавил намеренно, D-021).
  final pskRaw = q['presharedkey'] ?? '';
  // SPEC 103 D-023/D-030 — тот же ключевой guard, что private/public key;
  // пустой psk остаётся пустым (опционален), мусорный/невалидной длины —
  // нода отбрасывается (эталон Go normalizeWGKey на presharedkey).
  String psk;
  if (pskRaw.isEmpty) {
    psk = '';
  } else {
    final normalized = normalizeWGKey(pskRaw);
    if (normalized == null) return null;
    psk = normalized;
  }
  // §421 — число как раньше; AWG3-диапазон `25-35` — строкой.
  final keepalive = parseWgKeepalive(q['keepalive']);

  // §025 — WARP client_id: `reserved=b0,b1,b2` или base64 `client_id`.
  final reservedRaw = q['reserved'] ?? q['client_id'] ?? '';
  final reserved = reservedRaw.isEmpty ? null : parseReserved(reservedRaw);

  final peer = WireguardPeer(
    publicKey: publicKey,
    preSharedKey: psk,
    endpointHost: p.host,
    endpointPort: port,
    allowedIps: allowedIps,
    persistentKeepalive: keepalive,
    reserved: reserved,
  );

  final label = decodeFragment(p.fragment);
  final tag = tagFromLabel(label, 'wireguard', p.host, port);

  // §097/SPEC 103 D-026 — AWG: клиентский MTU клампим до 1280 (awgClampMtu);
  // обычный WG без явного mtu= в URI поле не эмитим вовсе — ядро само
  // ставит 1408 (transport/wireguard/endpoint.go), свой дефолт спорит с ним
  // и ломает identity-хеш (CANON §2.4).
  // SPEC 103 `awg_header_invalid` — битый magic-header снимается, ядро берёт
  // WireGuard-дефолт: handshake уходит, ответа нет (тихо сломанный узел).
  final badHeaders = <(String, String)>[];
  final badAwg3 = <(String, String)>[];
  // §421 — ключ защиты заголовка читаем с сохранением сырого `+`
  // (Uri.queryParameters превратил бы его в пробел → «not base64» → узел
  // потерян); эталон Go queryParamPreservePlus.
  final headerKeyParam = Awg.awg3Param(Awg.headerKey);
  final headerKeyRaw = queryParamPreservePlus(p, headerKeyParam);
  final awgQuery = headerKeyRaw == null
      ? q
      : <String, String>{...q, headerKeyParam: headerKeyRaw};
  final awg =
      Awg.fromQuery(awgQuery, badHeaders: badHeaders, badAwg3: badAwg3);
  // §421 — узел с битым ключом защиты / коротким паддингом выбрасывается:
  // ядро отвергло бы конфиг целиком (SPEC 123 §2). Причина — в debug-лог.
  if (awg != null) {
    final dropReason = awg3NodeError(awg);
    if (dropReason != null) {
      AppLog.I.debug('$tag: ${dropReason.renderEn()}');
      return null;
    }
  }
  final rawMtu = int.tryParse(q['mtu'] ?? '');
  // §421 — AWG3-маркер (любой AWG3-параметр или диапазонный keepalive) сам
  // делает узел AmneziaWG даже без AWG2-полей, и кламп до 1280 действует так
  // же: экспорт Amnezia несёт mtu 1376, но у владельца на нём данные не шли,
  // а на 1280 туннель заработал (решение 2026-09-05, SPEC 123 / Go
  // hasAWGParams).
  final isAwg = awg != null || Awg.hasAwg3Params(q);
  final mtu = isAwg ? awgClampMtu(rawMtu, tag) : rawMtu;

  return WireguardSpec(
    id: newUuidV4(),
    warnings: [
      for (final (field, value) in badHeaders)
        AwgHeaderInvalidWarning(field, value),
      for (final (field, value) in badAwg3)
        Awg3FieldInvalidWarning(field, value),
      if (awg != null && awg.randomTrailersWithWideHeaders)
        const Awg3RandomTrailersWideHeadersWarning(),
    ],
    tag: tag,
    label: label,
    server: p.host,
    port: port,
    rawSource: uri,
    privateKey: privateKey,
    localAddresses: localAddresses,
    peers: [peer],
    mtu: mtu,
    awg: awg, // §097 — AmneziaWG2 obfuscation params (null = WG)
  );
}


// ════════════════════════════════════════════════════════════════════════════
// §450 — awg://<base64 .conf>#label (вторая форма share-link)
// ════════════════════════════════════════════════════════════════════════════

/// Разбор ссылки, в которой после схемы лежит base64 целого wg-quick
/// (`[Interface]`…`[Peer]`), а не `key@host:port?…`. Эталон Go
/// `parseWGConfBase64Link` (контракт §20.1):
///
/// 1. payload — между `://` и `#`; признак формы — в нём нет ни `@`, ни `:`,
///    ни `?` (base64 этих символов не содержит, а `key@host:port?…` несёт);
/// 2. декодирование — те же 4 варианта base64, что везде ([decodeBase64Safe]);
/// 3. текст обязан содержать `[Interface]`, иначе форма не наша — вызывающий
///    идёт штатным путём и отдаёт штатную ошибку;
/// 4. конвертация — ТЕМ ЖЕ [parseWireguardIni], что вставленный `.conf`:
///    валидация ключей, MTU-клэмп и AWG2/3-поля остаются одной точкой;
/// 5. метка = фрагмент; без фрагмента — хост Endpoint (как `ConvertWGConfText`
///    в Go), а не общий фолбэк `WireGuard`.
///
/// `null` = форма не распознана (не ошибка): вызывающий продолжает обычный
/// разбор URI.
WireguardSpec? _parseWgConfBase64Link(String uri) {
  final sep = uri.indexOf('://');
  if (sep < 0) return null;
  var payload = uri.substring(sep + 3);
  var fragment = '';
  final hash = payload.indexOf('#');
  if (hash >= 0) {
    fragment = payload.substring(hash + 1);
    payload = payload.substring(0, hash);
  }
  payload = payload.trim();
  // Форма `key@host:port?…` — не наш случай.
  if (payload.isEmpty || payload.contains(RegExp(r'[@:?]'))) return null;

  final raw = decodeBase64Safe(payload);
  if (raw == null) return null;
  final text = utf8Lossy(raw);
  // Не .conf — пусть падает штатно (parse_error), а не превращается в узел.
  if (!text.contains('[Interface]')) return null;

  // Один share-link = один узел: берём первый [Interface]-блок.
  final conf = _firstWgConfBlock(text);
  if (conf == null) return null;

  final label = decodeFragment(fragment);
  final hint = label.isNotEmpty ? label : _wgEndpointHost(conf);
  final spec = parseWireguardIni(conf, nameHint: hint);
  if (spec == null) return null;
  // Источник узла (вкладка Source, identity-хеш) — исходная ссылка, а не
  // синтетический `wireguard://` из INI-конвертера. `rawIni` не несём: узел
  // пришёл ссылкой, а не вставленным файлом.
  return WireguardSpec(
    id: spec.id,
    tag: spec.tag,
    label: spec.label,
    server: spec.server,
    port: spec.port,
    rawSource: uri,
    privateKey: spec.privateKey,
    localAddresses: spec.localAddresses,
    peers: spec.peers,
    mtu: spec.mtu,
    awg: spec.awg,
    warnings: spec.warnings,
  );
}

/// Первый `[Interface]`-блок текста: от первого `[Interface]` до следующего
/// (второй профиль в том же payload игнорируем — контракт §20.1).
String? _firstWgConfBlock(String text) {
  final start = text.indexOf('[Interface]');
  if (start < 0) return null;
  final next = text.indexOf('[Interface]', start + '[Interface]'.length);
  final block = next < 0 ? text.substring(start) : text.substring(start, next);
  return block.trim().isEmpty ? null : block;
}

/// Хост из `[Peer].Endpoint` — метка узла, когда фрагмента нет (эталон Go
/// `wgEndpointHost`). Голый IPv6 в `[…]` разворачивается; порт снимается
/// только при однозначном `host:port`.
String _wgEndpointHost(String conf) {
  for (final line in conf.split(RegExp(r'\r?\n'))) {
    final t = line.trim();
    final idx = t.indexOf('=');
    if (idx < 0) continue;
    if (t.substring(0, idx).trim().toLowerCase() != 'endpoint') continue;
    final v = t.substring(idx + 1).trim();
    if (v.isEmpty) return '';
    if (v.startsWith('[')) {
      final close = v.indexOf(']');
      return close > 0 ? v.substring(1, close) : v;
    }
    final lastColon = v.lastIndexOf(':');
    // Несколько ':' без скобок — голый IPv6, порт неотличим (§219).
    if (lastColon > 0 && v.indexOf(':') == lastColon) {
      return v.substring(0, lastColon);
    }
    return v;
  }
  return '';
}
