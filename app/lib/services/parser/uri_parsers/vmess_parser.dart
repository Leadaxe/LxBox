import 'dart:convert';

import '../../../models/node_spec.dart';
import '../../../models/node_warning.dart';
import '../transport.dart';
import '../uri_utils.dart';

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
  };
  final transport = parseTransport(
    q,
    networkOverride: net,
    defaultHost: server,
  );

  final tls = parseVmessTls(cfg, server, net);

  final warnings = <NodeWarning>[];
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

VmessSpec? _vmessLegacy(String s, String fragment, String rawUri) {
  final atIdx = s.indexOf('@');
  if (atIdx < 0) return null;
  final userinfo = s.substring(0, atIdx);
  final hp = s.substring(atIdx + 1).split('?').first;
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

  return VmessSpec(
    id: newUuidV4(),
    tag: tag,
    label: label,
    server: host,
    port: port,
    rawUri: rawUri,
    uuid: uuid,
    security: normalizeVmessSecurity(method),
  );
}
