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
TransportSpec? parseTransport(
  Map<String, String> q, {
  String? networkOverride,
  String? defaultHost,
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
      final (path, edFromPath) =
          splitEarlyDataPath(decodeResidualPercent(q['path'] ?? '/'));
      var host = (q['host'] ?? '').trim();
      if (host.isEmpty) host = (q['sni'] ?? '').trim();
      if (host.isEmpty) host = (q['obfsParam'] ?? '').trim();
      // §320 — вторая форма early data: плоские `ed`/`eh` (хвост пути в
      // приоритете — он адресует конкретный путь, а не ссылку целиком).
      final ed = edFromPath ?? _positiveInt(q['ed']);
      // `eh` без `ed` — не сирота, а ничто: режим early data ядро включает по
      // `max_early_data > 0`, имя заголовка без размера не значит ничего.
      final eh = ed == null ? null : _nonEmpty(q['eh']);
      return WsTransport(
        path: path,
        host: host,
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
      final (path, _) =
          splitEarlyDataPath(decodeResidualPercent(q['path'] ?? '/'));
      var host = (q['host'] ?? '').trim();
      if (host.isEmpty) host = (q['sni'] ?? '').trim();
      return HttpUpgradeTransport(path: path, host: host);
    case 'xhttp':
      // §097/§127 — нативный xhttp + расширенные поля Xray splithttp (SPEC 002
      // v2). Ключи читаем в обеих формах: camelCase (Xray URI) и snake_case
      // (sing-box). Плюс параметр `extra` (URL-encoded JSON) с доп. полями.
      return _parseXhttp(q);
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

/// §127 — разбор `type=xhttp` со всеми клиентскими полями SPEC 002 v2.
///
/// Источник полей — плоские query И параметр `extra` (URL-encoded JSON).
/// extra сливается в копию query (его ключи в приоритете для своих); битый
/// extra игнорируется — ссылка остаётся рабочей на плоских параметрах.
XhttpTransport _parseXhttp(Map<String, String> q) {
  final m = _mergeXhttpExtra(q);

  // path: срезать `?…`-хвост (реальные ноды: path=/x?ed=2048 — хвост не путь).
  // §303 — общий хелпер; early data у xhttp нет, значение отбрасываем.
  final (path, _) = splitEarlyDataPath(m['path'] ?? '/');

  var host = (m['host'] ?? '').trim();
  if (host.isEmpty) host = (m['sni'] ?? '').trim();

  // §217 — читаем поля дословно; нормализацию против правил ядра
  // (normalizeMeta, transport/v2rayxhttp/meta.go) делает XhttpTransport.toSingbox,
  // где есть канал NodeWarning для ⚠️ в подписке.
  return XhttpTransport(
    path: path,
    host: host,
    mode: (m['mode'] ?? '').trim(),
    xPaddingBytes: _pick(m, 'xPaddingBytes', 'x_padding_bytes'),
    noGrpcHeader: _truthy(m['noGRPCHeader'] ?? m['no_grpc_header']),
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

/// extra (URL-encoded JSON) → копия query со слитыми ключами. extra в приоритете
/// для своих ключей (как Xray). Битый/обрезанный extra → возвращаем исходную
/// query как есть (не роняем парсинг ссылки). extra-значения приводим к строке.
Map<String, String> _mergeXhttpExtra(Map<String, String> q) {
  final raw = q['extra'];
  if (raw == null || raw.trim().isEmpty) return q;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return q;
    final merged = Map<String, String>.from(q);
    decoded.forEach((k, v) {
      if (k is String && v != null) merged[k] = _scalarToString(v);
    });
    return merged;
  } catch (_) {
    // Битый extra — игнорируем, ссылка живёт на плоских параметрах.
    return q;
  }
}

/// JSON-скаляр → строка. `30.0` (double без дроби) → `"30"`; bool → `true`/
/// `false`; число/строка как есть.
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
    return TlsSpec(
      enabled: true,
      serverName: sni,
      fingerprint: fp,
      reality: RealitySpec(
        publicKey: pbk,
        shortId: normalizeRealityShortId(q['sid'] ?? ''),
      ),
      insecure: isTlsInsecure(q),
      alpn: _alpnFromQuery(q),
      );
  }

  if (sec == 'reality') {
    return TlsSpec(
      enabled: true,
      serverName: sni,
      fingerprint: fp,
      insecure: isTlsInsecure(q),
      alpn: _alpnFromQuery(q),
      );
  }

  if (sec.isEmpty && plaintextVlessPorts.contains(port)) return TlsSpec.disabled;

  return TlsSpec(
    enabled: true,
    serverName: sni,
    fingerprint: fp,
    insecure: isTlsInsecure(q),
    alpn: _alpnFromQuery(q),
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
    alpn: _alpnFromQuery(q),
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

List<String> _alpnFromQuery(Map<String, String> q) {
  return _normalizeAlpn(q['alpn'] ?? '');
}

/// §151 F2 — нормализация ALPN-списка из сырого query/JSON значения.
///
/// Корень бага: некоторые подписки-агрегаторы шлют `alpn=http%252F1.1`
/// (двойное percent-кодирование). `Uri.queryParameters` декодит ровно один
/// раз → остаётся `http%2F1.1`, и этот мусор уходил в `tls.alpn` ядра
/// дословно (валидный ALPN-id = `http/1.1`/`h2`/`h3`). Здесь: split по
/// запятой, повторный decode пока остаётся `%XX`, и drop значений, которые
/// после де-кода всё ещё содержат `%` / пробелы / управляющие символы
/// (не валидный protocol-id). Корректные `h2`/`http/1.1`/`h3` не меняются.
final _percentSeq = RegExp(r'%[0-9A-Fa-f]{2}');
final _badAlpnChar = RegExp(r'[%\s\x00-\x1f]');

List<String> _normalizeAlpn(String raw) {
  if (raw.isEmpty) return const [];
  final out = <String>[];
  for (var e in raw.split(',')) {
    e = e.trim();
    if (e.isEmpty) continue;
    // Снять остаточное percent-кодирование (defensive: до 2 проходов хватает
    // на двойное кодирование; больше — почти наверняка мусор, не раскручиваем).
    var guard = 0;
    while (_percentSeq.hasMatch(e) && guard < 2) {
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
        earlyDataHeaderName: final eh
      ):
      // §303 — early data возвращаем в URI тем же хвостом пути, каким она в
      // него пришла (`/x?ed=2560`), иначе round-trip её теряет.
      final withEd = ed == null ? p : '${p.isEmpty ? '/' : p}?ed=$ed';
      return {
        'type': 'ws',
        if (withEd.isNotEmpty && withEd != '/') 'path': withEd,
        if (h.isNotEmpty) 'host': h,
        // §320 — header-режим восстановим только парой с `ed` (в одиночку `eh`
        // при импорте игнорируется, вернуть его без размера = вернуть мусор).
        if (ed != null && eh != null && eh.isNotEmpty) 'eh': eh,
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
