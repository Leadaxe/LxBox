import 'dart:convert';

import '../../models/node_warning.dart';
import '../../models/tls_spec.dart';
import '../../models/transport_spec.dart';
import 'uri_utils.dart';

/// Разбор query-параметров URI в `TransportSpec?`.
///
/// sing-box поддерживает: http | ws | quic | grpc | httpupgrade.
/// XHTTP → `XhttpTransport` (fallback в toSingbox).
///
/// [networkOverride] — если транспорт лежит под другим ключом, чем `type`
/// (VMess хранит в `network`). [defaultHost] — fallback для h2 когда
/// `q['host']`/`q['sni']` пусты.
/// [warnings] — узловой список: конверсия Xray-хвоста `?ed=N` в пути ws
/// получает `ws_early_data_converted` (contract/registry/warnings.json).
TransportSpec? parseTransport(
  Map<String, String> q, {
  String? networkOverride,
  String? defaultHost,
  List<NodeWarning>? warnings,
}) {
  var typ = ((networkOverride ?? q['type']) ?? '').toLowerCase().trim();
  final headerType = (q['headerType'] ?? '').toLowerCase().trim();

  if ((typ == 'raw' || typ == 'tcp') && headerType == 'http') {
    final path = q['path'] ?? '/';
    final host = q['host'] ?? '';
    return HttpTransport(
      path: path,
      hosts: host.isNotEmpty ? [host] : const [],
    );
  }

  switch (typ) {
    case 'ws':
      // §303 — `?ed=N` в пути = early data (Xray), а не часть пути.
      // §320 — путь мог прийти дважды percent-кодированным (`/%2Fassignment`);
      // снимаем остаток ДО срезки хвоста, иначе `%3Fed%3D2560` не распознается.
      // §103 D-016(в) — параметр отсутствовал в URI вовсе → путь остаётся ''
      // (не эмитим); если он БЫЛ (даже как явный `path=/`), пропускаем через
      // splitEarlyDataPath как обычно (та функция уже нормализует '' → '/'
      // для случая, когда путь стал пустым ПОСЛЕ среза `?ed=` хвоста).
      final pathParamPresent = q.containsKey('path');
      final (splitPath, edFromPath) =
          splitEarlyDataPath(decodeResidualPercent(q['path'] ?? ''));
      final path = pathParamPresent ? splitPath : '';
      var host = (q['host'] ?? '').trim();
      if (host.isEmpty) host = (q['sni'] ?? '').trim();
      if (host.isEmpty) host = (q['obfsParam'] ?? '').trim();
      // §320 — вторая форма early data: плоские `ed`/`eh` (хвост пути в
      // приоритете — он адресует конкретный путь, а не ссылку целиком).
      final ed = edFromPath ?? _positiveInt(q['ed']);
      // `eh` без `ed` — не сирота, а ничто: режим early data ядро включает по
      // `max_early_data > 0`, имя заголовка без размера не значит ничего.
      var eh = ed == null ? null : _nonEmpty(q['eh']);
      // §103 D-008 / IDENTITY.md §3 — Xray-форма `?ed=N` хвостом пути БЕЗ
      // явного `eh`: Go подставляет дефолтный заголовок `Sec-WebSocket-
      // Protocol` в момент разбора этого самого хвоста (applyWSEarlyData,
      // node_parser_transport.go:528-536) — только для path-tail формы,
      // НЕ для плоских ed/eh (те Go вообще не читает). `implicit` — флаг,
      // а не совпадение строки: явный `eh=Sec-WebSocket-Protocol` не должен
      // молча выглядеть «неявным» на round-trip.
      var ehImplicit = false;
      if (eh == null && edFromPath != null) {
        eh = 'Sec-WebSocket-Protocol';
        ehImplicit = true;
      }
      // SPEC 103 `ws_early_data_converted` — путь в конфиг уехал НЕ буквально.
      // Ровно path-tail форма: плоские `ed=`/`eh=` конверсией не считаются
      // (Go: noteWSEarlyDataConverted читает только хвост пути).
      if (edFromPath != null) {
        warnings?.add(WsEarlyDataConvertedWarning(edFromPath));
      }
      return WsTransport(
        path: path,
        host: host,
        earlyDataHeaderImplicit: ehImplicit,
        maxEarlyData: ed,
        earlyDataHeaderName: eh,
      );
    case 'grpc':
      final sn = (q['serviceName'] ?? q['service_name'] ?? q['path'] ?? '').trim();
      return GrpcTransport(serviceName: sn);
    case 'http':
      final path = q['path'] ?? '/';
      final host = (q['host'] ?? '').trim();
      return HttpTransport(
        path: path,
        hosts: host.isNotEmpty ? [host] : const [],
      );
    case 'h2':
      // SPEC 103 CANON — `h2` разрешён ТОЛЬКО когда пришёл из VMess `net`
      // ([networkOverride], node_parser_vmess.go: net=h2 маппится в
      // transport type=http с фолбэком host на sni/server,
      // node_parser_core.go:679-694). Голый `type=h2` в query VLESS/Trojan
      // share-URI Go не распознаёт вовсе (uriTransportFromQuery — нет кейса
      // "h2", падает в default → транспорт не эмитится); тут — то же самое.
      if (networkOverride == null) return null;
      final path = q['path'] ?? '/';
      var host = (q['host'] ?? '').trim();
      if (host.isEmpty) host = (q['sni'] ?? '').trim();
      if (host.isEmpty && defaultHost != null) host = defaultHost;
      return HttpTransport(
        path: path,
        hosts: host.isNotEmpty ? [host] : const [],
      );
    case 'httpupgrade':
      // §303 — early data у httpupgrade в sing-box нет: хвост срезаем, ed
      // отбрасываем (иначе он уедет в путь и даст 404). §320 — включая форму
      // плоским `ed`/`eh`: их здесь просто не читаем.
      // §103 D-016(в) — как и у ws: параметр отсутствовал вовсе → путь ''.
      final hasPathParam = q.containsKey('path');
      final (splitPath, _) =
          splitEarlyDataPath(decodeResidualPercent(q['path'] ?? ''));
      final path = hasPathParam ? splitPath : '';
      // §103 D-016(в) — Go НЕ подставляет sni как фолбэк host для httpupgrade
      // (node_parser_transport.go:183-185, в отличие от ws): только явный
      // `host=`. Фолбэк давал разные конфиги/identity-хеши на пустом host.
      final host = (q['host'] ?? '').trim();
      return HttpUpgradeTransport(path: path, host: host);
    case 'xhttp':
      // §097/§127 — нативный xhttp + расширенные поля Xray splithttp (SPEC 002
      // v2). Ключи читаем в обеих формах: camelCase (Xray URI) и snake_case
      // (sing-box). Плюс параметр `extra` (URL-encoded JSON) с доп. полями.
      // §399 — состав полей общий с JSON-ветками (xhttpFromMap).
      return xhttpFromMap(mergeXhttpExtra(q));
    case 'raw':
    case 'tcp':
    case '':
      return null;
    default:
      return null;
  }
}

/// §303 — разделить Xray-путь вида `/api/v2/channel?ed=2560` на чистый путь и
/// значение early data. Хвост `?…` не является частью пути ни для одного
/// транспорта sing-box — срезаем всегда, даже если `ed` невалиден или его нет.
///
/// Возвращает `(path, maxEarlyData)`; `maxEarlyData == null`, когда `ed`
/// отсутствует или не является положительным целым.
(String, int?) splitEarlyDataPath(String raw) {
  final qIdx = raw.indexOf('?');
  if (qIdx < 0) return (raw.isEmpty ? '/' : raw, null);

  var path = raw.substring(0, qIdx);
  if (path.isEmpty) path = '/';

  // Битый percent-encoding в хвосте роняет splitQueryString — путь всё равно
  // должен быть очищен, поэтому падение гасим до «ed отсутствует».
  // splitQueryString бросает ArgumentError на битом percent-encoding.
  String? ed;
  try {
    ed = Uri.splitQueryString(raw.substring(qIdx + 1))['ed'];
  } catch (_) {
    ed = null;
  }
  final parsed = ed == null ? null : int.tryParse(ed.trim());
  return (path, parsed != null && parsed > 0 ? parsed : null);
}

/// §320 — снять остаточное percent-кодирование пути. Агрегаторы отдают
/// `path=%2F%252Fassignment`: `Uri.queryParameters` декодит ровно один раз, и
/// в путь уходит `/%2Fassignment` вместо `//assignment` → сервер даёт 404.
///
/// Тот же приём, что в `_normalizeAlpn` (§151), но БЕЗ проверки валидности:
/// путь может содержать что угодно — эмодзи (`path=Telegram🇨🇳`), двойные
/// слэши (`//assignment`), `@`. Здесь только доводим декодирование до конца,
/// ничего не отбрасывая. До 2 проходов: больше — почти наверняка мусор.
String decodeResidualPercent(String raw) {
  var v = raw;
  var guard = 0;
  while (_percentSeq.hasMatch(v) && guard < 2) {
    final decoded = Uri.tryParse('x://x?a=$v')?.queryParameters['a'];
    if (decoded == null || decoded == v) break;
    v = decoded;
    guard++;
  }
  return v;
}

/// Положительное целое из query-значения; иначе `null` (0/отрицательное/мусор).
int? _positiveInt(String? v) {
  final n = int.tryParse((v ?? '').trim());
  return n != null && n > 0 ? n : null;
}

/// Непустая обрезанная строка; иначе `null`.
String? _nonEmpty(String? v) {
  final s = (v ?? '').trim();
  return s.isEmpty ? null : s;
}

/// §399 — единственное место, где перечислены имена полей XHTTP.
///
/// Принимает **уже слитую** карту (плоские ключи + `extra`, см.
/// [mergeXhttpExtra]) и читает каждое поле в обеих формах: camelCase (Xray) и
/// snake_case (sing-box), camelCase в приоритете.
///
/// Вызывается из трёх веток парсера — URI (`parseTransport`), Xray-JSON и
/// sing-box-JSON (`json_parsers.dart`). Поле, добавленное сюда, появляется во
/// всех трёх сразу; расхождение схем — дефект (§399 R1).
///
/// [headers] отдельным параметром: это `Map`, а не скаляр, и в карту полей не
/// укладывается (в URI-ветке его нет вовсе).
///
/// §217 — поля читаются **дословно**. Нормализацию против правил ядра
/// (`normalizeMeta`, `transport/v2rayxhttp/meta.go`) делает
/// `XhttpTransport.toSingbox`, где есть канал NodeWarning для ⚠️ в подписке.
XhttpTransport xhttpFromMap(
  Map<String, String> m, {
  Map<String, String> headers = const {},
}) {
  // path: срезать `?…`-хвост (реальные ноды: path=/x?ed=2048 — хвост не путь).
  // §303 — общий хелпер; early data у xhttp нет, значение отбрасываем.
  // SPEC 103 CANON §2.4 — без query-параметра path не эмитим дефолт '/'
  // (Go: xhttpCleanPath, node_parser_transport.go) — только явный path=
  // доходит до конфига, включая явный path=%2F → "/". splitEarlyDataPath
  // сама нормализует '' → '/' (для случая, когда путь стал пустым ПОСЛЕ
  // среза ?ed= хвоста) — поэтому здесь, как и у ws/httpupgrade, отсутствие
  // ключа проверяем СНАРУЖИ, до вызова хелпера.
  final hasPathKey = m.containsKey('path');
  final (splitPath, _) = splitEarlyDataPath(m['path'] ?? '');
  final path = hasPathKey ? splitPath : '';

  // §103 D-016(в) — Go читает host ТОЛЬКО из явного host= (xhttpBuildTransport,
  // node_parser_transport.go:280-330) — никакого фолбэка на sni, в отличие
  // от ws. Фолбэк давал разные конфиги/identity-хеши на пустом host=.
  final host = (m['host'] ?? '').trim();

  return XhttpTransport(
    path: path,
    host: host,
    mode: (m['mode'] ?? '').trim(),
    xPaddingBytes: _pick(m, 'xPaddingBytes', 'x_padding_bytes'),
    noGrpcHeader: _truthy(m['noGRPCHeader'] ?? m['no_grpc_header']),
    headers: headers,
    sessionPlacement: _pick(m, 'sessionPlacement', 'session_placement'),
    sessionKey: _pick(m, 'sessionKey', 'session_key'),
    seqPlacement: _pick(m, 'seqPlacement', 'seq_placement'),
    seqKey: _pick(m, 'seqKey', 'seq_key'),
    uplinkDataPlacement: _pick(m, 'uplinkDataPlacement', 'uplink_data_placement'),
    uplinkDataKey: _pick(m, 'uplinkDataKey', 'uplink_data_key'),
    uplinkChunkSize: _pick(m, 'uplinkChunkSize', 'uplink_chunk_size'),
    uplinkHttpMethod: _pick(m, 'uplinkHTTPMethod', 'uplink_http_method'),
    xPaddingObfsMode:
        _truthy(m['xPaddingObfsMode'] ?? m['x_padding_obfs_mode']),
    xPaddingKey: _pick(m, 'xPaddingKey', 'x_padding_key'),
    xPaddingHeader: _pick(m, 'xPaddingHeader', 'x_padding_header'),
    xPaddingPlacement: _pick(m, 'xPaddingPlacement', 'x_padding_placement'),
    xPaddingMethod: _pick(m, 'xPaddingMethod', 'x_padding_method'),
    scMaxEachPostBytes:
        _normScRange(_pick(m, 'scMaxEachPostBytes', 'sc_max_each_post_bytes')),
    scMinPostsIntervalMs: _normScRange(
        _pick(m, 'scMinPostsIntervalMs', 'sc_min_posts_interval_ms')),
  );
}

/// §399 — JSON-объект `xhttpSettings` / sing-box `transport` → плоская карта
/// строк, пригодная для [xhttpFromMap].
///
/// Вложенные объекты и массивы отбрасываются: в карту полей укладываются только
/// скаляры. `extra` и `headers` вызывающая сторона достаёт до этого вызова —
/// у них своя обработка.
Map<String, String> xhttpScalarsFromJson(Map raw) {
  final out = <String, String>{};
  raw.forEach((k, v) {
    if (k is! String || v == null) return;
    if (v is Map || v is List) return;
    out[k] = _scalarToString(v);
  });
  return out;
}

/// §399 — слить `extra` в карту полей. `extra` в приоритете для своих ключей
/// (поведение Xray и URI-ветки).
///
/// [raw] — источник `extra`: строка с JSON (URI-ветка, где значение уже
/// percent-декодировано `Uri.queryParameters`) **или** уже распарсенный `Map`
/// (JSON-ветки). Отсутствующий, битый, не-объектный `extra` игнорируется —
/// узел остаётся рабочим на плоских полях (§399 R6).
Map<String, String> mergeXhttpExtra(Map<String, String> q, {Object? raw}) {
  final src = raw ?? q['extra'];
  if (src == null) return q;

  Map? decoded;
  if (src is Map) {
    decoded = src;
  } else {
    final s = src.toString().trim();
    if (s.isEmpty) return q;
    try {
      final parsed = jsonDecode(s);
      if (parsed is Map) decoded = parsed;
    } catch (_) {
      // Битый extra — игнорируем, узел живёт на плоских параметрах.
      return q;
    }
  }
  if (decoded == null) return q;

  final merged = Map<String, String>.from(q);
  decoded.forEach((k, v) {
    if (k is! String || v == null) return;
    if (v is Map || v is List) return;
    merged[k] = _scalarToString(v);
  });
  return merged;
}

/// JSON-скаляр → строка. `30.0` (double без дроби) → `"30"`; bool → `true`/
/// `false`; число/строка как есть.
///
/// §399 — `1000000.0` обязано стать `"1000000"`, а не `1e+06`: эмиттер кладёт
/// значение в конфиг как есть, и ядро не разберёт экспоненциальную запись.
String _scalarToString(Object v) {
  if (v is bool) return v ? 'true' : 'false';
  if (v is double && v == v.truncateToDouble()) {
    return v.toInt().toString();
  }
  return v.toString();
}

/// camelCase ИЛИ snake_case (camelCase в приоритете — Xray-форма URL).
String _pick(Map<String, String> q, String camel, String snake) =>
    (q[camel] ?? q[snake] ?? '').trim();

/// §127 §2.4 — `sc*`-поле: дробное число `30.0` → `"30"`. Транспорт примет и
/// `"N"`, и `"N-N"` — нормализуем только float-хвост, range-форму не трогаем.
String _normScRange(String v) {
  if (v.isEmpty) return v;
  final d = double.tryParse(v);
  if (d != null && d == d.truncateToDouble()) return d.toInt().toString();
  return v;
}

/// §320 — ECH из подписки НЕ включаем, только предупреждаем.
///
/// Xray-форма `ech=<name>+<resolver>` не несёт ECH-ключа: она означает «возьми
/// ECHConfigList из DNS HTTPS-записи имени `<name>`». Ключ привязан к тому
/// имени, у которого взят, — а подписки кладут туда публичные ECH-пробники
/// (`ip.gs`, `encryptedsni.com`). DEVICE-VERIFIED: DNS отдаёт для обоих ОДИН
/// конфиг с `public_name = cloudflare-ech.com`, тогда как SNI узла —
/// `www.ignitelimit.com`. Ключ не от того сервера ⇒ ClientHello зашифрован
/// впустую и рукопожатие падает.
///
/// Замер на устройстве (узел 172.67.149.60 `/in-pdr`): с `ech` — мёртв, без
/// `ech` — 723 мс. NekoBox этот параметр отбрасывает (в его базе 103 узла, ни
/// одного упоминания `ech`) и держит тот же узел живым на 23 мс.
///
/// Проверить пригодность до подключения нельзя: `public_name` виден только
/// после DNS-запроса, уже в рантайме ядра, а fallback на обычный TLS в sing-box
/// отсутствует (`ech.go` при неудаче возвращает ошибку, а не откат). Поэтому
/// единственное безопасное поведение — не включать, но сказать об этом.
///
/// `echfq` не читаем: Xray-шный pq-signature-schemes, парная опция ядра
/// помечена «legacy… removed in sing-box 1.13.0» и при `true` роняет конфиг.
void warnEchIgnored(Map<String, String> q, List<NodeWarning> warnings) {
  final raw = (q['ech'] ?? '').trim();
  if (raw.isEmpty || raw.toLowerCase() == 'none') return;
  warnings.add(EchIgnoredWarning(raw.split('+').first.trim()));
}

/// TLS parameters for VLESS (с поддержкой REALITY через `pbk`/`sid`).
TlsSpec parseVlessTls(
  Map<String, String> q,
  String server,
  int port, {
  List<NodeWarning>? warnings,
}) {
  // §320 — ECH из ссылки не включаем (ломает узлы), но предупреждаем.
  if (warnings != null) warnEchIgnored(q, warnings);
  final sec = (q['security'] ?? '').toLowerCase().trim();
  final pbk = (q['pbk'] ?? '').trim();

  if (sec == 'none') return TlsSpec.disabled;

  var sni = q['sni'] ?? q['peer'] ?? '';
  if (sni.isEmpty) sni = server;
  var fp = (q['fp'] ?? q['fingerprint'] ?? '').toLowerCase().trim();
  if (fp.isEmpty) fp = 'random';

  // §169 — REALITY только при ВАЛИДНОМ X25519-ключе, не «pbk непустой».
  // Мусор (pbk=enabled/true из битых подписок) → проваливаемся ниже в plain
  // TLS, а не отравляем reality.public_key и весь config.json. См.
  // isValidRealityPublicKey.
  if (isValidRealityPublicKey(pbk)) {
    // SPEC 103 `reality_short_id_invalid` — код ставится ДО нормализации:
    // после неё исходного значения уже нет, а узел уехал бы с чужим sid.
    final rawSid = q['sid'] ?? '';
    if (warnings != null && realityShortIdWouldDegrade(rawSid)) {
      warnings.add(RealityShortIdInvalidWarning(rawSid.trim()));
    }
    return TlsSpec(
      enabled: true,
      serverName: sni,
      fingerprint: fp,
      reality: RealitySpec(
        publicKey: pbk,
        shortId: normalizeRealityShortId(rawSid),
      ),
      insecure: isTlsInsecure(q),
      alpn: alpnFromQuery(q),
      );
  }

  if (sec == 'reality') {
    return TlsSpec(
      enabled: true,
      serverName: sni,
      fingerprint: fp,
      insecure: isTlsInsecure(q),
      alpn: alpnFromQuery(q),
      );
  }

  if (sec.isEmpty && plaintextVlessPorts.contains(port)) return TlsSpec.disabled;

  return TlsSpec(
    enabled: true,
    serverName: sni,
    fingerprint: fp,
    insecure: isTlsInsecure(q),
    alpn: alpnFromQuery(q),
  );
}

/// TLS parameters for Trojan.
TlsSpec parseTrojanTls(
  Map<String, String> q,
  String server, {
  List<NodeWarning>? warnings,
}) {
  if (warnings != null) warnEchIgnored(q, warnings);
  final sec = (q['security'] ?? '').toLowerCase().trim();
  if (sec == 'none') return TlsSpec.disabled;

  var sni = q['sni'] ?? q['peer'] ?? q['host'] ?? '';
  if (sni.isEmpty) sni = server;
  final fp = (q['fp'] ?? '').toLowerCase().trim();

  return TlsSpec(
    enabled: true,
    serverName: sni,
    fingerprint: fp.isEmpty ? null : fp,
    insecure: isTlsInsecure(q),
    alpn: alpnFromQuery(q),
  );
}

/// TLS parameters for VMess (активируется при `tls=tls` или `h2`).
TlsSpec parseVmessTls(Map<String, dynamic> cfg, String server, String net) {
  final tlsEnabled = cfg['tls'] == 'tls' || net == 'h2';
  if (!tlsEnabled) return TlsSpec.disabled;

  var sni = cfg['sni']?.toString() ?? '';
  if (sni.isEmpty) sni = cfg['host']?.toString() ?? '';
  if (sni.isEmpty) sni = server;

  final alpn = cfg['alpn']?.toString() ?? '';
  final fp = (cfg['fp']?.toString() ?? '').toLowerCase().trim();

  return TlsSpec(
    enabled: true,
    serverName: sni,
    fingerprint: fp.isEmpty ? null : fp,
    insecure: cfg['insecure'] == '1' || cfg['insecure'] == true,
    alpn: _normalizeAlpn(alpn), // §151 F2 — единый нормализатор ALPN
  );
}

/// §097 — query-bool: `true`/`1` → true (для `no_grpc_header`).
bool _truthy(String? v) {
  final s = (v ?? '').toLowerCase().trim();
  return s == 'true' || s == '1';
}

List<String> alpnFromQuery(Map<String, String> q) {
  return _normalizeAlpn(q['alpn'] ?? '');
}

/// §151 F2 / SPEC 103 vless/alpn_multiply_encoded — нормализация ALPN-списка
/// из сырого query/JSON значения.
///
/// Корень бага: некоторые подписки-агрегаторы шлют `alpn=http%252F1.1`
/// (двойное percent-кодирование, а на практике встречается и multiply —
/// `http%2525252F1.1`, вложенное 4 раза). `Uri.queryParameters` декодит ровно
/// один раз → остаётся `%XX`-мусор, и он уходил в `tls.alpn` ядра дословно
/// (валидный ALPN-id = `http/1.1`/`h2`/`h3`). Эталон Go
/// `normalizePercentDecodeLoop` (node_parser_transport.go) декодирует
/// БЕЗ ограничения проходов, до стабильной точки (`dec == s`) — элемент
/// валиден после раскрутки, канон не выбрасывает его. Здесь: split по
/// запятой, повторный decode до стабильности (с защитным потолком от
/// патологического ввода — реальные multiply-encoded подписки укладываются
/// в единицы проходов), и drop значений, которые после де-кода всё ещё
/// содержат `%` / пробелы / управляющие символы (не валидный protocol-id).
/// Корректные `h2`/`http/1.1`/`h3` не меняются.
final _percentSeq = RegExp(r'%[0-9A-Fa-f]{2}');
final _badAlpnChar = RegExp(r'[%\s\x00-\x1f]');

List<String> _normalizeAlpn(String raw) {
  if (raw.isEmpty) return const [];
  final out = <String>[];
  for (var e in raw.split(',')) {
    e = e.trim();
    if (e.isEmpty) continue;
    // Раскручиваем до стабильности, как Go normalizePercentDecodeLoop;
    // потолок в 16 проходов — защита от патологического ввода, не от
    // легитимного multiply-encoding (тот стабилизируется за 3-5 проходов).
    var guard = 0;
    while (_percentSeq.hasMatch(e) && guard < 16) {
      final decoded = Uri.tryParse('x://x?a=$e')?.queryParameters['a'];
      if (decoded == null || decoded == e) break;
      e = decoded.trim();
      guard++;
    }
    // Drop значения, не похожие на валидный ALPN-id.
    if (_badAlpnChar.hasMatch(e)) continue;
    out.add(e);
  }
  return out;
}

/// Emit TransportSpec → строка query для `toUri()`. Возвращает пары
/// `type`/`path`/`host`/`serviceName`, игнорируя пустые.
Map<String, String> transportToQuery(TransportSpec t) {
  switch (t) {
    case WsTransport(
        path: final p,
        host: final h,
        maxEarlyData: final ed,
        earlyDataHeaderName: final eh,
        earlyDataHeaderImplicit: final ehImplicit
      ):
      // §303 — early data возвращаем в URI тем же хвостом пути, каким она в
      // него пришла (`/x?ed=2560`), иначе round-trip её теряет.
      final withEd = ed == null ? p : '${p.isEmpty ? '/' : p}?ed=$ed';
      // §103 D-008 — дефолтный заголовок (подставленный при разборе `?ed=N`
      // хвоста, см. parseTransport) в URI не возвращаем: он подразумевается
      // самой path-tail формой, Go тоже никогда не пишет `eh=` обратно
      // (shareuri_helpers.go — только `?ed=N`, без eh). Явный `eh=`
      // (даже численно совпавший со значением по умолчанию) сохраняем.
      final ehForUri = ehImplicit ? null : eh;
      return {
        'type': 'ws',
        if (withEd.isNotEmpty && withEd != '/') 'path': withEd,
        if (h.isNotEmpty) 'host': h,
        // §320 — header-режим восстановим только парой с `ed` (в одиночку `eh`
        // при импорте игнорируется, вернуть его без размера = вернуть мусор).
        if (ed != null && ehForUri != null && ehForUri.isNotEmpty)
          'eh': ehForUri,
      };
    case GrpcTransport(serviceName: final sn):
      return {
        'type': 'grpc',
        if (sn.isNotEmpty) 'serviceName': sn,
      };
    case HttpTransport(path: final p, hosts: final hs):
      return {
        'type': 'http',
        if (p.isNotEmpty && p != '/') 'path': p,
        if (hs.isNotEmpty) 'host': hs.join(','),
      };
    case HttpUpgradeTransport(path: final p, host: final h):
      return {
        'type': 'httpupgrade',
        if (p.isNotEmpty && p != '/') 'path': p,
        if (h.isNotEmpty) 'host': h,
      };
    // §127 — пишем плоско camelCase, и только не-дефолтные значения
    // (URL_PARSING §8.3) — иначе URI раздувается, а round-trip даёт ту же
    // spec (на входе пустое поле == дефолтное поле).
    case XhttpTransport x:
      return {
        'type': 'xhttp',
        if (x.path.isNotEmpty && x.path != '/') 'path': x.path,
        if (x.host.isNotEmpty) 'host': x.host,
        if (x.mode.isNotEmpty) 'mode': x.mode,
        if (x.xPaddingBytes.isNotEmpty) 'xPaddingBytes': x.xPaddingBytes,
        if (x.noGrpcHeader) 'noGRPCHeader': 'true',
        if (x.sessionPlacement.isNotEmpty)
          'sessionPlacement': x.sessionPlacement,
        if (x.sessionKey.isNotEmpty) 'sessionKey': x.sessionKey,
        if (x.seqPlacement.isNotEmpty) 'seqPlacement': x.seqPlacement,
        if (x.seqKey.isNotEmpty) 'seqKey': x.seqKey,
        if (x.uplinkDataPlacement.isNotEmpty)
          'uplinkDataPlacement': x.uplinkDataPlacement,
        if (x.uplinkDataKey.isNotEmpty) 'uplinkDataKey': x.uplinkDataKey,
        if (x.uplinkChunkSize.isNotEmpty) 'uplinkChunkSize': x.uplinkChunkSize,
        if (x.uplinkHttpMethod.isNotEmpty)
          'uplinkHTTPMethod': x.uplinkHttpMethod,
        if (x.xPaddingObfsMode) 'xPaddingObfsMode': 'true',
        if (x.xPaddingKey.isNotEmpty) 'xPaddingKey': x.xPaddingKey,
        if (x.xPaddingHeader.isNotEmpty) 'xPaddingHeader': x.xPaddingHeader,
        if (x.xPaddingPlacement.isNotEmpty)
          'xPaddingPlacement': x.xPaddingPlacement,
        if (x.xPaddingMethod.isNotEmpty) 'xPaddingMethod': x.xPaddingMethod,
        if (x.scMaxEachPostBytes.isNotEmpty)
          'scMaxEachPostBytes': x.scMaxEachPostBytes,
        if (x.scMinPostsIntervalMs.isNotEmpty)
          'scMinPostsIntervalMs': x.scMinPostsIntervalMs,
      };
  }
}
