import 'dart:convert';

import '../../../models/node_spec.dart';
import '../../../models/node_warning.dart';
import '../../../models/tls_spec.dart';
import '../transport.dart';
import '../uri_utils.dart';
import '../utls_fingerprint.dart';

// ════════════════════════════════════════════════════════════════════════════
// VMess (legacy JSON base64 + modern cleartext)
// ════════════════════════════════════════════════════════════════════════════

VmessSpec? parseVmess(String uri) {
  var body = uri.substring('vmess://'.length);
  var fragment = '';
  final hashIdx = body.indexOf('#');
  if (hashIdx >= 0) {
    fragment = body.substring(hashIdx + 1);
    body = body.substring(0, hashIdx);
  }

  final bytes = decodeBase64Safe(body);
  if (bytes == null || bytes.isEmpty) return null;
  final decoded = utf8Lossy(bytes).trim();
  if (decoded.isEmpty) return null;

  // Попытка распарсить как JSON (v2rayN format).
  try {
    final j = jsonDecode(decoded);
    if (j is Map<String, dynamic>) {
      return _vmessFromJson(j, uri);
    }
  } catch (_) {}

  // Fallback: legacy cleartext `method:uuid@host:port`.
  return _vmessLegacy(decoded, fragment, uri);
}

VmessSpec? _vmessFromJson(Map<String, dynamic> cfg, String rawUri) {
  final server = cfg['add']?.toString() ?? '';
  final id = cfg['id']?.toString() ?? '';
  if (server.isEmpty || id.isEmpty) return null;

  final portRaw = cfg['port'];
  final port = portRaw is num
      ? portRaw.toInt()
      : int.tryParse(portRaw?.toString() ?? '') ?? 443;

  final ps = cfg['ps']?.toString() ?? '';
  final label = sanitizeForDisplay(ps);
  final tag = tagFromLabel(label, 'vmess', server, port);

  final security = normalizeVmessSecurity(
    (cfg['scy'] ?? cfg['security'])?.toString() ?? '',
  );
  final aidRaw = cfg['aid'];
  final alterId = aidRaw is num
      ? aidRaw.toInt()
      : int.tryParse(aidRaw?.toString() ?? '') ?? 0;

  final net = (cfg['net']?.toString() ?? 'tcp').toLowerCase().trim();
  final q = <String, String>{
    if (cfg['path'] != null) 'path': cfg['path'].toString(),
    if (cfg['host'] != null) 'host': cfg['host'].toString(),
    if (cfg['sni'] != null) 'sni': cfg['sni'].toString(),
    if (cfg['serviceName'] != null)
      'serviceName': cfg['serviceName'].toString(),
    // SPEC 071/103 vmess/json_net_xhttp — net=xhttp несёт свой `mode`
    // (stream-one/stream-up/packet-up) прямо в JSON-объекте, как и
    // path/host; xhttpFromMap читает его из этого же q под ключом 'mode'.
    if (net == 'xhttp' && cfg['mode'] != null)
      'mode': cfg['mode'].toString(),
  };
  final warnings = <NodeWarning>[];
  final transport = parseTransport(
    q,
    networkOverride: net,
    defaultHost: server,
    warnings: warnings,
  );

  // §281 — fp вне словаря ядра = fatal всего конфига; канонизируем на входе.
  final tls = normalizeTlsFingerprint(parseVmessTls(cfg, server, net), warnings);

  if (tls.insecure) warnings.add(const InsecureTlsWarning());

  return VmessSpec(
    id: newUuidV4(),
    tag: tag,
    label: label,
    server: server,
    port: port,
    rawUri: rawUri,
    uuid: id,
    alterId: alterId,
    security: security,
    tls: tls,
    transport: transport,
    warnings: warnings,
  );
}

// SPEC 103 vmess/legacy_cleartext_userinfo — эталон Go
// parseVMessLegacyCleartext (core/config/subscription/node_parser_vmess.go):
// `method:uuid@host:port?type=ws&path=%2Fws&tls=1` несёт транспорт/TLS в
// query-хвосте после host:port, как обычный share-URI. Раньше этот хвост
// просто отбрасывался (`.split('?').first`) — транспорт/TLS терялись.
VmessSpec? _vmessLegacy(String s, String fragment, String rawUri) {
  final atIdx = s.indexOf('@');
  if (atIdx < 0) return null;
  final userinfo = s.substring(0, atIdx);
  final rest = s.substring(atIdx + 1);
  final qIdx = rest.indexOf('?');
  final hp = qIdx < 0 ? rest : rest.substring(0, qIdx);
  final rawQuery = qIdx < 0 ? '' : rest.substring(qIdx + 1);
  final parts = userinfo.split(':');
  if (parts.length < 2) return null;
  final method = parts[0].trim();
  final uuid = parts.sublist(1).join(':').trim();
  if (method.isEmpty || uuid.isEmpty) return null;

  final lastColon = hp.lastIndexOf(':');
  if (lastColon <= 0) return null;
  final host = hp.substring(0, lastColon);
  final port = int.tryParse(hp.substring(lastColon + 1)) ?? 443;

  final label = sanitizeForDisplay(decodeFragment(fragment));
  final tag = tagFromLabel(label, 'vmess', host, port);

  final q = rawQuery.isEmpty ? const <String, String>{} : Uri.splitQueryString(rawQuery);

  // Go: query `type=` (folded case) maps to `network`.
  final net = (q['type'] ?? '').toLowerCase().trim();
  final warnings = <NodeWarning>[];
  final transport = parseTransport(
    q,
    networkOverride: net.isEmpty ? null : net,
    warnings: warnings,
  );

  // Go: tls=1/true/tls → tls_enabled, sni fallback chain sni→peer→server.
  final tlsRaw = (q['tls'] ?? '').toLowerCase().trim();
  final tlsEnabled = tlsRaw == '1' || tlsRaw == 'true' || tlsRaw == 'tls';
  var sni = (q['sni'] ?? '').trim();
  if (sni.isEmpty) sni = (q['peer'] ?? '').trim();
  if (sni.isEmpty) sni = host;
  final fp = (q['fp'] ?? '').toLowerCase().trim();
  final tls = tlsEnabled
      ? normalizeTlsFingerprint(
          TlsSpec(
            enabled: true,
            serverName: sni,
            fingerprint: fp.isEmpty ? null : fp,
            insecure: q['insecure'] == '1' || q['insecure'] == 'true',
            alpn: alpnFromQuery(q),
          ),
          warnings,
        )
      : TlsSpec.disabled;
  if (tls.insecure) warnings.add(const InsecureTlsWarning());

  return VmessSpec(
    id: newUuidV4(),
    tag: tag,
    label: label,
    server: host,
    port: port,
    rawUri: rawUri,
    uuid: uuid,
    security: normalizeVmessSecurity(method),
    tls: tls,
    transport: transport,
    warnings: warnings,
  );
}
